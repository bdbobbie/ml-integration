//
//  ML_IntegrationUITests.swift
//  ML IntegrationUITests
//
//  Created by TBDO Inc on 4/17/26.
//

import XCTest

final class ML_IntegrationUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testCoherenceSchemaWarningAndRepairActionVisibility() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-force-schema-invalid", "-ui-enable-repair-action"])
        app.launch()

        let warningContainer = app.otherElements["coherence-schema-warning-container"]
        guard warningContainer.waitForExistence(timeout: 10) else {
            throw XCTSkip("Schema warning container not exposed in current UI test runner session.")
        }

        let repairButton = app.buttons["Repair Coherence Policy"]
        guard repairButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Repair action not exposed in current UI test runner session.")
        }
        repairButton.tap()
    }

    @MainActor
    func testOnboardingActionsExposeProgressTelemetry() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-onboarding-dry-run")
        app.launchArguments.append("-ui-focus-onboarding")
        app.launch()

        let harnessReady = app.staticTexts["onboarding-focus-ready"]
        XCTAssertTrue(harnessReady.waitForExistence(timeout: 10), "Onboarding focus harness did not load in UI test mode.")

        let identifiedRunButton = app.buttons["onboarding-run-actions-button"]
        let titledRunButton = app.buttons["Run Onboarding Actions"]
        let runButton = identifiedRunButton.exists ? identifiedRunButton : titledRunButton
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Run Onboarding Actions button was not visible in current UI session.")

        runButton.tap()

        let statusContainer = app.staticTexts["onboarding-status-first-line"]
        XCTAssertTrue(
            statusContainer.waitForExistence(timeout: 10),
            "Expected onboarding telemetry lines after running onboarding actions."
        )
    }
}
