import Foundation
import CoreGraphics
import Darwin

enum OCRReader: String, CaseIterable, Identifiable {
    case apple, tesseract
    var id: String { rawValue }
}

/// Runs the bundled or locally installed Tesseract reader.
enum TesseractService {
    /// Finds an executable in the app bundle, then in Homebrew's usual folders.
    static func executableURL() -> URL? {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: "tesseract"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/tesseract"),
                          URL(fileURLWithPath: "/usr/local/bin/tesseract")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The user's language packs, created when first needed.
    static var packFolder: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Divisio Textus/tessdata", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let installLock = NSLock()

    /// Copies bundled packs the user's folder lacks; a pack already there, maybe the
    /// user's own, stays.
    static func installBundledPacks() {
        installLock.lock(); defer { installLock.unlock() }
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("tessdata"),
              let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "traineddata" {
            let target = packFolder.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path), let data = try? Data(contentsOf: file) {
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    /// Lists the language codes present in a pack folder.
    static func installedPacks(in folder: URL = packFolder) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return Set(files.filter {
            $0.pathExtension == "traineddata" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { $0.deletingPathExtension().lastPathComponent })
    }

    enum PackError: Error { case badResponse, tooSmall, badName, unreadable }

    /// True when Tesseract can load `file` as the pack `code` (it reads a blank
    /// image with it); a truncated or foreign file fails. True when there is no
    /// Tesseract to ask.
    static func loads(_ file: URL, code: String) -> Bool {
        guard executableURL() != nil else { return true }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("PackCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: folder.appendingPathComponent("\(code).traineddata"))
        } catch { return false }
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let blank = ctx.makeImage() else { return false }
        return recognize(blank, languages: [code], tessdata: folder, timeout: 60) != nil
    }

    /// Checks a finished download (HTTP 200, over 1 KB) and moves it into the folder
    /// as `<code>.traineddata`, replacing any old copy.
    static func accept(download file: URL, response: URLResponse, code: String, folder: URL = packFolder,
                       check: (URL, String) -> Bool = loads) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PackError.badResponse }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 1024 else { throw PackError.tooSmall }
        guard check(file, code) else { throw PackError.unreadable }
        let target = folder.appendingPathComponent("\(code).traineddata")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: target)
        }
    }

    /// Downloads one language pack from tessdata_best.
    static func download(_ code: String, folder: URL = packFolder,
                         session: URLSession = .shared) async throws {
        let (file, response) = try await session.download(from: TesseractLanguage.downloadURL(code))
        defer { try? FileManager.default.removeItem(at: file) }
        try accept(download: file, response: response, code: code, folder: folder)
    }

    /// Copies a `.traineddata` file into the folder, replacing any old copy; returns its code.
    @discardableResult
    static func addPack(from url: URL, folder: URL = packFolder,
                        check: (URL, String) -> Bool = loads) throws -> String {
        guard url.pathExtension == "traineddata" else { throw PackError.badName }
        let code = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 1024 else { throw PackError.tooSmall }
        guard check(url, code) else { throw PackError.unreadable }
        let target = folder.appendingPathComponent(url.lastPathComponent)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try fm.copyItem(at: url, to: temp)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
        return code
    }

    /// Reads a page as gray PGM; returns nil if writing, launching, or reading fails.
    static func recognize(_ image: CGImage, languages: [String], tessdata: URL = packFolder,
                          executable: URL? = executableURL(), timeout: TimeInterval = 180) -> OCRService.Recognition? {
        guard let executable, !languages.isEmpty, timeout.isFinite, timeout > 0,
              let gray = GrayBuffer(cgImage: image, maxDim: max(image.width, image.height)) else { return nil }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Tesseract-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let input = folder.appendingPathComponent("page.pgm")
            var pgm = Data("P5\n\(gray.width) \(gray.height)\n255\n".utf8)
            pgm.append(contentsOf: gray.pixels)
            try pgm.write(to: input)

            // Files drain both streams without pipe buffers or reader threads.
            let output = folder.appendingPathComponent("stdout")
            let errors = folder.appendingPathComponent("stderr")
            try Data().write(to: output)
            try Data().write(to: errors)
            let stdout = try FileHandle(forWritingTo: output)
            defer { try? stdout.close() }
            let stderr = try FileHandle(forWritingTo: errors)
            defer { try? stderr.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = [input.path, "stdout", "--tessdata-dir", tessdata.path,
                                 "-l", languages.joined(separator: "+"), "--psm", "3",
                                 "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=0"]
            var environment = ProcessInfo.processInfo.environment
            environment["OMP_THREAD_LIMIT"] = "1"
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                return nil
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            let tsv = try String(contentsOf: output, encoding: .utf8)
            guard tsv.hasPrefix("level\tpage_num\t") else { return nil }
            return OCRService.Recognition(lines: parseTSV(tsv, imageSize: CGSize(width: image.width, height: image.height)), complete: true)
        } catch {
            return nil
        }
    }

    /// Groups TSV words into lines and converts top-left pixels to bottom-left boxes.
    static func parseTSV(_ tsv: String, imageSize: CGSize) -> [OCRService.Line] {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return [] }
        var groups: [[OCRService.Word]] = []
        var indices: [[Int]: Int] = [:]
        for row in tsv.split(whereSeparator: \.isNewline) {
            let fields = row.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
            guard fields.count == 12, fields[0] == "5" else { continue }
            let key = fields[1...4].compactMap { Int($0) }
            let text = fields[11].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count == 4, !text.isEmpty,
                  let left = Double(fields[6]), let top = Double(fields[7]),
                  let width = Double(fields[8]), let height = Double(fields[9]),
                  [left, top, width, height].allSatisfy(\.isFinite),
                  left >= 0, top >= 0, width > 0, height > 0 else { continue }
            let box = CGRect(x: left / imageSize.width, y: 1 - (top + height) / imageSize.height,
                             width: width / imageSize.width, height: height / imageSize.height)
            let index: Int
            if let found = indices[key] { index = found }
            else { index = groups.count; indices[key] = index; groups.append([]) }
            groups[index].append(OCRService.Word(text: text, box: box))
        }
        return groups.map { words in
            OCRService.Line(text: words.map(\.text).joined(separator: " "),
                            box: words.reduce(.null) { $0.union($1.box) }, words: words)
        }
    }
}
