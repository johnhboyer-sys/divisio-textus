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
                .onAppear { appDelegate.onOpenPDF { model.load(url: $0) } }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF…") { model.exportPanel() }
                    .keyboardShortcut("e")
                    .disabled(model.document == nil || model.isBusy)
                Button("Cancel Export") { model.cancelExport() }
                    .keyboardShortcut(".")
                    .disabled(!model.isExporting)
            }
            CommandGroup(after: .undoRedo) {
                Button("Re-detect All Pages") { model.redetectAllPages() }
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
            }
            CommandMenu("Go") {
                Button("Previous Page") { model.selectAdjacentPage(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(model.pages.isEmpty)
                Button("Next Page") { model.selectAdjacentPage(1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(model.pages.isEmpty)
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
