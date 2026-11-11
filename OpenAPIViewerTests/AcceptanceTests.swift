import AppKit
import Foundation
import Network
import SwiftUI
import WebKit
import XCTest
@testable import OpenAPIViewer

@MainActor
final class AcceptanceTests: XCTestCase {
    private var state: AcceptanceViewerState!
    private var window: NSWindow!
    private var hostingView: NSHostingView<AcceptanceViewerRoot>!

    override func setUp() async throws {
        try await super.setUp()
        let ready = expectation(description: "Bundled viewer bridge is ready")
        state = AcceptanceViewerState(
            text: "openapi: 3.1.0\ninfo: { title: Initial, version: 1 }\npaths: {}\n",
            onReady: { ready.fulfill() },
        )
        hostingView = NSHostingView(rootView: AcceptanceViewerRoot(state: state))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertNotNil(findWebView(in: hostingView))
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        hostingView = nil
        window = nil
        state = nil
        try await super.tearDown()
    }

    func testBundledWebViewResolvesSchemasFiltersOperationsAndKeepsExampleDataLiteral() async throws {
        let probe = try LoopbackProbe()
        let control = try XCTUnwrap(URL(string: "\(probe.baseURL)/positive-control"))
        let (_, controlResponse) = try await URLSession.shared.data(from: control)
        XCTAssertEqual((controlResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(probe.requests, ["GET /positive-control HTTP/1.1"])
        probe.reset()

        let literalReference = "\(probe.baseURL)/literal.json"
        let source = acceptanceSpec(
            imageURL: "\(probe.baseURL)/image.png",
            literalReference: literalReference,
        )
        let loadID = "acceptance-\(UUID().uuidString)"
        let render = state.expectRender(loadID: loadID)
        state.load(text: source, loadID: loadID)
        await fulfillment(of: [render], timeout: 30)

        let webView = try XCTUnwrap(findWebView(in: hostingView))
        let initialDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(initialDOM.contains("/pets/{petId}"))
        XCTAssertTrue(initialDOM.contains("/registrations"))
        XCTAssertFalse(
            initialDOM.contains("openapi-viewer.invalid"),
            "Synthetic resolver URL leaked into visible content: \(initialDOM)")
        let externalDocumentationIsVisible =
            try await evaluateJavaScript(
                """
                (() => {
                  const link = Array.from(document.querySelectorAll('#swagger-ui a')).find(node => node.href === 'https://docs.example.invalid/api');
                  return Boolean(link && getComputedStyle(link).display !== 'none' && getComputedStyle(link).visibility !== 'hidden');
                })()
                """,
                in: webView,
            ) as? Bool
        XCTAssertEqual(externalDocumentationIsVisible, true)
        let apiServerIsVisible =
            try await evaluateJavaScript(
                "Array.from(document.querySelectorAll('#swagger-ui option')).some(option => option.value === 'https://api.example.invalid/v1')",
                in: webView,
            ) as? Bool
        XCTAssertEqual(apiServerIsVisible, true)

        try await expandFirstOperation(in: webView)
        let literalWasRendered = try await waitForJavaScript(
            "document.querySelector('#swagger-ui')?.innerText.includes('\(literalReference)') === true",
            in: webView,
        )
        XCTAssertTrue(literalWasRendered, "Example value not shown after operation expansion.")
        try await selectAndExpandResponseSchema(in: webView)
        let afterOperationExpansion = try await evaluateString(
            "JSON.stringify({ text: document.querySelector('#swagger-ui')?.innerText ?? '', response: document.querySelector('#swagger-ui .responses-wrapper')?.outerHTML ?? '', tabs: Array.from(document.querySelectorAll('#swagger-ui .responses-wrapper .tab-item')).map(node => ({ text: node.innerText, className: node.className })), toggles: Array.from(document.querySelectorAll('#swagger-ui .responses-wrapper .model-toggle')).map(node => node.outerHTML) })",
            in: webView,
        )

        let referencedFieldWasRendered = try await waitForJavaScript(
            "document.querySelector('#swagger-ui .responses-wrapper [data-name=\"modelPanel\"]')?.innerText.includes('deeplyReferencedIdentifier') === true",
            in: webView,
        )
        XCTAssertTrue(referencedFieldWasRendered, "DOM after operation expansion: \(afterOperationExpansion)")
        let sourceRemainsText =
            try await evaluateJavaScript(
                "globalThis.acceptanceInjected === undefined && document.querySelector('#swagger-ui script') === null",
                in: webView,
            ) as? Bool
        XCTAssertEqual(sourceRemainsText, true)

        state.filter = "accounts"
        let ownerFilterApplied = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.includes('/registrations') && !paths.some(path => path.includes('/pets')); })()",
            in: webView,
        )
        let visiblePaths = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        XCTAssertTrue(
            ownerFilterApplied,
            "Owner filter was not reflected in the DOM. Events: \(state.eventLog). Paths: \(visiblePaths)")
        XCTAssertTrue(visiblePaths.contains("/registrations"))
        XCTAssertFalse(visiblePaths.contains("/pets"))

