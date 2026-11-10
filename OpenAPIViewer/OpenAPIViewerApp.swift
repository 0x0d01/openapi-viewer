import SwiftUI

@main
struct OpenAPIViewerApp: App {
    var body: some Scene {
        DocumentGroup(viewing: SpecDocument.self) { configuration in
            DocumentView(document: configuration.document, fileURL: configuration.fileURL)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
