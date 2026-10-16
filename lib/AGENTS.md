# AGENTS.md: lib/

The `copy-backtest` library, module `Copy_backtest`.

- `backtest.ml`: the replay. `run` walks the `Source` items; `advance` runs the grid
  (algo ticks, curve samples, funding hours, daily-loss window); parents are
  `Execution_algos.Scheduler`s, child ids made unique per coin for its `Paper` venue.
- `source.ml`, `market.ml`, `leader_fills.ml`, `synthetic.ml`: the inputs.
- `params.ml`, `specs.ml`, `copy_algo.ml`, `sweep.ml`: the settings.
- `output.ml`: Parquet files and the DuckDB check (the SQL recomputes parents, shortfall,
  fees, end equity and drawdown).

Rule: the replay must stay deterministic and must not reimplement mirror or scheduler
logic; change those in their own repositories.

See `../AGENTS.md`.
