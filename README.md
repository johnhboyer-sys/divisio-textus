# Divisio Textus

A native macOS app for turning scanned-book PDFs (two book pages per scanned
spread) into clean PDFs with **one book page per PDF page**, cropped to the
content, straightened, searchable, and in correct reading order. Inspired by [Briss](https://briss.sourceforge.net/).

Built with Swift + SwiftUI using only Apple frameworks (PDFKit, Core Image,
Vision — no third-party dependencies). Everything runs on your Mac: the app has
no networking code and sends nothing anywhere.

**Public beta (0.9).** Download the app from
[Releases](https://github.com/johnhboyer-sys/divisio-textus/releases). If something
goes wrong (a crash, a crop that cuts text, a page split in the wrong place),
please [open an issue](https://github.com/johnhboyer-sys/divisio-textus/issues)
saying which Mac and macOS version you use and, if you can, which book or scan.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel. So far it has been tested only
  on macOS 27 (Apple Silicon, and Intel code under Rosetta); reports from
  macOS 14, 15 and 26 are especially welcome.
- To build it: a Swift 6 toolchain (Command Line Tools is enough — full Xcode not required)

## Run

```sh
swift run
```

The first build takes ~45s. If the project sits in an iCloud-synced folder,
macOS may offload build files and stall the build; pass
`--scratch-path ~/Library/Caches/divisio-textus-build` to build outside it. To open a sample, use **Open PDF** and pick
`sample-book.pdf` (a synthetic 6-page scan: 1 cover + 5 spreads).

## Test

```sh
swift test -c release -Xswiftc -enable-testing
```

Run the tests as an optimized build: the image analysis is pixel loops, which a
debug build runs many times slower (plain `swift test` works but takes minutes).
About 78 tests (~20 seconds plus the build) covering page analysis (splits,
crops, scanner bands, shadows, the book block's edge, a speck or hairline on a
blank page, 300 random pages), whole-page crops (the sheet on a dark scanner bed,
a black fold, the corners straightening leaves empty), straightening (known turns, two columns, sparse
lines, tinted paper, pictures beside text), rendering, gray detection,
scan-resolution detection, export (page size, cancel, reading order, skipped
pages) and editing (undo/redo, autosave, re-detect, odd/even crops). Test PDFs are generated on the fly; saved edits go to
a temporary folder, never your real ones. OCR isn't covered: Vision is too slow
and erratic for an automated suite.

## Opening the app (first time)

If someone sent you the **Divisio Textus** app, follow these steps the **first
time** you open it. (You only need to do this once.)

1. Drag **Divisio Textus.app** into your **Applications** folder.
2. **Do not double-click it yet.** Instead, **right-click** the app icon (or hold
   **Control** and click) and choose **Open** from the menu that appears.
3. A message will say macOS "cannot verify the developer." Click the **Open**
   button in that message.
4. The app opens. From now on you can open it normally by **double-clicking**.

> If you don't see an **Open** button in step 3, go to the Apple menu →
> **System Settings → Privacy & Security**, scroll down, and click
> **"Open Anyway"** next to the Divisio Textus message, then try again.

Why this happens: the app is signed for personal use but not registered with
Apple's paid notarization service, so macOS asks you to confirm the first launch.

## How it works

```
Import → auto-classify → gutter split → deskew → crop → OCR → reorder → export
```

1. **Import** a PDF; each page is rendered to a preview bitmap.
2. **Auto-classify** each page as Spread / Single / Skip (aspect ratio + content).
3. **Gutter detection** finds the split line: a binding shadow if there is one,
   otherwise the middle of the clean white gap between the pages (off center is fine).
4. **Content-bounds detection** seeds a crop box for each half (Briss-style),
   trimming dark scanner bands along the edges first (even behind a thin light
   strip, with ragged streaks). When analysis finishes, blank and nearly empty
   pages (part titles, chapter ends) get the book's usual crop and split, so
   every page comes out a matching size. **Crop to: Whole page** (the default
   for new books) crops to the sheet of paper instead, margins included: it leaves out the scanner
   background around the sheet and a black fold at the gutter, and keeps clear
   of the corners straightening leaves empty (but never cuts printed text).
   It then gives the whole book one page size: measured on the pages whose
   sheet edges show (paper meeting the scanner bed, or the strip of
   neighbouring leaves beyond it), placed on each page where its sheet is, so
   those strips are left out. The inspector shows the size, and you can type
   the book's real size instead.
5. **Edit** in the UI: drag the orange split line, drag/resize the blue (left) and
   green (right) crop boxes, right-click a thumbnail to change its type.
   "Apply layout to all spreads" copies one spread's layout everywhere; for
   single-page scans, crops can go to all pages or to alternate (left-hand /
   right-hand) pages. ↑/↓ move between pages; ⌘Z / ⇧⌘Z undo and redo edits;
   pinch or ⌘= / ⌘− / ⌘0 to zoom. Edits are saved automatically and come back
   when you reopen the same PDF. The inspector's **Whole book** group (also in
   the Edit menu) has Auto-detect all pages, which starts over, and
   Auto-straighten all pages (angles only, crops kept); each is one undo step.
   **Stack** view (⌘2; ⌘1 back to Page) lays every left-hand page on top of the
   others, likewise right-hand and single pages, with each page's crop drawn
   over the blend. Pages whose crop is a different size from the rest turn red
   and are listed; click one to open it. The orange box can be applied to every
   page in the stack, or only to the flagged ones.
6. **Export** renders each page at its scan's own resolution (150–600 DPI; a
   fixed DPI for pages without a scan), at its own size (never padded or scaled;
   the page keeps its physical size), adds an invisible OCR text layer, and
   writes pages in reading order. Each page is stored as JPEG or losslessly,
   whichever is smaller (gray when the scan has no color). Pages are processed a
   few at a time, so memory stays flat however long the book is; ⌘. cancels.

## Project layout

| Path | Role |
|------|------|
| `Models/CropRect.swift` | Normalized (top-left origin) crop rectangle |
| `Models/BookPage.swift` | Per-source-page state: type, split, crops |
| `Models/PageStack.swift` | Stack view groups, side coordinates, flagged pages |
| `Models/AppModel.swift` | `ObservableObject` document/app state + actions |
| `Services/GrayBuffer.swift` | Fast downsampled grayscale for analysis |
| `Services/PageAnalyzer.swift` | Gutter + content-bounds + classification heuristics |
| `Services/PDFRenderer.swift` | Render PDF pages to bitmaps; crop |
| `Services/PDFExporter.swift` | Crops → output PDF with OCR text layer |
| `Services/StackRenderer.swift` | Blends a stack's pages into one image |
| `Views/*` | Thumbnail rail, page editor canvas, stack view, inspector |
| `Tools/make_sample.swift` | Standalone generator for `sample-book.pdf` |
| `Tests/PDFCropperTests/` | `swift test` suite (Swift Testing) |

## Roadmap (phased)

- [x] **v1:** import → auto-split → manual crop → uniform export
- [x] **Deskew:** auto skew detection (projection profile) + manual straighten
      slider, applied to preview and export before cropping. **Per-side:** the
      two book pages of a spread are detected and straightened independently
      (left/right often differ on hand scans), then composited at the gutter.
- [x] **OCR:** Vision text recognition → invisible searchable text layer
      embedded over each page (toggle in Output). PDF stays selectable/searchable.
- [x] **Multi-column OCR:** detect column boundaries and recognize each column
      separately so multi-column pages (and boxed tables) read in correct order.
- [x] **Color / Grayscale:** optional plain desaturation (no contrast or
      sharpening) that shrinks color scans ≈ −40% with no visible quality loss.
      (B&W binarize / clean-up / despeckle were tried and removed — they
      over-processed readable book scans.)
- [x] **Full-res fidelity:** export at each scan's native DPI
- [x] Separate crop layouts for odd vs. even (left vs. right) pages
- [ ] Right-to-left reading mode in the UI
- [x] Packaged, ad-hoc signed universal `.app` (`Tools/make_app.sh`)
- [ ] Notarized `.app` (needs a paid Apple Developer account)
```