        _ = try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(probe.requests, [])

        let externalReference = "\(probe.baseURL)/external-schema.json"
        let error = state.expectError(containing: "External reference")
        state.load(
            text: """
                openapi: 3.1.0
                info: { title: External Reference, version: '1' }
                paths: {}
                components:
                  schemas:
                    Remote:
                      $ref: '\(externalReference)'
                """,
            loadID: "external-\(UUID().uuidString)",
        )
        await fulfillment(of: [error], timeout: 15)
        let clearedDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(clearedDOM.isEmpty)
        _ = try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(probe.requests, [])
    }

    func testFilteringAppliesAfterInitialRenderAndSurvivesCollapsedTagUpdates() async throws {
        let loadID = "pre-filtered-\(UUID().uuidString)"
        state.filter = "accounts"
        let initialRender = state.expectRender(loadID: loadID)
        state.load(
            text: acceptanceSpec(
                imageURL: "data:image/png;base64,iVBORw0KGgo=",
                literalReference: "#/components/schemas/ReferencedPet",
            ),
            loadID: loadID,
        )
        await fulfillment(of: [initialRender], timeout: 30)

        let webView = try XCTUnwrap(findWebView(in: hostingView))
        let ownerFilterApplied = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.includes('/registrations') && !paths.some(path => path.includes('/pets')); })()",
            in: webView,
        )
        let ownerOnly = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        XCTAssertTrue(
            ownerFilterApplied,
            "Owner filter was not reflected in the DOM. Events: \(state.eventLog). Paths: \(ownerOnly)")
        XCTAssertTrue(ownerOnly.contains("/registrations"))
        XCTAssertFalse(ownerOnly.contains("/pets"))

        state.filter = ""
        let clearFilterApplied = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.some(path => path.includes('/registrations')) && paths.some(path => path.includes('/pets')); })()",
            in: webView,
        )
        XCTAssertTrue(
            clearFilterApplied,
            "Clearing the initial filter did not restore both operations. Events: \(state.eventLog)")

        _ = try await evaluateJavaScript(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock-tag')).find(node => node.textContent.toLowerCase().includes('pets'))?.click(); true",
            in: webView,
        )
        state.filter = "pets"
        let petFilterReady = try await waitForJavaScript(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock-tag')).some(node => node.textContent.toLowerCase().includes('pets'))",
            in: webView,
        )
        XCTAssertTrue(petFilterReady)

        _ = try await evaluateJavaScript(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock-tag')).find(node => node.textContent.toLowerCase().includes('pets'))?.click(); true",
            in: webView,
        )
        let petVisibleWhileFiltered = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.some(path => path.includes('/pets')) && !paths.some(path => path.includes('/registrations')); })()",
            in: webView,
        )
        let filteredPaths = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        XCTAssertTrue(
            petVisibleWhileFiltered,
            "Pets filter should persist when its collapsed tag is expanded. Events: \(state.eventLog). Paths: \(filteredPaths)",
        )

        state.filter = ""
        let clearSucceeded = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.some(path => path.includes('/pets')) && paths.includes('/registrations'); })()",
            in: webView,
        )
        let restoredDOM = try await evaluateString(
            "JSON.stringify({ paths: Array.from(document.querySelectorAll('#swagger-ui .opblock-summary-path')).map(node => node.textContent.trim()), visible: Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()), sections: Array.from(document.querySelectorAll('#swagger-ui .opblock-tag-section')).map(node => ({ hidden: node.hidden, text: node.innerText })) })",
            in: webView,
        )
        let expandedPaths = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        XCTAssertTrue(
            clearSucceeded,
            "Expected a filter-clear response. Events: \(state.eventLog). DOM: \(restoredDOM)",
        )
        XCTAssertTrue(
            expandedPaths.contains("/pets/{petId}"),
            "Expected Pets after clearing filter. Events: \(state.eventLog). DOM: \(restoredDOM)",
        )
        XCTAssertTrue(
            expandedPaths.contains("/registrations"),
            "Expected Owners after clearing filter. Events: \(state.eventLog). DOM: \(restoredDOM)",
        )

        for (query, expectedPath) in [
            ("/registrations", "/registrations"),
            ("POST", "/registrations"),
            ("Save record", "/registrations"),
            ("accounts", "/registrations"),
        ] {
            state.filter = query
            let expectedOnlyPath = try await waitForJavaScript(
                "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.length === 1 && paths[0] === '\(expectedPath)'; })()",
                in: webView,
            )
            XCTAssertTrue(
                expectedOnlyPath,
                "Query '\(query)' should match only \(expectedPath). Events: \(state.eventLog)",
            )
        }
        state.filter = ""
    }

    func testCrossPathInternalReferenceRemainsFilterableAfterSwaggerResolution() async throws {
        let loadID = "path-reference-\(UUID().uuidString)"
        let source = """
            openapi: 3.1.0
            info: { title: Path Reference API, version: '1' }
            paths:
              /source:
                get:
                  tags: [inventory]
                  summary: List source records
                  responses: { '200': { description: Records } }
              /alias:
                $ref: '#/paths/~1source'
            """
        state.load(text: source, loadID: loadID)
        let webView = try XCTUnwrap(findWebView(in: hostingView))
        let aliasRendered = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock-summary-path')).map(node => node.textContent.trim()); return paths.includes('/source') && paths.includes('/alias'); })()",
            in: webView,
        )
        let paths = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        let aliasDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(
            aliasRendered,
            "Expected resolved alias rows. Events: \(state.eventLog). DOM: \(aliasDOM)",
        )
        XCTAssertTrue(
            paths.contains("/source"),
            "Expected resolved source operation. Events: \(state.eventLog). DOM: \(aliasDOM)",
        )
        XCTAssertTrue(
            paths.contains("/alias"),
            "Expected resolved alias operation. Events: \(state.eventLog). DOM: \(aliasDOM)",
        )

        let filterEventStart = state.eventLog.count
        state.filter = "/alias"
        let filterNotified = await waitForRenderEvent(
            loadID: loadID,
            timeout: 5,
            startingAt: filterEventStart,
        )
        let aliasOnly = try await waitForJavaScript(
            "(() => { const paths = Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()); return paths.includes('/alias') && !paths.includes('/source'); })()",
            in: webView,
        )
        let filteredPaths = try await evaluateString(
            "Array.from(document.querySelectorAll('#swagger-ui .opblock:not([hidden]) .opblock-summary-path')).map(node => node.textContent.trim()).join(',')",
            in: webView,
        )
        XCTAssertTrue(filteredPaths.contains("/alias"))
        XCTAssertFalse(filteredPaths.contains("/source"))
        XCTAssertTrue(filterNotified, "Alias filter returned no bridge message. Events: \(state.eventLog)")
        XCTAssertTrue(aliasOnly, "Alias filter did not update the resolved DOM rows. Paths: \(filteredPaths)")
    }

    func testDeepSchemaReferencesResolveForOpenAPI30And31() async throws {
        let webView = try XCTUnwrap(findWebView(in: hostingView))
        for version in ["3.0.3", "3.1.0"] {
            let loadID = "deep-schema-\(version)-\(UUID().uuidString)"
            let render = state.expectRender(loadID: loadID)
            state.load(
                text: acceptanceSpec(
                    imageURL: "data:image/png;base64,iVBORw0KGgo=",
                    literalReference: "#/components/schemas/ReferencedPet",
                    openAPIVersion: version,
                ),
                loadID: loadID,
            )
            await fulfillment(of: [render], timeout: 30)
            try await expandFirstResponseSchema(in: webView)

            let deeplyNestedField = try await waitForJavaScript(
                "document.querySelector('#swagger-ui .responses-wrapper [data-name=\"modelPanel\"]')?.innerText.includes('deeplyReferencedIdentifier') === true",
                in: webView,
            )
            let renderedText = try await evaluateString(
                "document.querySelector('#swagger-ui')?.innerText ?? ''",
                in: webView,
            )
            XCTAssertTrue(
                deeplyNestedField,
                "OpenAPI \(version) did not expand its nested response schema. DOM: \(renderedText)",
            )
            XCTAssertFalse(
                renderedText.contains("Resolver error"),
                "OpenAPI \(version) reported a resolver error. DOM: \(renderedText)",
            )
        }
    }

    func testOverlappingBridgeLoadsLeaveOnlyNewestDocumentVisible() async throws {
        let webView = try XCTUnwrap(findWebView(in: hostingView))
        let firstID = "overlap-first-\(UUID().uuidString)"
        let latestID = "overlap-latest-\(UUID().uuidString)"
        let firstPayload: [String: Any] = [
            "loadID": firstID,
            "format": "yaml",
            "text": slowReferenceSpec(),
        ]
        let latestPayload: [String: Any] = [
            "loadID": latestID,
            "format": "yaml",
            "text": simpleSpec(path: "/newest-render"),
        ]
        _ = try await callAsyncJavaScript(
            """
            const first = window.viewerBridge.loadDocument(payload.first);
            Promise.resolve().then(() => {
              const latest = window.viewerBridge.loadDocument(payload.latest);
              Promise.all([first, latest]).then(() => {
                window.__acceptanceOverlappingLoadsFinished = true;
              });
            });
            true
            """,
            arguments: ["payload": ["first": firstPayload, "latest": latestPayload]],
            in: webView,
        )
        let finished = try await waitForJavaScript(
            "window.__acceptanceOverlappingLoadsFinished === true",
            in: webView,
        )
        XCTAssertTrue(finished)
        let latestDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(latestDOM.contains("/newest-render"))
        XCTAssertFalse(latestDOM.contains("/late-render"))

        _ = try await callAsyncJavaScript(
            "await window.viewerBridge.setFilter({ query: 'no-matching-operation' }); true",
            arguments: [:],
            in: webView,
        )
        let unmatchedFilterApplied = try await waitForJavaScript(
            """
            document.querySelector("#swagger-ui .opblock-summary-path[data-path='/newest-render']")?.closest(".opblock")?.hidden === true
            """,
            in: webView,
        )
        XCTAssertTrue(
            unmatchedFilterApplied,
            "A late stale mount left the newest operation filter inactive. DOM: \(latestDOM)",
        )

        _ = try await callAsyncJavaScript(
            "await window.viewerBridge.setFilter({ query: 'newest-render' }); true",
            arguments: [:],
            in: webView,
        )
        let matchingFilterRestored = try await waitForJavaScript(
            """
            document.querySelector("#swagger-ui .opblock-summary-path[data-path='/newest-render']")?.closest(".opblock")?.hidden === false
            """,
            in: webView,
        )
        XCTAssertTrue(matchingFilterRestored)
    }

    func testNewLoadReplacesPreviousAndMalformedLoadClearsIt() async throws {
        let webView = try XCTUnwrap(findWebView(in: hostingView))
        let firstID = "first-\(UUID().uuidString)"
        let firstRender = state.expectRender(loadID: firstID)
        state.load(text: simpleSpec(path: "/first-document"), loadID: firstID)
        await fulfillment(of: [firstRender], timeout: 20)

        let secondID = "second-\(UUID().uuidString)"
        let secondRender = state.expectRender(loadID: secondID)
        state.load(text: simpleSpec(path: "/latest-document"), loadID: secondID)
        await fulfillment(of: [secondRender], timeout: 20)
        let latestDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(latestDOM.contains("/latest-document"))
        XCTAssertFalse(latestDOM.contains("/first-document"))

        let error = state.expectError(containing: "Invalid JSON")
        state.load(text: "{ \"openapi\": }", format: "json", loadID: "invalid-\(UUID().uuidString)")
        await fulfillment(of: [error], timeout: 15)
        let clearedDOM = try await evaluateString(
            "document.querySelector('#swagger-ui')?.innerText ?? ''",
            in: webView,
        )
        XCTAssertTrue(clearedDOM.isEmpty)
    }

    func testWebViewTracksLightAndDarkAppearance() async throws {
        let loadID = "appearance-\(UUID().uuidString)"
        let render = state.expectRender(loadID: loadID)
        state.load(text: simpleSpec(path: "/appearance"), loadID: loadID)
        await fulfillment(of: [render], timeout: 20)
        let webView = try XCTUnwrap(findWebView(in: hostingView))

        state.appearance = "dark"
        let darkAppearance = try await waitForJavaScript(
            "document.documentElement.dataset.appearance === 'dark' && getComputedStyle(document.body).backgroundColor === 'rgb(28, 28, 30)'",
            in: webView,
        )
        XCTAssertTrue(darkAppearance)

        state.appearance = "light"
        let lightAppearance = try await waitForJavaScript(
            "document.documentElement.dataset.appearance === 'light' && getComputedStyle(document.body).backgroundColor === 'rgb(255, 255, 255)'",
            in: webView,
        )
        XCTAssertTrue(lightAppearance)
    }

    func testBridgeMessagesRemainAcceptedAfterDeepLinkFragmentChanges() async throws {
        let loadID = "fragment-\(UUID().uuidString)"
        let render = state.expectRender(loadID: loadID)
        state.load(text: simpleSpec(path: "/fragment-probe"), loadID: loadID)
        await fulfillment(of: [render], timeout: 20)
        let webView = try XCTUnwrap(findWebView(in: hostingView))

        let eventCount = state.eventLog.count
        _ = try await callAsyncJavaScript(
            """
            window.location.hash = '#/acceptance-fragment-probe';
            window.webkit.messageHandlers.viewer.postMessage({
              type: 'rendered',
              loadID: payload.loadID,
              operationCount: 777
            });
            document.location.href
            """,
            arguments: ["payload": ["loadID": loadID]],
            in: webView,
        )
        let messageDelivered = await waitForRenderEvent(
            loadID: loadID,
            timeout: 3,
            startingAt: eventCount,
        )
        let currentURL = try await evaluateString("document.location.href", in: webView)
        XCTAssertTrue(
            messageDelivered,
            "Fragment navigation suppressed the bridge message. URL: \(currentURL). Events: \(state.eventLog)",
        )
        XCTAssertTrue(currentURL.contains("acceptance-fragment-probe"))
    }

    private func acceptanceSpec(
        imageURL: String,
        literalReference: String,
        openAPIVersion: String = "3.1.0",
    ) -> String {
        """
        openapi: \(openAPIVersion)
        info:
          title: Acceptance API
          version: '1'
          description: |
            A remote image: ![probe](\(imageURL))
            <script>globalThis.acceptanceInjected = true</script>
        externalDocs:
          description: Reference documentation
          url: https://docs.example.invalid/api
        servers:
          - url: https://api.example.invalid/v1
        paths:
          /pets/{petId}:
            get:
              tags: [pets]
              summary: Get pet
              parameters:
                - name: petId
                  in: path
                  required: true
                  schema: { type: string }
              responses:
                '200':
                  description: Pet response
                  content:
                    application/json:
                      schema:
                        $ref: '#/components/schemas/Envelope'
                      examples:
                        literal-reference:
                          value:
                            $ref: '\(literalReference)'
          /registrations:
            post:
              tags: [accounts]
              summary: Save record
              responses:
                '201': { description: Created }
        components:
          schemas:
            Envelope:
              type: object
              properties:
                result:
                  $ref: '#/components/schemas/ReferencedPet'
            ReferencedPet:
              type: object
              properties:
                profile:
                  $ref: '#/components/schemas/PetProfile'
            PetProfile:
              type: object
              properties:
                details:
                  $ref: '#/components/schemas/PetDetails'
            PetDetails:
              type: object
              required: [deeplyReferencedIdentifier]
              properties:
                deeplyReferencedIdentifier: { type: string }
        """
    }

    private func expandFirstResponseSchema(in webView: WKWebView) async throws {
        try await expandFirstOperation(in: webView)
        try await selectAndExpandResponseSchema(in: webView)
    }

    private func expandFirstOperation(in webView: WKWebView) async throws {
        _ = try await evaluateJavaScript(
            """
            (() => {
              const operation = document.querySelector('#swagger-ui .opblock');
              if (operation && !operation.classList.contains('is-open')) operation.querySelector('.opblock-summary-control')?.click();
              return Boolean(operation);
            })()
            """,
            in: webView,
        )
        let operationExpanded = try await waitForJavaScript(
            "document.querySelector('#swagger-ui .opblock')?.classList.contains('is-open') === true",
            in: webView,
        )
        XCTAssertTrue(operationExpanded, "The first operation did not expand.")
        let schemaTabExists = try await waitForJavaScript(
            "document.querySelector('#swagger-ui .responses-wrapper .model-example button[data-name=\"model\"]') !== null",
            in: webView,
        )
        XCTAssertTrue(schemaTabExists, "The response Schema tab was not mounted.")
    }

    private func selectAndExpandResponseSchema(in webView: WKWebView) async throws {
        let tabClickResult = try await evaluateString(
            """
            (() => {
              const tab = document.querySelector('#swagger-ui .responses-wrapper .model-example button[data-name="model"]');
              if (tab?.getAttribute('aria-selected') !== 'true') {
                tab?.focus();
                tab?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
              }
              return JSON.stringify({ found: Boolean(tab), selected: tab?.getAttribute('aria-selected'), html: tab?.outerHTML });
            })()
            """,
            in: webView,
        )
        let schemaTabActive = try await waitForJavaScript(
            "document.querySelector('#swagger-ui .responses-wrapper .model-example button[data-name=\"model\"][aria-selected=\"true\"]') !== null && document.querySelector('#swagger-ui .responses-wrapper [role=\"tabpanel\"][data-name=\"modelPanel\"]') !== null",
            in: webView,
        )
        XCTAssertTrue(
            schemaTabActive,
            "The response Schema tab did not become active. Click result: \(tabClickResult)",
        )
        _ = try await callAsyncJavaScript(
            """
            const panel = document.querySelector('#swagger-ui .responses-wrapper [data-name="modelPanel"]');
            if (panel?.querySelector('.json-schema-2020-12-expand-deep-button')) {
              const expandAll = Array.from(panel.querySelectorAll('.json-schema-2020-12-expand-deep-button')).find(button => /expand all/i.test(button.textContent));
              expandAll?.click();
              await new Promise(resolve => requestAnimationFrame(resolve));
            } else {
              for (let pass = 0; pass < 8; pass += 1) {
                const collapsed = Array.from(panel?.querySelectorAll('.model-box-control[aria-expanded="false"]') ?? []);
                if (collapsed.length === 0) break;
                collapsed.forEach(node => node.click());
                await new Promise(resolve => requestAnimationFrame(resolve));
              }
            }
            true
            """,
            arguments: [:],
            in: webView,
        )
    }

    private func simpleSpec(path: String) -> String {
        """
        openapi: 3.1.0
        info: { title: Latest Load, version: '1' }
        paths:
          \(path):
            get:
              summary: Latest marker
              responses:
                '200': { description: OK }
        """
    }

    private func slowReferenceSpec() -> String {
        """
        openapi: 3.1.0
        info: { title: Slow Older Load, version: '1' }
        paths:
          /late-render:
            get:
              summary: Older load marker
              responses:
                '200':
                  description: A nested schema keeps this render busy.
                  content:
                    application/json:
                      schema:
                        $ref: '#/components/schemas/FirstLevel'
        components:
          schemas:
            FirstLevel:
              type: object
              properties:
                second:
                  $ref: '#/components/schemas/SecondLevel'
            SecondLevel:
              type: object
              properties:
                third:
                  $ref: '#/components/schemas/ThirdLevel'
            ThirdLevel:
              type: object
              properties:
                fourth:
                  $ref: '#/components/schemas/FourthLevel'
            FourthLevel:
              type: object
              properties:
                marker: { type: string }
        """
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = findWebView(in: child) { return webView }
        }
        return nil
    }

    private func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        try await evaluateJavaScript(script, in: webView) as? String ?? ""
    }

    private func callAsyncJavaScript(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView,
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                in: .page,
                completionHandler: { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                },
            )
        }
    }

    private func waitForJavaScript(_ script: String, in webView: WKWebView) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await evaluateJavaScript(script, in: webView) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func waitForRenderEvent(
        loadID: String,
        timeout: Int,
        startingAt index: Int = 0,
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if state.eventLog.dropFirst(index).contains(where: { $0.hasPrefix("rendered \(loadID):") }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return state.eventLog.dropFirst(index).contains(where: { $0.hasPrefix("rendered \(loadID):") })
    }
}

