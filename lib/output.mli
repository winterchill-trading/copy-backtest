(** Results on disk, as Parquet (via the parquet library), and their check with DuckDB.

    [<dir>/summary.parquet]: one row per run ({!Backtest.Summary.t} plus [run]).
    [<dir>/curve.parquet]: [run], [time], [equity], [leader_equity], [gap_bps].
    [<dir>/parents.parquet]: one row per finished parent: [run], [coin], [decision_px],
    [algo], [side], [target], [filled], [avg_px], [arrival_px], [end_px], [arrival],
    [end], [children], [maker_filled], [fees], [arrival_slippage_bps], [shortfall],
    [shortfall_bps], [outcome].

    Runs are numbered from 0 in the order given. *)

open! Core
open! Async

(** Writes the three files, then, with [stats], [<dir>/stats.parquet] (one row per
    {!Stats.Row.t}: [scope] ([run] or [sweep]), [run], [label], [periods], [total_return],
    [sharpe_annualized], [psr], [dsr], [trials], [pbo], [reality_check_p_value],
    [spa_p_value] (the consistent one), [max_drawdown], [verdict], [reasons]) and
    [<dir>/reports.json] (every report in full), and always [<dir>/summary.md]
    ({!markdown}). *)
val write : ?stats:Stats.Row.t list -> dir:string -> Backtest.t list -> unit

(** A markdown table of the summaries with the band and the per-run PSR and DSR, and a
    line on the sweep's pick (PSR, DSR, PBO, reality check and SPA p-values, the gate's
    verdict). *)
val markdown : ?stats:Stats.Row.t list -> Backtest.t list -> string

(** Reads the three files back with the DuckDB CLI and recomputes, per run, the number of
    parents, the summed shortfall and fees of the parents, the end equity and the maximum
    drawdown of the curve, then compares them with the summaries (relative tolerance
    1e-9). Returns one line per run; an error when [duckdb] is not on the [PATH], a query
    fails or a value differs. *)
val check_duckdb : dir:string -> Backtest.t list -> string list Or_error.t Deferred.t

(** A fixed-width table of the summaries, one line per run. *)
val table : Backtest.t list -> string
