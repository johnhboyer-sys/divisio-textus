# Hill climb, 2026-11-19/20

Branch `claude/hill-climb`. Not merged, not installed. 387 tests pass (355 before).
Scores: `Tools/hillclimb/` (README there). Corpus: `~/Developer/divisio-hillclimb`.

## Scores, baseline → now

| | Before | After |
|---|---|---|
| Synthetic spreads with print cut (of 312) | 13 (2,730 px) | 10 (183 px) |
| Synthetic splits through print | 4 | 2 |
| Mean split error, % of width | 0.464 | 0.432 |
| Real books: splits moved | — | 0 |
| OCR, Apple + Greek fill-in: Greek errors | 5.45% | 1.94% |
| OCR, same run: all errors / word errors | 0.47% / 1.06% | 0.21% / 0.67% |
| OCR, Apple alone / Tesseract alone | 6.01% / 0.22% | unchanged |
| Export bytes (3 books) | 141.4 MB | 140.8 MB, same pixels |
| Design, blind judge, new vs old | — | 32 wins, 0 losses, 8 ties |

A split check by eye on 108 real pages found no print cut by the app; what the
scorecard counted were creases, fold speckle, comb teeth and page edges.

## Kept

- Split: a frame's side is told by every end of its ink, not only the column's
  first and last (fixes frame sides taken as the fold), with two guards so a
  broken fold crossed by a rule or a head's underline is still the fold.
- OCR fill-in: Greek Apple dropped is added back only with strong evidence; Greek
  lines, split words and junk Apple tokens get Tesseract's Greek; English,
  French, German and transliterations (sōma) Apple read stay.
- Export: pages that are only black and white are stored as 1-bit images.
- Design:
  - the rail shows the current page;
  - Stack: flagged list scrolls, heading names the problem, Show buttons line up;
  - no crop sizes while trimming; Cancel before Done;
  - "page" for "scan"; notes cut that only explain;
  - Trim All Pages: Leave Out Selected / Include Selected;
  - straighten sliders without tick marks;
  - Type and Export choices line up;
  - black text on the green and orange crop tags;
  - Apply under Width and Height.

## Dropped or parked

- `claude/hc-parked-gap-middle`: split at the gap's middle when folios cut the gap.
  Codex found three ways it could split into print; no real page gained.
- `claude/hc-parked-crop-to-fold`: Whole-page crop runs into the fold band when ink
  touches it. Fixes 5 synthetic pages; on 108 real pages it adds a black fold band.
- Parallel export encoding: within noise.

## Your call

1. Crop to the fold band (parked branch above): keep a sliver of print safe, or a clean edge?
   **John, 2026-11-20:** the page runs to the fold; the shadow at the fold is part of the
   page, so a crop that keeps it is right. Not done yet: every page's fold-side edge runs to
   the split (not only when ink touches it), then check the measured page size and exports.
2. Smith's scan is a mixed PDF (sharp text layer over a 75 dpi background), 50 KB a page;
   export flattens it to about 690 KB a page. Rebuilding pages that way is a big change.
   **John, 2026-11-20:** no ballooning exports. For scans stored this way, export the 300 dpi
   black-and-white text layer alone (prints clean: no grey page on a b/w printer, no wasted
   ink), but keep the colour layer on pages where it holds a picture, not just shadow.
   Not done yet.
3. Codex proposed and I held back, as they touch your earlier choices: Match ▾ and
   Apply crop menus as buttons; Languages label wording; fainter Stack outlines;
   no angles under Grid pages; a note when Stack pages are left out.
4. Wording I chose: "Resolution if unknown", "Keep page resolution", hover tips say
   "image" where "page" would read "the page is on the page".
   **John, 2026-11-20:** hide the resolution slider while "Keep page resolution" is on (pages
   with no scanned image then export at 300 DPI); switch off shows it as "Export resolution".
   Not done yet. Hover tips keep "image" (John, 2026-11-20).

## Known limits

- OCR: lowercase Czech/Polish words (č, ś, ń) and names the spell checker doesn't know
  get no protection against Greek; French "y" can still become Greek ἦ; a small Greek
  piece under one Apple word can drop.
- Synthetic pages still cut: comb binding and soft-shadow cases (10 pages, 183 px).

## John's review of the on-screen changes (2026-11-20)

- Page view: rail scroll good; Type/Export alignment good; straighten sliders: keep thin but
  bring back the tick marks (they show precision) — not done yet; crop tags: black text stays
  for now, try a darker green/orange tag with white text instead — not done yet.
- New feature asked for: remove the fold shadow on export (export setting, off by default;
  never wash out print in the shadow). After the current calls are built.
- Trim, Stack, Export: all good as changed.
- Welcome: notes cut is fine, but the screen is too blank (before and after). No explanatory
  notes; fill it with something useful instead. John chose: app icon above the name, and a
  recent-books list (first-page thumbnail, date; click reopens with saved edits). Not done yet.
