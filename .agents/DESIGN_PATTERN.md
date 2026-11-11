# Design patterns

## Ownership and document lifecycle

- SwiftUI owns windows, document opening, toolbar state, appearance, and user-visible file errors.
- `FileDocument` stores a read-only UTF-8 source snapshot and any read error. `DocumentGroup` supplies the source URL separately to `DocumentView`; file access and reload use coordinated reads, and JavaScript never reads user files directly.
- Each window owns its document and web view state. A new UUID identifies each load so late JavaScript results cannot affect a newer snapshot.
- When appearance is System, observe `NSApp.effectiveAppearance`, not the window's SwiftUI color-scheme environment, because that window may be forced to Light or Dark. The document appearance state owns and releases the weak KVO observation; explicit window choices remain local.
- The viewer is loaded from bundled `Viewer/dist` resources with read access scoped to that directory. No development server or remote resource is used at runtime.
- Finder file drops are registered by the native `FileDropWKWebView`, because Finder drags did not reach the enclosing SwiftUI drop handler in the tested WebKit view. The adapter accepts local file URLs from the pasteboard and forwards them through `DocumentView.openLocalFile` into `NSDocumentController`; JavaScript never handles dropped files. Clear the adapter callback when the web view is dismantled.

## Web view bridge and resource policy

- The native adapter sends structured arguments to `window.viewerBridge`; it never interpolates document text into JavaScript source or HTML.
- The JavaScript message handler is named `viewer`. Swift calls `window.viewerBridge.loadDocument({loadID,text,format})`, `.setFilter({query})`, and `.setAppearance({appearance})` with structured arguments.
- JavaScript reports `ready`, `diagnostics({loadID,diagnostics})`, and `rendered({loadID,operationCount})` messages. Native UI ignores results for stale load IDs and accepts messages only from the main frame of the bundled viewer URL.
- WebKit navigation and resource loads are restricted to bundled local resources. Remote references are reported by the viewer and never fetched. External documentation links may open in the default browser only after a direct user click.
- Swagger UI is pinned to 5.34.1 and receives the parsed document through its inline `spec` option. The [5.34.1 configuration](https://github.com/swagger-api/swagger-ui/blob/v5.34.1/docs/usage/configuration.md#core) says this mode uses an in-memory object and ignores `url`; the [resolver constructs its base document from the spec URL and `document.baseURI`](https://github.com/swagger-api/swagger-ui/blob/v5.34.1/src/core/plugins/spec/actions.js#L95-L106). In WKWebView, an empty spec URL therefore falls back to the local `index.html`, causing `#/components/...` pointers to be treated as references against that HTML URL. `createInlineSpecBasePlugin` replaces only that empty URL with `https://openapi-viewer.invalid/openapi.json`, a synthetic in-memory base that lets Swagger resolve JSON Pointers within the supplied spec. It must never use a source-file path or a real remote URL. This placeholder is not fetched: the viewer rejects external references, and WebKit's content rule blocks HTTP(S) resource loads.
- `WKWebView` teardown removes its script-message handler to avoid retaining a document window.

## Errors and dependencies

- Errors identify the operation that failed and preserve an underlying useful system description. Text decoding errors explain that UTF-8 is required.
- Swift owns document access and lifecycle; JavaScript owns parsing and Swagger UI rendering. Swift does not duplicate the OpenAPI model or parser.
- JSON documents use `JSON.parse`; the pinned `jsonc-parser` dependency is used only to locate syntax error offsets because browser `JSON.parse` messages do not reliably report line and column.
- Native code uses Apple frameworks only. The Viewer build owns pinned npm dependencies and bundles the complete offline runtime.
