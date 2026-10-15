open! Core
open! Async
open Copy_backtest
open Hl_copy_core

let follower = Address.of_string "0x00000000000000000000000000000000000000f1"
let default_leader = Address.of_string "0x00000000000000000000000000000000000000a1"

(* {2 Data} *)

let data_flags =
  let open Command.Let_syntax in
  let%map_open leader_fills =
    flag "-leader-fills" (optional string) ~doc:"FILE the leader's userFills (JSON or NDJSON)"
  and norm = flag "-norm" (optional string) ~doc:"DIR recorder data directory (norm event logs)"
  and synthetic =
    flag "-synthetic" (optional int) ~doc:"SEED a synthetic market and leader instead"
  and synthetic_hours =
    flag "-synthetic-hours" (optional_with_default 1. float) ~doc:"H synthetic length (1)"
  and from = flag "-from" (optional date) ~doc:"DATE first UTC day (default: first fill)"
  and to_ = flag "-to" (optional date) ~doc:"DATE last UTC day (default: last fill)"
  and coins =
    flag "-coins" (optional (Arg_type.comma_separated string)) ~doc:"C,.. coins (default all)"
  and meta = flag "-meta" (optional string) ~doc:"FILE saved meta response for size decimals"
  and copy_delay_ms =
    flag "-copy-delay-ms" (optional_with_default 200 int) ~doc:"MS leader fill to engine (200)"
  in
  let copy_delay = Time_ns.Span.of_int_ms copy_delay_ms in
  fun () ->
    match synthetic, leader_fills, norm with
    | Some seed, _, _ ->
      let t =
        Synthetic.generate
          { Synthetic.Config.default with
            seed
          ; duration = Time_ns.Span.of_sec (synthetic_hours *. 3600.)
          }
      in
      Deferred.return
        (Ok
           ( Source.create ~copy_delay ~events:t.events ~fills:t.fills ()
           , Specs.defaults [ Synthetic.Config.default.coin ]
           , t.leader ))
    | None, Some fills_file, Some dir ->
      let open Deferred.Or_error.Let_syntax in
      let%bind fills = Deferred.return (Leader_fills.load fills_file) in
      let fills = Leader_fills.select ?coins fills in
      let day ms =
        Time_ns.to_date
          (Time_ns.of_int_ns_since_epoch (ms * 1_000_000))
          ~zone:Time_float.Zone.utc
      in
      let%bind first, last =
        match fills with
        | [] -> Deferred.Or_error.error_string "no leader fills selected"
        | f :: _ -> Deferred.Or_error.return (f.time, (List.last_exn fills).time)
      in
      let from = Option.value from ~default:(day first) in
      let to_ = Option.value to_ ~default:(day last) in
      let in_days =
        Leader_fills.select
          ~from:(Time_ns.of_date_ofday ~zone:Time_float.Zone.utc from Time_ns.Ofday.start_of_day)
          ~to_:
            (Time_ns.of_date_ofday
               ~zone:Time_float.Zone.utc
               (Date.add_days to_ 1)
               Time_ns.Ofday.start_of_day)
          fills
      in
      let coins = Leader_fills.coins in_days in
      let%bind events = Source.load_norm ~dir ~coins ~from ~to_ () in
      let%map specs =
        match meta with
        | None -> Deferred.Or_error.return (Specs.defaults coins)
        | Some path -> Deferred.return (Specs.of_meta_file path ~coins)
      in
      Source.create ~copy_delay ~events ~fills:in_days (), specs, default_leader
    | None, _, _ ->
      Deferred.Or_error.error_string
        "give -leader-fills FILE -norm DIR, or -synthetic SEED"
;;

(* {2 Run settings} *)

let usd_flag name ~doc =
  Command.Param.flag name (Command.Param.optional Command.Param.float) ~doc
;;

