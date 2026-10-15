open! Core
open Copy_backtest

let fill ~tid ~time ~side ~sz ~start =
  sprintf
    {|{"coin":"BTC","px":"100000","sz":"%s","side":"%s","time":%d,"startPosition":"%s","dir":"Open Long","closedPnl":"0","hash":"0x0","oid":%d,"crossed":true,"fee":"0.45","tid":%d,"feeToken":"USDC"}|}
    sz
    side
    time
    start
    tid
    tid
;;

let a = fill ~tid:2 ~time:2000 ~side:"B" ~sz:"0.01" ~start:"0"
let b = fill ~tid:1 ~time:1000 ~side:"A" ~sz:"0.02" ~start:"0.05"

let show s =
  match Leader_fills.of_string s with
  | Error e -> print_s [%sexp (e : Error.t)]
  | Ok fills ->
    List.iter fills ~f:(fun (f : Hl_protocol.User_fill.t) ->
      printf
        "tid %d time %d %s -> position %s\n"
        f.tid
        f.time
        (Market_data.Size.to_string f.sz)
        (Market_data.Size.to_string (Leader_fills.position_after f)))
;;

let%expect_test "an array, NDJSON and raw pages; sorted by time, deduplicated" =
  show (sprintf "[%s,%s]" a b);
  [%expect
    {|
    tid 1 time 1000 0.02 -> position 0.03
    tid 2 time 2000 0.01 -> position 0.01
    |}];
  show (sprintf "%s\n%s\n%s\n" a b a);
  [%expect
    {|
    tid 1 time 1000 0.02 -> position 0.03
    tid 2 time 2000 0.01 -> position 0.01
    |}];
  show
    (sprintf
       "2026-10-13T07:32:16Z [%s]\n\
        2026-10-13T07:33:16Z [%s,%s]\n\
        2026-10-13T07:34:16Z []\n"
       a
       a
       b);
  [%expect
    {|
    tid 1 time 1000 0.02 -> position 0.03
    tid 2 time 2000 0.01 -> position 0.01
    |}];
  show "not json";
  [%expect
    {| ("Yojson__Common.Json_error(\"Line 1, bytes 0-8:\\nInvalid token 'not json'\")") |}]
;;

let%expect_test "select by coin and time" =
  let fills = ok_exn (Leader_fills.of_string (sprintf "[%s,%s]" a b)) in
  let at ms = Time_ns.of_int_ns_since_epoch (ms * 1_000_000) in
  print_s
    [%sexp
      (List.map (Leader_fills.select ~from:(at 1500) fills) ~f:(fun f -> f.tid)
       : int list)];
  print_s
    [%sexp
      (List.map (Leader_fills.select ~coins:[ "ETH" ] fills) ~f:(fun f -> f.tid)
       : int list)];
  print_s [%sexp (Leader_fills.coins fills : string list)];
  [%expect {|
    (2)
    ()
    (BTC)
    |}]
;;
