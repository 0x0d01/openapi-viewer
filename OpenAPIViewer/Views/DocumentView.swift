import SwiftUI
import UniformTypeIdentifiers

struct DocumentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var sourceText: String?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var isReadingFromDisk = false
    @State private var isViewerReady = false
    @State private var filter = ""
    @State private var appearance: AppearanceChoice = .system
    @State private var loadID = UUID().uuidString
    @State private var reloadID = 0

    let document: SpecDocument
    let fileURL: URL?

    init(document: SpecDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
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
                Text(fileURL?.lastPathComponent ?? "OpenAPI Viewer")
                    .lineLimit(1)
                    .help(fileURL?.path ?? "OpenAPI Viewer")
            }
            ToolbarItem(placement: .automatic) {
                TextField("Filter operations", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 190, idealWidth: 250)
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
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .accessibilityLabel("Appearance")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(appearance.colorScheme)
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

    private var documentFormat: String {
        fileURL?.pathExtension.lowercased() == "json" ? "json" : "yaml"
    }

    private var effectiveAppearance: String {
        switch appearance {
        case .system: systemColorScheme == .dark ? "dark" : "light"
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
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    guard let error else { return }
                    loadError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        return true
    }
}

private enum AppearanceChoice: String, CaseIterable, Identifiable {
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
