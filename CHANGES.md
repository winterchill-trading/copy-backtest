# Changes

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning once released.

## Unreleased

### Added

- No-trade bands: a follow's `band` plans through hl-copy-core's `No_trade_band` as the
  engine does (with `Impact` slippage estimated from each replayed book); `-band`,
  `-bands` in the sweep grid; band skips and their cost in the summary.
- `Stats`: a backtest-stats `Report` per run (PSR, DSR with the sweep as trials) and one
  for the sweep's pick (PBO across the grid, reality check and SPA against the leader);
  `-gate POLICY.sexp` fails the command on a rejection, `-oos-fraction`.
- `stats.parquet`, `reports.json` and `summary.md` in `-out`; `decision_px` in
  `parents.parquet`.
- `Attribution` and `Live_journal`: `copy-backtest attribute -backtest DIR -journal FILE`
  splits a live engine run's return difference from its backtest into fees, slippage,
  timing, partial fills, funding and a residual.
- `scripts/sim-vs-live.sh`; the `test/fixtures/sim-vs-live` recording with its journal.

### Changed

- Depends on backtest-stats and hl-copy-engine.

- `Backtest`: replays market event logs and a leader's fills through the copy mirror and
  the execution algorithms, with paper fills against the replayed book (queue position,
  latency), fees, hourly funding, caps and the daily-loss window.
- Equity curve, tracking error and gap against the leader, per-parent cost reports.
- `Output`: summary, curve and parents Parquet files, checked against DuckDB.
- `Sweep`: algorithms, scale modes and caps over the same data.
- `Synthetic`: a seeded market and leader; `Leader_fills` for userFills files.
- `copy-backtest run`, `sweep`, `synthetic` and `slice` commands.
