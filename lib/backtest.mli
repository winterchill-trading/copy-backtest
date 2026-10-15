(** The replay: a {!Source.t} through the copy mirror ([Hl_copy_core.Mirror]) and the
    execution algorithms ([Execution_algos.Scheduler]), with child orders filled by one
    [Execution_algos.Paper] venue per coin against the replayed book.

    For each item in time order:

    - a market event updates the coin's {!Market} and its paper venue (queue caps,
      crossing fills on a new book; queue and through fills on a trade), and the mark;
    - a leader fill moves the leader's position in its coin; both equities go to the
      mirror, which plans the follower's orders exactly as the engine does (scaling, caps,
      lot and tick rounding, minimum order). Each planned order is a parent worked by the
      follow's algorithm from that moment; a parent below the minimum order goes out as
      one IOC.

    Between items, on a fixed grid: market ticks for the parents ([tick]), equity samples
    ([sample]), funding at every UTC hour (position times mark times the coin's last
    hourly rate) and the daily-loss window at every UTC midnight.

    Fills pay [taker_fee_bps] or [maker_fee_bps]. Orders take [latency] to reach the
    venue. The leader's equity is [leader_equity] plus its realized and unrealized pnl on
    average-entry books of the replayed fills (a position held before the first fill is
    opened at that fill's price). The market does not react to the follower's orders (a
    fill takes from the replayed snapshot until the next one). *)

open! Core

module Point : sig
  type t =
    { time_ns : int
    ; equity : float (** follower, marked to the mids *)
    ; leader_equity : float
    ; gap_bps : float
    (** sum over coins of [|target - position| * mark], over the follower's equity: how
        far the follower is from the capped, scaled image of the leader *)
    }
  [@@deriving sexp_of]
end

module Parent : sig
  type t =
    { coin : string
    ; report : Execution_algos.Cost_report.t
    }
  [@@deriving sexp_of]
end

module Summary : sig
  type t =
    { label : string
    ; algo : string
    ; mode : string
    ; max_leverage : float option
    ; start_equity : float
    ; end_equity : float
    ; pnl : float
    ; return_ : float
    ; max_drawdown : float (** largest fall from a peak of the curve, as a fraction *)
    ; fees : float
    ; funding : float (** paid; negative when received *)
    ; turnover : float (** filled notional *)
    ; leader_changes : int
    ; parents : int (** finished parents *)
    ; filled_parents : int
    ; open_parents : int (** still working when the data ended *)
    ; children : int
    ; fill_rate : float (** filled notional over the parents' target notional *)
    ; shortfall : float (** USD, from the cost reports *)
    ; shortfall_bps : float (** of the parents' target notional *)
    ; slippage_bps : float (** fills against arrival mids, of the filled notional *)
    ; maker_share : float (** of the filled size *)
    ; tracking_error_bps : float
    (** standard deviation of the per-sample return difference, follower minus leader *)
    ; mean_gap_bps : float (** {!Point.t.gap_bps} averaged over the samples *)
    ; leader_return : float
    }
  [@@deriving sexp_of, fields]
end

type t =
  { summary : Summary.t
  ; curve : Point.t list
  ; parents : Parent.t list (** in the order they finished *)
  }
[@@deriving sexp_of]

val run : Params.t -> Source.t -> t
