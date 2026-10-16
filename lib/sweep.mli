(** Parameter sweeps: every combination of algorithms, scale modes and caps over the same
    data. *)

open! Core
open Hl_copy_core

module Grid : sig
  type t =
    { algos : Exec_algo.t list
    ; modes : Scale.Mode.t list
    ; max_leverages : float option list (** [None]: no leverage cap *)
    ; max_notionals : Usd.t option list (** per symbol; [None]: no cap *)
    ; bands : No_trade_band.t option list (** [None]: no band *)
    }
  [@@deriving sexp_of]

  (** Parsers for comma-separated command-line lists: algos in [Execution_algos.Algo]'s
      short form ([immediate,twap:30s:3,adaptive]), modes [equity], [mult:K], [fixed:USD],
      caps a number or [none]. *)
  val parse_algos : string -> Exec_algo.t list Or_error.t

  val parse_modes : string -> Scale.Mode.t list Or_error.t
  val parse_caps : string -> float option list Or_error.t

  (** One band: [none], [default] ({!No_trade_band.default}), [ra:G] (the default with
      risk aversion [G]), [impact:G] (and slippage estimated from the book, 5 bp until
      one is known), [quad:G:ETA] (quadratic costs with impact [ETA]), or a sexp. *)
  val parse_band : string -> No_trade_band.t option Or_error.t

  (** Comma-separated {!parse_band}s (commas inside a sexp do not split). *)
  val parse_bands : string -> No_trade_band.t option list Or_error.t
end

(** One run's parameters per combination, algos varying slowest. *)
val params : Grid.t -> base:Params.t -> Params.t list

val run : Grid.t -> base:Params.t -> Source.t -> Backtest.t list
