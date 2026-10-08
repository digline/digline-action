#!/usr/bin/env bash
# Every outcome the gate can record, pinned against the steps that ship.
#
# The `gate`, `comment` and `verdict` steps are extracted from `action.yml`, as
# test/fence.sh does, and run with a stubbed `docker` on PATH that exits with
# whatever code a case asks for. That is the only way to reach 70 on demand:
# digline exits 70 for a failure nobody anticipated, and nothing in a real
# image produces one deterministically. The paths a real image *can* reach, a
# refused `digline run` and an image that cannot be pulled, are also run for
# real in ci.yml.
#
# What is asserted, on each path: digline's code is the one the action exits
# with, never replaced by a 1; the four outputs are written; the kind decides
# the words, so 64 is a refusal, 70 is not, and an action failure is never
# reported as a digline code; and digline's stderr reaches none of the
# outputs or the comment.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

python3 - "$work" <<'PY'
import sys, pathlib, yaml
steps = yaml.safe_load(pathlib.Path("action.yml").read_text(encoding="utf-8"))["runs"]["steps"]
for name in ("gate", "comment", "verdict"):
    step = next(s for s in steps if s["id"] == name)
    pathlib.Path(sys.argv[1], f"{name}.sh").write_text(step["run"], encoding="utf-8")
PY

# `docker run <flags> <image> <command> ...`: the command is the first argument
# after the image. Every call writes a line to stderr that must never travel.
cat > "$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
seen=""
for a in "$@"; do
  if [ -n "$seen" ]; then command=$a; break; fi
  [ "$a" = "$INPUT_IMAGE" ] && seen=1
done
echo "PAYLOAD-FROM-THE-SUITE" >&2
case "$command" in
  run) [ "${STUB_RUN:-0}" = 0 ] && echo "2026-10-08T00-00-00-key"; exit "${STUB_RUN:-0}" ;;
  compare) printf '%s' "${STUB_OUT:-}"; exit "${STUB_COMPARE:-0}" ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr comment") for a in "$@"; do [ -f "$a" ] && cp "$a" "$GH_BODY"; done ;;
esac
STUB
chmod +x "$work/bin/docker" "$work/bin/gh"

fail() { echo "FAIL [$case]: $*"; exit 1; }

# outcome <case> [-NAME] [VAR=value ...]: runs the three steps the way the
# runner does, and leaves their results in $out (GITHUB_OUTPUT), $log, $body
# and $exited. `-NAME` leaves that input unset.
outcome() {
  case=$1; shift
  rm -rf "$work/case"; mkdir -p "$work/case"
  out="$work/case/output"; log="$work/case/log"; body="$work/case/digline-comment.md"
  : > "$out"
  local inputs=(INPUT_SUITE=eval/suite.py INPUT_ROOT=. INPUT_TENANT= INPUT_ENV=
                INPUT_IMAGE=ghcr.io/digline/digline:test INPUT_RUN=true INPUT_FORWARD_ENV=)
  if [ "${1:-}" != "${1#-}" ]; then
    local drop=${1#-}; shift
    local kept=()
    for i in "${inputs[@]}"; do [ "${i%%=*}" = "$drop" ] || kept+=("$i"); done
    inputs=("${kept[@]}")
  fi
  env -u "${drop:-NOTHING}" PATH="$work/bin:$PATH" GITHUB_OUTPUT="$out" \
    GITHUB_WORKSPACE="$work/case" RUNNER_TEMP="$work/case" "${inputs[@]}" "$@" \
    bash -e "$work/gate.sh" > "$log" 2>&1 || true

  # Each output, read the way the runner reads the file: `name=value`, or the
  # `name<<DELIM` block the headline is written as.
  get() { python3 - "$out" "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
want, i = sys.argv[2], 0
found = None
while i < len(lines):
    line = lines[i]
    if line.startswith(want + "<<"):
        delim = line[len(want) + 2:]
        j = lines.index(delim, i + 1)
        found = "\n".join(lines[i + 1:j]); i = j
    elif line.startswith(want + "="):
        found = line[len(want) + 1:]
    i += 1
if found is None:
    sys.exit(f"{want} was never written")
print(found)
PY
  }
  code=$(get exit-code) || fail "exit-code was never written"
  headline=$(get headline) || fail "headline was never written"
  key=$(get run-key) || fail "run-key was never written"
  report=$(get report) || fail "report was never written"
  kind=$(get kind); failed=$(get failed)
  [ -f "$report" ] || fail "the report file does not exist"

  env PATH="$work/bin:$PATH" RUNNER_TEMP="$work/case" GH_BODY="$body" GH_TOKEN=x \
    GH_REPO=acme/app PR=7 SUITE=eval/suite.py REPORT="$report" STATUS="$code" \
    KIND="$kind" FAILED="$failed" HEADLINE="$headline" \
    bash -e "$work/comment.sh" >> "$log" 2>&1 || fail "the comment step failed"
  [ -s "$body" ] || fail "no comment was posted"

  set +e
  STATUS="$code" FAILED="$failed" bash -e "$work/verdict.sh"
  exited=$?
  set -e

  if grep -q PAYLOAD "$report" "$body" || case "$headline" in *PAYLOAD*) true ;; *) false ;; esac; then
    fail "digline's stderr reached an output or the comment"
  fi
  echo "ok   $case: exit-code '$code', action exits $exited"
}

