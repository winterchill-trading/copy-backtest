open! Core
open! Async

module Item = struct
  type t =
    | Market of Market_data.Event.t
    | Leader of Hl_protocol.User_fill.t
  [@@deriving sexp_of]
end

type t = (int * Item.t) array

let create ?(copy_delay = Time_ns.Span.zero) ~events ~fills () =
  let delay = Time_ns.Span.to_int_ns copy_delay in
  let market =
    List.map events ~f:(fun e ->
      Time_ns.to_int_ns_since_epoch (Market_data.Event.recv_ts e), Item.Market e)
  in
  let leader =
    List.map fills ~f:(fun (f : Hl_protocol.User_fill.t) ->
      (f.time * 1_000_000) + delay, Item.Leader f)
  in
  let rank = function
    | Item.Market _ -> 0
    | Leader _ -> 1
  in
  (* stable: within one time, market events first, each list keeps its own order *)
  List.stable_sort (market @ leader) ~compare:(fun (a, x) (b, y) ->
    match Int.compare a b with
    | 0 -> Int.compare (rank x) (rank y)
    | c -> c)
  |> Array.of_list
;;

let load_norm ?(venue = Market_data.Venue.Hyperliquid) ~dir ~coins ~from ~to_ () =
  let days = List.init (Date.diff to_ from + 1) ~f:(fun i -> Date.add_days from i) in
  let%bind paths =
    Deferred.List.concat_map ~how:`Sequential coins ~f:(fun coin ->
      let instrument = Market_data.Instrument.create venue coin in
      Deferred.List.concat_map ~how:`Sequential Market_data.Stream.all ~f:(fun stream ->
        Deferred.List.filter_map ~how:`Sequential days ~f:(fun day ->
          let path = Market_data.Event_log.path ~dir instrument stream day in
          match%map Sys.file_exists path with
          | `Yes -> Some path
          | `No | `Unknown -> None)))
  in
  match paths with
  | [] ->
    return
      (Or_error.error_s
         [%message "no event log files" (dir : string) (coins : string list)])
  | paths ->
    let%map events = Pipe.to_list (Market_data.Event_log.read_merged paths) in
    Ok events
;;

let span t =
  if Array.is_empty t then None else Some (fst t.(0), fst t.(Array.length t - 1))
;;
