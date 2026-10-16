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

# no-trade bands in a sweep, statistics gated by a policy (exit 1 on a rejection)
copy-backtest sweep ... -bands none,default,ra:200,quad:20:0.01 \
  -gate policy.sexp -oos-fraction 0.3 -out results/

# a live engine journal against a backtest of the same leader and window
copy-backtest attribute -backtest results/ [-run 0] \
  -journal journal/<follower>-<leader>[/2026-10-16.v3.journal]
```

`-leader-fills` takes `userFills` as a JSON array (what `POST /info {"type":"userFills"}`
returns), NDJSON, or hl-leaderboard's raw pages. Other settings: `-copy-delay-ms` (200,
leader fill to the engine seeing it), `-latency-ms` (50, order to venue), `-resync-s`
(30, the engine's resync), `-tick-ms` (500, algorithm ticks), `-sample-s` (10, curve),
`-taker-fee-bps` 4.5, `-maker-fee-bps` 1.5, `-slippage-bps` (the follow's IOC bound, 20),
`-no-funding`, `-no-duckdb`, `-band` (one no-trade band for `run`, and the default of
`sweep`'s `-bands`: `none`, `default`, `ra:G` for the default band with risk aversion
`G`, `impact:G` with slippage estimated from the book, `quad:G:ETA` for quadratic costs,
or the band's sexp; see hl-copy-core's `No_trade_band`), `-gate POLICY.sexp` (a
backtest-stats `Gate.Policy`), `-oos-fraction F` (the last share of each curve is out of
sample for the statistics, 0 by default).

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
- With a no-trade band in the follow the mirror holds back rebalances inside it, as the
  engine does; a band with `Impact` slippage gets its estimate from every replayed book
  (the order that would close the coin's gap, walked with `Execution_algos.Impact`).
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
| `Summary` | pnl, return, maximum drawdown, fees, funding, turnover, leader changes, parents (filled, open), children, fill rate (filled over target notional), shortfall (USD and bps of target), slippage against arrival mids, maker share, tracking error (standard deviation of the per-sample return difference, follower minus leader, in bps), mean gap (sum over coins of `\|target - position\| x mark` over equity), the leader's return, band skips (`Within_band` notes, counted again at each resync while a gap lasts) and their estimated cost |
| curve | per sample: follower equity, leader equity, gap |
| parents | one `Execution_algos.Cost_report` per finished parent: algo, side, target, filled, average, arrival and end prices, times, children, maker size, fees, arrival slippage, implementation shortfall, outcome; and the decision price (the leader's fill price of the change that planned it, the mark for a resync) |
| stats | one backtest-stats `Report` per run and one for the sweep's pick (below) |

`-out DIR` writes `summary.parquet`, `curve.parquet` and `parents.parquet` (zstd), then
runs one DuckDB query that recomputes, per run, the number of parents, their summed
shortfall and fees, the end equity and the maximum drawdown (a window over the curve) and
compares them with the in-memory summary; a difference fails the check. It also writes
`stats.parquet` (one row per report: scope `run` or `sweep`, the run, periods, total
return, annualized Sharpe ratio, PSR, DSR and its trial count, PBO, reality check and SPA
p-values, maximum drawdown, the gate's verdict and reasons), `reports.json` (every report
in full) and `summary.md` (the summary table with the band and PSR/DSR columns, and the
sweep's pick).

### Statistics

The returns are the follower's curve, one per sample, annualized with the number of
samples in a year; the leader's curve over the same samples is the benchmark.

- Every run: Sharpe and Sortino ratios (plain and autocorrelation-adjusted), the
  probabilistic Sharpe ratio, drawdowns; in a sweep, the deflated Sharpe ratio with every
  configuration of the sweep counted as a trial.
- The sweep: the configuration with the best per-sample Sharpe ratio is its pick. Its
  report has every configuration as a candidate: the probability of backtest overfitting
  by combinatorially symmetric cross-validation across the parameter grid, White's reality
  check and the SPA test against the leader (stationary block bootstrap, seeded), and the
  DSR.
- `-gate POLICY.sexp` judges the decisive report (the run's, or the sweep pick's) and
  exits 1 after writing everything when the policy rejects it:

```text
((min_periods 500) (min_out_of_sample_fraction 0.3) (min_psr 0.95)
 (min_out_of_sample_psr 0.9) (min_dsr 0.9) (max_pbo 0.2) (max_spa_p_value 0.05)
 (max_drawdown 0.25))
