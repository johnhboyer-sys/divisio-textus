# OCR accuracy harness

Scores the text layer the app writes into an exported PDF against known truth, so
OCR changes can be compared before and after. Deterministic: fixed seeds, no
network, same pages every run.

    Tools/hillclimb/ocr/score_ocr.sh [label]

Runs only `swift test --filter HillClimbOCR` with `HILLCLIMB_DIR` set (default
`/Users/johnboyer/Developer/divisio-hillclimb`) and writes
`$HILLCLIMB_DIR/results/<label>/ocr.json` (label defaults to `current`). With
`HILLCLIMB_DIR` unset the suite is skipped. Run it outside the Claude Code sandbox
(Vision fails inside it) and not beside another heavy test run. About 6 minutes in
a debug build.

## Pages

26 pages typeset in code with CoreText (Times New Roman, Palatino), 300 dpi, then
degraded with a fixed seed: tilt up to 0.8 degrees, slight blur, grain, uneven paper
tone, a gutter shadow on every third page, JPEG at quality 0.6. Kinds: `prose` (5,
justified, hyphenated), `twocol` (4), `notes` (5: running head, footnotes in small
type, folio), `styled` (3: italic, small caps), `greekmixed` (4: English with
polytonic Greek), `greekfull` (3), `latgerm` (2). Text is original or public domain
(Jowett, KJV, Homer, Plato, Thucydides, Herodotus, Xenophon, Aristotle, Caesar,
Cicero, Virgil, Kant, Goethe).

The truth is the text actually drawn, in reading order (head, body, footnotes,
folio), with words broken at line ends written whole. `truth/pageNN.txt` holds a
copy. If the system hyphenator or fonts change, the generated truth can differ from
those files; the run says so (`truthDriftPages`) and scores against what it drew.
Rewrite the files with `HILLCLIMB_WRITE_TRUTH=1`; `HILLCLIMB_WRITE_FIXTURES=1` (not committed)
writes `fixtures/` (two sample scans and one clean page, to look at).

## Path under test

Pages go into one PDF; `PDFExporter.export` runs it with OCR on (Vision or Tesseract,
fill-in, `drawTextLayer`); the text is read back from the written PDF with
`PDFPage.string`. So the text layer and PDFKit's reading order count.

## Runs

| name | settings |
|---|---|
| `vision-en` | `reader = .apple`, no packs |
| `vision-grc-fillin` | `reader = .apple`, `packs = ["grc"]`. Vision has no Greek, so ticking Greek means Tesseract fills it in; this is also the "Vision with fill-in" mode |
| `tesseract` | `reader = .tesseract`, `packs` = those of `grc lat deu` found, plus English |
| `vision-en-clean` | pages 1, 6, 10 with no degradation, Vision English (sanity check) |

A run is skipped with a reason when Tesseract or a pack is missing. Packs come from
`$HILLCLIMB_TESSDATA` (colon-separated), `/opt/homebrew/share/tessdata`,
`/usr/local/share/tessdata`, the installed app's `Resources/tessdata`, and
`.build-tesseract/out/tessdata` in this checkout or any parent. They are linked, not
copied, into a temp folder. The app's Application Support folder is never read.

## Metrics

All on text normalised as: Unicode NFC, curly quotes and apostrophes straight, dashes
as `-`, ligatures and superscript digits spelled out, whitespace collapsed. The
reading also has line-end hyphens joined (`-` newline lowercase letter).

- `cer`: character edit distance (Levenshtein, over Unicode scalars) / truth characters,
  summed over all pages. `wer`: the same over space-separated words.
- `greekCER`, `latinCER`: the same after keeping only Greek-script scalars
  (U+0370-03FF, U+1F00-1FFF) or Latin letters, in truth and reading. Reading Greek as
  Latin letters is a Greek error; reading Latin as Greek is a Latin error.
- `order`: the truth is cut into chunks of three words (letters and digits, lowercased).
  A chunk is found when the reading has the same three words in a row. Among found
  chunks, `order` is the longest run whose places in the reading rise in truth order,
  divided by the number found. A column read before its neighbour, or a footnote read
  inside the body, lowers it. `chunkRecall` is found / all chunks (accuracy, not order).
- `secondsPerPage`: wall time of the whole `PDFExporter.export` call / pages (render,
  OCR in the exporter's parallel batches, write). Machine load changes it.
- `pages[]`: per-page `cer`, `wer`, `greekCER`, `latinCER`, edits, truth size.
  `cerByKind`: CER per page kind.

## Known

On the first baseline every run scores Greek CER 100%. Tesseract reads the Greek
(checked: `μῆνιν ἄειδε θεὰ Πηληϊάδεω Ἀχιλῆος` comes back whole), but the text layer
draws it in Helvetica, and PDFKit reads back only the capitals (`ΙΛΙΑΔΟΣΑ`). That is
what the exported PDF holds, so it is what the score shows.
