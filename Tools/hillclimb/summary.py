#!/usr/bin/env python3
"""One line per metric from a results folder: summary.py <results/label>."""
import json
import os
import sys


def load(folder, name):
    with open(os.path.join(folder, name)) as f:
        return json.load(f)


def main():
    folder = sys.argv[1]
    split = load(folder, "split.json")
    export = load(folder, "export.json")
    s = split["synthetic"]
    print("== %s ==" % split.get("label", folder))
    print("A synthetic  pages=%d printCut=%d (px %d) splitInPrint=%d meanSplitErrPct=%.4f p95SplitErrPct=%.4f "
          "classAcc=%.4f meanSlackPct=%.4f meanShortPct=%.4f" % (
              s["pages"], s["printCut"], s["printCutPx"], s["splitInPrint"], s["meanSplitErrPct"],
              s["p95SplitErrPct"], s["classAcc"], s["meanSlackPct"], s["meanShortPct"]))
    real = split["real"]
    for b in real["books"]:
        print("A real %-14s pages=%d%s glyphs=%d splitCutsGlyphs=%d cropCutsGlyphs=%d (%s)" % (
            b["name"], b["pagesScored"], " (every %d)" % b["sampleEvery"] if b["sampled"] else "",
            b["glyphs"], b["splitCutsGlyphs"], b["cropCutsGlyphs"],
            " ".join("%s=%d" % kv for kv in sorted(b["classes"].items()))))
    t = real["totals"]
    print("A real total pages=%d glyphs=%d splitCutsGlyphs=%d cropCutsGlyphs=%d" % (
        t["pages"], t["glyphs"], t["splitCutsGlyphs"], t["cropCutsGlyphs"]))
    for b in export["books"]:
        print("C %-14s pages=%d bytes=%s min=%d secs=%s min=%.2f meanPSNR=%.2f minPagePSNR=%.2f (page %d)" % (
            b["name"], b["outputPages"], "/".join(str(x) for x in b["bytes"]), b["bytesMin"],
            "/".join("%.2f" % x for x in b["seconds"]), b["secondsMin"], b["meanPSNR"],
            b["minPagePSNR"], b["minPagePSNRPage"]))
    o = export.get("ocr") or {}
    if o:
        print("C OCR on %-10s pages=%d secs=%s min=%.2f ocrFailedPages=%s" % (
            o["name"], o["outputPages"], "/".join("%.2f" % x for x in o["seconds"]), o["secondsMin"],
            o["ocrFailedPages"]))
    e = export["totals"]
    print("C total      bytes=%d secondsMin=%.2f meanPSNR=%.2f minPagePSNR=%.2f" % (
        e["bytes"], e["secondsMin"], e["meanPSNR"], e["minPagePSNR"]))


if __name__ == "__main__":
    main()
