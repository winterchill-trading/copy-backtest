(* Two minutes of hl-sim recorded by market-recorder (BTC event logs across a UTC
   midnight) and the fills of one of its simulated leaders (a mean-reversion trader with
   100,000 USD), cut with [copy-backtest slice]. *)

open! Core
open! Async
open Copy_backtest
open Hl_copy_core

let dir = "fixtures/hl-sim"

let%expect_test "the recorded fixture through three algos" =
  let fills = ok_exn (Leader_fills.load (dir ^/ "leader-fills.ndjson")) in
  let coins = Leader_fills.coins fills in
  let%bind events =
    Source.load_norm
      ~dir
      ~coins
      ~from:(Date.of_string "2026-10-15")
      ~to_:(Date.of_string "2026-10-16")
      ()
    >>| ok_exn
  in
  let specs = ok_exn (Specs.of_meta_file (dir ^/ "meta.json") ~coins) in
  printf
    "%d events, %d leader fills, coins %s\n"
    (List.length events)
    (List.length fills)
    (String.concat ~sep:"," coins);
  [%expect {| 3049 events, 275 leader fills, coins BTC |}];
  let source = Source.create ~copy_delay:(Time_ns.Span.of_int_ms 200) ~events ~fills () in
  let base =
    Params.create
      ~leader_equity:100_000.
      ~follow:
        (Follower_config.create
           ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
           ~leader:(Address.of_string "0x1eade50000000000000000000000000000000001")
           ())
      ~specs
      ()
  in
  let grid =
    { Sweep.Grid.algos = ok_exn (Sweep.Grid.parse_algos "immediate,passive:20s,adaptive")
    ; modes = [ Equity_ratio ]
    ; max_leverages = [ None ]
    ; max_notionals = [ None ]
    }
  in
  List.iter (Sweep.run grid ~base source) ~f:(fun r ->
    let s = r.summary in
    printf
      "%-20s pnl %8.2f fees %6.2f parents %3d children %3d fill %5.1f%% shortfall %6.2f \
       bps gap %7.1f bps\n"
      s.label
      s.pnl
      s.fees
      s.parents
      s.children
      (s.fill_rate *. 100.)
      s.shortfall_bps
      s.mean_gap_bps);
  [%expect
    {|
    immediate equity     pnl   -11.57 fees  13.81 parents   4 children   4 fill 100.0% shortfall   7.31 bps gap     1.5 bps
    passive:20s equity   pnl     5.49 fees   4.28 parents   4 children  14 fill  96.3% shortfall   1.82 bps gap     0.3 bps
    adaptive:20s equity  pnl   -11.57 fees  13.81 parents   4 children   4 fill 100.0% shortfall   7.31 bps gap     1.5 bps
    |}];
  return ()
;;
