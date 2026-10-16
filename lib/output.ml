open! Core
open! Async
module Summary = Backtest.Summary
module Cost_report = Execution_algos.Cost_report
module Price = Market_data.Price
module Size = Market_data.Size

let summary_schema =
  Parquet.Schema.create
    Parquet.Schema.Column.
      [ int32 "run" fst
      ; utf8 "label" (fun (_, (s : Summary.t)) -> s.label)
      ; dictionary (utf8 "algo" (fun (_, (s : Summary.t)) -> s.algo))
      ; dictionary (utf8 "mode" (fun (_, (s : Summary.t)) -> s.mode))
      ; optional float "max_leverage" (fun (_, (s : Summary.t)) -> s.max_leverage)
      ; float "start_equity" (fun (_, (s : Summary.t)) -> s.start_equity)
      ; float "end_equity" (fun (_, (s : Summary.t)) -> s.end_equity)
      ; float "pnl" (fun (_, (s : Summary.t)) -> s.pnl)
      ; float "return" (fun (_, (s : Summary.t)) -> s.return_)
      ; float "max_drawdown" (fun (_, (s : Summary.t)) -> s.max_drawdown)
      ; float "fees" (fun (_, (s : Summary.t)) -> s.fees)
      ; float "funding" (fun (_, (s : Summary.t)) -> s.funding)
      ; float "turnover" (fun (_, (s : Summary.t)) -> s.turnover)
      ; int32 "leader_changes" (fun (_, (s : Summary.t)) -> s.leader_changes)
      ; int32 "parents" (fun (_, (s : Summary.t)) -> s.parents)
      ; int32 "filled_parents" (fun (_, (s : Summary.t)) -> s.filled_parents)
      ; int32 "open_parents" (fun (_, (s : Summary.t)) -> s.open_parents)
      ; int32 "children" (fun (_, (s : Summary.t)) -> s.children)
      ; float "fill_rate" (fun (_, (s : Summary.t)) -> s.fill_rate)
      ; float "shortfall" (fun (_, (s : Summary.t)) -> s.shortfall)
      ; float "shortfall_bps" (fun (_, (s : Summary.t)) -> s.shortfall_bps)
      ; float "slippage_bps" (fun (_, (s : Summary.t)) -> s.slippage_bps)
      ; float "maker_share" (fun (_, (s : Summary.t)) -> s.maker_share)
      ; float "tracking_error_bps" (fun (_, (s : Summary.t)) -> s.tracking_error_bps)
      ; float "mean_gap_bps" (fun (_, (s : Summary.t)) -> s.mean_gap_bps)
      ; float "leader_return" (fun (_, (s : Summary.t)) -> s.leader_return)
      ; int32 "band_skips" (fun (_, (s : Summary.t)) -> s.band_skips)
      ; float "band_saved" (fun (_, (s : Summary.t)) -> s.band_saved)
      ]
;;

let curve_schema =
  Parquet.Schema.create
    Parquet.Schema.Column.
      [ int32 "run" fst
      ; timestamp_ns "time" (fun (_, (p : Backtest.Point.t)) ->
          Time_ns.of_int_ns_since_epoch p.time_ns)
      ; float "equity" (fun (_, (p : Backtest.Point.t)) -> p.equity)
      ; float "leader_equity" (fun (_, (p : Backtest.Point.t)) -> p.leader_equity)
      ; float "gap_bps" (fun (_, (p : Backtest.Point.t)) -> p.gap_bps)
      ]
;;

let parents_schema =
  let r f (_, (p : Backtest.Parent.t)) = f p.report in
  Parquet.Schema.create
    Parquet.Schema.Column.
      [ int32 "run" fst
      ; dictionary (utf8 "coin" (fun (_, (p : Backtest.Parent.t)) -> p.coin))
      ; float "decision_px" (fun (_, (p : Backtest.Parent.t)) -> p.decision_px)
      ; dictionary (utf8 "algo" (r (fun x -> x.Cost_report.algo)))
      ; dictionary
          (utf8
             "side"
             (r (fun x -> if Market_data.Side.is_buy x.side then "buy" else "sell")))
      ; float "target" (r (fun x -> Size.to_float x.target))
      ; float "filled" (r (fun x -> Size.to_float x.filled))
      ; float "avg_px" (r (fun x -> Price.to_float x.avg_px))
      ; float "arrival_px" (r (fun x -> Price.to_float x.arrival_px))
      ; float "end_px" (r (fun x -> Price.to_float x.end_px))
      ; timestamp_ns "arrival" (r (fun x -> Time_ns.of_int_ns_since_epoch x.arrival_ns))
      ; timestamp_ns "end" (r (fun x -> Time_ns.of_int_ns_since_epoch x.end_ns))
      ; int32 "children" (r (fun x -> x.children))
      ; float "maker_filled" (r (fun x -> Size.to_float x.maker_filled))
      ; float "fees" (r (fun x -> x.fees))
      ; float "arrival_slippage_bps" (r (fun x -> x.arrival_slippage_bps))
      ; float "shortfall" (r (fun x -> x.shortfall))
      ; float "shortfall_bps" (r (fun x -> x.shortfall_bps))
      ; dictionary (utf8 "outcome" (r (fun x -> Cost_report.Outcome.to_string x.outcome)))
      ]
;;

