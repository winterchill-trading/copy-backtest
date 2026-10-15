open! Core
module User_fill = Hl_protocol.User_fill

let decode_json json =
  match json with
  | `List items -> List.map items ~f:User_fill.t_of_yojson
  | `Assoc _ -> [ User_fill.t_of_yojson json ]
  | _ -> raise_s [%message "expected a fill object or an array of fills"]
;;

let parse_line line =
  let line = String.strip line in
  if String.is_empty line
  then []
  else (
    (* hl-leaderboard raw pages: "<ISO time> [...]" *)
    let body =
      match String.lfindi line ~f:(fun _ c -> Char.equal c '[' || Char.equal c '{') with
      | Some i -> String.drop_prefix line i
      | None -> line
    in
    decode_json (Yojson.Safe.from_string body))
;;

let dedup_sort fills =
  List.dedup_and_sort fills ~compare:(fun (a : User_fill.t) b -> Int.compare a.tid b.tid)
  |> List.sort ~compare:(fun (a : User_fill.t) b ->
    match Int.compare a.time b.time with
    | 0 -> Int.compare a.tid b.tid
    | c -> c)
;;

let of_string s =
  Or_error.try_with (fun () ->
    let fills =
      (* a whole-file JSON value, else one value per line *)
      match Yojson.Safe.from_string (String.strip s) with
      | json -> decode_json json
      | exception _ -> List.concat_map (String.split_lines s) ~f:parse_line
    in
    dedup_sort fills)
;;

let load path =
  Or_error.bind
    (Or_error.try_with (fun () -> In_channel.read_all path))
    ~f:(fun s ->
      Or_error.tag_s (of_string s) ~tag:[%message "leader fills" (path : string)])
;;

let to_ndjson fills =
  String.concat
    (List.map fills ~f:(fun f -> Yojson.Safe.to_string (User_fill.yojson_of_t f) ^ "\n"))
;;

let select ?(coins = []) ?from ?to_ fills =
  let ms t = Time_ns.to_int_ns_since_epoch t / 1_000_000 in
  List.filter fills ~f:(fun (f : User_fill.t) ->
    (List.is_empty coins
     || List.mem coins (Hl_protocol.Coin.to_string f.coin) ~equal:String.equal)
    && Option.value_map from ~default:true ~f:(fun t -> f.time >= ms t)
    && Option.value_map to_ ~default:true ~f:(fun t -> f.time < ms t))
;;

let coins fills =
  List.map fills ~f:(fun (f : User_fill.t) -> Hl_protocol.Coin.to_string f.coin)
  |> List.dedup_and_sort ~compare:String.compare
;;

let position_after (f : User_fill.t) =
  let signed =
    match f.side with
    | Buy -> f.sz
    | Sell -> Market_data.Size.neg f.sz
  in
  Market_data.Size.( + ) f.start_position signed
;;
