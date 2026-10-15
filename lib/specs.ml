open! Core
module Spec = Hl_copy_core.Rounding.Spec

type t = Spec.t Map.M(Market_data.Symbol).t [@@deriving sexp_of]

let default_sz_decimals = function
  | "BTC" -> 5
  | "ETH" -> 4
  | "SOL" -> 2
  | _ -> 2
;;

let defaults coins =
  List.map coins ~f:(fun c ->
    ( Market_data.Symbol.of_string c
    , Spec.hyperliquid_perp ~sz_decimals:(default_sz_decimals c) ))
  |> Map.of_alist_reduce (module Market_data.Symbol) ~f:(fun a _ -> a)
;;

let of_meta_file path ~coins =
  let open Or_error.Let_syntax in
  let%map meta =
    Or_error.try_with (fun () ->
      Hl_protocol.Meta.t_of_yojson (Yojson.Safe.from_file path))
  in
  List.fold
    meta.universe
    ~init:(defaults coins)
    ~f:(fun acc (a : Hl_protocol.Meta.Asset_meta.t) ->
      Map.set acc ~key:a.name ~data:(Spec.of_asset_meta a))
;;
