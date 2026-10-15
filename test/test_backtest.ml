open! Core
open Copy_backtest
open Hl_copy_core
module Price = Market_data.Price
module Size = Market_data.Size

let synthetic = Synthetic.generate Synthetic.Config.default

let params ?(algo = Exec_algo.Immediate) ?(mode = Scale.Mode.Equity_ratio) ?caps () =
  let follow =
    Follower_config.create
      ~mode
      ?caps
      ~algo
      ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
      ~leader:synthetic.leader
      ()
  in
  Params.create
    ~start_equity:10_000.
    ~leader_equity:100_000.
    ~follow
    ~specs:(Specs.defaults [ "BTC" ])
    ()
;;

let source =
  Source.create
    ~copy_delay:(Time_ns.Span.of_int_ms 200)
    ~events:synthetic.events
    ~fills:synthetic.fills
    ()
;;

let%expect_test "synthetic data" =
  printf
    "events %d, leader fills %d\n"
    (List.length synthetic.events)
    (List.length synthetic.fills);
  [%expect {| events 43202, leader fills 119 |}]
;;

(* the summary without its float noise *)
let print (r : Backtest.t) =
  let s = r.summary in
  printf
    "%s: pnl %.2f (%.3f%%), max dd %.3f%%, fees %.2f, funding %.4f, turnover %.0f\n\
    \  parents %d (filled %d, open %d), children %d, fill %.4f, shortfall %.3f bps, \
     slippage %.3f bps, maker %.3f\n\
    \  tracking error %.3f bps, gap %.1f bps, leader %.3f%%\n"
    s.label
    s.pnl
    (s.return_ *. 100.)
    (s.max_drawdown *. 100.)
    s.fees
    s.funding
    s.turnover
    s.parents
    s.filled_parents
    s.open_parents
    s.children
    s.fill_rate
    s.shortfall_bps
    s.slippage_bps
    s.maker_share
    s.tracking_error_bps
    s.mean_gap_bps
    (s.leader_return *. 100.)
;;

let%expect_test "every algo on the synthetic hour" =
  List.iter
    Execution_algos.Algo.
      [ Immediate
      ; Twap { duration_ms = 10_000; slices = 4; max_participation = None }
      ; Pov { participation = 0.2; max_duration_ms = 30_000 }
      ; Passive { display = 1.; timeout_ms = 10_000 }
      ; iceberg
      ; adaptive
      ]
    ~f:(fun algo ->
      print (Backtest.run (params ~algo:(Copy_algo.of_algo algo) ()) source));
  [%expect
    {|
    immediate equity: pnl -625.20 (-6.252%), max dd 6.275%, fees 653.11, funding 0.1376, turnover 1451362
      parents 119 (filled 119, open 0), children 119, fill 1.0000, shortfall 4.550 bps, slippage 0.050 bps, maker 0.000
      tracking error 0.009 bps, gap 0.5 bps, leader -6.246%
    twap:10s:4 equity: pnl -637.58 (-6.376%), max dd 6.399%, fees 652.65, funding 0.1374, turnover 1450338
      parents 119 (filled 118, open 0), children 471, fill 1.0000, shortfall 4.638 bps, slippage 0.138 bps, maker 0.000
      tracking error 3.193 bps, gap 1688.3 bps, leader -6.246%
    pov:0.2:30s equity: pnl -636.92 (-6.369%), max dd 6.393%, fees 652.89, funding 0.1376, turnover 1450859
      parents 119 (filled 119, open 0), children 174, fill 1.0000, shortfall 4.632 bps, slippage 0.132 bps, maker 0.000
      tracking error 2.232 bps, gap 490.7 bps, leader -6.246%
    passive:10s equity: pnl -293.99 (-2.940%), max dd 3.018%, fees 244.03, funding 0.1395, turnover 1473862
      parents 119 (filled 119, open 0), children 394, fill 1.0000, shortfall 2.247 bps, slippage 0.591 bps, maker 0.948
      tracking error 3.168 bps, gap 1131.3 bps, leader -6.246%
    iceberg:0.25:30s equity: pnl -273.63 (-2.736%), max dd 2.843%, fees 215.83, funding 0.1402, turnover 1437264
      parents 118 (filled 29, open 1), children 2361, fill 0.9799, shortfall 2.146 bps, slippage 0.595 bps, maker 0.999
      tracking error 3.946 bps, gap 3313.1 bps, leader -6.246%
    adaptive:20s equity: pnl -625.19 (-6.252%), max dd 6.275%, fees 653.10, funding 0.1376, turnover 1451362
      parents 119 (filled 119, open 0), children 119, fill 1.0000, shortfall 4.550 bps, slippage 0.050 bps, maker 0.000
      tracking error 0.009 bps, gap 0.5 bps, leader -6.246%
    |}]
