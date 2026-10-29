import XCTest

final class QuotaMeterUITests: XCTestCase {
    func testLiquidTabBarSwipesBetweenTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["QUOTAMETER_DEMO"] = "1"
        app.launch()

        let tabBar = app.sliders["liquid-tab-bar"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let initialValue = tabBar.value as? String
        XCTAssertNotNil(initialValue)

        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.94))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.94))
        left.press(forDuration: 0.08, thenDragTo: right)
        expectation(
            for: NSPredicate(format: "value != %@", initialValue!),
            evaluatedWith: tabBar
        )
        waitForExpectations(timeout: 3)

        right.press(forDuration: 0.08, thenDragTo: left)
        expectation(
            for: NSPredicate(format: "value == %@", initialValue!),
            evaluatedWith: tabBar
        )
        waitForExpectations(timeout: 3)
    }

    func testBlankAreaDoesNotSelectTab() {
        let app = XCUIApplication()
        app.launchEnvironment["QUOTAMETER_DEMO"] = "1"
        app.launch()

        let tabBar = app.sliders["liquid-tab-bar"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let initialValue = tabBar.value as? String
        XCTAssertNotNil(initialValue)

        let blankGap = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.65, dy: 0.94)
        )
        blankGap.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(tabBar.value as? String, initialValue)

        let platformCenter = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)
        )
        platformCenter.tap()
        expectation(
            for: NSPredicate(format: "value != %@", initialValue!),
            evaluatedWith: tabBar
        )
        waitForExpectations(timeout: 3)
    }
}
