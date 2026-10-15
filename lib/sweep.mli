(** Parameter sweeps: every combination of algorithms, scale modes and caps over the
    same data. *)

open! Core
open Hl_copy_core

module Grid : sig
  type t =
    { algos : Exec_algo.t list
    ; modes : Scale.Mode.t list
    ; max_leverages : float option list (** [None]: no leverage cap *)
    ; max_notionals : Usd.t option list (** per symbol; [None]: no cap *)
    }
  [@@deriving sexp_of]

  (** Parsers for comma-separated command-line lists: algos in
      [Execution_algos.Algo]'s short form ([immediate,twap:30s:3,adaptive]), modes
      [equity], [mult:K], [fixed:USD], caps a number or [none]. *)
  val parse_algos : string -> Exec_algo.t list Or_error.t

  val parse_modes : string -> Scale.Mode.t list Or_error.t
  val parse_caps : string -> float option list Or_error.t
end

(** One run's parameters per combination, algos varying slowest. *)
val params : Grid.t -> base:Params.t -> Params.t list

val run : Grid.t -> base:Params.t -> Source.t -> Backtest.t list