# --- 1. digline run fails: its code, not 1 ----------------------------------- #
outcome "run refused" STUB_RUN=64
[ "$code" = 64 ] || fail "exit-code is '$code', not digline's 64"
[ "$exited" = 64 ] || fail "the action exits $exited, not digline's 64"
[ -z "$key" ] || fail "run-key is '$key' for a run that does not exist"
case "$headline" in "digline run exited 64: digline refused the request."*) ;;
  *) fail "headline: $headline" ;; esac
grep -q '::error title=digline refused the request (exit 64)::' "$log" || fail "annotation"
grep -q 'digline refused the request' "$body" || fail "the comment does not say refused"

outcome "run failed unexpectedly" STUB_RUN=70
[ "$code" = 70 ] && [ "$exited" = 70 ] || fail "exit-code '$code', exits $exited, not 70"
grep -q '::error title=digline: internal error (exit 70)::' "$log" || fail "annotation"
! grep -q 'digline refused the request' "$log" "$body" || fail "a 70 is called a refusal"

# --- 2. compare's non-verdicts, each by its own name ------------------------- #
outcome "compare 70" STUB_COMPARE=70
[ "$code" = 70 ] && [ "$exited" = 70 ] || fail "exit-code '$code', exits $exited, not 70"
[ "$key" = 2026-10-08T00-00-00-key ] || fail "run-key is '$key'"
grep -q '::error title=digline: internal error (exit 70)::' "$log" || fail "annotation"
! grep -q 'digline refused the request' "$log" "$body" || fail "a 70 is called a refusal"

outcome "compare 64" STUB_COMPARE=64
[ "$code" = 64 ] && [ "$exited" = 64 ] || fail "exit-code '$code', exits $exited, not 64"

outcome "compare 2" STUB_COMPARE=2 STUB_OUT=$'1 case could not be judged.\n'
[ "$code" = 2 ] && [ "$exited" = 2 ] || fail "exit-code '$code', exits $exited, not 2"
[ "$headline" = "1 case could not be judged." ] || fail "headline is not the report's: $headline"
grep -q '::error title=digline: the run could not be judged::' "$log" || fail "annotation"

# --- 3. the action fails: not a digline code, and not reported as one --------- #
outcome "image not pulled" STUB_COMPARE=125
[ -z "$code" ] || fail "exit-code is '$code' for a code digline never gave"
[ "$failed" = 125 ] && [ "$exited" = 125 ] || fail "failed '$failed', exits $exited, not 125"
grep -q '::error title=digline-action failed; not a digline exit code::' "$log" || fail "annotation"
! grep -q 'digline refused\|::error title=digline:' "$log" || fail "reported as digline's"
grep -q 'This action failed before digline gave an answer' "$body" || fail "comment"

outcome "run's container killed" STUB_RUN=137
[ -z "$code" ] && [ "$exited" = 137 ] || fail "exit-code '$code', exits $exited"

# The gate step's own stop, before anything ran: an unset input under `set -u`.
# Recorded all the same, and the shell's 1 is not reported as digline's 1.
outcome "the gate step stopped" -INPUT_FORWARD_ENV
[ -z "$code" ] || fail "exit-code is '$code' for a stop of the action's own"
[ "$exited" = 255 ] || fail "exits $exited; a shell's 1 would read as 'worse'"

echo "OK: every outcome is recorded, named by its kind, and exits with digline's code."
