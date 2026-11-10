import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let openAPIYAML = UTType(exportedAs: "com.openai.openapi-viewer.yaml", conformingTo: .text)
}

struct SpecDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.openAPIYAML, .json] }

    let text: String?
    let readError: String?

    init(text: String) {
        self.text = text
        readError = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            text = nil
            readError = "The selected file does not contain readable text."
            return
        }

        guard let decoded = String(data: data, encoding: .utf8) else {
            text = nil
            readError = "This file is not valid UTF-8 text. Save it as UTF-8 and open it again."
            return
        }

        text = decoded
        readError = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data((text ?? "").utf8))
    }
}
