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
    immediate equity: pnl -625.24 (-6.252%), max dd 6.276%, fees 653.13, funding 0.1376, turnover 1451408
      parents 139 (filled 139, open 0), children 139, fill 1.0000, shortfall 4.550 bps, slippage 0.050 bps, maker 0.000
      tracking error 0.009 bps, gap 2.9 bps, leader -6.246%
    twap:10s:4 equity: pnl -640.47 (-6.405%), max dd 6.428%, fees 652.54, funding 0.1374, turnover 1450079
      parents 149 (filled 128, open 0), children 532, fill 0.9169, shortfall 4.272 bps, slippage 0.153 bps, maker 0.000
      tracking error 3.221 bps, gap 1689.6 bps, leader -6.246%
    pov:0.2:30s equity: pnl -636.96 (-6.370%), max dd 6.393%, fees 652.90, funding 0.1376, turnover 1450897
      parents 139 (filled 139, open 0), children 194, fill 1.0000, shortfall 4.632 bps, slippage 0.132 bps, maker 0.000
      tracking error 2.231 bps, gap 493.0 bps, leader -6.246%
    passive:10s equity: pnl -293.97 (-2.940%), max dd 3.018%, fees 244.03, funding 0.1395, turnover 1473860
      parents 127 (filled 125, open 0), children 426, fill 0.9835, shortfall 2.218 bps, slippage 0.579 bps, maker 0.948
      tracking error 3.168 bps, gap 1132.4 bps, leader -6.246%
    iceberg:0.25:30s equity: pnl -277.44 (-2.774%), max dd 2.876%, fees 217.78, funding 0.1402, turnover 1450222
      parents 142 (filled 27, open 0), children 2569, fill 0.8879, shortfall 1.942 bps, slippage 0.307 bps, maker 0.999
      tracking error 3.968 bps, gap 3412.7 bps, leader -6.246%
    adaptive:20s equity: pnl -625.12 (-6.251%), max dd 6.275%, fees 652.99, funding 0.1376, turnover 1451416
      parents 139 (filled 139, open 0), children 220, fill 1.0000, shortfall 4.549 bps, slippage 0.050 bps, maker 0.000
      tracking error 0.009 bps, gap 2.9 bps, leader -6.246%
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
    immediate equity lev<=1 loss<=200: pnl -212.46 (-2.125%), max dd 2.125%, fees 163.87, funding 0.0000, turnover 364150
      parents 43 (filled 43, open 0), children 43, fill 1.0000, shortfall 4.563 bps, slippage 0.063 bps, maker 0.000
      tracking error 4.434 bps, gap 28.1 bps, leader -6.246%
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
    let c = p.report in
    (* printed rounded: arm64 and amd64 differ in the last digits (fused multiply-adds) *)
    printf
      "%s %s target %s filled %s @ %s, arrival %s, fees %.6f, slippage %.6f bps, \
       shortfall %.6f (%.6f bps), %s\n"
      c.algo
      (Sexp.to_string (Market_data.Side.sexp_of_t c.side))
      (Size.to_string c.target)
      (Size.to_string c.filled)
      (Price.to_string c.avg_px)
      (Price.to_string c.arrival_px)
      c.fees
      c.arrival_slippage_bps
      c.shortfall
      c.shortfall_bps
      (Execution_algos.Cost_report.Outcome.to_string c.outcome));
  print r;
  [%expect
    {|
    immediate Buy target 0.10004 filled 0.10004 @ 100001, arrival 100000, fees 4.501845, slippage 0.100000 bps, shortfall 4.601885 (4.600045 bps), filled
    immediate equity: pnl -4.60 (-0.046%), max dd 0.046%, fees 4.50, funding 0.0000, turnover 10004
      parents 1 (filled 1, open 0), children 1, fill 1.0000, shortfall 4.600 bps, slippage 0.100 bps, maker 0.000
      tracking error 0.001 bps, gap 2.7 bps, leader -0.046%
    |}]
;;
