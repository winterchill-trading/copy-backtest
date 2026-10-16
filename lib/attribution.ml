open! Core
module Cost_report = Execution_algos.Cost_report
module Price = Market_data.Price
module Size = Market_data.Size

module Parent = struct
  type t =
    { coin : string
    ; decision_px : float
    ; report : Cost_report.t
    }
  [@@deriving sexp_of]
end

module Leg = struct
  type t =
    { start_equity : float
    ; end_equity : float
    ; start_ns : int
    ; end_ns : int
    ; funding : float
    ; parents : Parent.t list
    }
  [@@deriving sexp_of]

  let return_ t =
    if Float.(t.start_equity > 0.) then (t.end_equity /. t.start_equity) -. 1. else 0.
  ;;

  module Costs = struct
    type t =
      { fees : float
      ; slippage : float
      ; timing : float
      ; partial_fills : float
      ; funding : float
      }
    [@@deriving sexp_of]
  end

  let costs t =
    let sum f = List.sum (module Float) t.parents ~f in
    let side (r : Cost_report.t) = if Market_data.Side.is_buy r.side then 1. else -1. in
    let px = Price.to_float in
    { Costs.fees = sum (fun p -> p.report.fees)
    ; slippage =
        sum (fun p ->
          let r = p.report in
          if Size.is_zero r.filled
          then 0.
          else side r *. Size.to_float r.filled *. (px r.avg_px -. px r.arrival_px))
    ; timing =
        sum (fun p ->
          let r = p.report in
          side r *. Size.to_float r.target *. (px r.arrival_px -. p.decision_px))
    ; partial_fills =
        sum (fun p ->
          let r = p.report in
          side r
          *. (Size.to_float r.target -. Size.to_float r.filled)
          *. (px r.end_px -. px r.arrival_px))
    ; funding = t.funding
    }
  ;;
end

module Term = struct
  type t =
    { name : string
    ; backtest_usd : float
    ; live_usd : float
    ; bps : float
    }
  [@@deriving sexp_of]
end

type t =
  { backtest_return : float
  ; live_return : float
  ; difference_bps : float
  ; terms : Term.t list
  ; residual_bps : float
  ; dominant : string
  ; backtest_parents : int
  ; live_parents : int
  }
[@@deriving sexp_of]

let compute ~(backtest : Leg.t) ~(live : Leg.t) =
  let b = Leg.costs backtest in
  let l = Leg.costs live in
  let per (leg : Leg.t) x =
    if Float.(leg.start_equity > 0.) then x /. leg.start_equity else 0.
  in
  let term name f =
    let backtest_usd = f b in
    let live_usd = f l in
    { Term.name
    ; backtest_usd
    ; live_usd
    ; bps = (per backtest backtest_usd -. per live live_usd) *. 10_000.
    }
  in
  let terms =
    [ term "fees" (fun (c : Leg.Costs.t) -> c.fees)
    ; term "slippage" (fun c -> c.slippage)
    ; term "timing" (fun c -> c.timing)
    ; term "partial fills" (fun c -> c.partial_fills)
    ; term "funding" (fun c -> c.funding)
    ]
  in
  let backtest_return = Leg.return_ backtest in
  let live_return = Leg.return_ live in
  let difference_bps = (live_return -. backtest_return) *. 10_000. in
  let residual_bps =
    difference_bps -. List.sum (module Float) terms ~f:(fun (x : Term.t) -> x.bps)
  in
  let dominant =
    List.fold
      terms
      ~init:("residual", Float.abs residual_bps)
      ~f:(fun (name, m) (x : Term.t) ->
        if Float.(abs x.bps > m) then x.name, Float.abs x.bps else name, m)
    |> fst
  in
  { backtest_return
  ; live_return
  ; difference_bps
  ; terms
  ; residual_bps
  ; dominant
  ; backtest_parents = List.length backtest.parents
  ; live_parents = List.length live.parents
  }
;;

let to_string_hum t =
  let line name ~bt ~live ~bps =
    sprintf "%-14s %12s %12s %10.2f%s\n" name bt live bps
      (if String.equal name t.dominant then "  <- largest" else "")
  in
  let usd = sprintf "%.2f" in
  String.concat
    ([ sprintf "%-14s %12s %12s %10s\n" "term" "backtest USD" "live USD" "bps" ]
     @ List.map t.terms ~f:(fun (x : Term.t) ->
       line x.name ~bt:(usd x.backtest_usd) ~live:(usd x.live_usd) ~bps:x.bps)
     @ [ line "residual" ~bt:"" ~live:"" ~bps:t.residual_bps
       ; sprintf
           "return: backtest %.4f%%, live %.4f%%, difference %.2f bps; parents: backtest \
            %d, live %d\n"
           (t.backtest_return *. 100.)
           (t.live_return *. 100.)
           t.difference_bps
           t.backtest_parents
           t.live_parents
       ])
