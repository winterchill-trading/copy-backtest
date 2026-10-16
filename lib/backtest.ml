open! Core
open Hl_copy_core
module Price = Market_data.Price
module Size = Market_data.Size
module Symbol = Market_data.Symbol
module Scheduler = Execution_algos.Scheduler
module Paper = Execution_algos.Paper
module Cost_report = Execution_algos.Cost_report

module Point = struct
  type t =
    { time_ns : int
    ; equity : float
    ; leader_equity : float
    ; gap_bps : float
    }
  [@@deriving sexp_of]
end

module Parent = struct
  type t =
    { coin : string
    ; decision_px : float
    ; report : Cost_report.t
    }
  [@@deriving sexp_of]
end

module Summary = struct
  type t =
    { label : string
    ; algo : string
    ; mode : string
    ; max_leverage : float option
    ; start_equity : float
    ; end_equity : float
    ; pnl : float
    ; return_ : float
    ; max_drawdown : float
    ; fees : float
    ; funding : float
    ; turnover : float
    ; leader_changes : int
    ; parents : int
    ; filled_parents : int
    ; open_parents : int
    ; children : int
    ; fill_rate : float
    ; shortfall : float
    ; shortfall_bps : float
    ; slippage_bps : float
    ; maker_share : float
    ; tracking_error_bps : float
    ; mean_gap_bps : float
    ; leader_return : float
    ; band_skips : int
    ; band_saved : float
    }
  [@@deriving sexp_of, fields]
end

type t =
  { summary : Summary.t
  ; curve : Point.t list
  ; parents : Parent.t list
  }
[@@deriving sexp_of]

