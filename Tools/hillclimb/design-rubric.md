# Design rubric: pairwise judging

You see two screenshots, A and B, of the same screen in the same theme (light or
dark) of Divisio Textus, a Mac app that cuts scanned two-page spreads into single
book pages. Judge each criterion on its own. For each, answer `A`, `B` or `tie`
and give one line of reason that points at something visible. Then give an overall
pick (`A`, `B`, `tie`) and the single most important difference.

Judge what you see. Do not guess what the code does. If the two shots differ in
content only (a different page shown), ignore the page and compare the app's own
controls and text.

## Criteria

1. **Plain, short labels.** Everyday words. Say "page", not "scan". No jargon, no
   internal terms, no long phrases where one word does. Shorter wins when
   the meaning is the same.
2. **Notes and captions.** A note appears only when something is wrong, and says
   what is wrong. It never describes what the user did ("You changed...",
   "Trim applied"). A screen with no problem and no notes is best. Prefer the
   one with fewer needless notes; prefer a note that names the problem.
3. **Alignment, spacing, grouping.** Edges line up. Gaps repeat the same few
   sizes. Related controls sit together and unrelated ones apart. Rows in the
   sidebar share one rhythm.
4. **Visual hierarchy.** The main action stands out. The current page is plain
   to see in the rail and the canvas. Secondary controls recede.
5. **Contrast and legibility in this theme.** Text, icons, selection and
   borders read clearly against their background at normal viewing size. Judge
   the theme shown, not the other one.
6. **Nothing clipped, truncated or overlapping.** No cut-off words, no "..."
   where a label should show whole, no controls on top of each other, no
   content running off an edge.
7. **macOS conventions.** Toolbar, sidebar and sheets look and act as in
   Apple's apps: standard controls, title bar use, sheet placement, button
   order and style, system fonts and sizes.
8. **No hidden actions.** An action the user needs is visible, not tucked
   behind a "..." button or a dropdown menu. No split percentage appears
   anywhere (it is not a number a user should see).

## Fixed by the owner. Do not reward changing these.

- The left page rail is always visible (except where the screen has none now:
  Grid and Export).
- Three views: Grid, Page, Stack, in the toolbar switch.
- The right sidebar has a `This Page | All Pages` switch.
- Export opens a full Export view, not a sheet.

A shot that moves, hides or renames any of these loses on the matching
criteria; one that merely keeps them earns nothing extra for it.

## Output format

```
1 labels:      A|B|tie  - reason
2 notes:       A|B|tie  - reason
3 alignment:   A|B|tie  - reason
4 hierarchy:   A|B|tie  - reason
5 contrast:    A|B|tie  - reason
6 clipping:    A|B|tie  - reason
7 conventions: A|B|tie  - reason
8 hidden:      A|B|tie  - reason
overall: A|B|tie  - most important difference
```
