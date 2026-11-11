import XCTest

final class OpenAPIViewerUITests: XCTestCase {
    private let filterLabel = "Filter operations by path, method, tag, or summary"

    func testAppearanceMenuDarkThenSystemSelection() throws {
        try verifyAppearanceMenuSequence(
            initialInterfaceStyle: "Light",
            choices: ["Dark", "System"],
        )
    }

    func testAppearanceMenuLightThenSystemSelection() throws {
        try verifyAppearanceMenuSequence(
            initialInterfaceStyle: "Dark",
            choices: ["Light", "System"],
        )
    }

    func testOpenPanelCommandOAndFileMenuOpenYamlYmlAndJSONInSeparateWindows() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAPIViewerUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let yaml = fixtureDirectory.appendingPathComponent("first.yaml")
        let yml = fixtureDirectory.appendingPathComponent("second.yml")
        let json = fixtureDirectory.appendingPathComponent("third.json")
        try yamlFixture(title: "First Fixture", path: "/first").write(
            to: yaml, atomically: true, encoding: .utf8)
        try yamlFixture(title: "Second Fixture", path: "/second").write(
            to: yml, atomically: true, encoding: .utf8)
        try jsonFixture(title: "Third Fixture", path: "/third").write(
            to: json, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        openFixture(yaml, in: app)
        let firstWindow = documentWindow(named: yaml.lastPathComponent, in: app)
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 15))
        XCTAssertTrue(firstWindow.buttons["Reload"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstWindow.textFields[filterLabel].exists)

        app.typeKey("o", modifierFlags: .command)
        openFixture(yml, in: app)
        let secondWindow = documentWindow(named: yml.lastPathComponent, in: app)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 15))

        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        for commandID in [
            "saveDocument:", "saveDocumentAs:", "duplicateDocument:", "renameDocument:", "moveDocument:",
        ] {
            XCTAssertFalse(app.menuItems.matching(identifier: commandID).firstMatch.exists)
        }
        let openMenuItem = app.menuItems.matching(identifier: "openDocument:").firstMatch
        XCTAssertTrue(openMenuItem.waitForExistence(timeout: 5))
        openMenuItem.click()
        openFixture(json, in: app)
        let thirdWindow = documentWindow(named: json.lastPathComponent, in: app)
        XCTAssertTrue(thirdWindow.waitForExistence(timeout: 15))

        XCTAssertTrue(firstWindow.exists)
        XCTAssertTrue(secondWindow.exists)
        XCTAssertTrue(thirdWindow.exists)
        XCTAssertEqual(
            app.windows.matching(
                NSPredicate(
                    format: "title CONTAINS '.yaml' OR title CONTAINS '.yml' OR title CONTAINS '.json'")
            ).count, 3)

        app.terminate()
    }

    private func openFixture(_ url: URL, in app: XCUIApplication) {
        let openPanel = app.windows["Open"]
        if !openPanel.exists {
            app.typeKey("o", modifierFlags: .command)
        }
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
        XCTAssertTrue(openButton.isEnabled)
        openButton.click()
    }

    private func verifyAppearanceMenuSequence(
        initialInterfaceStyle: String,
        choices: [String],
    ) throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAPIViewerAppearanceUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fixture = fixtureDirectory.appendingPathComponent("appearance.yaml")
        try yamlFixture(title: "Appearance Fixture", path: "/appearance").write(
            to: fixture, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-AppleInterfaceStyle", initialInterfaceStyle,
        ]
        app.launch()
        defer { app.terminate() }

        openFixture(fixture, in: app)
        let window = documentWindow(named: fixture.lastPathComponent, in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let appearanceButton = window.buttons["Appearance"]
        XCTAssertTrue(appearanceButton.waitForExistence(timeout: 10))

        for choice in choices {
            appearanceButton.click()
            let menuItem = app.menuItems[choice]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
            menuItem.click()
            XCTAssertTrue(window.exists)
        }
    }

    private func documentWindow(named fileName: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", fileName)).firstMatch
    }

    private func yamlFixture(title: String, path: String) -> String {
        """
        openapi: 3.1.0
        info:
          title: \(title)
          version: 1.0.0
        paths:
          \(path):
            get:
              summary: \(title) operation
              responses:
                '200':
                  description: Success
        """
    }

    private func jsonFixture(title: String, path: String) -> String {
        """
        {
          "openapi": "3.1.0",
          "info": { "title": "\(title)", "version": "1.0.0" },
          "paths": {
            "\(path)": {
              "get": {
                "summary": "\(title) operation",
                "responses": { "200": { "description": "Success" } }
              }
            }
          }
        }
        """
    }
}
