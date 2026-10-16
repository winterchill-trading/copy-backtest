# AGENTS.md: .github/

`workflows/ci.yml` builds and tests on the infra `ox-setup` action, installs the DuckDB
CLI the tests use, builds the odoc docs (any warning fails) and runs the shared
obj-magic job.

The `pins` list must match the org dependencies in `../dune-project`, in dependency
order: `fixed-decimal`, `exchange-core`, `parquet`, `market-data`, `hl-protocol`,
`hl-copy-core`, `execution-algos`.

See `../AGENTS.md`.