@MainActor
private final class AcceptanceViewerState: ObservableObject {
    @Published var text: String
    @Published var format = "yaml"
    @Published var loadID = UUID().uuidString
    @Published var filter = ""
    @Published var appearance = "light"

    private let onReady: () -> Void
    private var renderExpectations: [String: (Int?, XCTestExpectation)] = [:]
    private var errorExpectations: [(String, XCTestExpectation)] = []
    private(set) var eventLog: [String] = []

    init(text: String, onReady: @escaping () -> Void) {
        self.text = text
        self.onReady = onReady
    }

    func expectRender(loadID: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Load \(loadID) renders")
        renderExpectations[loadID] = (nil, expectation)
        return expectation
    }

    func expectError(containing text: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Viewer reports error containing \(text)")
        errorExpectations.append((text, expectation))
        return expectation
    }

    func load(text: String, format: String = "yaml", loadID: String) {
        self.text = text
        self.format = format
        self.loadID = loadID
    }

    func ready() {
        onReady()
    }

    func rendered(loadID: String, operationCount: Int) {
        eventLog.append("rendered \(loadID): \(operationCount)")
        guard let (_, expectation) = renderExpectations[loadID] else { return }
        renderExpectations.removeValue(forKey: loadID)
        expectation.fulfill()
    }

