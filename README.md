# OpenAPI Viewer

OpenAPI Viewer is a read-only macOS application for browsing local OpenAPI 3.0
and 3.1 documents written as YAML or JSON. It uses a native SwiftUI document
window with Swagger UI embedded in a WebKit view.

Use **File > Open** or Command-O to select `.yaml`, `.yml`, or `.json` files.
The app also registers document types for Finder's **Open With** menu and has a
file drop handler; verify those routes in a built app before relying on them.
Each document is intended to open in its own window. Use the toolbar to filter
operations by path, HTTP method, tag, or summary, reload the source from disk,
and choose system, light, or dark appearance.

The application is read-only. It does not execute API operations. Parsing and
rendering do not claim complete OpenAPI semantic validation. Local UTF-8 text
is required. Internal references are supported; external references are
reported and are not resolved. Viewer assets are bundled in the application,
and document content is passed to the viewer locally. Automatic network access
for validation, references, and subresources is disabled. External
documentation links can be opened in the browser after an explicit click.

## Requirements

- macOS 14 or later on Apple Silicon (`arm64`)
- Xcode with the macOS SDK and Swift toolchain
- Node.js 20.19 or later and npm, for development and packaging the viewer
  assets only

The installed application does not require Node.js, a backend, or a local
development server. Local development and personal use do not require paid
Apple Developer Program membership. Developer ID signing, notarization, and
App Store distribution are outside this initial version.

## Build and verify

Run these commands from the repository root. Build the bundled viewer assets
before building the Xcode app:

```sh
npm ci
npm run lint
npm run format:check
npm test
npm run build
swift format lint --strict --recursive OpenAPIViewer OpenAPIViewerTests OpenAPIViewerUITests
xcodebuild -project OpenAPIViewer.xcodeproj -scheme OpenAPIViewer -destination 'platform=macOS,arch=arm64' test
xcodebuild -project OpenAPIViewer.xcodeproj -scheme OpenAPIViewer -configuration Release -destination 'platform=macOS,arch=arm64' build
git diff --check
```

To run from Xcode, first build the viewer assets with `npm run build`, open
`OpenAPIViewer.xcodeproj`, select the shared **OpenAPIViewer** scheme and **My
Mac** destination, then choose **Product > Run**.

For a predictable Release app location, build and launch it with:

```sh
xcodebuild -project OpenAPIViewer.xcodeproj -scheme OpenAPIViewer -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build build
open .build/Build/Products/Release/OpenAPIViewer.app
```

The complete viewer runtime and third-party notices are copied into the app at
`OpenAPIViewer.app/Contents/Resources/Viewer/dist/`; the notices are in
`THIRD-PARTY-NOTICES.txt` there.

## Verification status

The targeted WebKit acceptance suite passed 8/8 on the current bundled viewer.
It exercises real Swagger rendering, internal references in OpenAPI 3.0 and
3.1, filtering by path, method, tag, and summary, overlapping loads, stale
content clearing, appearance, and a loopback recorder that confirms external
references and remote images make no requests. The native UI suite passed its
open-panel and read-only menu checks for YAML/YML/JSON.

Manual checks on the Debug app verified opening YAML, YML, and JSON through the
system open panel or File > Open, opening through Finder's Open With route,
separate document windows, and reloading a changed file while preserving that
window's filter. A 174 KB fixture also rendered and filtered. The automated
Finder drag test drops a YAML document directly onto the WebKit view, opens a
new document window, and confirms that the document renders.

The Release arm64 app built successfully and was inspected for its architecture,
bundled viewer resources, and absence of Node or server binaries. A copied app
under `/tmp` was launched and rendered a separate `/tmp` fixture while loading
the viewer from its own app resources. The WebKit acceptance suite also
confirmed that blocked external references and remote images generated no
loopback requests.

## Further manual acceptance checks

Use a built app to verify the following behaviors in macOS/WebKit:

- Verify Finder's **Open With** and drag and drop; open two files and confirm
  their windows, filters, and reloads remain independent.
- Compare equivalent YAML and JSON specifications. Check operation filtering,
  internal schema references, and a schema nested several levels deep.
- Change a file on disk and reload it. Check that a missing or unreadable file,
  malformed YAML or JSON, an unsupported OpenAPI version, and an external
  reference produce useful errors without presenting old content as current.
- Open a fixture containing remote references, remote images, and literal
  example data with a `$ref`-shaped field. Confirm the viewer makes no
  automatic network requests and renders example data as data.
- Check source containing quotes, backticks, and HTML-like text, resizing,
  keyboard use, light and dark appearance, and that API request execution is
  unavailable.
- The Release executable was confirmed to contain only `arm64`.
