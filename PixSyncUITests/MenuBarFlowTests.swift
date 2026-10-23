import XCTest

final class MenuBarFlowTests: XCTestCase {
  func testMenuBarProvidesFolderSetupAndOpensSingletonWindowAndSettings() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    let statusItem = app.menuBarItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
    statusItem.click()

    XCTAssertTrue(app.buttons["Choose Folder…"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["No folder selected"].exists)
    XCTAssertFalse(app.buttons["Sync Now"].isEnabled)
    app.buttons["Open PixSync Window…"].click()
    XCTAssertTrue(app.windows["PixSync"].waitForExistence(timeout: 5))

    statusItem.click()
    app.buttons["Settings…"].click()
    XCTAssertTrue(app.switches["Include edited versions"].waitForExistence(timeout: 5))

    app.terminate()
  }
}
