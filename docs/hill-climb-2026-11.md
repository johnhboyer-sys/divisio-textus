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
  recent-books list (first-page thumbnail, date; click reopens with saved edits). The name set
  as on the site hero (divisio-site style.css .hero h1): "Divisio" and "Textus" in heavy type
  either side of a dashed split line, icon above. Not done yet.
- Held-back design ideas (proposals on branch claude/hc-design-proposals), John's calls:
  a. Yes, as two full-width buttons "Make Right Match Left" / "Make Left Match Right", with the
     words Left and Right coloured as the boxes (left blue, right green).
  b. Yes to the two buttons, but keep the label "Apply crop" (not "Copy crop").
  c. "Other languages:" followed by the ticked languages (Choose… when none). Apple Vision only.
  d. Yes (fainter Stack outlines).
  e. Yes (no angles under Grid pages).
  f. Yes (note when Stack pages are left out); the page list is much narrower than the
     window — to settle.
- Welcome layout (John): logo centred left-right, its centre on the upper third line of the window
  (rule of thirds), not the window's middle; recent files as a
  horizontal grid of cards (first-page thumbnail, name, date) below it.
- Stack page list (John): thumbnails layout (branch claude/hc-stack-list-variants, DEBUG
  variant "thumbs"). To do: show the stack's own page (the left or right page cropped), not the
  whole scan, so each is narrow and sharp; box height fits short stacks.
- Built on branch claude/ui-approved, John approved from screenshots (2026-11-20): Match buttons
  (Left blue, Right green), "Apply crop" with two buttons, "Other languages:", resolution slider
  hidden while Keep page resolution is on, thin straighten sliders with drawn ticks, darker
  green/orange crop tags with white text (now the default), Welcome (logo on the upper third,
  dashed line only as tall as the name, recent-book cards).
- B/W export (John): clean b/w of layered scans approved; it must not lose ink (Smith title
  letters, PART TWO rules, stamps). Remove shadows in b/w while keeping the full page size.
  In progress on branch claude/bw-ink (ink judged against local paper; also a trial b/w for
  plain scans to judge as a future option).
- Page to the fold (branch claude/page-to-fold), Codex review 2026-11-20: John keeps it as is.
  A white corner triangle on straightened pages stays (the page must be straight; users can
  undo the turn). A wrong split pulling in a strip of the other page stays (the user drags
  the split; that is what manual editing is for).
- Feature idea (John): an erase tool — draw a box on a page to blank that area in the export
  (library stamps, call numbers, marks the b/w step keeps). Not started.
- B/w review (John, 2026-11-20): needs work — complete shadow removal: no shadow, streak or
  black by the fold; pages as pristine as possible. Black outside the page (scanner bed) is
  the user's to trim; don't focus on it. Yes to a "Black and white" export option for plain
  scans.
- Shadow removal (John): an OPTION ("Remove shadows", export setting) that removes shadows
  completely, in colour, grey and b/w; trimming to the page is the user's job. Run it as a
  hill climb with a score (fold residue down, print loss ~0).
- Remove shadows (branch claude/bw-pristine), John's review 2026-11-21: good, but clean the comb
  teeth too. Speed work kept output identical (Riezler Color+Remove shadows 140 → 102 s; Wallace
  B&W 36 → 23 s); Smith's slow modes stay about 4× plain Color. Comb teeth: in progress.
- Next climbs (John, 2026-11-21): split and crop, speed, page flattening; not Czech/Polish OCR
  for now. Split/crop (claude/hc2-split) and flattening (claude/hc2-flatten, an export option
  "Flatten pages", off by default; round 1 plain scans only) started from 3660816. Speed waits
  for the comb-teeth fixes, which touch the same files.
- Rebuilding pages as typeset text (matched font, OCR text drawn visibly): dropped 2026-11-21.
  A different app, and OCR errors would show on the page. "A better version" comes from
  Remove shadows, Black and white and Flatten pages instead.
- Grok review of claude/ui-approved (2026-11-21): nothing serious. Four low items for the
  finishing pass: "Apply crop" row clips at the 260pt inspector minimum (InspectorView:149);
  a recent card whose file was deleted after Welcome appeared stays after a failed open
  (WelcomeView:114, refresh on failure); fileExists on main thread can wait on a stalled network
  share (RecentFiles:35); Welcome logo has no accessibility label (WelcomeView:24, hide it).
