open! Core
open! Async
open Copy_backtest
open Hl_copy_core

(* Two short synthetic runs written to Parquet and read back with the DuckDB CLI (CI
   installs it). *)
let%expect_test "parquet results agree with DuckDB" =
  let synthetic =
    Synthetic.generate
      { Synthetic.Config.default with duration = Time_ns.Span.of_min 10. }
  in
  let source = Source.create ~events:synthetic.events ~fills:synthetic.fills () in
  let base =
    Params.create
      ~leader_equity:100_000.
      ~follow:
        (Follower_config.create
           ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
           ~leader:synthetic.leader
           ())
      ~specs:(Specs.defaults [ "BTC" ])
      ()
  in
  let grid =
    { Sweep.Grid.algos = ok_exn (Sweep.Grid.parse_algos "immediate,passive:5s")
    ; modes = ok_exn (Sweep.Grid.parse_modes "equity")
    ; max_leverages = [ None ]
    ; max_notionals = [ None ]
    }
  in
  let runs = Sweep.run grid ~base source in
  let dir = Filename_unix.temp_dir "copy-backtest" "" in
  Output.write ~dir runs;
  let%bind checks = Output.check_duckdb ~dir runs in
  List.iter (ok_exn checks) ~f:print_endline;
  [%expect
    {|
    run 0: parents 21, shortfall 96.26, fees 95.20, end equity 9851.27, drawdown 1.4873% agree
    run 1: parents 21, shortfall 55.48, fees 41.55, end equity 9891.95, drawdown 1.0805% agree
    |}];
  (* a tampered summary is caught *)
  let tampered =
    List.map runs ~f:(fun r ->
      { r with summary = { r.summary with shortfall = r.summary.shortfall +. 1. } })
  in
  let%bind bad = Output.check_duckdb ~dir tampered in
  print_s [%sexp (Result.is_error bad : bool)];
  [%expect {| true |}];
  return ()
;;

let%expect_test "sweep grid" =
  let grid =
    { Sweep.Grid.algos = ok_exn (Sweep.Grid.parse_algos "immediate,twap:30s:3,adaptive")
    ; modes = ok_exn (Sweep.Grid.parse_modes "equity,mult:0.5")
    ; max_leverages = ok_exn (Sweep.Grid.parse_caps "none,3")
    ; max_notionals = [ None ]
    }
  in
  let base =
    Params.create
      ~follow:
        (Follower_config.create
           ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
           ~leader:(Address.of_string "0x00000000000000000000000000000000000000a1")
           ())
      ~specs:(Specs.defaults [ "BTC" ])
      ()
  in
  List.iter (Sweep.params grid ~base) ~f:(fun p -> print_endline (Params.label p));
  print_s [%sexp (Sweep.Grid.parse_modes "equity,bogus" : Scale.Mode.t list Or_error.t)];
  [%expect
    {|
    immediate equity
    immediate equity lev<=3
    immediate mult:0.5
    immediate mult:0.5 lev<=3
    twap:30s:3 equity
    twap:30s:3 equity lev<=3
    twap:30s:3 mult:0.5
    twap:30s:3 mult:0.5 lev<=3
    adaptive:20s equity
    adaptive:20s equity lev<=3
    adaptive:20s mult:0.5
    adaptive:20s mult:0.5 lev<=3
    (Error ("unknown mode (equity, mult:K, fixed:USD)" bogus))
    |}];
  return ()
;;
