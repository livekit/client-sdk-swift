#!/usr/bin/env bash
# Run the opt-in native Session benchmark against an isolated local SFU.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
bench_output="${1:-$repo_root/Benchmarks/SessionStartup/results}"
mkdir -p "$bench_output"
bench_output="$(cd "$bench_output" && pwd)"
bench_tmp="$(mktemp -d -t livekit-session-bench)"
server_pid=''
relay_pid=''
cleanup() {
  if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$bench_tmp"
}
trap cleanup EXIT
for port in 17880 17881 17882 17883; do
  if lsof -nP -i ":$port" >/dev/null 2>&1; then
    echo "Benchmark port $port is occupied; stop its owner before running." >&2
    exit 1
  fi
done
cat > "$bench_tmp/server.yaml" <<'YAML'
port: 17880
bind_addresses: [127.0.0.1]
rtc:
  tcp_port: 17881
  udp_port: 17882
  use_external_ip: false
  node_ip: 127.0.0.1
logging:
  level: error
YAML
livekit-server --dev --config "$bench_tmp/server.yaml" > "$bench_output/server.log" 2>&1 &
server_pid=$!
ONE_WAY_MS="${ONE_WAY_MS:-50}" node scripts/benchmark-session-signaling.mjs > "$bench_output/relay.log" 2>&1 &
relay_pid=$!
for attempt in $(seq 1 100); do
  kill -0 "$server_pid"
  kill -0 "$relay_pid"
  if curl --silent --fail http://127.0.0.1:17883 >/dev/null; then break; fi
  sleep 0.1
done
curl --silent --fail http://127.0.0.1:17883 >/dev/null
LIVEKIT_TESTING_URL=ws://127.0.0.1:17883 \
LK_SESSION_BENCHMARK=1 LK_SESSION_BENCHMARK_SAMPLES="${LK_SESSION_BENCHMARK_SAMPLES:-10}" \
  xcrun swift test --skip-update -j 4 --filter SessionPublicationBenchmarkTests 2>&1 | tee "$bench_output/run.log"
python3 scripts/summarize-session-audio.py "$bench_output/run.log" "$bench_output" \
  --added-signaling-rtt-ms "$(( ${ONE_WAY_MS:-50} * 2 ))"
