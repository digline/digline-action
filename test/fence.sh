#!/usr/bin/env bash
# The computed-fence rule, pinned against the script that actually ships.
#
# The comment step's shell is extracted from `action.yml` rather than copied
# here: a copy would pass while the action broke. It is run with a stubbed `gh`
# on PATH, against a report carrying backtick runs of three and four — the
# shape a provider-reported `resolved_model` could take, since that value is
# written by whatever server answered and reaches the comment by value.
#
# What is asserted: the fence that wraps the report is LONGER than the longest
# run of backticks inside it. If it is not, the report closes the fence early
# and the rest of it renders as Markdown in a comment a reviewer trusts.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/acme/app/issues/7/comments") ;;                 # no existing comment
  "pr comment") for a in "$@"; do [ -f "$a" ] && cp "$a" "$GH_BODY"; done ;;
esac
STUB
chmod +x "$work/bin/gh"

python3 - "$work/comment.sh" <<'PY'
import sys, pathlib, yaml
steps = yaml.safe_load(pathlib.Path("action.yml").read_text(encoding="utf-8"))["runs"]["steps"]
step = next(s for s in steps if s["id"] == "comment")
pathlib.Path(sys.argv[1]).write_text(step["run"], encoding="utf-8")
PY

# Three backticks and four, in a configuration value — by value, in the line
# ADR 0005 exists for.
cat > "$work/report.txt" <<'REPORT'
1 check got worse compared with the reference. Every case could be judged.

  resolved_model gpt-4o-mini → acme```legal````v3

where-is-my-order · contains · Went from passing to failing (1.000000 → 0.000000).
REPORT

PATH="$work/bin:$PATH" \
RUNNER_TEMP="$work" GH_BODY="$work/body.md" GH_TOKEN=x GH_REPO=acme/app PR=7 \
SUITE=test/fixtures/green/suite.toml REPORT="$work/report.txt" STATUS=1 \
  bash "$work/comment.sh" > /dev/null

longest=$(grep -o '`\+' "$work/report.txt" | awk '{ print length }' | sort -rn | head -n 1)
fence=$(grep -oE '^`{3,}$' "$work/body.md" | head -n 1)
echo "longest backtick run in the report: ${longest}"
echo "fence the comment used:             ${#fence}"

[ -n "$fence" ] || { echo "FAIL: the body has no fence line at all"; exit 1; }
[ "${#fence}" -gt "$longest" ] || {
  echo "FAIL: fence ${#fence} does not exceed the ${longest} backticks in the report;"
  echo "the report would close it early and render as Markdown."
  exit 1
}
# Both fences present, so the block is actually closed.
[ "$(grep -cE '^`{3,}$' "$work/body.md")" -eq 2 ] || {
  echo "FAIL: the body does not have exactly two fence lines"; exit 1; }

echo "OK: the fence is computed, not typed."

# --------------------------------------------------------------------------- #
# The marker is reduced to a safe alphabet before it reaches a jq program.
# --------------------------------------------------------------------------- #
# A `"` in the suite path used to break out of the jq string literal that finds
# the previous comment — losing the comment at best, and selecting a different
# comment id at worst. A `-->` closed the HTML comment early. Both are
# workflow-author values rather than attacker values, and both are one `tr`
# away from impossible.
rm -f "$work/body.md"
PATH="$work/bin:$PATH" RUNNER_TEMP="$work" GH_BODY="$work/body.md" GH_TOKEN=x GH_REPO=acme/app PR=7 SUITE='a".toml-->x' REPORT="$work/report.txt" STATUS=1   bash "$work/comment.sh" > /dev/null

marker=$(head -n 1 "$work/body.md")
echo "marker from a hostile suite name: ${marker}"
case "${marker}" in
  *'"'*) echo "FAIL: a quote survived into the marker, and so into the jq"; exit 1 ;;
esac
# Exactly one `-->`, at the end: the comment closes where it should.
[ "$(grep -c -- '-->' <<<"${marker}")" = "1" ] || {
  echo "FAIL: the marker does not close as a single HTML comment"; exit 1; }
case "${marker}" in
  '<!-- digline-action:'*' -->') ;;
  *) echo "FAIL: the marker lost its shape"; exit 1 ;;
esac

echo "OK: the marker cannot carry a quote or close itself early."
