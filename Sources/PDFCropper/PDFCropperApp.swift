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
                    .disabled(model.document == nil)
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
}
