import XCTest

final class DragAndDropUITests: XCTestCase {
    private let finderDropClearance: CGFloat = 32

    func testDraggingSpecificationFromFinderOpensDocumentWindow() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAPIViewerDragUITests-\(UUID().uuidString)", isDirectory: true)
        let initialDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAPIViewerInitialUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: initialDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        defer { try? FileManager.default.removeItem(at: initialDirectory) }

        let fixture = fixtureDirectory.appendingPathComponent("dragged-\(UUID().uuidString).yaml")
        let initialDocument = initialDirectory.appendingPathComponent("initial-spec.yaml")
        try """
        openapi: 3.1.0
        info:
          title: Finder Drop Fixture
          version: 1.0.0
        paths:
          /dropped:
            get:
              summary: Opened by dropping from Finder
              responses:
                '200':
                  description: Success
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try """
        openapi: 3.1.0
        info:
          title: Initial Fixture
          version: 1.0.0
        paths: {}
        """.write(to: initialDocument, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        openFixture(initialDocument, in: app)
        let targetWindow = app.windows.matching(
            NSPredicate(format: "title CONTAINS %@", initialDocument.lastPathComponent)
        ).firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 15))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        for oldWindow in finder.windows.matching(
            NSPredicate(format: "title BEGINSWITH %@", "OpenAPIViewerDragUITests-")
        ).allElementsBoundByIndex where oldWindow.exists {
            oldWindow.click()
            finder.typeKey("w", modifierFlags: .command)
        }
        let reveal = Process()
        reveal.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reveal.arguments = ["-R", fixture.path]
        try reveal.run()
        reveal.waitUntilExit()
        XCTAssertEqual(reveal.terminationStatus, 0)
        finder.activate()

        let finderWindow = finder.windows.matching(
            NSPredicate(format: "title CONTAINS %@", fixtureDirectory.lastPathComponent)
        ).firstMatch
        guard finderWindow.waitForExistence(timeout: 10) else {
            XCTFail("Finder did not open the fixture folder.")
            return
        }
        defer {
            if finderWindow.exists {
                finderWindow.click()
                finder.typeKey("w", modifierFlags: .command)
            }
        }
        finderWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).click()
        finder.typeKey("2", modifierFlags: .command)

        let fileRow = finderWindow.outlines["ListView"].descendants(matching: .outlineRow).firstMatch
        guard fileRow.waitForExistence(timeout: 10) else {
            XCTFail("Finder did not expose the fixture file row.")
            return
        }
        let fileName = fileRow.descendants(matching: .textField)
            .matching(NSPredicate(format: "value == %@", fixture.lastPathComponent)).firstMatch
        guard fileName.exists else {
            XCTFail("The Finder row does not contain the fixture filename.")
            return
        }
        let fileIcon = fileRow.images.firstMatch
        guard fileIcon.exists else {
            XCTFail("Finder did not expose the fixture file icon.")
            return
        }
        guard fileRow.isHittable else {
            XCTFail("The fixture row is not visible in Finder.")
            return
        }

        let originalFinderFrame = finderWindow.frame
        resizeFinderWindow(finderWindow, toWidth: 460)
        let resizedFinderFrame = finderWindow.frame
        let finderShift = -finderWindow.frame.minX
        if finderShift != 0 {
            moveWindow(finderWindow, by: CGVector(dx: finderShift, dy: 0))
        }
        let arrangedFinderFrame = finderWindow.frame
        let sourcePoint = fileIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint
        let desktop = finder.descendants(matching: .scrollView)
            .matching(NSPredicate(format: "label == %@", "desktop")).firstMatch
        guard desktop.exists else {
            XCTFail("Finder did not expose the desktop bounds needed to verify the drop surface.")
            return
        }
        let screenFrame = desktop.frame
        let finderFrames = finder.windows.allElementsBoundByIndex.map(\.frame)
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 10) else {
            XCTFail("The existing document window does not expose its WebView.")
            return
        }
        let webViewFrame = webView.frame
        let dropOffset = CGVector(dx: 0.5, dy: 0.65)
        guard
            let clearPoint = clearDropPoint(
                for: targetWindow,
                offset: dropOffset,
                screen: screenFrame,
                finderFrames: finderFrames,
                sourcePoint: sourcePoint,
                webViewFrame: webViewFrame
            )
        else {
            throw XCTSkip("No exposed viewer-content point is clear of the current Finder window layout.")
        }

        app.activate()
        let currentDropPoint = targetWindow.coordinate(withNormalizedOffset: dropOffset).screenPoint
        moveWindow(
            targetWindow,
            by: CGVector(dx: clearPoint.x - currentDropPoint.x, dy: clearPoint.y - currentDropPoint.y)
        )
        finder.activate()

        let dropPoint = targetWindow.coordinate(withNormalizedOffset: dropOffset)
        let currentFinderFrames = finder.windows.allElementsBoundByIndex.map(\.frame)
        let targetFrame = targetWindow.frame
        let currentWebViewFrame = webView.frame
        let sourceExposed = finderWindow.frame.contains(sourcePoint) && !targetFrame.contains(sourcePoint)
        let targetExposed =
            screenFrame.contains(dropPoint.screenPoint)
            && targetFrame.contains(dropPoint.screenPoint)
            && currentWebViewFrame.contains(dropPoint.screenPoint)
            && currentFinderFrames.allSatisfy {
                !$0.insetBy(dx: -finderDropClearance, dy: -finderDropClearance)
                    .contains(dropPoint.screenPoint)
            }
        guard sourceExposed, targetExposed else {
            let frames = currentFinderFrames.map(String.init(describing:)).joined(separator: "; ")
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Finder drop surface is obscured"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail(
                "Drop surfaces are obscured. Screen: \(screenFrame), Finder: \(frames), source: \(sourcePoint), icon: \(fileIcon.frame), app: \(targetFrame), WebView: \(currentWebViewFrame), target: \(dropPoint.screenPoint)"
            )
            return
        }

        print(
            "Finder drop geometry: fixtureExists=\(FileManager.default.fileExists(atPath: fixture.path)), fixture=\(fixture.path), screen=\(screenFrame), initial Finder=\(originalFinderFrame), resized Finder=\(resizedFinderFrame), arranged Finder=\(arrangedFinderFrame), app=\(targetFrame), initial WebView=\(webViewFrame), current WebView=\(currentWebViewFrame), source row=\(fileRow.frame), icon=\(fileIcon.frame), source point=\(sourcePoint), target=\(dropPoint.screenPoint), Finder windows=\(currentFinderFrames)"
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Before Finder file drop"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let dragStart = fileIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.click(forDuration: 1, thenDragTo: dropPoint)
        let afterDropScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterDropScreenshot.name = "Immediately after Finder file drop"
        afterDropScreenshot.lifetime = .keepAlways
        add(afterDropScreenshot)

        app.activate()
        let openedWindow = app.windows.matching(
            NSPredicate(format: "title CONTAINS %@", fixture.lastPathComponent)
        ).firstMatch
        XCTAssertTrue(openedWindow.waitForExistence(timeout: 15))
        let renderedTitle = openedWindow.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", "Finder Drop Fixture")).firstMatch
        XCTAssertTrue(renderedTitle.waitForExistence(timeout: 10))
        let renderedOperation = openedWindow.buttons.matching(
            NSPredicate(format: "title CONTAINS %@", "/dropped")
        ).firstMatch
        XCTAssertTrue(renderedOperation.waitForExistence(timeout: 10))
    }

    private func resizeFinderWindow(_ window: XCUIElement, toWidth width: CGFloat) {
        let amount = window.frame.width - width
        guard amount > 0 else { return }
        let bottomRight = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
        bottomRight.click(forDuration: 0.5, thenDragTo: bottomRight.withOffset(CGVector(dx: -amount, dy: 0)))
    }

    private func moveWindow(_ window: XCUIElement, by offset: CGVector) {
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        titleBar.click(forDuration: 0.5, thenDragTo: titleBar.withOffset(offset))
    }

    private func clearDropPoint(
        for window: XCUIElement,
        offset: CGVector,
        screen: CGRect,
        finderFrames: [CGRect],
        sourcePoint: CGPoint,
        webViewFrame: CGRect
    ) -> CGPoint? {
        let safeScreen = screen.insetBy(dx: 8, dy: 8)
        let windowFrame = window.frame
        let initialPoint = window.coordinate(withNormalizedOffset: offset).screenPoint
        let titleBarPoint = CGPoint(x: windowFrame.midX, y: windowFrame.minY + 16)
        var bestPoint: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        var y = safeScreen.minY
        while y <= safeScreen.maxY {
            var x = safeScreen.minX
            while x <= safeScreen.maxX {
                let point = CGPoint(x: x, y: y)
                let translation = CGVector(dx: point.x - initialPoint.x, dy: point.y - initialPoint.y)
                let translatedWindow = windowFrame.offsetBy(dx: translation.dx, dy: translation.dy)
                let translatedTitleBar = CGPoint(
                    x: titleBarPoint.x + translation.dx,
                    y: titleBarPoint.y + translation.dy
                )
                let pointIsClear = finderFrames.allSatisfy {
                    !$0.insetBy(dx: -finderDropClearance, dy: -finderDropClearance).contains(point)
                }
                let sourceStaysClear = !translatedWindow.insetBy(dx: -8, dy: -8).contains(sourcePoint)
                let titleBarStaysVisible = safeScreen.contains(translatedTitleBar)
                let translatedWebView = webViewFrame.offsetBy(dx: translation.dx, dy: translation.dy)
                let distance = hypot(translation.dx, translation.dy)

                if pointIsClear, sourceStaysClear, titleBarStaysVisible,
                    translatedWebView.contains(point), distance < bestDistance
                {
                    bestPoint = point
                    bestDistance = distance
                }
                x += 8
            }
            y += 8
        }
        return bestPoint
    }

    private func openFixture(_ url: URL, in app: XCUIApplication) {
        app.typeKey("o", modifierFlags: .command)
        let openPanel = app.windows["Open"]
        XCTAssertTrue(openPanel.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])

        let pathField = openPanel.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(url.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let openButton = openPanel.buttons["OKButton"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.click()
    }
}