;;

(* {2 Reading a backtest's -out directory} *)

let column_index reader name =
  match
    List.findi (Parquet.Reader.columns reader) ~f:(fun _ (c : Parquet.Metadata.Schema_element.t) ->
      String.equal c.name name)
  with
  | Some (i, _) -> Ok i
  | None -> Or_error.error_s [%message "missing column" name]
;;

let rows path ~columns ~f =
  Parquet.Reader.with_file path ~f:(fun reader ->
    let open Or_error.Let_syntax in
    let%bind idx = List.map columns ~f:(column_index reader) |> Or_error.all in
    let idx = Array.of_list idx in
    let%bind acc =
      Parquet.Reader.fold_rows reader ~init:[] ~f:(fun acc row ->
        Array.map idx ~f:(fun i -> row.(i)) :: acc)
    in
    List.rev acc |> List.map ~f |> Or_error.all)
;;

let num : Parquet.Reader.Value.t -> float Or_error.t = function
  | Float x -> Ok x
  | Int i -> Ok (Float.of_int i)
  | Null -> Ok 0.
  | v -> Or_error.error_s [%message "not a number" (v : Parquet.Reader.Value.t)]
;;

let int v = Or_error.map (num v) ~f:Float.to_int

let str : Parquet.Reader.Value.t -> string Or_error.t = function
  | String s -> Ok s
  | v -> Or_error.error_s [%message "not a string" (v : Parquet.Reader.Value.t)]
;;

let backtest_leg ?(run = 0) dir =
  let open Or_error.Let_syntax in
  let%bind summaries =
    rows
      (dir ^/ "summary.parquet")
      ~columns:[ "run"; "start_equity"; "end_equity"; "funding" ]
      ~f:(fun v ->
        let%map r = int v.(0)
        and s = num v.(1)
        and e = num v.(2)
        and f = num v.(3) in
        r, (s, e, f))
  in
  let%bind start_equity, end_equity, funding =
    match List.Assoc.find summaries run ~equal:Int.equal with
    | Some x -> Ok x
    | None -> Or_error.error_s [%message "no such run" (run : int)]
  in
  let%bind curve =
    rows
      (dir ^/ "curve.parquet")
      ~columns:[ "run"; "time" ]
      ~f:(fun v ->
        let%map r = int v.(0)
        and t = int v.(1) in
        r, t)
  in
  let times = List.filter_map curve ~f:(fun (r, t) -> Option.some_if (r = run) t) in
  let%map parents =
    rows
      (dir ^/ "parents.parquet")
      ~columns:
        [ "run"
        ; "coin"
        ; "decision_px"
        ; "algo"
        ; "side"
        ; "target"
        ; "filled"
        ; "avg_px"
        ; "arrival_px"
        ; "end_px"
        ; "fees"
        ; "arrival"
        ; "end"
        ]
      ~f:(fun v ->
        let%map r = int v.(0)
        and coin = str v.(1)
        and decision_px = num v.(2)
        and algo = str v.(3)
        and side = str v.(4)
        and target = num v.(5)
        and filled = num v.(6)
        and avg_px = num v.(7)
        and arrival_px = num v.(8)
        and end_px = num v.(9)
        and fees = num v.(10)
        and arrival_ns = int v.(11)
        and end_ns = int v.(12) in
        let size x = (Size.of_float [@alert "-lossy"]) x in
        let price x = (Price.of_float [@alert "-lossy"]) x in
        ( r
        , { Parent.coin
          ; decision_px
          ; report =
              { Cost_report.algo
              ; side = (if String.equal side "buy" then Buy else Sell)
              ; target = size target
              ; filled = size filled
              ; avg_px = price avg_px
              ; arrival_px = price arrival_px
              ; end_px = price end_px
              ; arrival_ns
              ; end_ns
              ; children = 0
              ; maker_filled = Size.zero
              ; fees
              ; arrival_slippage_bps = 0.
              ; shortfall = 0.
              ; shortfall_bps = 0.
              ; outcome = Unfilled
              }
          } ))
  in
  { Leg.start_equity
  ; end_equity
  ; start_ns = Option.value (List.hd times) ~default:0
  ; end_ns = Option.value (List.last times) ~default:0
  ; funding
  ; parents = List.filter_map parents ~f:(fun (r, p) -> Option.some_if (r = run) p)
  }
;;
