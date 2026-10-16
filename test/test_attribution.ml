open! Core
open Copy_backtest
module Price = Market_data.Price
module Size = Market_data.Size

let report ?(fees = 0.) ~side ~target ~filled ~avg ~arrival ~end_ () =
  { Execution_algos.Cost_report.algo = "immediate"
  ; side
  ; target = Size.of_string target
  ; filled = Size.of_string filled
  ; avg_px = Price.of_string avg
  ; arrival_px = Price.of_string arrival
  ; end_px = Price.of_string end_
  ; arrival_ns = 0
  ; end_ns = 0
  ; children = 1
  ; maker_filled = Size.zero
  ; fees
  ; arrival_slippage_bps = 0.
  ; shortfall = 0.
  ; shortfall_bps = 0.
  ; outcome = Filled
  }
;;

let leg ?(funding = 0.) ~start ~end_ parents =
  { Attribution.Leg.start_equity = start
  ; end_equity = end_
  ; start_ns = 0
  ; end_ns = 0
  ; funding
  ; parents
  }
;;

(* The backtest buys 1 BTC at 100,000 with no cost and the price ends at 101,000: +1,000
   on 100,000. Live buys the same with each cost added on purpose, so its return is the
   backtest's minus exactly those costs: every term comes back and nothing is left. *)
let%expect_test "known components are recovered and nothing is left over" =
  let backtest =
    leg
      ~start:100_000.
      ~end_:101_000.
      [ { coin = "BTC"
        ; decision_px = 100_000.
        ; report =
            report
              ~side:Buy
              ~target:"1"
              ~filled:"1"
              ~avg:"100000"
              ~arrival:"100000"
              ~end_:"101000"
              ()
        }
      ]
  in
  (* timing: arrives at 100,020 (20 USD); slippage: fills 0.9 at 100,030 (9 USD); partial
     fills: misses 0.1 of the move from 100,020 to 101,000 (98 USD); fees 45; funding 7 *)
  let live_pnl = (0.9 *. (101_000. -. 100_030.)) -. 45. -. 7. in
  let live =
    leg
      ~funding:7.
      ~start:100_000.
      ~end_:(100_000. +. live_pnl)
      [ { coin = "BTC"
        ; decision_px = 100_000.
        ; report =
            report
              ~fees:45.
              ~side:Buy
              ~target:"1"
              ~filled:"0.9"
              ~avg:"100030"
              ~arrival:"100020"
              ~end_:"101000"
              ()
        }
      ]
  in
  let t = Attribution.compute ~backtest ~live in
  print_string (Attribution.to_string_hum t);
  [%expect
    {|
    term           backtest USD     live USD        bps
    fees                   0.00        45.00      -4.50
    slippage               0.00         9.00      -0.90
    timing                 0.00        20.00      -2.00
    partial fills          0.00        98.00      -9.80  <- largest
    funding                0.00         7.00      -0.70
    residual                                       0.00
    return: backtest 1.0000%, live 0.8210%, difference -17.90 bps; parents: backtest 1, live 1
    |}];
  printf "residual %.9f\n" t.residual_bps;
  [%expect {| residual 0.000000000 |}]
;;

let%expect_test "sells count with the opposite sign" =
  let p ~avg ~arrival ~decision =
    { Attribution.Parent.coin = "ETH"
    ; decision_px = decision
    ; report = report ~side:Sell ~target:"2" ~filled:"2" ~avg ~arrival ~end_:arrival ()
    }
  in
  let backtest =
    leg ~start:10_000. ~end_:10_000. [ p ~avg:"4000" ~arrival:"4000" ~decision:4000. ]
  in
  (* selling 4 lower than the arrival (8 USD), which was 2 under the leader's price (4
     USD): live ends 12 USD down *)
  let live =
    leg ~start:10_000. ~end_:9_988. [ p ~avg:"3994" ~arrival:"3998" ~decision:4000. ]
  in
  let t = Attribution.compute ~backtest ~live in
  print_string (Attribution.to_string_hum t);
  [%expect
    {|
    term           backtest USD     live USD        bps
    fees                   0.00         0.00       0.00
    slippage               0.00         8.00      -8.00  <- largest
    timing                 0.00         4.00      -4.00
    partial fills          0.00         0.00       0.00
    funding                0.00         0.00       0.00
    residual                                       0.00
    return: backtest 0.0000%, live -0.1200%, difference -12.00 bps; parents: backtest 1, live 1
    |}]
;;
