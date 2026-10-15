(** The replayed market of one coin: the L2 book (or the BBO when the recording has no
    depth), the cumulative traded size, the last trade and the funding rate, and the
    snapshot the schedulers and the paper venue see. *)

open! Core

type t

val create : unit -> t

(** Applies one recorded event. *)
val apply : t -> Market_data.Event.t -> unit

(** Top 20 levels per side; empty before the first book. *)
val book : t -> Execution_algos.Book.t

val traded : t -> Market_data.Size.t

(** The book's mid, else the last trade price. *)
val mark : t -> Market_data.Price.t option

(** Funding rate per hour of the last funding event (Hyperliquid funds hourly); [None]
    before the first. *)
val funding_rate : t -> float option
