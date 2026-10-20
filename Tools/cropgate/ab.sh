#!/bin/bash
# Crop gate: runs every page in main.swift through PageAnalyzer.contentBounds as of
# commit e93b1c4 (OLD) and as in this checkout (NEW), and fails if NEW keeps less
# print than OLD on any page (check.py). Usage: Tools/cropgate/ab.sh
# To judge textBounds instead, change the two calls in main.swift's show/showRange.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
W="$(mktemp -d)"; mkdir -p "$W/old" "$W/new"
git -C "$REPO" show e93b1c4:Sources/PDFCropper/Services/PageAnalyzer.swift > "$W/old/PageAnalyzer.swift"
cp "$REPO/Sources/PDFCropper/Services/PageAnalyzer.swift" "$W/new/"
for v in old new; do
  cp "$HERE/CropRect.swift" "$HERE/GrayBuffer.swift" "$W/$v/"
  swiftc -O -module-cache-path "$W/cache" -o "$W/$v/run" "$HERE/main.swift" "$W/$v/"*.swift
done
"$W/old/run" > "$W/old.txt"; "$W/new/run" > "$W/new.txt"
paste -d'\n' "$W/old.txt" "$W/new.txt" | awk 'NR%2==1{o=$0} NR%2==0{ if (o!=$0) {print "OLD: " o; print "NEW: " $0} }' > "$W/diff.txt"
python3 -I "$HERE/check.py" "$W/diff.txt"
