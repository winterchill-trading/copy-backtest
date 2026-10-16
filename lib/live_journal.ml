open! Core
open! Async
open Hl_copy_core
module Journal = Hl_copy_engine.Journal
module Follower_core = Hl_copy_engine.Follower_core

let load_file path =
  match%bind Market_data.Framed.read_digest path with
  | Some d when String.equal d Journal.digest_v1 ->
    let%map entries, _ =
      Market_data.Framed.load_file
        ~digest:d
        Journal.Entry.Stable.V1.bin_reader_t
        path
    in
    List.map entries ~f:Journal.Entry.Stable.V3.of_v1
  | Some d when String.equal d Journal.digest_v2 ->
    let%map entries, _ =
      Market_data.Framed.load_file
        ~digest:d
        Journal.Entry.Stable.V2.bin_reader_t
        path
    in
    List.map entries ~f:Journal.Entry.Stable.V3.of_v2
  | _ ->
    let%map entries, _ =
      Market_data.Framed.load_file
        ~digest:Journal.digest
        Journal.Entry.Stable.V3.bin_reader_t
        path
    in
    entries
;;

let load path =
  Deferred.Or_error.try_with_join (fun () ->
    match%bind Sys.is_directory path with
    | `Yes -> Deferred.ok (Journal.load path)
    | `No | `Unknown -> Deferred.ok (load_file path))
;;

let cloids (t : Follower_core.t) =
  List.map t.execs ~f:(fun (e : Follower_core.Exec.t) -> e.order.cloid)
;;

let leg entries =
  let open Or_error.Let_syntax in
  let inputs =
    List.filter_map entries ~f:(function
      | Journal.Entry.Input { time_ns; input } -> Some (time_ns, input)
      | Output _ | Legacy_output _ -> None)
  in
  let%bind first_time, follow, specs, rest =
    match inputs with
    | (time_ns, Follower_core.Input.Configure { follow; specs }) :: rest ->
      Ok (time_ns, follow, specs, rest)
    | _ -> Or_error.error_string "journal must start with Configure"
  in
  let core = ref (Follower_core.create ~follow ~specs) in
  (* parents being worked: client order id -> coin, decision price, side, target *)
  let open_ = Hashtbl.create (module Cloid) in
  let parents = Queue.create () in
  let start = ref None in
  let last = ref (first_time, 0.) in
  List.iter rest ~f:(fun (time_ns, input) ->
    let before = !core in
    let after, (out : Follower_core.Output.t) = Follower_core.apply before input in
    core := after;
    let was = cloids before in
    let now = cloids after in
    List.iter after.execs ~f:(fun (e : Follower_core.Exec.t) ->
      if not (List.mem was e.order.cloid ~equal:Cloid.equal)
      then (
        let decision =
          match Map.find after.mirror.marks e.order.symbol with
          | Some m -> Market_data.Price.to_float m
          | None -> Market_data.Price.to_float e.order.limit_px
        in
        Hashtbl.set open_ ~key:e.order.cloid ~data:(e, decision)));
    (* parents that finished on this input, oldest first, and their reports in order *)
    let finished =
      List.filter_map was ~f:(fun c ->
        if List.mem now c ~equal:Cloid.equal then None else Hashtbl.find open_ c)
    in
    let rec pair finished (reports : Execution_algos.Cost_report.t list) =
      match reports with
      | [] -> ()
      | r :: reports ->
        (* the parent with this side and target, the oldest if several *)
        (match
           List.findi finished ~f:(fun _ ((e : Follower_core.Exec.t), _) ->
             Market_data.Side.equal e.order.side r.side
             && Market_data.Size.equal e.order.size r.target)
         with
         | Some (i, ((e : Follower_core.Exec.t), decision)) ->
           Hashtbl.remove open_ e.order.cloid;
           Queue.enqueue
             parents
             { Attribution.Parent.coin = Market_data.Symbol.to_string e.order.symbol
             ; decision_px = decision
             ; report = r
             };
           pair (List.filteri finished ~f:(fun j _ -> j <> i)) reports
         | None ->
           (* a report whose parent is unknown keeps its arrival as the decision *)
           Queue.enqueue
             parents
             { Attribution.Parent.coin = ""
             ; decision_px = Market_data.Price.to_float r.arrival_px
             ; report = r
             };
           pair finished reports)
    in
    pair finished out.reports;
    let equity = Usd.to_float after.mirror.follower_equity in
    if Float.(equity > 0.)
    then (
      if Option.is_none !start then start := Some (time_ns, equity);
      last := time_ns, equity));
  let%map start_ns, start_equity =
    match !start with
    | Some s -> Ok s
    | None -> Or_error.error_string "the journal never saw the follower's equity"
  in
  let end_ns, end_equity = !last in
  { Attribution.Leg.start_equity
  ; end_equity
  ; start_ns
  ; end_ns
  ; funding = 0.
  ; parents = Queue.to_list parents
  }
;;
