# Design patterns

## Ownership and document lifecycle

- SwiftUI owns windows, document opening, toolbar state, appearance, and user-visible file errors.
- `FileDocument` stores a read-only UTF-8 source snapshot and its source URL. File access and reload use coordinated reads; JavaScript never reads user files directly.
- Each window owns its document and web view state. A new UUID identifies each load so late JavaScript results cannot affect a newer snapshot.
- The viewer is loaded from bundled `Viewer/dist` resources with read access scoped to that directory. No development server or remote resource is used at runtime.

## Web view bridge and resource policy

- The native adapter sends structured arguments to `window.viewerBridge`; it never interpolates document text into JavaScript source or HTML.
- The JavaScript message handler is named `viewer`. Swift calls `window.viewerBridge.loadDocument({loadID,text,format})`, `.setFilter({query})`, and `.setAppearance({appearance})` with structured arguments.
- JavaScript reports `ready`, `diagnostics({loadID,diagnostics})`, and `rendered({loadID,operationCount})` messages. Native UI ignores results for stale load IDs and accepts messages only from the main frame of the bundled viewer URL.
- WebKit navigation and resource loads are restricted to bundled local resources. Remote references are reported by the viewer and never fetched. External documentation links may open in the default browser only after a direct user click.
- `WKWebView` teardown removes its script-message handler to avoid retaining a document window.

## Errors and dependencies

- Errors identify the operation that failed and preserve an underlying useful system description. Text decoding errors explain that UTF-8 is required.
- Swift owns document access and lifecycle; JavaScript owns parsing and Swagger UI rendering. Swift does not duplicate the OpenAPI model or parser.
- JSON documents use `JSON.parse`; the pinned `jsonc-parser` dependency is used only to locate syntax error offsets because browser `JSON.parse` messages do not reliably report line and column.
- Native code uses Apple frameworks only. The Viewer build owns pinned npm dependencies and bundles the complete offline runtime.
