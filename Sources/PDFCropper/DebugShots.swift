#if DEBUG
import SwiftUI
import AppKit
import PDFKit

/// DEBUG builds only. With DIVISIO_SHOTS=<path to a JSON plan> in the environment,
/// drives the app through each screen by code and writes PNGs of its own window,
/// light and dark, then quits. Nothing here is compiled into a release build, and
/// without the variable nothing here runs. See Tools/hillclimb/shots.sh.
///
/// Plan keys: outDir, scratchDir (where this run's saved edits go, in place of
/// Application Support), smith, riezler (PDF paths), width, height, spreadIndex,
/// only (optional list of scenario names).
@MainActor
enum DebugShots {
    struct Plan: Decodable {
        var outDir: String
        var scratchDir: String
        var smith: String
        var riezler: String
        var width: Double = 1440
        var height: Double = 900
        var spreadIndex: Int = 19
        var only: [String]?
    }

    private static var started = false

    static func startIfRequested(_ model: AppModel) {
        guard !started, let path = ProcessInfo.processInfo.environment["DIVISIO_SHOTS"],
              let data = FileManager.default.contents(atPath: path),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return }
        started = true
        // Saved edits go to a scratch folder, so a run never reads or writes the
        // real ones: every run analyses each book fresh, the same way.
        let scratch = URL(fileURLWithPath: plan.scratchDir, isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        ProjectStore.directory = scratch
        Task { @MainActor in
            let run = Run(model: model, plan: plan)
            await run.go()
            try? "done".write(toFile: plan.outDir + "/.done", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    final class Run {
        let model: AppModel
        let plan: Plan
        init(model: AppModel, plan: Plan) { self.model = model; self.plan = plan }

        var window: NSWindow? {
            NSApp.windows.first { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.contentView != nil }
        }

        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

        func log(_ s: String) { FileHandle.standardError.write(Data(("[shots] " + s + "\n").utf8)) }

        // MARK: window and capture

        func prepareWindow() {
            guard let w = window else { return }
            // Set the content size outright; AppKit does not shrink this to the screen.
            w.setContentSize(NSSize(width: plan.width, height: plan.height))
            w.setFrameOrigin(NSPoint(x: 0, y: 0))
        }

        func snapshot(_ w: NSWindow) -> NSBitmapImageRep? {
            guard let frame = w.contentView?.superview else { return nil }
            w.displayIfNeeded()
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            // A sheet is its own window: draw it over the parent where it sits.
            if let sheet = w.attachedSheet, let sframe = sheet.contentView?.superview,
               let srep = sframe.bitmapImageRepForCachingDisplay(in: sframe.bounds) {
                sframe.cacheDisplay(in: sframe.bounds, to: srep)
                let scale: CGFloat = 1   // the bitmap's drawing space is in points
                let rel = NSRect(x: sheet.frame.minX - w.frame.minX, y: sheet.frame.minY - w.frame.minY,
                                 width: sheet.frame.width, height: sheet.frame.height)
                NSGraphicsContext.saveGraphicsState()
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.current = ctx
                    NSColor.black.withAlphaComponent(0.15).setFill()
                    NSRect(origin: .zero, size: rep.size).fill()
                    let dest = NSRect(x: rel.minX * scale, y: rel.minY * scale,
                                      width: rel.width * scale, height: rel.height * scale)
                    srep.draw(in: dest)
                    ctx.flushGraphics()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return rep
        }

        func bytes(_ rep: NSBitmapImageRep) -> Data {
            guard let p = rep.bitmapData else { return Data() }
            return Data(bytes: p, count: rep.bytesPerRow * rep.pixelsHigh)
        }

        func spinning(in view: NSView) -> Bool {
            if let p = view as? NSProgressIndicator, !p.isHidden { return true }
            return view.subviews.contains { spinning(in: $0) }
        }

        /// Quiet means: the model is not working, every page is analysed, no spinner shows,
        /// and two captures 0.4 s apart are the same, pixel for pixel.
        func settle(timeout: Double = 240, also: () -> Bool = { true }) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            var last: Data?
            var stable = 0
            while Date() < end {
                await pause(0.4)
                guard let w = window else { continue }
                let analysed = model.pages.allSatisfy(\.analyzed)
                let spin = (w.contentView?.superview).map(spinning) ?? false
                let sheetSpin = w.attachedSheet?.contentView.map(spinning) ?? false
                guard (model.document == nil || (analysed && !model.isBusy)), !spin, !sheetSpin, also(),
                      let rep = snapshot(w) else { stable = 0; last = nil; continue }
                let now = bytes(rep)
                if now == last { stable += 1 } else { stable = 0; last = now }
                if stable >= 2 { return true }
            }
            log("gave up: busy=\(model.isBusy) analysed=\(model.pages.allSatisfy(\.analyzed)) status=\(model.statusText)")
            return false
        }

        func save(_ name: String, _ appearance: String, quiet: Bool) {
            guard let w = window, let rep = snapshot(w),
                  let png = rep.representation(using: .png, properties: [:]) else { log("no image for \(name)"); return }
            let file = "\(plan.outDir)/\(name)-\(appearance).png"
            try? png.write(to: URL(fileURLWithPath: file))
            log("\(name)-\(appearance) \(rep.pixelsWide)x\(rep.pixelsHigh)\(quiet ? "" : " NOT SETTLED")")
        }

        /// Both themes of the screen as it now stands.
        func shoot(_ name: String, also: () -> Bool = { true }) async {
            guard plan.only?.contains(name) ?? true else { return }
            for (appearance, ns) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: ns)
                await pause(0.5)
                let quiet = await settle(also: also)
                save(name, appearance, quiet: quiet)
            }
        }

        // MARK: driving the views

        func views(of root: NSView?) -> [NSView] {
            guard let root else { return [] }
            return [root] + root.subviews.flatMap { views(of: $0) }
        }

        /// The sidebar's This Page | All Pages switch (segment 0 or 1).
        func chooseSide(_ segment: Int) async {
            guard let w = window else { return }
            for v in views(of: w.contentView?.superview) {
                guard let s = v as? NSSegmentedControl, s.segmentCount == 2,
                      s.label(forSegment: 1) == "All Pages" else { continue }
                s.selectedSegment = segment
                s.sendAction(s.action, to: s.target)
                await pause(0.5)
                return
            }
            log("sidebar switch not found")
        }

        func pressLanguages() async {
            await pause(2)
            guard let w = window else { return }
            // The Languages row's button has no title or label to find it by (SwiftUI
            // draws its text itself). In the Export view it is the first plain button
            // after the Reader popup, the second popup down the sidebar.
            let all = views(of: w.contentView?.superview)
            let popups = all.enumerated().filter { $0.element is NSPopUpButton }
            guard popups.count >= 2,
                  let b = all[popups[1].offset...].first(where: {
                      guard let b = $0 as? NSButton, !(b is NSPopUpButton) else { return false }
                      return b.title.isEmpty && b.frame.width > 40
                  }) as? NSButton else { return log("languages button not found") }
            b.performClick(nil)
            await pause(1)
        }

        func closeSheet() async {
            if let w = window, let sheet = w.attachedSheet { w.endSheet(sheet) }
            await pause(0.8)
        }

        func open(_ path: String) async {
            model.load(url: URL(fileURLWithPath: path))
            for _ in 0..<100 where model.pages.isEmpty { await pause(0.2) }
            _ = await settle(timeout: 900)
        }

        func go() async {
            await pause(1.5)
            prepareWindow()
            await pause(0.5)
            try? FileManager.default.createDirectory(atPath: plan.outDir, withIntermediateDirectories: true)
            model.refreshPacks()

            await shoot("welcome")

            await open(plan.smith)
            let i = min(plan.spreadIndex, model.pages.count - 1)
            let spread = model.pages[i...].first { $0.classification == .spread } ?? model.pages[i]
            log("spread page: source \(spread.sourceIndex + 1) of \(model.pages.count)")
            model.viewMode = .page
            model.showsExport = false
            model.selectedPageID = spread.id
            await chooseSide(0)
            await shoot("page-spread")

            await chooseSide(1)
            await shoot("page-allpages")
            await chooseSide(0)

            model.beginTrim()
            await shoot("page-trim", also: { self.model.trimmingPage != nil })
            model.cancelTrim()

            model.showsStack = true
            await shoot("stack", also: { self.model.stackImageReady })
            // The same stack with its first three pages unticked (for the "left out" line).
            if let stack = model.stacks.first(where: { $0.id == model.stackKind }) {
                for member in stack.allMembers.prefix(3) {
                    model.setStackPage(member.id, included: false, in: stack.id)
                }
            }
            await shoot("stack-leftout", also: { self.model.stackImageReady })
            model.setAllStackPages(included: true, in: model.stacks.first(where: { $0.id == model.stackKind })!)
            model.showsStack = false

            model.viewMode = .grid
            let ids = model.pages.map(\.id)
            let k = min(spread.sourceIndex, ids.count - 3)
            model.chooseInGrid(ids[k], .plain, order: ids)
            model.chooseInGrid(ids[k + 2], .range, order: ids)
            await shoot("grid")
            model.viewMode = .page

            model.showsExport = true
            await shoot("export")

            await pressLanguages()
            await shoot("languages", also: { self.window?.attachedSheet != nil })
            await closeSheet()
            model.showsExport = false

            await open(plan.riezler)
            // Riezler scans as spreads throughout. Page 5 is its first page of running
            // text, so it is made a single, as the Type switch would, and re-detected.
            let target = model.pages[min(4, model.pages.count - 1)]
            if target.classification != .single {
                model.setClassification(.single, for: target.id)
                _ = await settle()
                // The app leaves the old page count in the title bar until something else
                // rewrites it, and when that happens varies from run to run. Write it now,
                // so every run shows the same line.
                model.statusText = "Ready — \(model.pages.count) source pages → \(model.outputPageCount) output pages."
            }
            let single = model.pages.first { $0.id == target.id } ?? target
            log("single page: source \(single.sourceIndex + 1) of \(model.pages.count)")
            model.viewMode = .page
            model.selectedPageID = single.id
            await chooseSide(0)
            await shoot("page-single")
        }
    }
}
#endif
