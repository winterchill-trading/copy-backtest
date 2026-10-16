open! Core
open! Async
open Copy_backtest
open Hl_copy_core

(* A synthetic half hour, copied with and without the default no-trade band. *)
let runs () =
  let synthetic =
    Synthetic.generate
      { Synthetic.Config.default with duration = Time_ns.Span.of_min 30. }
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
    ; bands = ok_exn (Sweep.Grid.parse_bands "none,default")
    }
  in
  base, Sweep.run grid ~base source
;;

(* Statistics from resampled or simulated numbers are printed to three decimals: the last
   digits of bootstrap and floating-point results differ between arm64 and amd64. *)
let show (rows : Stats.Row.t list) =
  List.iter rows ~f:(fun row ->
    let x = row.report in
    let f = Option.value_map ~default:"-" ~f:(sprintf "%.3f") in
    printf
      "%s %d %-32s periods %d psr %.3f dsr %s pbo %s spa %s verdict %s\n"
      (match row.scope with
       | `Run -> "run  "
       | `Sweep -> "sweep")
      row.run
      row.label
      x.periods
      x.psr
      (f x.dsr)
      (f x.pbo)
      (f
         (Option.map x.spa ~f:(fun s ->
            s.Backtest_stats.Multiple_testing.Spa.p_value_consistent)))
      (Option.value (Stats.Row.verdict row) ~default:"-"))
;;

let%expect_test "a report per run and one for the sweep's pick" =
  let base, runs = runs () in
  List.iter runs ~f:(fun r ->
    printf
      "%-32s band skips %d saved %.2f fees %.2f gap %.0f bps\n"
      r.summary.label
      r.summary.band_skips
      r.summary.band_saved
      r.summary.fees
      r.summary.mean_gap_bps);
  [%expect
    {|
    immediate equity                 band skips 0 saved 0.00 fees 328.10 gap 3 bps
    immediate equity band:ra20       band skips 35 saved 16.90 fees 309.55 gap 519 bps
    passive:5s equity                band skips 0 saved 0.00 fees 151.18 gap 583 bps
    passive:5s equity band:ra20      band skips 31 saved 15.18 fees 142.45 gap 1079 bps
    |}];
  let rows = Stats.rows ~sample:base.sample runs in
  show rows;
  [%expect
    {|
    run   0 immediate equity                 periods 181 psr 0.000 dsr 0.000 pbo - spa - verdict -
    run   1 immediate equity band:ra20       periods 181 psr 0.000 dsr 0.000 pbo - spa - verdict -
    run   2 passive:5s equity                periods 181 psr 0.000 dsr 0.000 pbo - spa - verdict -
    run   3 passive:5s equity band:ra20      periods 181 psr 0.000 dsr 0.000 pbo - spa - verdict -
    sweep 3 passive:5s equity band:ra20      periods 181 psr 0.000 dsr 0.000 pbo 0.000 spa 0.000 verdict -
    |}];
  return ()
;;

let%expect_test "the gate rejects the sweep's pick, a permissive policy accepts it" =
  let base, runs = runs () in
  let strict = Backtest_stats.Gate.Policy.default in
  let rows =
    Stats.rows ~policy:strict ~out_of_sample_fraction:0.3 ~sample:base.sample runs
  in
  (match Stats.rejected rows with
   | None -> print_endline "accepted"
   | Some row -> print_s [%sexp (Stats.Row.reasons row : string list)]);
  [%expect
    {|
    ("181 periods, at least 250 required"
     "probabilistic Sharpe ratio 0.000 below 0.950"
     "out-of-sample probabilistic Sharpe ratio 0.000 below 0.900"
     "deflated Sharpe ratio 0.000 below 0.950")
    |}];
  let rows =
    Stats.rows ~policy:Backtest_stats.Gate.Policy.permissive ~sample:base.sample runs
  in
  print_s [%sexp (Option.is_some (Stats.rejected rows) : bool)];
  [%expect {| false |}];
  (* one run alone: its own verdict *)
  let one = Stats.rows ~policy:strict ~sample:base.sample [ List.hd_exn runs ] in
  show one;
  [%expect
    {| run   0 immediate equity                 periods 181 psr 0.000 dsr - pbo - spa - verdict reject |}];
  return ()
;;

let%expect_test "stats are written next to the results and DuckDB reads them" =
  let base, runs = runs () in
  let stats = Stats.rows ~sample:base.sample runs in
  let dir = Filename_unix.temp_dir "copy-backtest-stats" "" in
  Output.write ~stats ~dir runs;
  let%bind out =
    Process.run_exn
      ~prog:"duckdb"
      ~args:
        [ "-csv"
        ; "-c"
        ; sprintf
            "select scope, count(*) as n, count(dsr) as dsr, count(pbo) as pbo from \
             '%s/stats.parquet' group by scope order by scope"
            dir
        ]
      ()
  in
  print_string out;
  [%expect {|
    scope,n,dsr,pbo
    run,4,4,0
    sweep,1,1,1
    |}];
  let md = In_channel.read_all (dir ^/ "summary.md") in
  print_endline (List.hd_exn (String.split_lines md));
  [%expect
    {| | Run | Label | Return | Max drawdown | Fees | Parents | Fill rate | Shortfall (bps) | Tracking error (bps) | Mean gap (bps) | Band skips | Band saved | PSR | DSR | |}];
  return ()
;;
