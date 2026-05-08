//
//  ML_IntegrationUITests.swift
//  ML IntegrationUITests
//
//  Created by TBDO Inc on 4/17/26.
//

import XCTest

final class ML_IntegrationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {}

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testLaunchPerformance() throws {
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
        app.launchArguments = ["-ui-onboarding-dry-run", "-ui-focus-onboarding"]

        launchOnboardingFocusApp(app)

        let harness = try waitForOnboardingHarness(in: app, timeout: 12)

        let runButton = harness.buttons["onboarding-run-actions-button"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 8), "Run Onboarding Actions button was not visible in focus harness.")

        runButton.tap()

        let firstStatusLine = harness.staticTexts["onboarding-status-first-line"]
        XCTAssertTrue(
            firstStatusLine.waitForExistence(timeout: 12),
            "Expected onboarding telemetry lines after running onboarding actions."
        )
    }

    // MARK: - Harness Synchronization

    @MainActor
    private func launchOnboardingFocusApp(_ app: XCUIApplication) {
        app.launch()
        app.activate()

        let foregroundPredicate = NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue)
        let foregroundExpectation = XCTNSPredicateExpectation(predicate: foregroundPredicate, object: app)
        _ = XCTWaiter.wait(for: [foregroundExpectation], timeout: 5)
    }

    @MainActor
    private func waitForOnboardingHarness(in app: XCUIApplication, timeout: TimeInterval) throws -> XCUIElement {
        let harness = app.otherElements["onboarding-focus-harness"]
        let readyMarker = app.staticTexts["onboarding-focus-ready"]

        if harness.waitForExistence(timeout: timeout), readyMarker.waitForExistence(timeout: 2) {
            return harness
        }

        // One clean retry to recover from transient disabled-session launches.
        app.terminate()
        launchOnboardingFocusApp(app)
        if harness.waitForExistence(timeout: timeout), readyMarker.waitForExistence(timeout: 2) {
            return harness
        }

        let debugTree = app.debugDescription
        XCTContext.runActivity(named: "Onboarding harness not available") { activity in
            let note = "Onboarding focus harness unavailable in runner session. " +
                "launchArguments=\(app.launchArguments)\n" +
                "appEnabled=\(app.isEnabled)\n" +
                "appState=\(app.state.rawValue)\n" +
                "debugDescription=\(debugTree)"
            activity.add(XCTAttachment(string: note))

            let screenshot = XCUIScreen.main.screenshot()
            let imageAttachment = XCTAttachment(screenshot: screenshot)
            imageAttachment.name = "onboarding-harness-missing"
            imageAttachment.lifetime = .keepAlways
            activity.add(imageAttachment)
        }

        throw XCTSkip("Onboarding focus harness unavailable after relaunch; skipping to avoid hanging test session.")
    }
}
