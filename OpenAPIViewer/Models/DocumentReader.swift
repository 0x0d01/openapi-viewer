import Foundation

enum DocumentReader {
    static func readUTF8(from url: URL) throws -> String {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }

        if let coordinationError {
            throw DocumentReadError.access(coordinationError.localizedDescription)
        }

        guard let dataResult = result else {
            throw DocumentReadError.access("The file could not be read.")
        }

        let data = try dataResult.get()
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentReadError.encoding
        }
        return text
    }
}

enum DocumentReadError: LocalizedError {
    case access(String)
    case encoding

    var errorDescription: String? {
        switch self {
        case let .access(message): "Could not reload the document: \(message)"
        case .encoding: "The file is not valid UTF-8 text. Save it as UTF-8 and reload."
        }
    }
}
