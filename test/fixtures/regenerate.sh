#!/usr/bin/env bash
# Rebuild the two fixtures from the stub. Run from this directory.
#
#     ./regenerate.sh [digline]        # default: the `digline` on PATH
#
# The fixtures are *stored runs*, which is what lets the workflow gate with
# `run: false` — no key, no network, no provider call in this repository's CI.
# They are committed with `git add -f`, because digline writes a `.gitignore`
# into `.digline/` that ignores `*/runs/`. That ignore is right for a real
# repository, where a run is an artifact; here the run IS the fixture.
set -euo pipefail
cd "$(dirname "$0")"
digline=${1:-digline}

stub() {
  (cd "$1" && ${WORSE:+WORSE=1} python3 stub.py &)
  for _ in $(seq 1 20); do
    curl -sf -o /dev/null --head http://127.0.0.1:8731/answer && return 0
    sleep 0.5
  done
  echo "the stub never came up"; exit 1
}
stop() { pkill -f "python3 stub.py" 2>/dev/null || true; }
trap stop EXIT

# green: a baseline, and a later run that agrees with it.
stop; rm -rf green/.digline
stub green
key=$(cd green && "$digline" run --suite suite.toml)
(cd green && "$digline" promote --suite suite.toml --run "$key")
(cd green && "$digline" run --suite suite.toml >/dev/null)
(cd green && "$digline" compare --suite suite.toml --run latest)

# worse: the same baseline, and a run where one answer lost its sign-off. A
# flip from passing to failing, which is never rescued by a tolerance — so the
# red fixture cannot go green on a rounding change.
stop; rm -rf worse/.digline && cp -r green/.digline worse/.digline
rm -rf worse/.digline/acme/runs/gate/*
WORSE=1 stub worse
(cd worse && "$digline" run --suite suite.toml >/dev/null)
set +e
(cd worse && "$digline" compare --suite suite.toml --run latest)
status=$?
set -e
[ "$status" -eq 1 ] || { echo "the worse fixture exited $status, not 1"; exit 1; }

echo
echo "fixtures rebuilt. Commit them with:"
echo "    git add -f test/fixtures/*/.digline"