;;

let%expect_test "the same inputs give the same result" =
  let p = params ~algo:(Copy_algo.of_algo Execution_algos.Algo.adaptive) () in
  let a = Backtest.run p source in
  let b = Backtest.run p source in
  print_s [%sexp (Sexp.equal [%sexp (a : Backtest.t)] [%sexp (b : Backtest.t)] : bool)];
  [%expect {| true |}]
;;

let%expect_test "caps: leverage and daily loss" =
  let caps =
    { Caps.none with max_leverage = Some 1.; max_daily_loss = Some (Usd.of_string "200") }
  in
  print (Backtest.run (params ~caps ()) source);
  [%expect
    {|
    immediate equity lev<=1 loss<=200: pnl -212.93 (-2.129%), max dd 2.129%, fees 163.86, funding 0.0000, turnover 364127
      parents 42 (filled 42, open 0), children 42, fill 1.0000, shortfall 4.550 bps, slippage 0.050 bps, maker 0.000
      tracking error 4.433 bps, gap 0.4 bps, leader -6.246%
    |}]
;;

(* A hand-made case with a known answer: a static book, one leader buy of 1 BTC at the ask
   with 100,000 USD of equity, a follower of 10,000 USD. The leader's equity is then
   100,000 less its 45 USD fee and 1 USD below its entry at the mid (99,954), so the
   follower's target is 10,000 / 99,954 BTC = 0.10004 (lot 0.00001): one IOC at the ask,
   4.5 bp of fees, marked at the mid. *)
let%expect_test "known answer" =
  let instrument = Market_data.Instrument.of_string "hyperliquid:BTC" in
  let t0 = Time_ns.of_string_with_utc_offset "2026-10-16T00:00:00Z" in
  let at s = Time_ns.add t0 (Time_ns.Span.of_sec s) in
  let book s =
    Market_data.Event.L2
      { instrument
      ; exch_ts = at s
      ; recv_ts = at s
      ; kind = Snapshot
      ; bids = [ { price = Price.of_string "99999"; size = Size.of_string "5" } ]
      ; asks = [ { price = Price.of_string "100001"; size = Size.of_string "5" } ]
      }
  in
  let fills =
    ok_exn
      (Leader_fills.of_string
         {|[{"coin":"BTC","px":"100001","sz":"1","side":"B","time":1792108801000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0x0","oid":1,"crossed":true,"fee":"45","tid":1,"feeToken":"USDC"}]|})
  in
  let source =
    Source.create ~events:(List.map [ 0.; 1.; 2.; 30.; 60. ] ~f:book) ~fills ()
  in
  let r =
    Backtest.run
      (Params.create
         ~start_equity:10_000.
         ~leader_equity:100_000.
         ~funding:false
         ~follow:
           (Follower_config.create
              ~follower:(Address.of_string "0x00000000000000000000000000000000000000f1")
              ~leader:synthetic.leader
              ())
         ~specs:(Specs.defaults [ "BTC" ])
         ())
      source
  in
  List.iter r.parents ~f:(fun p ->
    print_s [%sexp (p.report : Execution_algos.Cost_report.t)]);
  print r;
  [%expect
    {|
    ((algo immediate) (side Buy) (target 0.10004) (filled 0.10004)
     (avg_px 100001) (arrival_px 100000) (end_px 100000)
     (arrival_ns 1792108801000000000) (end_ns 1792108801000000000) (children 1)
     (maker_filled 0) (fees 4.5018450180000009)
     (arrival_slippage_bps 0.10000000000145519) (shortfall 4.6018850180007806)
     (shortfall_bps 4.60004500000078) (outcome Filled))
    immediate equity: pnl -4.60 (-0.046%), max dd 0.046%, fees 4.50, funding 0.0000, turnover 10004
      parents 1 (filled 1, open 0), children 1, fill 1.0000, shortfall 4.600 bps, slippage 0.100 bps, maker 0.000
      tracking error 0.001 bps, gap 0.5 bps, leader -0.046%
    |}]
;;
