(** Sim-versus-live attribution: why a live copy run (an engine journal) returned
    something other than its backtest over the same leader and window.

    Each side is a {!Leg.t}: start and end equity, the parents it executed (each with the
    price the follower decided at, the leader's fill price, and its cost report) and the
    funding it paid. With [s = +1] for a buy and [-1] for a sell, [d] the decision price,
    [a] the arrival price, [p] the average fill, [e] the price when the parent ended, [q]
    the filled size, [u] the unfilled size and [T = q + u] the target, a leg's costs in
    USD are

    - fees: the parents' fees;
    - slippage: [s q (p - a)], fills against the arrival price;
    - timing: [s T (a - d)], the price move between the leader's fill and the follower's
      arrival (copy delay, latency, the leader's own impact);
    - partial fills: [s u (e - a)], the move missed by what did not fill;
    - funding: paid (negative when received).

    The return difference [r_live - r_backtest] (basis points of each leg's start equity)
    splits into one term per cost, [-(cost_live / E_live - cost_backtest / E_backtest)],
    and the residual: what the costs do not explain (market moves on positions held,
    rounding, events one side saw and the other did not). A positive term means live did
    better on that cost. *)

open! Core

module Parent : sig
  type t =
    { coin : string
    ; decision_px : float
    ; report : Execution_algos.Cost_report.t
    }
  [@@deriving sexp_of]
end

module Leg : sig
  type t =
    { start_equity : float
    ; end_equity : float
    ; start_ns : int
    ; end_ns : int
    ; funding : float (** USD paid *)
    ; parents : Parent.t list
    }
  [@@deriving sexp_of]

  val return_ : t -> float

  module Costs : sig
    type t =
      { fees : float
      ; slippage : float
      ; timing : float
      ; partial_fills : float
      ; funding : float
      }
    [@@deriving sexp_of]
  end

  val costs : t -> Costs.t
end

module Term : sig
  type t =
    { name : string
    ; backtest_usd : float
    ; live_usd : float
    ; bps : float (** contribution to [r_live - r_backtest] *)
    }
  [@@deriving sexp_of]
end

type t =
  { backtest_return : float
  ; live_return : float
  ; difference_bps : float
  ; terms : Term.t list (** fees, slippage, timing, partial fills, funding *)
  ; residual_bps : float
  ; dominant : string (** the term (or ["residual"]) with the largest magnitude *)
  ; backtest_parents : int
  ; live_parents : int
  }
[@@deriving sexp_of]

val compute : backtest:Leg.t -> live:Leg.t -> t

(** A fixed-width table, one line per term, then the residual and the totals. *)
val to_string_hum : t -> string

(** The backtest leg of run [run] (default 0) in a [-out] directory: [summary.parquet]
    (equities, funding) and [parents.parquet] (cost reports and decision prices). *)
val backtest_leg : ?run:int -> string -> Leg.t Or_error.t
