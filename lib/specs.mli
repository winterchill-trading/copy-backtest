(** Lot and tick rules per coin for the mirror's rounding, from a saved Hyperliquid
    [meta] response or a built-in table of size decimals. *)

open! Core

type t = Hl_copy_core.Rounding.Spec.t Map.M(Market_data.Symbol).t [@@deriving sexp_of]

(** Size decimals of Hyperliquid perpetuals used when no [meta] is given: BTC 5, ETH 4,
    SOL 2, anything else 2. *)
val default_sz_decimals : string -> int

(** Specs for [coins] from the table above. *)
val defaults : string list -> t

(** Specs for every coin in a saved [meta] JSON file; coins missing from it fall back to
    {!defaults}. *)
val of_meta_file : string -> coins:string list -> t Or_error.t
