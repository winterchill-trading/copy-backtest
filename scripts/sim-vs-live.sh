#!/usr/bin/env bash
# Sim versus live on the simulator: hl-sim with simulated leaders, market-recorder
# recording its BTC market, and hl-copy-engine copying one leader with a throwaway
# follower, all at once for RUN_FOR seconds. Then the recording and the leader's fills
# are backtested with the same follow settings, and `copy-backtest attribute` splits the
# live run's return difference from the backtest into costs.
#
# Assumed layout: copy-backtest is checked out next to hl-sim, market-recorder,
# hl-copy-engine and their dependencies inside one dune workspace (a directory with
# dune-workspace and dune-project files containing '(lang dune 3.17)').
#
# Environment overrides: WORKSPACE (<root>), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-copy-backtest), SEED (11), RUN_FOR (180), LEADER_INDEX (1), MODE
# ("(Multiplier 0.01)": the follower account holds $1,000,000 and the leaders $100,000,
# so this copies a tenth of the leader's sizes), BAND (empty: none; else the follow's band
# sexp), SIM_PORT (3591), RECORDER_PORT (9916), ENGINE_PORT (9961), OUT (a temporary
# directory: recording, fills, journal, backtest results and logs).
#
# The keys below are throwaway keys for the simulator only; the engine refuses mainnet.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
if [[ ! -f "$root/dune-workspace" && ! -f "$root/dune-project" ]]; then
  echo "sim-vs-live: $root is not a dune workspace root (see the header of $0)" >&2
  exit 1
fi
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-copy-backtest}"
seed="${SEED:-11}"
run_for="${RUN_FOR:-180}"
leader_index="${LEADER_INDEX:-1}"
mode="${MODE:-(Multiplier 0.01)}"
band="${BAND:-}"
sim_port="${SIM_PORT:-3591}"
recorder_port="${RECORDER_PORT:-9916}"
engine_port="${ENGINE_PORT:-9961}"
out="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/sim-vs-live.XXXXXX")}"
mkdir -p "$out/data" "$out/follows" "$out/journal"
leader=$(printf '0x1eade5%034x' "$leader_index")

export HL_COPY_E2E_USER_KEY=0x1111111111111111111111111111111111111111111111111111111111111111
export HL_COPY_E2E_AGENT_KEY=0x2222222222222222222222222222222222222222222222222222222222222222
follower=0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a

echo "sim-vs-live: building (switch $switch, build dir $DUNE_BUILD_DIR)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  hl-sim/bin/main.exe market-recorder/bin/main.exe hl-copy-engine/bin/main.exe \
  "$(basename "$repo")/bin/main.exe")
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/hl-sim/bin/main.exe"
recorder_exe="$build/market-recorder/bin/main.exe"
engine_exe="$build/hl-copy-engine/bin/main.exe"
backtest_exe="$build/$(basename "$repo")/bin/main.exe"

pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

base="http://127.0.0.1:$sim_port"
"$sim_exe" -port "$sim_port" -seed "$seed" -leaders 3 -noise-traders 40 \
  -strict-signatures >"$out/sim.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do
  if curl -sf "$base/info" -d '{"type":"meta"}' >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -s "$base/info" -d '{"type":"meta"}' >"$out/meta.json"

cat >"$out/recorder.sexp" <<SEXP
((data_dir $out/data)
 (http_port $recorder_port)
 (venues
  (((venue Hyperliquid) (symbols (BTC)) (streams (Trades Bbo L2))
    (config (Local (port $sim_port)))))))
SEXP
"$recorder_exe" run -config "$out/recorder.sexp" 2>"$out/recorder.log" &
recorder_pid=$!
pids+=("$recorder_pid")

"$engine_exe" approve-agent -base-url "$base" \
  -user-key-env HL_COPY_E2E_USER_KEY -agent-key-env HL_COPY_E2E_AGENT_KEY
cat >"$out/follows/$follower-$leader.sexp" <<SEXP
((follower $follower) (leader $leader) (mode $mode)
 (caps ((max_leverage ()) (max_notional_per_symbol ()) (max_daily_loss ())
        (allowlist ()) (min_order_notional 10)))
 (slippage_bps 50) (paused false)${band:+ (band $band)})
SEXP
"$engine_exe" run -base-url "$base" -configs-dir "$out/follows" \
  -journal-dir "$out/journal" -port "$engine_port" -resync-s 10 \
  -agent-key-env HL_COPY_E2E_AGENT_KEY 2>"$out/engine.log" &
engine_pid=$!
pids+=("$engine_pid")

echo "sim-vs-live: following $leader for ${run_for}s, files in $out" >&2
sleep "$run_for"

kill "$engine_pid"
wait "$engine_pid" 2>/dev/null || true
# the recorder writes its event logs on SIGTERM
kill -TERM "$recorder_pid"
wait "$recorder_pid" 2>/dev/null || true
curl -s "$base/info" -d "{\"type\":\"userFills\",\"user\":\"$leader\"}" >"$out/leader-fills.json"

mult=$(sed -E 's/\(Multiplier ([0-9.]+)\)/\1/' <<<"$mode")
band_flag=()
if [[ -n "$band" ]]; then band_flag=(-band "$band"); fi
echo "sim-vs-live: backtest of the same window" >&2
"$backtest_exe" run -leader-fills "$out/leader-fills.json" -norm "$out/data" \
  -meta "$out/meta.json" -mode "mult:$mult" -equity 1000000 -leader-equity 100000 \
  -slippage-bps 50 -resync-s 10 -copy-delay-ms 5 -latency-ms 2 -no-funding \
  ${band_flag[@]+"${band_flag[@]}"} -out "$out/backtest" | tee "$out/backtest.txt"

echo "sim-vs-live: attribution" >&2
"$backtest_exe" attribute -backtest "$out/backtest" \
  -journal "$out/journal/$follower-$leader" | tee "$out/attribution.txt"
