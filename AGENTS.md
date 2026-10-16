# AGENTS.md: copy-backtest

## Purpose

copy-backtest replays recorded market data and a leader's Hyperliquid fills through the
copy mirror (`hl-copy-core`) and the execution algorithms (`execution-algos`), filling
child orders on paper venues against the replayed book. It reports equity curves,
tracking error and execution costs, as Parquet checked with DuckDB, and sweeps settings
(including hl-copy-core's no-trade bands). It scores runs and sweeps with backtest-stats
(PSR, DSR, PBO, SPA, an acceptance gate) and attributes a live engine journal's return
gap against its backtest.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `copy-backtest` (module `Copy_backtest`): `Backtest`, `Source`, `Market`, `Leader_fills`, `Params`, `Specs`, `Copy_algo`, `Output`, `Sweep`, `Synthetic`, `Stats`, `Attribution`, `Live_journal` |
| `bin/` | The `copy-backtest` command: `run`, `sweep`, `synthetic`, `slice`, `attribute` |
| `scripts/` | `sim-vs-live.sh`: hl-sim, market-recorder and hl-copy-engine at once, then the backtest and the attribution |
| `test/` | Expect tests on synthetic data, a known-answer case, the DuckDB check and the hl-sim fixture |
| `test/fixtures/hl-sim/` | Two minutes of hl-sim BTC event logs and a simulated leader's fills (`slice` output) |
| `test/fixtures/sim-vs-live/` | Three minutes of hl-sim BTC event logs, leader 1's fills, the follow file and the engine journal of the same run (`scripts/sim-vs-live.sh`) |
| `.github/` | CI workflow |

## Build, test, docs

Run from this repository, inside the workspace:

    opam exec --switch 5.2.0+ox -- dune build --root .. @copy-backtest/all
    opam exec --switch 5.2.0+ox -- dune build --root .. @copy-backtest/runtest
    opam exec --switch 5.2.0+ox -- dune build --root .. @copy-backtest/doc
    opam exec --switch 5.2.0+ox -- dune exec --root .. copy-backtest -- sweep -synthetic 1 -leader-equity 100000 -out /tmp/cb

Parallel agents set `DUNE_BUILD_DIR=_build-copy-backtest`. Tests need the `duckdb` CLI on
the `PATH` (CI installs it). The docs build must produce no warnings.

## Conventions

- Format this repository only: `dune build --root .. @copy-backtest/fmt --auto-promote`.
- Every module has an `.mli` with odoc on each value; no odoc links into other packages
  (CI builds docs without theirs): write `[Market_data.X]`, not a link.
- The replay is deterministic: no clock reads, no randomness outside `Synthetic`'s seed.
  A change in results shows up in `test/test_backtest.ml`; read the diff before
  promoting it.
- Mirror and scheduler semantics belong in `hl-copy-core` and `execution-algos`; this
  repository only wires them and models the venue.
- User-visible changes get a line under `## Unreleased` in `CHANGES.md`.
- Statistics come from backtest-stats; do not reimplement a ratio or a test here. Print
  bootstrap and simulated statistics rounded (three decimals) in tests: the last digits
  differ between arm64 and amd64.
- `Live_journal` reads the engine's journal through `Hl_copy_engine.Journal` and replays
  it with `Follower_core`; a new journal version in the engine needs a branch in
  `Live_journal.load_file`.

## Dependencies

- Sibling repositories: `fixed-decimal`, `exchange-core`, `parquet`, `backtest-stats`,
  `market-data`, `hl-protocol`, `venue-net`, `hl-client`, `hl-copy-core`,
  `execution-algos`, `hl-copy-engine` (for its journal format).
- Used by: nothing in the organization yet.
- CI pin order: `fixed-decimal`, `exchange-core`, `parquet`, `backtest-stats`,
  `market-data`, `hl-protocol`, `venue-net`, `hl-client`, `hl-copy-core`,
  `execution-algos`, `hl-copy-engine`.

## CI

`.github/workflows/ci.yml`: infra `ox-setup` (cached switch, pins above), the DuckDB CLI,
build, tests, odoc with warnings failing the step, and the shared obj-magic job. Check
with one `gh run list --limit 1` and at most one `gh run watch <id> --exit-status`.

## Pitfalls

- Base's `List.init` calls `f` from the last index down; keep generators in index order
  with `List.range`.
- `open Async` makes `return` the Deferred one; inside `Command` parameter blocks it is
  the parameter's. Write `Deferred.return` there.
- A broken dune file in any workspace repository stops every build; use a scratch
  workspace of symlinks or `git archive` snapshots of the dependencies.

## Where to read more

- `README.md`; `../specs/repos/copy-backtest.md`; `../specs/design/copytrading.md`.
- `../execution-algos/README.md` (algorithms, cost definitions, paper venue).
- Workspace guide: `../oxcaml-claude-skills/AGENTS.md`.

## Never do

- Install opam packages that change the compiler, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release; poll CI in a loop.
- Send anything to a live venue: this repository only reads recordings;
  `scripts/sim-vs-live.sh` runs against hl-sim with throwaway keys only.
