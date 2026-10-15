(** Results on disk, as Parquet (via the parquet library), and their check with DuckDB.

    [<dir>/summary.parquet]: one row per run ({!Backtest.Summary.t} plus [run]).
    [<dir>/curve.parquet]: [run], [time], [equity], [leader_equity], [gap_bps].
    [<dir>/parents.parquet]: one row per finished parent: [run], [coin], [algo], [side],
    [target], [filled], [avg_px], [arrival_px], [end_px], [arrival], [end], [children],
    [maker_filled], [fees], [arrival_slippage_bps], [shortfall], [shortfall_bps],
    [outcome].

    Runs are numbered from 0 in the order given. *)

open! Core
open! Async

val write : dir:string -> Backtest.t list -> unit

(** Reads the three files back with the DuckDB CLI and recomputes, per run, the number
    of parents, the summed shortfall and fees of the parents, the end equity and the
    maximum drawdown of the curve, then compares them with the summaries (relative
    tolerance 1e-9). Returns one line per run; an error when [duckdb] is not on the
    [PATH], a query fails or a value differs. *)
val check_duckdb : dir:string -> Backtest.t list -> string list Or_error.t Deferred.t

(** A fixed-width table of the summaries, one line per run. *)
val table : Backtest.t list -> string