let params_flags =
  let open Command.Let_syntax in
  let%map_open config = flag "-config" (optional string) ~doc:"FILE follow file (sexp)"
  and algo =
    flag
      "-algo"
      (optional Execution_algos.Algo.arg_type)
      ~doc:"ALGO immediate, twap[:D[:N]], vwap, pov[:R[:D]], passive[:T], iceberg, adaptive"
  and mode = flag "-mode" (optional string) ~doc:"MODE equity, mult:K or fixed:USD"
  and max_leverage = usd_flag "-max-leverage" ~doc:"X account leverage cap"
  and max_notional = usd_flag "-max-notional" ~doc:"USD notional cap per coin"
  and max_daily_loss = usd_flag "-max-daily-loss" ~doc:"USD daily loss cap"
  and slippage_bps = flag "-slippage-bps" (optional int) ~doc:"BPS IOC bound (20)"
  and equity = flag "-equity" (optional_with_default 10_000. float) ~doc:"USD follower (10000)"
  and leader_equity =
    flag "-leader-equity" (optional_with_default 1_000_000. float) ~doc:"USD leader at start"
  and latency_ms = flag "-latency-ms" (optional_with_default 50 int) ~doc:"MS order latency"
  and tick_ms = flag "-tick-ms" (optional_with_default 500 int) ~doc:"MS algo ticks (500)"
  and sample_s = flag "-sample-s" (optional_with_default 10 int) ~doc:"S curve spacing (10)"
  and taker = flag "-taker-fee-bps" (optional_with_default 4.5 float) ~doc:"BPS (4.5)"
  and maker = flag "-maker-fee-bps" (optional_with_default 1.5 float) ~doc:"BPS (1.5)"
  and no_funding = flag "-no-funding" no_arg ~doc:" ignore funding" in
  fun ~leader ~specs ->
    let open Or_error.Let_syntax in
    let%bind base =
      match config with
      | Some path ->
        let%map c = Follower_config.of_file_contents (In_channel.read_all path) in
        { c with follower; leader }
      | None -> Ok (Follower_config.create ~follower ~leader ())
    in
    let%bind mode =
      match mode with
      | None -> Ok base.mode
      | Some m ->
        let%map modes = Sweep.Grid.parse_modes m in
        List.hd_exn modes
    in
    let usd x = (Usd.of_float [@alert "-lossy"]) x in
    let caps =
      { base.caps with
        max_leverage = Option.first_some max_leverage base.caps.max_leverage
      ; max_notional_per_symbol =
          Option.first_some (Option.map max_notional ~f:usd) base.caps.max_notional_per_symbol
      ; max_daily_loss =
          Option.first_some (Option.map max_daily_loss ~f:usd) base.caps.max_daily_loss
      }
    in
    let follow =
      { base with
        mode
      ; caps
      ; slippage_bps = Option.value slippage_bps ~default:base.slippage_bps
      ; algo = Option.value_map algo ~default:base.algo ~f:Copy_algo.of_algo
      }
    in
    let%map () = Follower_config.validate follow in
    Params.create
      ~start_equity:equity
      ~leader_equity
      ~latency:(Time_ns.Span.of_int_ms latency_ms)
      ~tick:(Time_ns.Span.of_int_ms tick_ms)
      ~sample:(Time_ns.Span.of_int_sec sample_s)
      ~taker_fee_bps:taker
      ~maker_fee_bps:maker
      ~funding:(not no_funding)
      ~follow
      ~specs
      ()
;;

let finish ~out ~no_duckdb runs =
  print_string (Output.table runs);
  match out with
  | None -> return ()
  | Some dir ->
    Output.write ~dir runs;
    printf "wrote %s/{summary,curve,parents}.parquet\n" dir;
    if no_duckdb
    then return ()
    else (
      match%map Output.check_duckdb ~dir runs with
      | Ok lines -> List.iter lines ~f:(fun l -> print_endline ("duckdb check: " ^ l))
      | Error err -> Print.eprint_s [%message "duckdb check failed" (err : Error.t)])
;;

let out_flags =
  let open Command.Let_syntax in
  let%map_open out = flag "-out" (optional string) ~doc:"DIR write Parquet results here"
  and no_duckdb = flag "-no-duckdb" no_arg ~doc:" skip the DuckDB check of -out" in
  out, no_duckdb
;;

let run_command =
  Command.async_or_error
    ~summary:"Backtest one follow configuration"
    (let%map_open.Command data = data_flags
     and params = params_flags
     and out, no_duckdb = out_flags in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       let%bind source, specs, leader = data () in
       let%bind p = Deferred.return (params ~leader ~specs) in
       let r = Backtest.run p source in
       Deferred.ok (finish ~out ~no_duckdb [ r ]))
;;

let sweep_command =
  Command.async_or_error
    ~summary:"Backtest every combination of algos, modes and caps"
    (let%map_open.Command data = data_flags
     and params = params_flags
     and out, no_duckdb = out_flags
     and algos =
       flag
         "-algos"
         (optional_with_default "immediate,twap,adaptive" string)
         ~doc:"A,.. algos (immediate,twap,adaptive)"
     and modes = flag "-modes" (optional_with_default "equity" string) ~doc:"M,.. modes"
     and leverages =
       flag "-max-leverages" (optional_with_default "none" string) ~doc:"X,.. or none"
     and notionals =
       flag "-max-notionals" (optional_with_default "none" string) ~doc:"USD,.. or none"
     in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       let%bind source, specs, leader = data () in
       let%bind base = Deferred.return (params ~leader ~specs) in
       let%bind grid =
         Deferred.return
           (let open Or_error.Let_syntax in
            let%map algos = Sweep.Grid.parse_algos algos
            and modes = Sweep.Grid.parse_modes modes
            and max_leverages = Sweep.Grid.parse_caps leverages
            and notionals = Sweep.Grid.parse_caps notionals in
            { Sweep.Grid.algos
            ; modes
            ; max_leverages
            ; max_notionals =
                List.map notionals ~f:(Option.map ~f:(Usd.of_float [@alert "-lossy"]))
            })
       in
       Deferred.ok (finish ~out ~no_duckdb (Sweep.run grid ~base source)))
;;

let synthetic_command =
  Command.async
    ~summary:"Write a synthetic market (event logs) and leader (fills) to a directory"
    (let%map_open.Command seed = flag "-seed" (optional_with_default 1 int) ~doc:"N seed"
     and hours = flag "-hours" (optional_with_default 1. float) ~doc:"H length"
     and out = flag "-out" (required string) ~doc:"DIR" in
     fun () ->
       let t =
         Synthetic.generate
           { Synthetic.Config.default with
             seed
           ; duration = Time_ns.Span.of_sec (hours *. 3600.)
           }
       in
       let%map () = Synthetic.write ~dir:out t in
       printf
         "%d events, %d leader fills in %s\n"
         (List.length t.events)
         (List.length t.fills)
         out)
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"Copy-trading backtests on recorded or synthetic data"
       [ "run", run_command; "sweep", sweep_command; "synthetic", synthetic_command ])
;;