```

## Sim versus live

`copy-backtest attribute -backtest DIR -journal FILE` compares one backtest run with a
follow's hl-copy-engine journal (its directory or one day file) over the same leader and
window. The journal is replayed through the engine's pure core, so each parent is seen
when it starts (coin, the mirror's mark: the leader's fill price for a leader update) and
when it ends (its cost report); the follower's equity is the resyncs'. With `s` the side
(+1 buy), `d` the decision price, `a` the arrival, `p` the average fill, `e` the price at
the end, `q` filled, `u` unfilled and `T = q + u`, each side's costs are fees,
slippage `s q (p - a)`, timing `s T (a - d)`, partial fills `s u (e - a)` and funding.
The return difference (live minus backtest, in bps of each side's start equity) is the
sum of one term per cost, `-(cost_live / E_live - cost_backtest / E_backtest)`, and a
residual (market moves on the positions held, rounding, events one side saw and the other
did not). Constructed legs with known costs come back exactly, with a zero residual
(`test/test_attribution.ml`).

`scripts/sim-vs-live.sh` runs hl-sim (seed 11, three leaders, 40 noise traders, strict
signatures), market-recorder on its BTC market and hl-copy-engine copying leader 1 with
the e2e throwaway follower (1,000,000 USD, `(Multiplier 0.01)`, 50 bps IOC bound, 10 s
resyncs) for `RUN_FOR` seconds, then backtests the recording with the same follow (5 ms
copy delay, 2 ms latency, no funding) and attributes. A 180 s run on 2026-10-16
(`test/fixtures/sim-vs-live`, replayed in `test/test_sim_vs_live.ml`):

```text
term           backtest USD     live USD        bps
fees                  29.79        29.67       0.00
slippage              19.43        10.70       0.09
timing              -136.38         0.00      -1.36  <- largest
partial fills          0.00         0.00       0.00
funding                0.00         0.00       0.00
residual                                       0.09
return: backtest 0.0153%, live 0.0035%, difference -1.18 bps; parents: backtest 21, live 24
```

The live run trailed its backtest by 1.2 bps (118 USD on 1,000,000). Fees agree to the
cent and nothing was left unfilled on either side. The gap is timing: in the backtest the
follower arrives 5 ms after the leader's fill at the replayed mid, 136 USD better than
the leader's own sweep prices, while the engine's `Immediate` parents carry no book, so
their arrival price is the leader's fill price (timing 0) and the whole move shows under
slippage. Read timing and slippage together for `Immediate` follows (-117 USD backtest,
+11 live); the algorithms that tick on the book measure them apart.

## Numbers

### hl-sim recording

hl-sim (seed 11, three simulated leaders with 100,000 USD each, 40 noise traders) was
recorded with market-recorder for 17 minutes on 2026-10-15/16 (BTC trades, BBO and L2;
32,198 events across two UTC days; the simulator serves no funding), and each leader's
`userFills` saved at the end. A 10,000 USD follower in `Equity_ratio` mode, default
settings, `sweep -algos immediate,twap:30s:3,pov:0.2:60s,passive:20s,adaptive -bands
none,default` (rerun on 2026-10-16: the rows without a band are the same as before
bands existed, to the cent):

| Leader | Algo | Band | Return | Max drawdown | Fees | Parents | Fill rate | Shortfall (bps) | Tracking error (bps) | Mean gap (bps) | Band skips | Saved (USD) | PSR | DSR |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 (trend, +3.27%) | immediate | none | 5.42% | 1.25% | 137.35 | 47 | 87.8% | 8.28 | 4.85 | 303 | 0 | 0.00 | 0.986 | 0.962 |
|  |  | default | 5.32% | 1.23% | 133.64 | 43 | 89.2% | 8.38 | 5.01 | 779 | 23 | 11.47 | 0.987 | 0.963 |
|  | twap:30s:3 | none | 5.90% | 0.78% | 118.60 | 52 | 82.3% | 6.61 | 10.81 | 3,892 | 0 | 0.00 | 0.995 | 0.984 |
|  |  | default | 5.71% | 0.78% | 115.76 | 47 | 88.2% | 7.25 | 11.06 | 4,199 | 19 | 9.49 | 0.994 | 0.983 |
|  | pov:0.2:1m | none | 6.16% | 1.08% | 137.83 | 47 | 98.2% | 6.23 | 6.38 | 991 | 0 | 0.00 | 0.993 | 0.980 |
|  |  | default | 6.01% | 1.07% | 134.11 | 41 | 100.0% | 6.49 | 6.56 | 1,463 | 21 | 10.36 | 0.993 | 0.980 |
|  | passive:20s | none | 7.08% | 1.00% | 44.31 | 46 | 95.2% | 3.43 | 7.71 | 872 | 0 | 0.00 | 0.998 | 0.993 |
|  |  | default | 6.90% | 1.00% | 43.38 | 42 | 97.7% | 3.65 | 7.87 | 1,347 | 23 | 11.55 | 0.998 | 0.993 |
|  | adaptive | none | 5.42% | 1.22% | 137.34 | 46 | 100.0% | 8.68 | 4.54 | 4 | 0 | 0.00 | 0.986 | 0.963 |
|  |  | default | 5.33% | 1.20% | 133.67 | 41 | 100.0% | 8.70 | 4.74 | 509 | 24 | 11.93 | 0.987 | 0.964 |
| 1 (mean reversion, +0.94%) | immediate | none | 4.36% | 1.10% | 192.17 | 89 | 92.4% | 9.75 | 5.18 | 159 | 0 | 0.00 | 0.964 | 0.831 |
|  |  | default | 4.48% | 1.06% | 182.71 | 87 | 93.1% | 9.68 | 5.44 | 665 | 16 | 8.04 | 0.970 | 0.850 |
|  | twap:30s:3 | none | 5.91% | 0.93% | 131.81 | 96 | 71.1% | 7.03 | 9.97 | 3,539 | 0 | 0.00 | 0.994 | 0.951 |
|  |  | default | 5.87% | 0.92% | 122.92 | 88 | 74.9% | 7.65 | 10.25 | 3,945 | 17 | 8.57 | 0.994 | 0.953 |
|  | pov:0.2:1m | none | 6.23% | 0.93% | 198.62 | 90 | 97.7% | 5.67 | 6.80 | 1,171 | 0 | 0.00 | 0.995 | 0.958 |
|  |  | default | 6.16% | 0.92% | 188.08 | 85 | 99.8% | 5.92 | 6.94 | 1,594 | 14 | 7.00 | 0.995 | 0.959 |
|  | passive:20s | none | 7.61% | 0.93% | 64.09 | 91 | 92.9% | 2.68 | 8.28 | 1,281 | 0 | 0.00 | 0.999 | 0.990 |
|  |  | default | 7.51% | 0.92% | 60.56 | 85 | 97.8% | 2.85 | 8.51 | 1,713 | 17 | 8.61 | 0.999 | 0.991 |
|  | adaptive | none | 4.29% | 1.08% | 198.76 | 90 | 100.0% | 10.03 | 5.03 | 3 | 0 | 0.00 | 0.963 | 0.827 |
|  |  | default | 4.44% | 1.04% | 187.47 | 87 | 100.0% | 9.95 | 5.27 | 518 | 15 | 7.50 | 0.970 | 0.848 |
| 2 (random, +2.40%) | immediate | none | 2.50% | 1.74% | 53.05 | 20 | 99.4% | 12.51 | 2.25 | 10 | 0 | 0.00 | 0.786 | 0.694 |
|  |  | default | 2.43% | 1.73% | 51.82 | 18 | 99.8% | 12.60 | 2.55 | 508 | 27 | 13.05 | 0.784 | 0.692 |
|  | twap:30s:3 | none | 3.24% | 1.26% | 53.10 | 25 | 84.0% | 4.76 | 9.97 | 2,031 | 0 | 0.00 | 0.866 | 0.794 |
|  |  | default | 3.18% | 1.24% | 51.78 | 19 | 88.5% | 5.38 | 10.14 | 2,491 | 24 | 11.58 | 0.866 | 0.794 |
|  | pov:0.2:1m | none | 3.55% | 1.26% | 53.29 | 19 | 100.0% | 3.59 | 4.09 | 19 | 0 | 0.00 | 0.876 | 0.808 |
|  |  | default | 3.46% | 1.24% | 52.05 | 17 | 100.0% | 3.65 | 4.37 | 520 | 27 | 13.19 | 0.876 | 0.808 |
|  | passive:20s | none | 3.60% | 1.26% | 17.75 | 20 | 95.1% | 3.04 | 5.32 | 326 | 0 | 0.00 | 0.880 | 0.813 |
|  |  | default | 3.51% | 1.24% | 17.34 | 18 | 99.5% | 3.19 | 5.44 | 779 | 23 | 11.25 | 0.879 | 0.812 |
|  | adaptive | none | 2.51% | 1.74% | 53.07 | 20 | 100.0% | 12.38 | 2.26 | 2 | 0 | 0.00 | 0.786 | 0.695 |
|  |  | default | 2.43% | 1.73% | 51.85 | 17 | 100.0% | 12.61 | 2.55 | 497 | 28 | 13.51 | 0.784 | 0.692 |

Every run's DuckDB check agreed. The sweep's pick per leader (`stats.parquet`, sweep row;
ten configurations, 86 to 100 ten-second samples):

| Leader | Pick | PSR | DSR | Probability of backtest overfitting | Reality check p | SPA p (vs the leader) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | passive:20s, no band | 0.998 | 0.993 | 0.038 | 0.000 | 0.000 |
| 1 | passive:20s, default band | 0.999 | 0.991 | 0.000 | 0.000 | 0.000 |
| 2 | passive:20s, no band | 0.880 | 0.813 | 0.711 | 0.114 | 0.059 |

Reading it:

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
- The default no-trade band (half-width 5.3% of equity, 528 USD on this follower) held
  back 14 to 28 rebalances per run and cut 2 to 8 parents and 2 to 7% of the fees, for a
  mean gap of about 500 bps more and slightly higher tracking error; the return moved by
  -0.19 to +0.15 points. On a 17-minute window the band is close to neutral; the saved
  cost column counts a held-back gap again at every resync while it lasts, so it is an
  upper bound.
- The statistics separate the leaders: for leaders 0 and 1 the best configuration beats
  the leader with a deflated Sharpe ratio above 0.95 and an overfitting probability near
  zero (every configuration ranks the same out of sample); for the random leader the
  probability of backtest overfitting is 0.71 and the SPA test does not reject at 5%, so
  picking its best configuration is mostly picking noise. Ten-second samples over minutes
  make the annualized Sharpe ratios meaningless (hundreds); read PSR, DSR, PBO and the
  p-values.

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
three algorithms; band arguments; the statistics per run and per sweep, the gate on a
strict and a permissive policy, `stats.parquet` read by DuckDB; the attribution of
constructed legs (every cost recovered, zero residual) and of the recorded live run
(`test/fixtures/sim-vs-live`: three minutes of hl-sim with the engine's journal) against
its backtest. The DuckDB CLI must be on the `PATH` (CI installs it).

## Build

Inside the organization's dune workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @copy-backtest/all @copy-backtest/runtest
opam exec --switch 5.2.0+ox -- dune exec --root .. copy-backtest -- sweep -synthetic 1 -leader-equity 100000
```

Standalone, with the organization's opam repository added: `opam install . --deps-only
--with-test && dune build && dune test`.
