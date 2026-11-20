# Hill-climb harness

Scores Auto-detect (split and crop) and Export (size, speed, fidelity), so a change to
`Sources/` can be judged by numbers before and after. Test code lives in
`Tests/PDFCropperTests/HillClimb*.swift`. Both suites skip unless `HILLCLIMB_DIR` is set,
so a plain `swift test` is unchanged.

## Run

    Tools/hillclimb/score.sh baseline

Builds (release, testing on: several times faster than debug), runs
`swift test --filter HillClimb`, prints one line per metric and the total runtime.
Env: `HILLCLIMB_DIR` (default `/Users/johnboyer/Developer/divisio-hillclimb`; its `books/`
holds the corpus and is never written), `HILLCLIMB_LABEL` (set by the script from its
argument; `current` when run by hand).

Vision OCR can fail inside a sandbox. If the OCR export line reports failed pages or the
run records an issue, rerun the command with the sandbox off.

Never run the full `swift test` for this: it takes over an hour. Use `--filter HillClimb`.

Quick checks while editing the harness: `HILLCLIMB_ONLY=synthetic` or `=real` runs half
of the split score; `--filter HillClimbExport` runs only the export score.
`HILLCLIMB_DUMP_SYNTH=<folder>` saves the first 12 synthetic pages of each book as PNG
(scan, and the mask of the left leaf's print).

## Output: `$HILLCLIMB_DIR/results/<label>/`

* `split.json`: summary of score A.
* `split-pages.json`: one record per page (synthetic and real), for diffing.
* `export.json`: score C.

Synthetic books are written to `$HILLCLIMB_DIR/synth/synth-N.pdf` on every run (same bytes
each time), so `diff_split.py` can draw them. Nothing is written to `books/`, to
`~/Library/Application Support/Divisio Textus` (saved edits go to a temporary folder,
as in the other tests) or to `~/Documents`.

## A. split.json

**Synthetic.** 312 grayscale pages from a fixed seed (6 books of 52): about 85% spreads,
the rest singles; real text in Times drawn with CoreText; known fold, known print for
every word, folio, running head, rule, frame, marginal number, footnote and plate.
Distractors, chosen per page at random and recorded as tags: soft and hard fold
shadows, a dark fold crease, scanner bed bands (black or white), tilt of +/-1.5
degrees, comb and spiral binding marks, folios and heads within 8-22 px of the fold,
marginal numbers, frames and rules, blank leaves, uneven paper tone, a neighbouring
leaf's edge. The books are written as PDFs sized so a 110 DPI render (the app's analysis
DPI) gives the drawn pixels, then loaded and Auto-detected as the app does it
(`AppModel.load` then `analyzeAll`, with the default Crop-to mode, **Whole page**, and
deskew on), so the book-wide steps (split moves, even-out, page sizing) run too.

Truth is checked on masks: each leaf's print (and paper) is drawn alone, black on white,
with the page's tilt, then put through the same straightening the exporter uses
(`ImageTransform.deskewedComposite` with the page's found split and skews).

* `printCut`: pages where any print pixel (mask < 100/255) lies outside the crop of its
  own leaf (the crop grown by 1 px for rounding) or on the wrong side of the split.
  **Hard gate: it must not rise.** `printCutPx` counts the pixels; `cutPages` names
  the pages.
* `splitInPrint`: pages whose split column (in the scan's own frame) runs through print.
* `meanSplitErrPct`, `p95SplitErrPct`: |found split - true fold| as % of the image width,
  spreads the app called spreads. The fold is taken at mid-height of the tilted sheet.
* `classAcc`: share of pages called spread/single as drawn. (Blank leaves have no class of
  their own in the app: a blank single is a single.)
* `meanSlackPct`: extra margin beyond the true paper box (the default mode, Whole page, aims at
  the sheet), as % of width/height, averaged over the four edges and pages. `meanShortPct`
  is the same for crops that fall inside the paper.
* `byTag`: all of these per distractor tag.

**Real books.** Every PDF in `books/`, loaded and Auto-detected as above. A book over 150 MB
(only Oesterle) is sampled: every 4th page, taken into a temporary PDF (recorded as
`sampled`, `sampleEvery`; page numbers in the records are the original ones).
An independent glyph finder (`HillClimbGlyphs.swift`: Otsu on the render, 8-connected
components 0.4-4% of the page tall and at most 10% of its width) counts glyphs the split
line runs through (`splitCutsGlyphs`, in the scan's frame) and glyphs a crop edge runs
through (`cropCutsGlyphs`, in the straightened frame, as exported). There is no ground
truth, so the counts only show change: a lower number is better, but compare pages with
`diff_split.py`.

## Diff two runs

    Tools/hillclimb/diff_split.py $HILLCLIMB_DIR/results/baseline $HILLCLIMB_DIR/results/new /tmp/diff

Lists pages whose type changed, whose split moved over 0.3% of the width, or whose crop
edge moved over 0.5% of the page; writes `moved.json` and one PNG per page: two panels side
by side, full height, a strip about the two splits. Left panel: split lines, A red, B blue.
Right panel: crop boxes, A red solid, B blue dashed. The PNGs come from
`render_strips.swift` (PDFKit, run through `swift`); `--no-images` skips them.

## C. export.json

Smith-1950 pages 1-40, Riezler-1940 all pages, Wallace-1992 pages 1-30, exported with
`PDFExporter` as the app calls it: 300 DPI setting with match-scan-resolution on, JPEG 0.7,
color, left-to-right, OCR **off**. Each export runs twice on a background thread; time covers
the export alone. Per book: `bytes` (both runs; they should match) and `bytesMin`,
`seconds` and `secondsMin`, pages, and fidelity: PSNR (all color channels, dB) between each
exported page drawn again at its export DPI and the uncompressed crop given to the
exporter (`PDFExporter.outputImages`); `meanPSNR`, `minPagePSNR` and the page it is on.
`sizeMismatchPages` counts pages whose two images differ in pixel size (compared over
the common area).

`ocr`: Smith-1950 pages 1-10 with Apple Vision on, time only (two runs).

## Notes on what is a guess

* "Default Crop-to mode" is read as `AppModel.cropTarget`'s initial value, Whole page.
* A page counts as cut when a print pixel is out by more than 1 px.
* Times vary from run to run; split numbers, bytes and page records should not.
