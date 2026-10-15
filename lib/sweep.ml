open! Core
open Hl_copy_core

module Grid = struct
  type t =
    { algos : Exec_algo.t list
    ; modes : Scale.Mode.t list
    ; max_leverages : float option list
    ; max_notionals : Usd.t option list
    }
  [@@deriving sexp_of]

  let items s =
    String.split s ~on:','
    |> List.map ~f:String.strip
    |> List.filter ~f:(Fn.non String.is_empty)
  ;;

  let parse_algos s =
    items s
    |> List.map ~f:(fun a ->
      Or_error.map (Execution_algos.Algo.of_string a) ~f:Copy_algo.of_algo)
    |> Or_error.all
  ;;

  let parse_mode s : Scale.Mode.t Or_error.t =
    Or_error.try_with (fun () ->
      match String.lsplit2 s ~on:':' with
      | None when String.equal s "equity" -> Scale.Mode.Equity_ratio
      | Some ("mult", k) -> Multiplier (Float.of_string k)
      | Some ("fixed", n) -> Fixed_notional (Usd.of_string n)
      | _ -> raise_s [%message "unknown mode (equity, mult:K, fixed:USD)" s])
  ;;

  let parse_modes s = items s |> List.map ~f:parse_mode |> Or_error.all

  let parse_caps s =
    items s
    |> List.map ~f:(fun c ->
      if String.equal c "none"
      then Ok None
      else Or_error.try_with (fun () -> Some (Float.of_string c)))
    |> Or_error.all
  ;;
end

let params (g : Grid.t) ~(base : Params.t) =
  let ( let* ) l f = List.concat_map l ~f in
  let* algo = g.algos in
  let* mode = g.modes in
  let* max_leverage = g.max_leverages in
  let* max_notional_per_symbol = g.max_notionals in
  [ { base with
      follow =
        { base.follow with
          algo
        ; mode
        ; caps = { base.follow.caps with max_leverage; max_notional_per_symbol }
        }
    }
  ]
;;

let run g ~base source = List.map (params g ~base) ~f:(fun p -> Backtest.run p source)