    func failed(_ message: String) {
        eventLog.append("error \(loadID): \(message)")
        guard let index = errorExpectations.firstIndex(where: { message.contains($0.0) }) else { return }
        let expectation = errorExpectations.remove(at: index).1
        expectation.fulfill()
    }
}

private struct AcceptanceViewerRoot: View {
    @ObservedObject var state: AcceptanceViewerState

    var body: some View {
        let loadID = state.loadID
        ViewerWebView(
            text: state.text,
            format: state.format,
            loadID: loadID,
            filter: state.filter,
            appearance: state.appearance,
            onOpenFile: { _ in },
            onReady: state.ready,
            onRendered: { operationCount in
                state.rendered(loadID: loadID, operationCount: operationCount)
            },
            onError: state.failed,
        )
    }
}

private final class LoopbackProbe {
    private let queue = DispatchQueue(label: "OpenAPIViewer.AcceptanceTests.Loopback")
    private let listener: NWListener
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var capturedRequests: [String] = []

    var baseURL: String {
        "http://127.0.0.1:\(listener.port!.rawValue)"
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        listener.stateUpdateHandler = { [ready] state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            throw NSError(
                domain: "OpenAPIViewer.AcceptanceTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The loopback probe failed to start."])
        }
    }

    deinit {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            if let line = data.flatMap({ String(data: $0, encoding: .utf8) })?.components(separatedBy: "\r\n")
                .first
            {
                self?.record(line)
            }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func record(_ request: String) {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        capturedRequests.removeAll()
        lock.unlock()
    }
}
