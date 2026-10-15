(** A deterministic market and leader from a seed, so tests and demos need no
    recordings.

    One coin. The mid follows a random walk on a 1-unit tick (a 0.5 bp step at 100,000),
    with an L2 snapshot every [book_every] (10 levels per side, random sizes) and trade
    prints at the touch between them; a funding event every hour. The leader changes its
    position every [decide_every] on average, toward a random target within
    [max_position], taking liquidity at the touch: its fills carry the start position,
    the realized pnl against its average entry and a 4.5 bp fee, like Hyperliquid's. *)

open! Core

module Config : sig
  type t =
    { seed : int
    ; coin : string
    ; start : Time_ns.t
    ; duration : Time_ns.Span.t
    ; start_px : float
    ; step_bps : float (** random-walk step per book, in basis points *)
    ; book_every : Time_ns.Span.t
    ; level_size : float (** mean size per level *)
    ; trades_per_book : int
    ; decide_every : Time_ns.Span.t
    ; max_position : float
    ; funding_rate : float (** per hour *)
    }
  [@@deriving sexp]

  (** BTC at 100,000, one hour from 2026-10-16 00:30 UTC (one funding hour), books every 250 ms, 1 BTC per
      level, the leader deciding every 30 s within 2 BTC, funding 0.00125% per hour. *)
  val default : t
end

type t =
  { events : Market_data.Event.t list
  ; fills : Hl_protocol.User_fill.t list
  ; leader : Hl_protocol.Address.t
  }

val generate : Config.t -> t

(** Writes the market as a recorder would ([<dir>/hyperliquid/<coin>/norm/<stream>/<day>.bin],
    {!Market_data.Event_log}) and the fills as [<dir>/leader-fills.ndjson]. *)
val write : dir:string -> t -> unit Async.Deferred.t
