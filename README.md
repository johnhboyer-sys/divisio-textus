# Divisio Textus

A native macOS app for turning scanned-book PDFs (two book pages per scanned
spread) into clean PDFs with **one book page per PDF page**, cropped to uniform
size and margins, in correct reading order. Inspired by [Briss](https://briss.sourceforge.net/).

Built with Swift + SwiftUI using only Apple frameworks (PDFKit, Core Image,
Vision — no third-party dependencies).

## Requirements

- macOS 14+
- Swift 6 toolchain (Command Line Tools is enough — full Xcode not required)

## Run

```sh
swift run
```

The first build takes ~45s. To open a sample, use **Open PDF** and pick
`sample-book.pdf` (a synthetic 6-page scan: 1 cover + 5 spreads).

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
Import → auto-classify → gutter split → crop → pad to common size → reorder → export
```

1. **Import** a PDF; each page is rendered to a preview bitmap.
2. **Auto-classify** each page as Spread / Single / Skip (aspect ratio + content).
3. **Gutter detection** finds the split line (darkest central column = binding shadow).
4. **Content-bounds detection** seeds a crop box for each half (Briss-style).
5. **Edit** in the UI: drag the orange split line, drag/resize the blue (left) and
   green (right) crop boxes, right-click a thumbnail to change its type.
   "Apply crop to all pages" copies one layout everywhere.
6. **Export** renders each crop at the chosen DPI and pads (never scales) it onto a
   common canvas so every output page is identical in size, emitted in L→R order.

## Project layout

| Path | Role |
|------|------|
| `Models/CropRect.swift` | Normalized (top-left origin) crop rectangle |
| `Models/BookPage.swift` | Per-source-page state: type, split, crops |
| `Models/AppModel.swift` | `ObservableObject` document/app state + actions |
| `Services/GrayBuffer.swift` | Fast downsampled grayscale for analysis |
| `Services/PageAnalyzer.swift` | Gutter + content-bounds + classification heuristics |
| `Services/PDFRenderer.swift` | Render PDF pages to bitmaps; crop |
| `Services/PDFExporter.swift` | Compose padded uniform pages → output PDF |
| `Views/*` | Thumbnail rail, page editor canvas, inspector |
| `Tools/make_sample.swift` | Standalone generator for `sample-book.pdf` |

## Roadmap (phased)

- [x] **v1:** import → auto-split → manual crop → uniform export
- [x] **Deskew:** auto skew detection (projection profile) + manual straighten
      slider, applied to preview and export before cropping. **Per-side:** the
      two book pages of a spread are detected and straightened independently
      (left/right often differ on hand scans), then composited at the gutter.
- [x] **OCR:** Vision text recognition → invisible searchable text layer
      embedded over each page (toggle in Output). PDF stays selectable/searchable.
- [ ] **Multi-column OCR:** detect column boundaries and recognize each column
      separately so multi-column pages (and boxed tables) read in correct order.
      Current OCR assumes single-column flow; multi-column pages scramble order.
- [x] **Color / Grayscale:** optional plain desaturation (no contrast or
      sharpening) that shrinks color scans ≈ −40% with no visible quality loss.
      (B&W binarize / clean-up / despeckle were tried and removed — they
      over-processed readable book scans.)
- [ ] **Full-res fidelity:** extract source images at native scan DPI
- [ ] Separate crop layouts for odd vs. even (left vs. right) pages
- [ ] Right-to-left reading mode in the UI
- [ ] Packaged, signed/notarized `.app`
```
