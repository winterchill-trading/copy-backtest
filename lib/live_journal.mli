(** The live side of an {!Attribution}: a follow's hl-copy-engine journal, replayed through
    the engine's pure core ([Hl_copy_engine.Follower_core]) so every parent order is seen
    when it starts (its coin and the mirror's mark at that moment: the leader's fill price
    for a leader update, the mid for a resync) and when it finishes (its cost report).

    The follower's equity is the mirror's, from the resyncs (the engine reads
    [clearinghouseState]): the first known value is the start, the last the end. Funding
    is not journaled; the live leg's funding is zero. *)

open! Core
open! Async

(** Every entry of a journal: a follow's directory ([<journal-dir>/<follower>-<leader>],
    all day files in order) or one day file ([.journal], [.v2.journal] or
    [.v3.journal]). *)
val load : string -> Hl_copy_engine.Journal.Entry.t list Or_error.t Deferred.t

val leg : Hl_copy_engine.Journal.Entry.t list -> Attribution.Leg.t Or_error.t
