import SwiftUI
import AppKit

@main
struct PDFCropperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Divisio Textus") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.watch(model)
                    appDelegate.onOpenPDF { model.load(url: $0) }
                }
        }
        .windowStyle(.titleBar)
        // A PDF opened from Finder goes to AppDelegate and loads into the existing
        // window; without this SwiftUI also opens a second window for it.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF…") { model.showsExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.document == nil)
                Button("Cancel Export") { model.cancelExport() }
                    .keyboardShortcut(".")
                    .disabled(!model.isExporting)
            }
            CommandGroup(after: .undoRedo) {
                Button("Auto-detect All Pages") { model.autoDetectAllPages() }
                    .disabled(model.document == nil || model.isBusy)
                Button("Auto-straighten All Pages") { Task { await model.autoStraightenAllPages() } }
                    .disabled(model.document == nil || model.isBusy)
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("=")
                    .disabled(model.document == nil)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(model.document == nil)
                Button("Zoom to Fit") { model.zoomToFit() }
                    .keyboardShortcut("0")
                    .disabled(model.document == nil)
                Divider()
                RulerMenuButton()
                Divider()
            }
            CommandMenu("Go") {
                Button("Page View") { model.showsStack = false; model.showsExport = false }
                    .keyboardShortcut("1")
                Button("Stack View") { model.showsStack = true; model.showsExport = false }
                    .keyboardShortcut("2")
                Button("Grid View") { model.viewMode = .grid; model.showsExport = false }
                    .keyboardShortcut("3")
                Divider()
                Button("Previous Page") { model.selectAdjacentPage(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(model.pages.isEmpty)
                Button("Next Page") { model.selectAdjacentPage(1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(model.pages.isEmpty)
                Button("Next Page Needing a Look") { model.selectNextFlaggedPage() }
                    .keyboardShortcut("'")
                    .disabled(model.flaggedSides.isEmpty)
            }
        }
    }
}

/// Running as a SwiftUI SPM executable, we must promote the process to a
/// regular foreground app so the window and menu bar appear and focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Promote to a regular app BEFORE SwiftUI builds the window. Done later (in
        // didFinishLaunching) the window is already on screen and ends up missing its
        // standard title-bar controls (the red/yellow/green traffic-light buttons).
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The open document, so quitting can save and ask if that failed.
    private var model: AppModel?

    func watch(_ model: AppModel) { self.model = model }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return MainActor.assumeIsolated { model.terminateReply() }
    }

    // Finder "Open With" / dropping a PDF on the Dock icon. At launch this can
    // arrive before the window exists, so hold the URL until a handler is set.
    private var openPDF: ((URL) -> Void)?
    private var pendingURL: URL?

    func onOpenPDF(_ handler: @escaping (URL) -> Void) {
        openPDF = handler
        if let url = pendingURL {
            pendingURL = nil
            handler(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        if let openPDF { openPDF(url) } else { pendingURL = url }
    }
}
