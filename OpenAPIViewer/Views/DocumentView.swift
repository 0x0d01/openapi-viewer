import SwiftUI
import UniformTypeIdentifiers

struct DocumentView: View {
    @State private var sourceText: String?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var isReadingFromDisk = false
    @State private var isViewerReady = false
    @State private var filter = ""
    @StateObject private var appearanceState: DocumentAppearanceState
    @State private var loadID = UUID().uuidString
    @State private var reloadID = 0

    let document: SpecDocument
    let fileURL: URL?

    init(
        document: SpecDocument,
        fileURL: URL?,
        appearanceState: DocumentAppearanceState = DocumentAppearanceState()
    ) {
        self.document = document
        self.fileURL = fileURL
        _appearanceState = StateObject(wrappedValue: appearanceState)
        _sourceText = State(initialValue: document.text)
        _loadError = State(initialValue: document.readError)
        _isLoading = State(initialValue: document.text != nil)
    }

    var body: some View {
        Group {
            if let sourceText {
                let representedLoadID = loadID
                ViewerWebView(
                    text: sourceText,
                    format: documentFormat,
                    loadID: loadID,
                    filter: filter,
                    appearance: effectiveAppearance,
                    onOpenFile: openLocalFile,
                    onReady: { isViewerReady = true },
                    onRendered: { _ in
                        guard representedLoadID == loadID else { return }
                        guard !isReadingFromDisk else { return }
                        isLoading = false
                    },
                    onError: { message in
                        guard representedLoadID == loadID, !isReadingFromDisk else { return }
                        isLoading = false; loadError = message
                    }
                )
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if isLoading {
                            ProgressView(isViewerReady ? "Rendering specification…" : "Starting viewer…")
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .padding(12)
                                .frame(maxWidth: 680, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.top, 12)
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Unable to Open Document", systemImage: "doc.text.magnifyingglass",
                    description: Text(loadError))
            } else {
                ContentUnavailableView(
                    "Open an OpenAPI File", systemImage: "doc.text",
                    description: Text("Choose a YAML or JSON specification, or drop one into this window."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Filter operations", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .accessibilityLabel("Filter operations by path, method, tag, or summary")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: reload) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(fileURL == nil || isLoading)
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        appearanceState.choice = .system
                    } label: {
                        appearanceChoiceLabel(.system)
                    }
                    Button {
                        appearanceState.choice = .light
                    } label: {
                        appearanceChoiceLabel(.light)
                    }
                    Button {
                        appearanceState.choice = .dark
                    } label: {
                        appearanceChoiceLabel(.dark)
                    }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .accessibilityLabel("Appearance")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(appearanceState.choice.colorScheme)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: openDroppedFile)
        .onChange(of: document.text) { _, newValue in
            sourceText = newValue
            loadError = newValue == nil ? document.readError : nil
            loadID = UUID().uuidString
            isLoading = newValue != nil
        }
        .onChange(of: document.readError) { _, newValue in
            guard document.text == nil else { return }
            sourceText = nil
            loadError = newValue
            isLoading = false
        }
    }

    @ViewBuilder
    private func appearanceChoiceLabel(_ choice: AppearanceChoice) -> some View {
        if appearanceState.choice == choice {
            Label(choice.label, systemImage: "checkmark")
        } else {
            Text(choice.label)
        }
    }

    private var documentFormat: String {
        fileURL?.pathExtension.lowercased() == "json" ? "json" : "yaml"
    }

    private var effectiveAppearance: String {
        switch appearanceState.choice {
        case .system: appearanceState.systemAppearance
        case .light: "light"
        case .dark: "dark"
        }
    }

    private func reload() {
        guard let fileURL else { return }
        reloadID += 1
        let currentReloadID = reloadID
        isReadingFromDisk = true
        isLoading = true
        loadError = nil

        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try DocumentReader.readUTF8(from: fileURL)
                }.value
                guard currentReloadID == reloadID else { return }
                isReadingFromDisk = false
                sourceText = text
                loadID = UUID().uuidString
                isLoading = true
            } catch {
                guard currentReloadID == reloadID else { return }
                isReadingFromDisk = false
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    private func openDroppedFile(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                DispatchQueue.main.async {
                    loadError = "Could not open the dropped file: \(error.localizedDescription)"
                }
                return
            }
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else if let itemURL = item as? NSURL {
                url = itemURL as URL
            } else {
                url = nil
            }

            guard let url else {
                DispatchQueue.main.async {
                    loadError = "The dropped item did not provide a readable file URL."
                }
                return
            }
            DispatchQueue.main.async {
                openLocalFile(url)
            }
        }
        return true
    }

    private func openLocalFile(_ url: URL) {
        guard url.isFileURL else {
            loadError = "Only local files can be opened from a drop."
            return
        }

        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                loadError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
            NSApp.activate()
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

final class DocumentAppearanceState: ObservableObject {
    @Published var choice: AppearanceChoice = .system
    @Published private(set) var systemAppearance: String

    private var appearanceObservation: NSKeyValueObservation?

    init() {
        systemAppearance = Self.resolve(NSApp.effectiveAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            let nextAppearance = Self.resolve(app.effectiveAppearance)
            DispatchQueue.main.async {
                self?.systemAppearance = nextAppearance
            }
        }
    }

    private static func resolve(_ appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }
}
