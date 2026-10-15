(** One backtest's settings. *)

open! Core
open Hl_copy_core

type t =
  { follow : Follower_config.t
  (** mode, caps, IOC slippage bound and execution algo, as the engine reads them *)
  ; start_equity : float (** follower USD *)
  ; leader_equity : float
  (** the leader's USD equity at the start (its realized and unrealized pnl from the
      replayed fills are added as it trades) *)
  ; copy_delay : Time_ns.Span.t (** leader fill on the exchange to the engine seeing it *)
  ; latency : Time_ns.Span.t (** order sent to order live on the venue *)
  ; tick : Time_ns.Span.t (** market ticks for the algorithms *)
  ; sample : Time_ns.Span.t (** equity curve spacing *)
  ; taker_fee_bps : float
  ; maker_fee_bps : float
  ; funding : bool (** pay or receive funding at each UTC hour *)
  ; specs : Specs.t
  }
[@@deriving sexp_of]

(** Defaults: 10,000 USD follower, 1,000,000 USD leader, 200 ms copy delay, 50 ms
    latency, 500 ms ticks, 10 s samples, 4.5 / 1.5 bp fees, funding on. *)
val create
  :  ?start_equity:float
  -> ?leader_equity:float
  -> ?copy_delay:Time_ns.Span.t
  -> ?latency:Time_ns.Span.t
  -> ?tick:Time_ns.Span.t
  -> ?sample:Time_ns.Span.t
  -> ?taker_fee_bps:float
  -> ?maker_fee_bps:float
  -> ?funding:bool
  -> follow:Follower_config.t
  -> specs:Specs.t
  -> unit
  -> t

(** A short label of the run's varying settings: algo, mode, leverage and notional caps. *)
val label : t -> string
