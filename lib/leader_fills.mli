(** A leader's fill history: Hyperliquid [userFills] objects, read from a file.

    Accepted layouts, one or several per file:
    - a JSON array of fills (what [POST /info {"type": "userFills"}] returns);
    - one JSON fill object per line (NDJSON);
    - one JSON array per line, optionally after a timestamp and a space, as
      hl-leaderboard's raw files store each page ([<ISO time> [...]]).

    Fills are de-duplicated by trade id and sorted by time (then trade id). *)

open! Core

val of_string : string -> Hl_protocol.User_fill.t list Or_error.t
val load : string -> Hl_protocol.User_fill.t list Or_error.t

(** One fill object per line. *)
val to_ndjson : Hl_protocol.User_fill.t list -> string

(** Fills of the coins in [coins] (all when empty) with [time] (epoch milliseconds) in the
    half-open interval from [from] (inclusive) to [to_] (exclusive). *)
val select
  :  ?coins:string list
  -> ?from:Time_ns.t
  -> ?to_:Time_ns.t
  -> Hl_protocol.User_fill.t list
  -> Hl_protocol.User_fill.t list

(** The coins traded, sorted. *)
val coins : Hl_protocol.User_fill.t list -> string list

(** The leader's position in the fill's coin right after it: [start_position] plus the
    signed size. *)
val position_after : Hl_protocol.User_fill.t -> Market_data.Size.t
