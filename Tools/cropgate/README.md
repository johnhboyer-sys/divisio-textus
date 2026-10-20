# Crop gate

Synthetic test pages (real Times type at scan edges, folios, marginal numbers, rules,
frames, bed bands, bindings, slanted plates) that shadow-removal rules have cut by
mistake, collected from Codex and Grok reviews in October 2026. `ab.sh` compares this
checkout's PageAnalyzer with e93b1c4's and fails if any page keeps less print.

CropRect.swift and GrayBuffer.swift are stand-alone copies so the harness builds
without the app. Run from anywhere: `Tools/cropgate/ab.sh`.
