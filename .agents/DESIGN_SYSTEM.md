# Design system

## Native shell

- Use standard macOS SwiftUI document windows, menus, toolbar items, buttons, and search fields so keyboard behavior and accessibility follow platform conventions.
- Keep the toolbar compact: document identity, operation filter, reload, and appearance controls. Do not rebuild Swagger UI's endpoint or schema navigation in SwiftUI.
- Keep the operation filter at a fixed 250-point width in its own principal toolbar position, with a trailing gap before reload; expose System, Light, and Dark as direct appearance menu choices.
- The main content fills the window and resizes with it. Use the system font and native control sizing rather than fixed custom typography or spacing.

## Appearance and status

- Follow the system light or dark appearance by default and send the effective appearance to the viewer after readiness and whenever it changes.
- Resolve System from the observed application appearance so a window's explicit preferred color scheme cannot feed back into the system selection, and so changes while System is selected update the viewer.
- Show a clear loading state while a document is read or rendered. Show actionable errors in the document window while retaining the native toolbar where possible.
- Empty state: explain that the user can open or drop an OpenAPI YAML or JSON file.
- Keep status and error text concise; include available line and column details for parser diagnostics.

## Documentation content

- Swagger UI owns operation grouping, HTTP method colors, schemas, parameters, request bodies, and responses. Native UI must not duplicate these structures.
- The native search field filters the rendered operation list by path, method, tag, or summary.
- Keep the web content readable at different window sizes and in both system appearances; do not impose a fixed content width from the native shell.
