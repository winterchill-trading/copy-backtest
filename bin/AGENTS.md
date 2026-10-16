# AGENTS.md: bin/

`main.ml`, the `copy-backtest` command group: `run` (one configuration), `sweep` (a grid
of algos, modes and caps), `synthetic` (write seeded data in the recorder layout) and
`slice` (cut a window of recordings and leader fills, for fixtures). Data comes from
`-leader-fills FILE -norm DIR` or `-synthetic SEED`; `-out DIR` writes Parquet and runs
the DuckDB check unless `-no-duckdb`.

See `../AGENTS.md`.
