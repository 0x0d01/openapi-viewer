import SwiftUI
import UniformTypeIdentifiers

struct SpecDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.yaml, .json] }

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
        throw SpecDocumentError.readOnly
    }
}

private enum SpecDocumentError: LocalizedError {
    case readOnly

    var errorDescription: String? {
        "OpenAPI documents are read-only in OpenAPI Viewer."
    }
}
