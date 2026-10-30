#!/usr/bin/env bash
# The fixtures' stub is a second witness: one line for every call it receives,
# and nothing when it receives none.
#
#     test/stub.sh               # the `digline` on PATH
#     DIGLINE=/path/to/digline test/stub.sh
#
# Until 2026-10-30 the stub silenced `log_message`, so "Nothing was called" was
# digline's word and nobody else's. Each fixture's `stub.py` now writes, on
# stderr, one line per POST, in the format digline's example stubs share:
#
#     stub: call <n> POST <path> question=<value>
#
# The liveness HEAD is not a call and writes no line.
#
# Both halves, for each fixture's stub, on a port of its own:
# - a run that calls (no baseline) gets exactly as many lines as `digline run`
#   announced calls to the target;
# - a run digline refuses before calling (the baseline declared at schema 21,
#   which this digline does not read) gets none, beside its own
#   "Nothing was called".
set -euo pipefail
cd "$(dirname "$0")/.."
digline=${DIGLINE:-digline}

work=$(mktemp -d)
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

failed=0
fail() { echo "FAIL [$case]: $*"; failed=1; return 1; }

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# A copy of one fixture, its suite pointed at `port`, and its stub started on
# that port with stderr kept in `log`. Waits for the HEAD the stub answers.
start() {
  local fixture=$1 dir=$2 port=$3 log=$4
  cp -R "test/fixtures/${fixture}" "$dir"
  sed -i.bak "s#http://127.0.0.1:8731/answer#http://127.0.0.1:${port}/answer#" "$dir/suite.toml"
  grep -q "127.0.0.1:${port}/answer" "$dir/suite.toml" || { fail "the suite's url was not rewritten"; return 1; }
  (cd "$dir" && STUB_PORT=$port exec python3 stub.py 2>"$log") &
  pids+=("$!")
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null --head "http://127.0.0.1:${port}/answer" && return 0
    sleep 0.25
  done
  fail "the stub never came up on ${port}"
  return 1
}

calls() { grep -cE '^stub: call [0-9]+ POST /[^ ]+ question=.+$' "$1" || true; }

# Each half is a function and runs whatever the other did, so a mutation is
# caught by the half it is about and not only by the first that fails.
calls_half() {
  local fixture=$1
  case="${fixture}: a run that calls"
  local dir="$work/${fixture}-calls" log="$work/${fixture}-calls.log" err ran planned got numbers expected
  start "$fixture" "$dir" "$(free_port)" "$log" || return 1
  rm -rf "$dir/.digline/acme/baselines" "$dir/.digline/acme/runs"
  set +e
  err=$(cd "$dir" && "$digline" run --suite suite.toml 2>&1 >/dev/null)
  ran=$?
  set -e
  [ "$ran" -eq 0 ] || { fail "digline run exited ${ran}: ${err}"; return 1; }
  planned=$(printf '%s\n' "$err" | sed -nE 's/.*= ([0-9]+) calls? to the target.*/\1/p' | head -1)
  [ -n "$planned" ] || { fail "no planned call count in: ${err}"; return 1; }
  got=$(calls "$log")
  [ "$got" -eq "$planned" ] || { fail "the stub wrote ${got} call lines, digline announced ${planned}"; return 1; }
  numbers=$(sed -nE 's/^stub: call ([0-9]+) .*/\1/p' "$log" | tr '\n' ' ')
  expected=""
  for n in $(seq 1 "$planned"); do expected="${expected}${n} "; done
  [ "$numbers" = "$expected" ] || { fail "the calls are numbered ${numbers}, not ${expected}"; return 1; }
  echo "ok   ${case}: ${got} lines for ${planned} calls"
}

refused_half() {
  local fixture=$1
  case="${fixture}: a run digline refuses"
  local dir="$work/${fixture}-refused" log="$work/${fixture}-refused.log" err ran got
  start "$fixture" "$dir" "$(free_port)" "$log" || return 1
  python3 - "$dir/.digline/acme/baselines/gate.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path, encoding="utf-8"))
document["schema_version"] = 21
json.dump(document, open(path, "w", encoding="utf-8"))
PY
  set +e
  err=$(cd "$dir" && "$digline" run --suite suite.toml 2>&1 >/dev/null)
  ran=$?
  set -e
  [ "$ran" -eq 64 ] || { fail "digline run exited ${ran}, not 64: ${err}"; return 1; }
  printf '%s\n' "$err" | grep -q 'Nothing was called' || { fail "no \"Nothing was called\" in: ${err}"; return 1; }
  got=$(calls "$log")
  [ "$got" -eq 0 ] || { fail "the stub wrote ${got} call lines while digline refused"; return 1; }
  echo "ok   ${case}: no line"
}

for fixture in green worse; do
  calls_half "$fixture" || true
  refused_half "$fixture" || true
done
exit "$failed"
