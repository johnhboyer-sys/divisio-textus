import Foundation
import AppKit
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PDFCropper

/// Shared plumbing for the hill-climb measurement suites (see Tools/hillclimb/README.md).
/// Everything here is test-only. The suites run only when HILLCLIMB_DIR is set.
enum HillClimb {
    static let env = ProcessInfo.processInfo.environment

    /// The gate every hill-climb suite uses.
    static let enabled = ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil

    static var dir: URL { URL(fileURLWithPath: env["HILLCLIMB_DIR"] ?? "/nonexistent", isDirectory: true) }
    static var label: String {
        let l = env["HILLCLIMB_LABEL"] ?? ""
        return l.isEmpty ? "current" : l
    }
    static var books: URL { dir.appendingPathComponent("books", isDirectory: true) }
    static var results: URL { dir.appendingPathComponent("results/\(label)", isDirectory: true) }
    /// Synthetic books are rewritten here each run, so the diff tool can draw them.
    static var synth: URL { dir.appendingPathComponent("synth", isDirectory: true) }

    /// Scratch space inside the test run's temporary folder (never the books folder).
    static var scratch: URL {
        let u = Fixtures.directory.appendingPathComponent("hillclimb", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Point saved edits at a temporary folder, so no run reads or writes the user's real ones.
    static func prepare() {
        _ = Fixtures.directory
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    }

    /// A model as the app ships it (default Crop-to mode, deskew on), saving into the test folder.
    @MainActor static func makeModel() -> AppModel {
        _ = Fixtures.directory
        let m = AppModel(defaults: UserDefaults(suiteName: "hillclimb-\(UUID().uuidString)") ?? .standard)
        m.revealExportInFinder = false
        return m
    }

    /// Open a PDF the way the app does and wait for Auto-detect to finish.
    @MainActor static func load(_ url: URL, into m: AppModel) async {
        m.load(url: url)
        // The first pass starts on the next turn of the run loop.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await waitUntilIdle(m)
    }

    static func write(_ object: Any, _ name: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try? data.write(to: results.appendingPathComponent(name), options: .atomic)
    }

    /// Doubles rounded so two runs print the same text.
    static func r(_ x: Double, _ digits: Int = 5) -> Double {
        guard x.isFinite else { return 0 }
        let p = pow(10.0, Double(digits))
        return (x * p).rounded() / p
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded(.up)))]
    }

    /// 8-bit gray pixels of an image (luma), top-left origin.
    static func gray(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// 8-bit RGBX pixels of an image, top-left origin, 4 bytes per pixel.
    static func rgbx(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    static func png(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// The books in the corpus, by name.
    static func bookURLs() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: books, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }

    /// A PDF holding every `step`-th page of `source`, written to scratch.
    static func sampledCopy(of source: URL, every step: Int, named name: String) -> URL? {
        guard let src = PDFDocument(url: source) else { return nil }
        let out = PDFDocument()
        var k = 0
        for i in stride(from: 0, to: src.pageCount, by: step) {
            guard let page = src.page(at: i)?.copy() as? PDFPage else { return nil }
            out.insert(page, at: k)
            k += 1
        }
        let url = scratch.appendingPathComponent(name)
        return out.write(to: url) ? url : nil
    }

    /// A short name for a book PDF: "Smith-1950".
    static func shortName(_ url: URL) -> String {
        let n = url.deletingPathExtension().lastPathComponent
        let parts = n.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? "\(parts[0])-\(parts[1])" : n
    }
}

/// SplitMix64: small, fast and the same on every run.
struct HCRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}
