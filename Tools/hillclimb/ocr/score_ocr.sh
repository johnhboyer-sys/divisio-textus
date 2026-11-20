#!/bin/bash
# Scores the app's OCR text layer against known truth.
#   Tools/hillclimb/ocr/score_ocr.sh [label]
# Builds and runs only the HillClimbOCR tests, writes
# $HILLCLIMB_DIR/results/<label>/ocr.json, and prints one line per run.
# Vision does not run inside the Claude Code sandbox; run this outside it.
# Do not run it beside another heavy test run: timings and Vision results shift.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export HILLCLIMB_DIR="${HILLCLIMB_DIR:-/Users/johnboyer/Developer/divisio-hillclimb}"
export HILLCLIMB_LABEL="${1:-${HILLCLIMB_LABEL:-current}}"
swift test --filter HillClimbOCR 2>&1 | grep -E '^HCOCR |error:|Issue|✘' | sed 's/^HCOCR //'
echo "results: $HILLCLIMB_DIR/results/$HILLCLIMB_LABEL/ocr.json"
