# Changes

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning once released.

## Unreleased

- `Backtest`: replays market event logs and a leader's fills through the copy mirror and
  the execution algorithms, with paper fills against the replayed book (queue position,
  latency), fees, hourly funding, caps and the daily-loss window.
- Equity curve, tracking error and gap against the leader, per-parent cost reports.
- `Output`: summary, curve and parents Parquet files, checked against DuckDB.
- `Sweep`: algorithms, scale modes and caps over the same data.
- `Synthetic`: a seeded market and leader; `Leader_fills` for userFills files.
- `copy-backtest run`, `sweep`, `synthetic` and `slice` commands.
