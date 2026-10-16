# AGENTS.md: test/

Inline expect tests (library `copy_backtest_test`).

- `test_backtest.ml`: every algo on the synthetic hour, caps, determinism, a known answer.
- `test_output.ml`: Parquet written and read back by DuckDB (needs `duckdb` on the
  `PATH`), a tampered summary rejected, the sweep grid.
- `test_leader_fills.ml`: the file layouts.
- `test_fixture.ml`: the recorded hl-sim window in `fixtures/hl-sim/`.

Accept new output with `dune promote <file>` (same `--root` and `DUNE_BUILD_DIR` as the
test run), one file at a time, after reading the diff.

See `../AGENTS.md`.
