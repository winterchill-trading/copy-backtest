(* Three minutes of hl-sim (seed 11, three leaders, 40 noise traders) recorded by
   market-recorder while hl-copy-engine copied leader 1 with a $1,000,000 follower at
   (Multiplier 0.01), made with scripts/sim-vs-live.sh: the BTC event logs, the leader's
   fills, the follow file and the engine's journal. The backtest of the same window with
   the same follow settings, then the attribution of the live run against it. *)

open! Core
open! Async
open Copy_backtest
open Hl_copy_core

let dir = "fixtures/sim-vs-live"

let backtest () =
  let fills = ok_exn (Leader_fills.load (dir ^/ "leader-fills.json")) in
  let coins = Leader_fills.coins fills in
  let day = Date.of_string "2026-10-16" in
  let%map events = Source.load_norm ~dir ~coins ~from:day ~to_:day () >>| ok_exn in
  let specs = ok_exn (Specs.of_meta_file (dir ^/ "meta.json") ~coins) in
  let follow =
    ok_exn (Follower_config.of_file_contents (In_channel.read_all (dir ^/ "follow.sexp")))
  in
  (* the engine's settings in the script: 10 s resyncs, a few milliseconds from the
     leader's fill to the follower's order on a laptop *)
  let p =
    Params.create
      ~start_equity:1_000_000.
      ~leader_equity:100_000.
      ~copy_delay:(Time_ns.Span.of_int_ms 5)
      ~latency:(Time_ns.Span.of_int_ms 2)
      ~resync:(Time_ns.Span.of_int_sec 10)
      ~funding:false
      ~follow
      ~specs
      ()
  in
  let source = Source.create ~copy_delay:p.copy_delay ~events ~fills () in
  List.length events, List.length fills, Backtest.run p source
;;

let%expect_test "the live run against its backtest" =
  let%bind events, fills, r = backtest () in
  printf
    "%d events, %d leader fills; backtest: %d parents, fees %.2f, return %.4f%%\n"
    events
    fills
    r.summary.parents
    r.summary.fees
    (r.summary.return_ *. 100.);
  [%expect {| 5602 events, 638 leader fills; backtest: 21 parents, fees 29.79, return 0.0153% |}];
  let out = Filename_unix.temp_dir "copy-backtest-attribution" "" in
  Output.write ~dir:out [ r ];
  let backtest = ok_exn (Attribution.backtest_leg out) in
  let%bind entries = Live_journal.load (dir ^/ "journal/2026-10-16.v3.journal") >>| ok_exn in
  let live = ok_exn (Live_journal.leg entries) in
  printf
    "journal: %d entries; live: %d parents, equity %.2f -> %.2f\n"
    (List.length entries)
    (List.length live.parents)
    live.start_equity
    live.end_equity;
  [%expect {| journal: 152 entries; live: 24 parents, equity 1000000.00 -> 1000034.58 |}];
  let t = Attribution.compute ~backtest ~live in
  print_string (Attribution.to_string_hum t);
  [%expect {|
    term           backtest USD     live USD        bps
    fees                  29.79        29.67       0.00
    slippage              19.43        10.70       0.09
    timing              -136.38         0.00      -1.36  <- largest
    partial fills          0.00         0.00       0.00
    funding                0.00         0.00       0.00
    residual                                       0.09
    return: backtest 0.0153%, live 0.0035%, difference -1.18 bps; parents: backtest 21, live 24
    |}];
  (* the terms and the residual add up to the difference *)
  let sum =
    List.sum (module Float) t.terms ~f:(fun x -> x.bps) +. t.residual_bps
  in
  printf "%b\n" Float.(abs (sum -. t.difference_bps) < 1e-9);
  [%expect {| true |}];
  (* a directory reads the same as its one file *)
  let%bind from_dir = Live_journal.load (dir ^/ "journal") >>| ok_exn in
  printf "%b\n" (List.length from_dir = List.length entries);
  [%expect {| true |}];
  return ()
;;
