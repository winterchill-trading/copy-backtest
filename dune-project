(lang dune 3.17)

(name copy-backtest)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/copy-backtest))

(package
 (name copy-backtest)
 (synopsis
  "Deterministic backtester for copy trading: recorded markets, a leader's fills, the mirror and execution algorithms")
 (description
  "Replays recorded market data (market-data event logs) and a leader's Hyperliquid fill history through hl-copy-core's mirror and execution-algos' schedulers, filling child orders against the replayed book with queue position, fees, funding, latency and risk caps. Writes equity curves, tracking error against the leader and per-parent cost reports to Parquet, checked with DuckDB, and runs parameter sweeps. A synthetic market and leader need no recordings.")
 (tags
  (trading backtest copy-trading oxcaml))
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  yojson
  ppx_jane
  ppx_yojson_conv
  fixed-decimal
  exchange-core
  parquet
  market-data
  hl-protocol
  hl-copy-core
  execution-algos
  backtest-stats))