- Comb teeth done (claude/bw-pristine 5f3bec5): Oesterle comb residue 636 B&W / 757 Color /
  685 Gray px, no print lost, hanging list "1." full stops kept. Known limits (rare, left by
  John's call): thin "1." with a stop 13 px off; faded serif "1" reaching above a tooth;
  hanging bullets before 1–2 character answers; a gray rule just short of a tooth; a column of
  thin "1"s or a thin table rule read as a page-stack stripe; a sliver at one Oesterle tooth tip.
- Split/crop climb 2 (claude/hc2-split, 3 commits on 3660816): mean split error 0.432 → 0.251%,
  p95 1.98 → 0.92%, synthetic pages with print cut 6 → 5, splits through print 2 → 2. 15 real
  pages moved (Freudenthal fold onto the crease, Oesterle onto the spiral's middle, Smith blank
  pages crop out scanner bed), no print cut by eye. Rejected: skipping frame sides in broad
  fold shadow (moved 13–153 real pages, new splits through print).
- Speed climb (claude/hc2-speed, 17 commits on 88680ec): output byte- and pixel-identical on
  822 pages. Under heavy load, B&W and Remove shadows now take 0.12–0.6× the time; Smith
  B&W 58.6 → 7.3 s; Riezler Color+Remove shadows 188 → 51 s. Left: ShadowRemoval.page loops,
  CG drawing of straightened layers, ImageTransform.rotateInPlace.
- Flatten pages (claude/hc2-flatten, 4 rounds on 3660816): export option off by default; off
  is byte-identical. Smith curled sides: gutter droop 2.00 → 0.61 pt, letter width at gutter
  0.955 → 0.983, no print lost by eye. But Smith is a layered scan, which round 1 leaves
  unflattened, and the plain scans in the corpus barely curl (Freudenthal 67L 1.12 → 0.28 pt).
  Useful in export only once layered scans are flattened (next round).
  Codex review of claude/hc2-flatten, to fix next round: a tall drop capital (or a folio on the
  crop's edge row) is left out of the edge guard and can be pushed out of the crop
  (Flatten.swift:304); two close columns with offset baselines join into "long lines" and a
  straight page gets bent (Flatten.swift:505); the 120 DPI preview skips small type that the
  300 DPI export flattens (AppModel.swift:577).
  Codex's three split findings fixed (8f15a5b, b6082d4, a1831ce); 0 real pages moved, scores
  unchanged. Limits: a frame corner within 4 px of the scan edge isn't checked; spiral holes
  under 1.5× x-height don't join gaps.
- Grok shadow fixes (claude/grok-fix 14e06d6): Wallace contents pages keep page numbers, section
  numbers and the dot of "vi"; margin rules kept (S2). New print-loss gate over every page of all
  8 books. Still losing print with Remove shadows: Cherniss index p215R–217R and p191R (file
  claims 72 ppi, so the shadow step's inch sizes are 4× off); fix in progress on
  claude/grok-fix-scale. Small leftovers: 13 marks of Freudenthal's cover emblem in B&W; a ";"
  and "i" at Wallace p2L's fold in Color; pencil notes and stamps are removed as marks.
- Cherniss fixed (claude/shadow-determinism, from claude/grok-fix-scale 0a729bd): its PDF claims
  72 ppi on a 36-inch spread, so Remove shadows now measures the scale from the letters on any
  crop 20 inches or longer. Index columns, line ends and the p4R notice kept; other books'
  pages unchanged. Remove shadows also gave a few different specks run to run; now it judges
  marks in a fixed order (2988 pages identical over two runs). Codex's limits, left as rare:
  a page claiming 20+ inches with two type sizes 4× apart can lose a margin column of thin
  small type; a true 20-inch foldout in large type can lose a margin rule.
- Flatten pages round 2 (claude/hc2-flatten2 d492e2e): layered scans flatten too (one warp on
  both layers, in register). Smith, all curled sides: gutter droop 1.97 → 0.46 pt (B&W 0.50),
  letter width 0.952 → 0.972; 392 of 488 sides flattened (B&W 384); bytes +0.2% (worst +1.8%);
  export about 1.3–1.7× slower with it on. Codex's round-1 and round-2 findings fixed with tests
  (edge folios and capitals, offset columns, colour-only print, preview at export resolution).
  Off is byte-identical. Limits: a capital wider than tall on the scan's own edge counts as cut;
  some sides with dark strips at the scan edge stay curved.
- Grok B&W fixes (claude/grok-bw a434b97, merged into claude/finish d250754): Black and white no
  longer erases print by fold bands, rims and the picture tests (Grok 1, 2, 3, 4, 8). Gate: no
  book worse; Freudenthal B&W lost letters 1224 → 1211; Freudenthal's cover title kept. Color and
  Gray off-mode output byte-identical in all 8 books; B&W changes only on the fixed pages.
  1.03× slower. Open for John: an edge picture in Color/Gray with the options off still exports
  as the 1-bit text layer (fixing it changes off-mode output). Codex's limits, left as rare: a
  long rim joined to kept print stays; a narrow letter by a band on a page too sparse for line
  finding (title page, short caption) gets no extra protection (same as before the fix).
- Grok review of all changes (claude/finish vs main, 2026-11-22, three static reads). Fixed:
  Flatten could push the gutter end of a line out when the first or last baseline sits within
  a pitch of the crop edge; such a side now stays curved (claude/flatten-edge dbb34e8, Codex: no
  findings; Smith 392/488 flattened, unchanged). Checked and false: text operators break image
  DPI reading (tested: the scanner drops leftover operands); Export grid freezes with the new
  options (timed: same cost as plain Color). By design: layered scans export their text layer
  in Color/Gray off; Keep page resolution uses 300 DPI for a page with no image; the new
  options aren't remembered across launches. Left as rare: B&W clears a rule within 0.05 in of
  the crop side or inside a dark top shadow, and a faint colour-layer-only accent next to a
  letter; Remove shadows can lift gray print where the fold pulls the paper map below it, and
  clears a margin digit within 0.25 in of the side if a speck sits near it; Flatten can miss an
  edge piece cut by the crop, and a dark crease touching letters can bend a straight line;
  stack thumbnails show the page before straightening.
