import AppKit
import SwiftUI
import XCTest
@testable import OpenAPIViewer

@MainActor
final class ViewerIntegrationTests: XCTestCase {
    func testBundledViewerCompletesBridgeHandshakeAndRendersOpenAPIDocument() async {
        let viewerReady = expectation(description: "Bundled viewer sent ready message")
        let documentRendered = expectation(description: "Bundled viewer rendered the OpenAPI document")
        let source = """
            {"openapi":"3.1.0","info":{"title":"Bridge Fixture","version":"1.0.0"},"paths":{"/pets":{"get":{"summary":"List pets","responses":{"200":{"description":"Success"}}}}}}
            """
        let view = ViewerWebView(
            text: source,
            format: "json",
            loadID: UUID().uuidString,
            filter: "",
            appearance: "light",
            onOpenFile: { _ in },
            onReady: { viewerReady.fulfill() },
            onRendered: { operationCount in
                XCTAssertEqual(operationCount, 1)
                documentRendered.fulfill()
            },
            onError: { message in XCTFail(message) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await fulfillment(of: [viewerReady, documentRendered], timeout: 30)
    }
}
