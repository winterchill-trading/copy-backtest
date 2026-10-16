# AGENTS.md: test/

Inline expect tests (library `copy_backtest_test`).

- `test_backtest.ml`: every algo on the synthetic hour, caps, determinism, a known answer.
- `test_output.ml`: Parquet written and read back by DuckDB (needs `duckdb` on the
  `PATH`), a tampered summary rejected, the sweep grid.
- `test_leader_fills.ml`: the file layouts.
- `test_fixture.ml`: the recorded hl-sim window in `fixtures/hl-sim/`.
- `test_stats.ml`: reports per run and per sweep, the gate, `stats.parquet` in DuckDB.
- `test_attribution.ml`: constructed legs, every cost recovered with a zero residual.
- `test_sim_vs_live.ml`: `fixtures/sim-vs-live/` (recording, leader fills, follow file,
  engine journal of one run) backtested and attributed. Remake the fixture with
  `scripts/sim-vs-live.sh` and copy the norm files, fills, meta, follow file and journal
  day file.

Accept new output with `dune promote <file>` (same `--root` and `DUNE_BUILD_DIR` as the
test run), one file at a time, after reading the diff.

See `../AGENTS.md`.