(* A parent order and its scheduler. Child ids are made unique across parents for the
   coin's paper venue ([globals]). *)
type exec =
  { order : Plan.Order.t
  ; decision_px : float
  ; mutable sched : Scheduler.t
  ; local_to_global : int Int.Table.t
  }

type state =
  { p : Params.t
  ; mutable mirror : Mirror.t
  ; markets : Market.t Hashtbl.M(Symbol).t
  ; papers : Paper.t Hashtbl.M(Symbol).t
  ; mutable execs : exec list
  ; globals : (exec * int) Int.Table.t
  ; mutable next_global : int
  ; mutable books : Pnl.Position.t Map.M(Symbol).t (** the follower's *)
  ; mutable leader_books : Pnl.Position.t Map.M(Symbol).t
  ; mutable leader_fees : float
  ; mutable fees : float
  ; mutable funding : float
  ; mutable turnover : float
  ; mutable children : int
  ; mutable leader_changes : int
  ; parents : Parent.t Queue.t
  ; curve : Point.t Queue.t
  ; mutable next_tick : int
  ; mutable next_sample : int
  ; mutable next_hour : int
  ; mutable next_resync : int
  ; mutable day : Date.t option
  ; mutable decision : Price.t option
  (** the leader's fill price while its change is being planned *)
  ; mutable band_skips : int
  ; mutable band_saved : float
  }

let usd x = (Usd.of_float [@alert "-lossy"]) x
let hour_ns = Time_ns.Span.to_int_ns Time_ns.Span.hour
let market t symbol = Hashtbl.find_or_add t.markets symbol ~default:Market.create

let paper t symbol =
  Hashtbl.find_or_add t.papers symbol ~default:(fun () ->
    Paper.create
      ~latency:t.p.latency
      ~taker_fee_bps:t.p.taker_fee_bps
      ~maker_fee_bps:t.p.maker_fee_bps
      ())
;;

let mark t symbol = Option.bind (Hashtbl.find t.markets symbol) ~f:Market.mark

let marks t =
  Hashtbl.to_alist t.markets
  |> List.filter_map ~f:(fun (s, m) -> Option.map (Market.mark m) ~f:(fun px -> s, px))
  |> Map.of_alist_exn (module Symbol)
;;

let book_value books ~marks =
  Map.fold books ~init:0. ~f:(fun ~key ~data:(pos : Pnl.Position.t) acc ->
    let unrealized =
      match Map.find marks key with
      | None -> 0.
      | Some mark -> Usd.to_float (Pnl.Position.unrealized pos ~mark)
    in
    acc +. Usd.to_float pos.realized +. unrealized)
;;

let equity t ~marks = t.p.start_equity +. book_value t.books ~marks -. t.fees -. t.funding

let leader_equity t ~marks =
  t.p.leader_equity +. book_value t.leader_books ~marks -. t.leader_fees
;;

(* {2 Parents} *)

let rec send t (e : exec) ~now_ns (actions : Execution_algos.Child.Action.t list) =
  let symbol = e.order.symbol in
  let venue = paper t symbol in
  let wire =
    List.filter_map actions ~f:(fun (a : Execution_algos.Child.Action.t) ->
      match a with
      | Place c ->
        let g = t.next_global in
        t.next_global <- g + 1;
        Hashtbl.set e.local_to_global ~key:c.id ~data:g;
        Hashtbl.set t.globals ~key:g ~data:(e, c.id);
        t.children <- t.children + 1;
        Some (Execution_algos.Child.Action.Place { c with id = g })
      | Cancel id ->
        Option.map (Hashtbl.find e.local_to_global id) ~f:(fun g ->
          Execution_algos.Child.Action.Cancel g))
  in
  Paper.send venue ~now_ns wire;
  drain t symbol ~now_ns

and step t (e : exec) ~now_ns event =
  let sched, actions = Scheduler.apply e.sched event in
  e.sched <- sched;
  if not (List.is_empty actions) then send t e ~now_ns actions;
  if Scheduler.is_done e.sched && List.exists t.execs ~f:(fun x -> phys_equal x e)
  then finish t e

and finish t (e : exec) =
  t.execs <- List.filter t.execs ~f:(fun x -> not (phys_equal x e));
  t.mirror <- Mirror.on_order_closed t.mirror e.order.cloid;
  Option.iter
    (Scheduler.report ?end_px:(mark t e.order.symbol) e.sched)
    ~f:(fun report ->
      Queue.enqueue
        t.parents
        { Parent.coin = Symbol.to_string e.order.symbol
        ; decision_px = e.decision_px
        ; report
        })

(* Fills and closes from the coin's paper venue, until it is quiet (a close can release
   the final sweep, which may fill at once). *)
and drain t symbol ~now_ns =
  match Paper.take_events (paper t symbol) with
  | [] -> ()
  | events ->
    List.iter events ~f:(fun (ev : Paper.Event.t) ->
      match ev with
      | Fill f ->
        (match Hashtbl.find t.globals f.child with
         | None -> ()
         | Some (e, local) ->
           let fill =
             { Fill.time_ns = now_ns
             ; symbol
             ; side = e.order.side
             ; size = f.size
             ; price = f.price
             ; fee = usd f.fee
             ; closed_pnl = Usd.zero
             ; cloid = Some e.order.cloid
             }
           in
           t.books
           <- Map.update t.books symbol ~f:(fun pos ->
                Pnl.Position.apply_fill
                  (Option.value pos ~default:Pnl.Position.flat)
                  { fill with fee = Usd.zero });
           t.fees <- t.fees +. f.fee;
           t.turnover <- t.turnover +. (Size.to_float f.size *. Price.to_float f.price);
           t.mirror <- Mirror.on_follower_fill t.mirror fill;
           step t e ~now_ns (Fill { f with child = local }))
      | Closed g ->
        (match Hashtbl.find t.globals g with
         | None -> ()
         | Some (e, local) -> step t e ~now_ns (Closed local)));
    drain t symbol ~now_ns
;;

let min_size (spec : Rounding.Spec.t) ~min_notional ~mark =
  let lot = Size.to_units spec.lot in
  let m = Price.to_units mark in
  if m <= 0 || lot <= 0
  then spec.lot
  else (
    let units = Fixed_decimal.div_units (Usd.to_units min_notional) m in
    Size.of_units ((units + lot - 1) / lot * lot))
;;

let start_parent t (o : Plan.Order.t) ~now_ns =
  match Map.find t.p.specs o.symbol with
  | None -> t.mirror <- Mirror.on_order_closed t.mirror o.cloid
  | Some spec ->
    let m = market t o.symbol in
    let reference = Option.value (Market.mark m) ~default:o.limit_px in
    let min_size =
      min_size spec ~min_notional:t.p.follow.caps.min_order_notional ~mark:reference
    in
    let algo : Execution_algos.Algo.t =
      if Size.( < ) o.size min_size then Immediate else Copy_algo.to_algo t.p.follow.algo
    in
    let parent =
      Execution_algos.Parent.create
        ~side:o.side
        ~size:o.size
        ~limit_px:o.limit_px
        ~reference_px:reference
        ~lot:spec.lot
        ~min_size
        ~equity:(equity t ~marks:(marks t))
        ()
    in
    let e =
      { order = o
      ; decision_px = Price.to_float (Option.value t.decision ~default:reference)
      ; sched = Scheduler.create algo parent
      ; local_to_global = Int.Table.create ()
      }
    in
    t.execs <- t.execs @ [ e ];
    (* the parent starts now, on the current book *)
    step t e ~now_ns (Tick { now_ns; book = Market.book m; traded = Market.traded m })
;;

let dispatch t (plan : Plan.t) ~now_ns =
  List.iter plan.notes ~f:(fun (n : Plan.Note.t) ->
    match n.reason with
    | Within_band { saved; _ } ->
      t.band_skips <- t.band_skips + 1;
      t.band_saved <- t.band_saved +. Usd.to_float saved
    | Capped _ | No_mark | No_spec | No_leader_equity -> ());
  List.iter plan.actions ~f:(function
    | Plan.Action.Place o -> start_parent t o ~now_ns
    | Cancel { cloid; _ } ->
      (match List.find t.execs ~f:(fun e -> Cloid.equal e.order.cloid cloid) with
       | Some e -> step t e ~now_ns Cancel
       | None -> t.mirror <- Mirror.on_order_closed t.mirror cloid))
;;

(* {2 The clock} *)

let sample t ~now_ns =
  let marks = marks t in
  let equity = equity t ~marks in
  let gap =
    Set.fold t.mirror.managed ~init:0. ~f:(fun acc symbol ->
      match Mirror.target t.mirror symbol, Map.find marks symbol with
      | (Some target, _), Some mark ->
        let pos =
          Option.value (Map.find t.mirror.follower_positions symbol) ~default:Size.zero
        in
        acc
        +. (Float.abs (Size.to_float target -. Size.to_float pos) *. Price.to_float mark)
      | _ -> acc)
  in
  Queue.enqueue
    t.curve
    { Point.time_ns = now_ns
    ; equity
    ; leader_equity = leader_equity t ~marks
    ; gap_bps = (if Float.(equity > 0.) then gap /. equity *. 10_000. else 0.)
    }
;;

let pay_funding t =
  Map.iteri t.books ~f:(fun ~key ~data:(pos : Pnl.Position.t) ->
    match Hashtbl.find t.markets key with
    | None -> ()
    | Some m ->
      (match Market.funding_rate m, Market.mark m with
       | Some rate, Some mark ->
         (* longs pay a positive rate *)
         t.funding <- t.funding +. (Size.to_float pos.size *. Price.to_float mark *. rate)
       | _ -> ()))
;;

let tick t ~now_ns =
  Hashtbl.iteri t.papers ~f:(fun ~key ~data ->
    Paper.advance data ~now_ns;
    drain t key ~now_ns);
  List.iter t.execs ~f:(fun e ->
    match Scheduler.algo e.sched with
    | Immediate -> ()
    | Twap _ | Vwap _ | Pov _ | Passive _ | Adaptive _ ->
      let m = market t e.order.symbol in
      step t e ~now_ns (Tick { now_ns; book = Market.book m; traded = Market.traded m }))
;;

let new_day t ~now_ns =
  let day =
    Time_ns.to_date (Time_ns.of_int_ns_since_epoch now_ns) ~zone:Time_float.Zone.utc
  in
  match t.day with
  | Some d when Date.equal d day -> ()
  | _ ->
    t.day <- Some day;
    t.mirror <- Mirror.on_follower_equity t.mirror (usd (equity t ~marks:(marks t)));
    t.mirror <- Mirror.start_day t.mirror
;;

(* The engine's periodic resync: both equities, then a rebalance of every coin, which
   re-plans what earlier IOCs left unfilled. *)
let resync t ~now_ns =
  let marks = marks t in
  t.mirror <- Mirror.on_leader_equity t.mirror (usd (leader_equity t ~marks));
  t.mirror <- Mirror.on_follower_equity t.mirror (usd (equity t ~marks));
  let mirror, plan = Mirror.rebalance t.mirror in
  t.mirror <- mirror;
  dispatch t plan ~now_ns
;;

(* Runs the grid (resyncs, ticks, samples, funding hours) up to [now_ns], in time order. *)
let advance t ~now_ns =
  let rec loop () =
    let next =
      Int.min (Int.min t.next_tick t.next_resync) (Int.min t.next_sample t.next_hour)
    in
    if next <= now_ns
    then (
      if t.next_resync = next
      then (
        resync t ~now_ns:next;
        t.next_resync <- t.next_resync + Time_ns.Span.to_int_ns t.p.resync);
      if t.next_hour = next
      then (
        if t.p.funding then pay_funding t;
        new_day t ~now_ns:next;
        t.next_hour <- t.next_hour + hour_ns);
      if t.next_tick = next
      then (
        tick t ~now_ns:next;
        t.next_tick <- t.next_tick + Time_ns.Span.to_int_ns t.p.tick);
      if t.next_sample = next
      then (
        sample t ~now_ns:next;
        t.next_sample <- t.next_sample + Time_ns.Span.to_int_ns t.p.sample);
      loop ())
  in
  loop ()
;;

(* {2 Items} *)

let band_uses_impact t =
  match t.p.follow.band with
  | Some { slippage = Impact _; _ } -> true
  | Some { slippage = Fixed_bps _; _ } | None -> false
;;

(* The slippage a band with [Impact] charges, as the engine computes it: the order that
   would close the coin's gap now (one lot when there is none), walked on the book. *)
let estimate_slippage t symbol book =
  match Map.find t.p.specs symbol with
  | None -> ()
  | Some (spec : Rounding.Spec.t) ->
    let m = t.mirror in
    let current =
      List.fold
        m.pending
        ~init:(Option.value (Map.find m.follower_positions symbol) ~default:Size.zero)
        ~f:(fun acc (p : Mirror.Pending.t) ->
          if Symbol.equal p.symbol symbol && not p.cancel_requested
          then Size.(acc + p.remaining)
          else acc)
    in
    let gap =
      match Mirror.target m symbol with
      | Some target, _ -> Size.(target - current)
      | None, _ -> Size.zero
    in
    let side : Market_data.Side.t = if Size.is_negative gap then Sell else Buy in
    let size = if Size.is_zero gap then spec.lot else Size.abs gap in
    Option.iter (Execution_algos.Impact.estimate book ~side ~size) ~f:(fun e ->
      t.mirror <- Mirror.on_slippage_estimate m ~symbol ~bps:(Float.max 0. e.slippage_bps))
;;

let on_market t (e : Market_data.Event.t) ~now_ns =
  let symbol = (Market_data.Event.instrument e).symbol in
  let m = market t symbol in
  Market.apply m e;
  (match e with
   | L2 _ | Bbo _ -> Paper.set_book (paper t symbol) ~now_ns (Market.book m)
   | Trade tr ->
     Paper.trade (paper t symbol) ~now_ns ~price:tr.price ~size:tr.size ~aggressor:tr.side
   | Funding _ -> ());
  drain t symbol ~now_ns;
  Option.iter (Market.mark m) ~f:(fun mark ->
    t.mirror <- Mirror.on_mark t.mirror ~symbol ~mark);
  match e with
  | (L2 _ | Bbo _) when band_uses_impact t -> estimate_slippage t symbol (Market.book m)
  | L2 _ | Bbo _ | Trade _ | Funding _ -> ()
;;

let on_leader_fill t (f : Hl_protocol.User_fill.t) =
  let symbol = f.coin in
  (* a position held before the history starts opens at the first fill's price *)
  if (not (Map.mem t.leader_books symbol)) && not (Size.is_zero f.start_position)
  then
    t.leader_books
    <- Map.set
         t.leader_books
         ~key:symbol
         ~data:{ Pnl.Position.flat with size = f.start_position; avg_entry = f.px };
  t.leader_books
  <- Map.update t.leader_books symbol ~f:(fun pos ->
       Pnl.Position.apply_fill
         (Option.value pos ~default:Pnl.Position.flat)
         { Fill.time_ns = f.time * 1_000_000
         ; symbol
         ; side = f.side
         ; size = f.sz
         ; price = f.px
         ; fee = Usd.zero
         ; closed_pnl = Usd.zero
         ; cloid = None
         });
  t.leader_fees <- t.leader_fees +. Usd.to_float f.fee
;;

(* One leader position change: the fills of one coin in one millisecond. *)
let on_leader t (fills : Hl_protocol.User_fill.t list) ~now_ns =
  List.iter fills ~f:(on_leader_fill t);
  let last = List.last_exn fills in
  let symbol = last.coin in
  t.leader_changes <- t.leader_changes + 1;
  if Map.mem t.p.specs symbol
  then (
    let marks = marks t in
    let mark = Option.value (Map.find marks symbol) ~default:last.px in
    t.mirror <- Mirror.on_leader_equity t.mirror (usd (leader_equity t ~marks));
    t.mirror <- Mirror.on_follower_equity t.mirror (usd (equity t ~marks));
    let mirror, plan =
      Mirror.on_leader_position_change
        t.mirror
        ~symbol
        ~size:(Leader_fills.position_after last)
        ~mark
    in
    t.mirror <- mirror;
    (* parents planned on this change measure their timing from the leader's price *)
    t.decision <- Some last.px;
    dispatch t plan ~now_ns;
    t.decision <- None)
;;

(* {2 Summary} *)

let max_drawdown curve =
  let _, dd =
    List.fold curve ~init:(Float.neg_infinity, 0.) ~f:(fun (peak, dd) (p : Point.t) ->
      let peak = Float.max peak p.equity in
      peak, if Float.(peak > 0.) then Float.max dd ((peak -. p.equity) /. peak) else dd)
  in
  dd
;;

let tracking_error curve =
  let returns =
    List.zip_exn (List.drop_last_exn curve) (List.tl_exn curve)
    |> List.filter_map ~f:(fun ((a : Point.t), (b : Point.t)) ->
      if Float.(a.equity > 0. && a.leader_equity > 0.)
      then
        Some ((b.equity /. a.equity) -. 1. -. ((b.leader_equity /. a.leader_equity) -. 1.))
      else None)
  in
  match returns with
  | [] | [ _ ] -> 0.
  | _ ->
    let n = Float.of_int (List.length returns) in
    let mean = List.sum (module Float) returns ~f:Fn.id /. n in
    let var =
      List.sum (module Float) returns ~f:(fun r -> (r -. mean) ** 2.) /. (n -. 1.)
    in
    Float.sqrt var *. 10_000.
;;

let summarize t ~curve =
  let reports = Queue.to_list t.parents |> List.map ~f:(fun (p : Parent.t) -> p.report) in
  let totals = Cost_report.Totals.of_list reports in
  let first, last =
    match curve with
    | [] -> None, None
    | _ -> Some (List.hd_exn curve), Some (List.last_exn curve)
  in
  let end_equity =
    Option.value_map last ~default:t.p.start_equity ~f:(fun (p : Point.t) -> p.equity)
  in
  let filled_size =
    List.sum (module Float) reports ~f:(fun r -> Size.to_float r.filled)
  in
  let maker_size =
    List.sum (module Float) reports ~f:(fun r -> Size.to_float r.maker_filled)
  in
  let leader_return =
    match first, last with
    | Some f, Some l when Float.(f.leader_equity > 0.) ->
      (l.leader_equity /. f.leader_equity) -. 1.
    | _ -> 0.
  in
  { Summary.label = Params.label t.p
  ; algo = Execution_algos.Algo.name (Copy_algo.to_algo t.p.follow.algo)
  ; mode = Params.mode_label t.p.follow.mode
  ; max_leverage = t.p.follow.caps.max_leverage
  ; start_equity = t.p.start_equity
  ; end_equity
  ; pnl = end_equity -. t.p.start_equity
  ; return_ = (end_equity /. t.p.start_equity) -. 1.
  ; max_drawdown = max_drawdown curve
  ; fees = t.fees
  ; funding = t.funding
  ; turnover = t.turnover
  ; leader_changes = t.leader_changes
  ; parents = totals.parents
  ; filled_parents = totals.filled_parents
  ; open_parents = List.length t.execs
  ; children = t.children
  ; fill_rate = Cost_report.Totals.fill_rate totals
  ; shortfall = totals.shortfall
  ; shortfall_bps = Cost_report.Totals.shortfall_bps totals
  ; slippage_bps = Cost_report.Totals.slippage_bps totals
  ; maker_share = (if Float.(filled_size > 0.) then maker_size /. filled_size else 0.)
  ; tracking_error_bps = tracking_error curve
  ; mean_gap_bps =
      (match curve with
       | [] -> 0.
       | _ ->
         List.sum (module Float) curve ~f:(fun p -> p.gap_bps)
         /. Float.of_int (List.length curve))
  ; leader_return
  ; band_skips = t.band_skips
  ; band_saved = t.band_saved
  }
;;

let run (p : Params.t) (source : Source.t) =
  let start =
    match Source.span source with
    | Some (first, _) -> first
    | None -> 0
  in
  let config = Follower_config.mirror_config p.follow ~specs:p.specs in
  let t =
    { p
    ; mirror = Mirror.create config
    ; markets = Hashtbl.create (module Symbol)
    ; papers = Hashtbl.create (module Symbol)
    ; execs = []
    ; globals = Int.Table.create ()
    ; next_global = 0
    ; books = Map.empty (module Symbol)
    ; leader_books = Map.empty (module Symbol)
    ; leader_fees = 0.
    ; fees = 0.
    ; funding = 0.
    ; turnover = 0.
    ; children = 0
    ; leader_changes = 0
    ; parents = Queue.create ()
    ; curve = Queue.create ()
    ; next_tick = start
    ; next_sample = start
    ; next_hour = ((start / hour_ns) + 1) * hour_ns
    ; next_resync = start + Time_ns.Span.to_int_ns p.resync
    ; day = None
    ; decision = None
    ; band_skips = 0
    ; band_saved = 0.
    }
  in
  t.mirror <- Mirror.on_follower_equity t.mirror (usd p.start_equity);
  t.mirror <- Mirror.on_leader_equity t.mirror (usd p.leader_equity);
  new_day t ~now_ns:start;
  Array.iter source ~f:(fun (now_ns, item) ->
    advance t ~now_ns;
    match item with
    | Market e -> on_market t e ~now_ns
    | Leader fills -> on_leader t fills ~now_ns);
  (* a last sample at the end of the data *)
  Option.iter (Source.span source) ~f:(fun (_, last) -> sample t ~now_ns:last);
  let curve = Queue.to_list t.curve in
  { summary = summarize t ~curve; curve; parents = Queue.to_list t.parents }
;;
