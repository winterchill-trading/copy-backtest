# AGENTS.md: bin/

`main.ml`, the `copy-backtest` command group: `run` (one configuration), `sweep` (a grid
of algos, modes, caps and no-trade bands), `synthetic` (write seeded data in the recorder
layout), `slice` (cut a window of recordings and leader fills, for fixtures) and
`attribute` (a live engine journal against a backtest run). Data comes from
`-leader-fills FILE -norm DIR` or `-synthetic SEED`; `-out DIR` writes Parquet, the
statistics and `summary.md`, and runs the DuckDB check unless `-no-duckdb`. `-gate
POLICY.sexp` makes `run` and `sweep` exit 1, after writing, when the policy rejects the
decisive report.

See `../AGENTS.md`.
