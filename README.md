# copy-backtest

A deterministic backtester for copy trading, in [OxCaml](https://oxcaml.org). It replays
recorded market data (the `Market_data.Event_log` files
[market-recorder](https://github.com/winterchill-trading/market-recorder) writes) and a
leader's Hyperliquid fill history through the copy mirror of
[hl-copy-core](https://github.com/winterchill-trading/hl-copy-core) and the execution
algorithms of [execution-algos](https://github.com/winterchill-trading/execution-algos),
the same code the copy engine runs, and fills the follower's child orders on paper venues
against the replayed book. It reports the follower's equity curve against the leader's,
tracking error, execution costs per parent order, fees and funding, writes them to
Parquet with the pure-OCaml [parquet](https://github.com/winterchill-trading/parquet)
writer, and checks the files with DuckDB. A synthetic mode needs no recordings.

`hl-copy-backtest` (in hl-copy-core) answers a different question: it ranks leaders
from leaderboard collections, filling each order at the leader's own price plus a fixed
slippage. This repository needs the market itself (book, trades, funding) and models
how the follower's orders would actually have executed.

## Commands

```sh
# one configuration on recorded data (UTC days default to the span of the fills)
copy-backtest run -leader-fills leader.json -norm DATA_DIR [-from 2026-10-15 -to 2026-10-16] \
  [-coins BTC] [-meta meta.json] -algo adaptive [-mode equity|mult:0.5|fixed:1000] \
  [-max-leverage 3] [-max-notional 5000] [-max-daily-loss 200] [-config follow.sexp] \
  [-equity 10000] [-leader-equity 100000] [-out results/]

# every combination of algorithms, scale modes and caps over the same data
copy-backtest sweep -leader-fills leader.json -norm DATA_DIR \
  -algos immediate,twap:30s:3,pov:0.2:60s,passive:20s,adaptive \
  -modes equity,mult:0.5 -max-leverages none,3 -out results/

# no recordings: a seeded market and leader
copy-backtest sweep -synthetic 1 -leader-equity 100000 -out results/
copy-backtest synthetic -seed 1 -hours 2 -out DIR     # the same data in the recorder layout

# cut a window of recordings and fills (how test/fixtures/hl-sim was made)
copy-backtest slice -norm DATA_DIR -leader-fills leader.json -coins BTC \
  -start 2026-10-15T23:59:00Z -stop 2026-10-16T00:01:00Z -out DIR
```

`-leader-fills` takes `userFills` as a JSON array (what `POST /info {"type":"userFills"}`
returns), NDJSON, or hl-leaderboard's raw pages. Other settings: `-copy-delay-ms` (200,
leader fill to the engine seeing it), `-latency-ms` (50, order to venue), `-resync-s`
(30, the engine's resync), `-tick-ms` (500, algorithm ticks), `-sample-s` (10, curve),
`-taker-fee-bps` 4.5, `-maker-fee-bps` 1.5, `-slippage-bps` (the follow's IOC bound, 20),
`-no-funding`, `-no-duckdb`.

## Model

Items are replayed in time order: market events at their receive time, the leader's
fills of one coin and millisecond (one message of the engine's feed) at their exchange
time plus the copy delay.

- A market event updates the coin's book (top 20 levels; the BBO when there is no
  depth), traded volume, funding rate and mark (the mid), and the coin's paper venue.
- A leader change updates the leader's average-entry book (a position held before the
  first fill opens at that fill's price) and its equity (`-leader-equity` plus realized
  and unrealized pnl, less fees). Both equities go to `Mirror`, which plans the
  follower's orders exactly as the engine does: scale mode, caps, lot and tick rounding,
  the 10 USD minimum order, in-flight orders.
- Every planned order is a parent worked by the follow's algorithm from that moment
  (`Execution_algos.Scheduler`); a parent below the minimum order goes out as one IOC.
  Children reach the paper venue after the latency: IOCs walk the replayed book within
  their limit (less what earlier IOCs took from the same snapshot); post-only children
  rest behind the displayed size at their price, trades at the price eat that queue
  first and trades through it fill them, a smaller displayed size shortens the queue and
  a book crossing the price fills them as the maker (the queue ideas of price-anchor's
  `Queue_ahead`).
- On a fixed grid: the engine's resync every 30 s (a rebalance of every coin, which
  re-plans what IOCs left unfilled), algorithm ticks, curve samples, funding at every
  UTC hour (position x mark x the coin's last hourly rate, longs pay a positive rate) and
  the daily-loss window at every UTC midnight.

Not modelled: the market's reaction to the follower (a fill takes from the replayed
snapshot until the next one; the leader's own impact is already in the recording),
liquidations, margin rejects, and the engine's websocket and REST delays beyond the two
fixed latencies.

## Output

| | |
| --- | --- |
| `Summary` | pnl, return, maximum drawdown, fees, funding, turnover, leader changes, parents (filled, open), children, fill rate (filled over target notional), shortfall (USD and bps of target), slippage against arrival mids, maker share, tracking error (standard deviation of the per-sample return difference, follower minus leader, in bps), mean gap (sum over coins of `\|target - position\| x mark` over equity), the leader's return |
| curve | per sample: follower equity, leader equity, gap |
| parents | one `Execution_algos.Cost_report` per finished parent: algo, side, target, filled, average, arrival and end prices, times, children, maker size, fees, arrival slippage, implementation shortfall, outcome |

`-out DIR` writes `summary.parquet`, `curve.parquet` and `parents.parquet` (zstd), then
runs one DuckDB query that recomputes, per run, the number of parents, their summed
shortfall and fees, the end equity and the maximum drawdown (a window over the curve) and
compares them with the in-memory summary; a difference fails the check.

## Numbers

### hl-sim recording

hl-sim (seed 11, three simulated leaders with 100,000 USD each, 40 noise traders) was
recorded with market-recorder for 17 minutes on 2026-10-15/16 (BTC trades, BBO and L2;
32,198 events across two UTC days; the simulator serves no funding), and each leader's
`userFills` saved at the end. A 10,000 USD follower in `Equity_ratio` mode, default
settings, `sweep -algos immediate,twap:30s:3,pov:0.2:60s,passive:20s,adaptive`:

| Leader | Algo | Return | Max drawdown | Fees | Parents | Children | Fill rate | Shortfall (bps) | Slippage (bps) | Maker share | Tracking error (bps) | Mean gap (bps) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 (trend, +3.27%) | immediate | 5.42% | 1.25% | 137.35 | 47 | 47 | 87.8% | 8.28 | 4.87 | 0 | 4.85 | 303 |
| | twap:30s:3 | 5.91% | 0.78% | 118.60 | 52 | 128 | 82.3% | 6.61 | 0.46 | 0 | 10.81 | 3,892 |
| | pov:0.2:1m | 6.16% | 1.08% | 137.83 | 47 | 337 | 98.2% | 6.23 | 1.78 | 0 | 6.38 | 991 |
| | passive:20s | 7.08% | 1.00% | 44.31 | 46 | 207 | 95.2% | 3.43 | 1.91 | 1.00 | 7.71 | 872 |
| | adaptive | 5.42% | 1.22% | 137.34 | 46 | 61 | 100.0% | 8.68 | 4.18 | 0 | 4.54 | 4 |
| 1 (mean reversion, +0.94%) | immediate | 4.36% | 1.10% | 192.17 | 89 | 89 | 92.4% | 9.75 | 5.94 | 0 | 5.18 | 159 |
| | twap:30s:3 | 5.91% | 0.93% | 131.81 | 96 | 218 | 71.1% | 7.03 | 0.74 | 0 | 9.97 | 3,539 |
| | pov:0.2:1m | 6.23% | 0.93% | 198.62 | 90 | 519 | 97.7% | 5.67 | 1.16 | 0 | 6.80 | 1,171 |
| | passive:20s | 7.61% | 0.93% | 64.09 | 91 | 327 | 92.9% | 2.68 | 0.63 | 1.00 | 8.28 | 1,281 |
| | adaptive | 4.29% | 1.08% | 198.76 | 90 | 107 | 100.0% | 10.03 | 5.53 | 0 | 5.03 | 3 |
| 2 (random, +2.40%) | immediate | 2.50% | 1.74% | 53.05 | 20 | 20 | 99.4% | 12.51 | 8.08 | 0 | 2.25 | 10 |
| | twap:30s:3 | 3.24% | 1.26% | 53.10 | 25 | 61 | 84.0% | 4.76 | -1.10 | 0 | 9.97 | 2,031 |
| | pov:0.2:1m | 3.55% | 1.26% | 53.29 | 19 | 134 | 100.0% | 3.59 | -0.91 | 0 | 4.09 | 19 |
| | passive:20s | 3.60% | 1.26% | 17.75 | 20 | 94 | 95.1% | 3.04 | 0.78 | 1.00 | 5.32 | 326 |
| | adaptive | 2.51% | 1.74% | 53.07 | 20 | 22 | 100.0% | 12.38 | 7.88 | 0 | 2.26 | 2 |

Every run's DuckDB check agreed. Reading it:

- The follower beats the leader it copies on the simulator: its orders are a tenth of
  the leader's, so they take the top of the book while the leader's market orders sweep
  many levels (the leaders' 1,193 to 4,340 fills are 18 to 85 orders).
- `Immediate` and `adaptive` track the leader closely (a mean gap of 4 bps or less for
  adaptive, which keeps taking until filled; `Immediate` leaves IOC remainders to the
  next resync). Slicing and resting trade tracking for cost: `passive` pays a third of
  the fees and under half the shortfall but lags the leader by 3 to 13% of equity on
  average, TWAP by 20 to 39%. With a trending leader on a short window the lag happened
  to pay; it is a risk, not an edge.
- On these thin books the default adaptive bounds (50 bps of equity behind) make every
  parent aggressive: a leader change is several percent of the follower's equity.

The runs take 0.06 s each (32,198 events and 4,340 fills, dev build, Apple M-series);
a 4-hour synthetic run (172,800 events) takes 0.27 s including generating the data.

### Synthetic hour

`test/test_backtest.ml` pins every algorithm on the seeded synthetic hour (a leader at up
to 200% leverage changing its position every 30 s on a 1-unit-tick book): copying it loses
about 6% for the takers, 4.55 bps of fees per parent and almost no slippage; `passive`
and the iceberg pay maker fees and lose half as much, at a gap of 11 to 34% of equity.

## Tests

`dune test`: the synthetic hour through six algorithms, caps, determinism, a
known-answer case (one leader buy on a static book: the follower buys 0.10004 BTC at the
ask, 4.5 bp), the Parquet files read back by DuckDB with a tampered summary rejected,
the sweep grid, the fill file layouts, and the recorded hl-sim fixture
(`test/fixtures/hl-sim`, two minutes across a UTC midnight with leader 1's fills) through
three algorithms. The DuckDB CLI must be on the `PATH` (CI installs it).

## Build

Inside the organization's dune workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @copy-backtest/all @copy-backtest/runtest
opam exec --switch 5.2.0+ox -- dune exec --root .. copy-backtest -- sweep -synthetic 1 -leader-equity 100000
```

Standalone, with the organization's opam repository added: `opam install . --deps-only
--with-test && dune build && dune test`.
