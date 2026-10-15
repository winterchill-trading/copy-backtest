(** What a backtest replays: market events and the leader's fills in one time order.

    A leader fill is seen [copy_delay] after its exchange time (the time the engine
    would learn it), and an event from the recording at its receive time, so the replay
    sees what a live follower would have seen. Ties keep market events first. *)

open! Core

module Item : sig
  type t =
    | Market of Market_data.Event.t
    | Leader of Hl_protocol.User_fill.t
  [@@deriving sexp_of]
end

type t = (int * Item.t) array (** nanoseconds since the epoch, sorted *)

val create
  :  ?copy_delay:Time_ns.Span.t
  -> events:Market_data.Event.t list
  -> fills:Hl_protocol.User_fill.t list
  -> unit
  -> t

(** Every event of [coins] on [venue] (default Hyperliquid) under a recorder data
    directory ([<dir>/<venue>/<coin>/norm/<stream>/<day>.bin]) for the UTC days from
    [from] to [to_] (inclusive), merged by receive time. Fails when no file exists. *)
val load_norm
  :  ?venue:Market_data.Venue.t
  -> dir:string
  -> coins:string list
  -> from:Date.t
  -> to_:Date.t
  -> unit
  -> Market_data.Event.t list Or_error.t Async.Deferred.t

(** First and last time of the items. *)
val span : t -> (int * int) option