let write ~dir runs =
  Core_unix.mkdir_p dir;
  let indexed = List.mapi runs ~f:(fun i (r : Backtest.t) -> i, r) in
  Parquet.Writer.with_file
    ~schema:summary_schema
    ~compression:`Zstd
    (dir ^/ "summary.parquet")
    ~f:(fun w -> List.iter indexed ~f:(fun (i, r) -> Parquet.Writer.add w (i, r.summary)));
  Parquet.Writer.with_file
    ~schema:curve_schema
    ~compression:`Zstd
    (dir ^/ "curve.parquet")
    ~f:(fun w ->
      List.iter indexed ~f:(fun (i, r) ->
        List.iter r.curve ~f:(fun p -> Parquet.Writer.add w (i, p))));
  Parquet.Writer.with_file
    ~schema:parents_schema
    ~compression:`Zstd
    (dir ^/ "parents.parquet")
    ~f:(fun w ->
      List.iter indexed ~f:(fun (i, r) ->
        List.iter r.parents ~f:(fun p -> Parquet.Writer.add w (i, p))))
;;

(* Per run, recomputed from the parents and the curve. The drawdown is the largest fall
   from the running peak, as {!Backtest} computes it. *)
let query dir =
  sprintf
    {|
with p as (
  select run, count(*) as parents, sum(shortfall) as shortfall, sum(fees) as fees
  from '%s/parents.parquet' group by run),
c as (
  select run, time, equity,
    max(equity) over (partition by run order by time
                      rows between unbounded preceding and current row) as peak
  from '%s/curve.parquet'),
d as (
  select run, max((peak - equity) / peak) as max_drawdown, arg_max(equity, time) as end_equity
  from c group by run)
select s.run, coalesce(p.parents, 0) as parents, coalesce(p.shortfall, 0) as shortfall,
  coalesce(p.fees, 0) as parent_fees, d.end_equity, d.max_drawdown
from '%s/summary.parquet' s left join p using (run) left join d using (run)
order by s.run
|}
    dir
    dir
    dir
;;

let close a b = Float.(abs (a - b) <= 1e-9 * Float.max 1. (Float.max (abs a) (abs b)))

let check_duckdb ~dir runs =
  match%bind Process.run ~prog:"duckdb" ~args:[ "-json"; "-c"; query dir ] () with
  | Error err -> return (Error (Error.tag err ~tag:"duckdb"))
  | Ok out ->
    return
      (Or_error.try_with_join (fun () ->
         let rows =
           match Yojson.Safe.from_string out with
           | `List rows -> rows
           | _ -> []
         in
         let num j k =
           match Yojson.Safe.Util.member k j with
           | `Int i -> Float.of_int i
           | `Float f -> f
           | `Intlit s | `String s -> Float.of_string s
           | `Null -> 0.
           | _ -> raise_s [%message "not a number" k]
         in
         if List.length rows <> List.length runs
         then Or_error.error_s [%message "run count differs" (List.length rows : int)]
         else
           List.zip_exn rows runs
           |> List.map ~f:(fun (row, (r : Backtest.t)) ->
             let fees = List.sum (module Float) r.parents ~f:(fun p -> p.report.fees) in
             let checks =
               [ "parents", Float.of_int r.summary.parents, num row "parents"
               ; "shortfall", r.summary.shortfall, num row "shortfall"
               ; "parent fees", fees, num row "parent_fees"
               ; "end equity", r.summary.end_equity, num row "end_equity"
               ; "max drawdown", r.summary.max_drawdown, num row "max_drawdown"
               ]
             in
             match List.find checks ~f:(fun (_, a, b) -> not (close a b)) with
             | Some (name, ours, duckdb) ->
               Or_error.error_s
                 [%message
                   "duckdb disagrees"
                     ~run:(num row "run" : float)
                     name
                     (ours : float)
                     (duckdb : float)]
             | None ->
               Ok
                 (sprintf
                    "run %d: parents %d, shortfall %.2f, fees %.2f, end equity %.2f, \
                     drawdown %.4f%% agree"
                    (Float.to_int (num row "run"))
                    r.summary.parents
                    r.summary.shortfall
                    fees
                    r.summary.end_equity
                    (r.summary.max_drawdown *. 100.)))
           |> Or_error.all))
;;

let table runs =
  let header =
    sprintf
      "%-3s %-34s %9s %8s %7s %8s %7s %8s %6s %7s %8s %8s %8s %8s"
      "run"
      "label"
      "pnl"
      "return"
      "max_dd"
      "fees"
      "funding"
      "parents"
      "kids"
      "fill"
      "short_bp"
      "slip_bp"
      "te_bp"
      "gap_bp"
  in
  let rows =
    List.mapi runs ~f:(fun i (r : Backtest.t) ->
      let s = r.summary in
      sprintf
        "%-3d %-34s %9.2f %7.3f%% %6.2f%% %8.2f %7.2f %8d %6d %6.1f%% %8.2f %8.2f %8.2f \
         %8.1f"
        i
        (String.prefix s.label 34)
        s.pnl
        (s.return_ *. 100.)
        (s.max_drawdown *. 100.)
        s.fees
        s.funding
        s.parents
        s.children
        (s.fill_rate *. 100.)
        s.shortfall_bps
        s.slippage_bps
        s.tracking_error_bps
        s.mean_gap_bps)
  in
  String.concat ~sep:"\n" (header :: rows) ^ "\n"
;;
