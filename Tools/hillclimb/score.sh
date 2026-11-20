#!/bin/bash
# Score the app: builds, runs both hill-climb suites, prints one line per metric.
#   Tools/hillclimb/score.sh [label]        label defaults to "current"
# Results: $HILLCLIMB_DIR/results/<label>/{split.json,split-pages.json,export.json}
# Vision OCR can fail inside a sandbox: if the OCR export line shows failures, rerun
# this command with the sandbox off.
set -euo pipefail

LABEL="${1:-current}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export HILLCLIMB_DIR="${HILLCLIMB_DIR:-/Users/johnboyer/Developer/divisio-hillclimb}"
export HILLCLIMB_LABEL="$LABEL"

[ -d "$HILLCLIMB_DIR/books" ] || { echo "no corpus at $HILLCLIMB_DIR/books" >&2; exit 1; }
cd "$ROOT"
START=$(date +%s)

# A release build with testing on: the analysis runs several times faster than in debug.
FLAGS=(-c release -Xswiftc -enable-testing)
swift build --build-tests "${FLAGS[@]}" 2>&1 | grep -E "error:|Build complete" || true
swift test "${FLAGS[@]}" --filter HillClimb 2>&1 | grep -E "✔|✘|Issue|error:|passed|failed" || true

RESULTS="$HILLCLIMB_DIR/results/$LABEL"
for f in split.json split-pages.json export.json; do
  [ -f "$RESULTS/$f" ] || { echo "missing $RESULTS/$f" >&2; exit 1; }
done
python3 -I "$HERE/summary.py" "$RESULTS"
echo "total runtime: $(( $(date +%s) - START )) s"
