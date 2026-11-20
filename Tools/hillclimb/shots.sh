#!/bin/bash
# Screenshots of every screen, light and dark, for the design hill climb.
#   Tools/hillclimb/shots.sh <outdir> [scenario ...]
# Builds a debug build and runs it once. The DEBUG-only hook in
# Sources/PDFCropper/DebugShots.swift drives the app by code, with no clicks, and
# writes <scenario>-light.png and <scenario>-dark.png of the app's own window
# (1440x900 points, 2x). The app starts in the background and takes no focus
# from you (see "focus" in the report that ships with it). It quits when done.
#
# Waiting: before each shot the hook waits until every page is analysed, the
# model is idle, no spinner shows in the window, and two captures 0.4 s apart
# match pixel for pixel. A shot that never settles in 4 minutes is saved anyway
# and logged "NOT SETTLED".
set -euo pipefail

OUT="${1:?usage: shots.sh <outdir> [scenario ...]}"
shift || true
BOOKS="${DIVISIO_BOOKS:-/Users/johnboyer/Developer/divisio-hillclimb/books}"
SMITH="$BOOKS/Smith-1950-Philosophical Physics.pdf"
RIEZLER="$BOOKS/Riezler-1940-Physics and Reality.pdf"
[ -f "$SMITH" ] && [ -f "$RIEZLER" ] || { echo "books missing under $BOOKS"; exit 1; }

cd "$(dirname "$0")/../.."
# Debug configuration (so #if DEBUG holds) but optimised: unoptimised, page analysis takes
# many minutes a book. Own build folder, so your normal .build is left alone.
SB=(swift build --build-path .build/shots -Xswiftc -O)
"${SB[@]}" 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$("${SB[@]}" --show-bin-path)/PDFCropper"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT"/*.png "$OUT/.done"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ONLY="null"
if [ $# -gt 0 ]; then
  ONLY="[$(printf '"%s",' "$@" | sed 's/,$//')]"
fi
cat > "$WORK/plan.json" <<EOF
{ "outDir": "$OUT", "scratchDir": "$WORK/edits", "smith": "$SMITH", "riezler": "$RIEZLER",
  "width": 1440, "height": 900, "spreadIndex": 19, "only": $ONLY }
EOF

START=$(date +%s)
# The binary is run directly (not through `open`), in the background, and the
# script waits for the hook's .done file. Its log goes to $OUT/shots.log.
DIVISIO_SHOTS="$WORK/plan.json" "$BIN" > "$OUT/shots.log" 2>&1 &
PID=$!
for _ in $(seq 1 1200); do
  [ -f "$OUT/.done" ] && break
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
if kill -0 $PID 2>/dev/null; then
  sleep 2                       # let the app quit itself
  kill $PID 2>/dev/null || true
fi
wait $PID 2>/dev/null || true
rm -f "$OUT/.done"
echo "$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') PNGs in $OUT, $(( $(date +%s) - START )) s"
