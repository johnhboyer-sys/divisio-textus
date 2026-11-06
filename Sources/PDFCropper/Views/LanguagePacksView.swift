import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The sheet behind Choose…: tick the packs to read with. Ticking one that
/// is not on this Mac downloads it. Add from File… brings in a pack of your own.
struct LanguagePacksView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    // State(initialValue:) rather than @State, for Command Line Tools (see PageSizeRow).
    private let queryState = State(initialValue: "")

    /// What the list offers: under Apple only the packs that fill in a script it
    /// can't read; under Tesseract all, plus any extra pack in the folder, named by its
    /// code. In name order.
    static func choices(reader: OCRReader, installed: Set<String>) -> [(code: String, name: String)] {
        let known = TesseractLanguage.all.filter { reader == .tesseract || $0.fillsIn }
        let table = Set(TesseractLanguage.all.map(\.code))
        let extra = reader == .tesseract ? installed.subtracting(table) : []
        return (known.map { ($0.code, $0.name) } + extra.map { ($0, $0) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var rows: [(code: String, name: String)] {
        let query = queryState.wrappedValue.trimmingCharacters(in: .whitespaces)
        let all = Self.choices(reader: model.ocrReader, installed: model.installedPacks)
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query) }
        let ticked = all.filter { isTicked($0.code) }
        return ticked + all.filter { !isTicked($0.code) }
    }

    /// The Tesseract reader always reads English, so its row stays ticked.
    private func englishLocked(_ code: String) -> Bool { model.ocrReader == .tesseract && code == "eng" }

    private func isTicked(_ code: String) -> Bool {
        englishLocked(code) || model.ocrPacks.contains(code)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Languages")
                .font(.headline).padding(.top, 12)
            TextField("Search", text: queryState.projectedValue)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(rows, id: \.code) { row in
                HStack {
                    Toggle(row.name, isOn: binding(row.code))
                        .toggleStyle(.checkbox)
                        .disabled(englishLocked(row.code))
                    Spacer()
                    status(row.code)
                }
            }
            Divider()
            HStack {
                Button("Add from File…") { addFromFile() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
        .onAppear { model.refreshPacks() }
    }

    @ViewBuilder private func status(_ code: String) -> some View {
        if model.packDownloads[code] == .downloading {
            ProgressView().controlSize(.small)
        } else if model.packDownloads[code] == .failed {
            Text("Download failed").font(.caption).foregroundStyle(.red)
        }
    }

    private func binding(_ code: String) -> Binding<Bool> {
        Binding(get: { isTicked(code) },
                set: { on in
                    if on {
                        if !model.ocrPacks.contains(code) { model.ocrPacks.append(code) }
                        if !model.installedPacks.contains(code) { model.downloadPack(code) }
                    } else {
                        model.ocrPacks.removeAll { $0 == code }
                    }
                })
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "traineddata") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.addPacks(from: panel.urls) }
    }
}
