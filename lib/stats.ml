open! Core
module Report = Backtest_stats.Report
module Gate = Backtest_stats.Gate

module Row = struct
  type t =
    { scope : [ `Run | `Sweep ]
    ; run : int
    ; label : string
    ; report : Report.t
    }
  [@@deriving sexp_of]

  let verdict t =
    Option.map t.report.verdict ~f:(function
      | Gate.Verdict.Accept -> "accept"
      | Reject _ -> "reject")
  ;;

  let reasons t =
    match t.report.verdict with
    | None | Some Accept -> []
    | Some (Reject reasons) -> List.map reasons ~f:Gate.Reason.to_string_hum
  ;;
end

let ratios values =
  let a = Array.of_list values in
  Array.init
    (Int.max 0 (Array.length a - 1))
    ~f:(fun i -> if Float.(a.(i) > 0.) then (a.(i + 1) /. a.(i)) -. 1. else 0.)
;;

let returns (r : Backtest.t) = ratios (List.map r.curve ~f:(fun p -> p.equity))

let leader_returns (r : Backtest.t) =
  ratios (List.map r.curve ~f:(fun p -> p.leader_equity))
;;

let periods_per_year sample =
  Time_ns.Span.to_sec (Time_ns.Span.of_day 365.) /. Time_ns.Span.to_sec sample
;;

let series ~sample ~start returns =
  Backtest_stats.Series.of_returns
    ~start
    ~step:sample
    (* a sample that lost everything would be -1, which a series refuses *)
    (Array.map returns ~f:(fun r -> Float.max r (-0.999999)))
;;

let per_period_sharpe r =
  let n = Array.length r in
  if n < 2
  then 0.
  else (
    let mean = Array.sum (module Float) r ~f:Fn.id /. Float.of_int n in
    let var =
      Array.sum (module Float) r ~f:(fun x -> (x -. mean) ** 2.) /. Float.of_int (n - 1)
    in
    if Float.(var <= 0.) then 0. else mean /. Float.sqrt var)
;;

let variance xs =
  let n = Array.length xs in
  if n < 2
  then 0.
  else (
    let mean = Array.sum (module Float) xs ~f:Fn.id /. Float.of_int n in
    Array.sum (module Float) xs ~f:(fun x -> (x -. mean) ** 2.) /. Float.of_int (n - 1))
;;

let start_of (r : Backtest.t) =
  match r.curve with
  | p :: _ -> Time_ns.of_int_ns_since_epoch p.time_ns
  | [] -> Time_ns.epoch
;;

let rows
  ?policy
  ?(out_of_sample_fraction = 0.)
  ?(bootstrap_samples = 1000)
  ?(seed = 0)
  ~sample
  runs
  =
  let oos n =
    let k = Float.iround_up_exn (out_of_sample_fraction *. Float.of_int n) in
    (* a report needs three out-of-sample periods or none *)
    if k >= 3 then Some k else None
  in
  let periods_per_year = periods_per_year sample in
  let indexed =
    List.filter_mapi runs ~f:(fun i (r : Backtest.t) ->
      let rs = returns r in
      if Array.length rs >= 3 then Some (i, r, rs) else None)
  in
  let several = List.length indexed >= 2 in
  (* every run of a sweep is a trial for the deflated Sharpe ratio *)
  let trials =
    if several
    then
      Some
        { Report.Trials.count = List.length indexed
        ; sharpe_variance =
            variance
              (Array.of_list
                 (List.map indexed ~f:(fun (_, _, rs) -> per_period_sharpe rs)))
        }
    else None
  in
  let run_rows =
    List.filter_map indexed ~f:(fun (i, r, rs) ->
      match
        Report.create
          ~name:r.summary.label
          ?out_of_sample_periods:(oos (Array.length rs))
          ?trials
          ~bootstrap_samples
          ~seed
          ?policy:(if several then None else policy)
          ~periods_per_year
          (series ~sample ~start:(start_of r) rs)
      with
      | Ok report -> Some { Row.scope = `Run; run = i; label = r.summary.label; report }
      | Error _ -> None)
  in
  let sweep_row =
    if not several
    then None
    else (
      (* runs sample the same grid; cut them to the shortest in case one ended early *)
      let len =
        List.fold indexed ~init:Int.max_value ~f:(fun acc (_, _, rs) ->
          Int.min acc (Array.length rs))
      in
      let candidates =
        Array.of_list (List.map indexed ~f:(fun (_, _, rs) -> Array.sub rs ~pos:0 ~len))
      in
      let best =
        List.max_elt indexed ~compare:(fun (_, _, a) (_, _, b) ->
          Float.compare (per_period_sharpe a) (per_period_sharpe b))
        |> Option.value_exn
      in
      let i, r, rs = best in
      let benchmark = Array.sub (leader_returns r) ~pos:0 ~len in
      match
        Report.create
          ~name:("sweep pick: " ^ r.summary.label)
          ?out_of_sample_periods:(oos len)
          ~candidates
          ~benchmark
          ~bootstrap_samples
          ~seed
          ?policy
          ~periods_per_year
          (series ~sample ~start:(start_of r) (Array.sub rs ~pos:0 ~len))
      with
      | Ok report -> Some { Row.scope = `Sweep; run = i; label = r.summary.label; report }
      | Error _ -> None)
  in
  run_rows @ Option.to_list sweep_row
;;

let rejected rows =
  let decisive =
    match List.find rows ~f:(fun (r : Row.t) -> Poly.equal r.scope `Sweep) with
    | Some s -> Some s
    | None -> List.hd rows
  in
  Option.bind decisive ~f:(fun (r : Row.t) ->
    match r.report.verdict with
    | Some (Reject _) -> Some r
    | None | Some Accept -> None)
;;
