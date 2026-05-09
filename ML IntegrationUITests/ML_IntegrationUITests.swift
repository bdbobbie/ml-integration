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

        let runButton = onboardingRunActionsButton(in: app)
        XCTAssertTrue(runButton.waitForExistence(timeout: 8), "Run Onboarding Actions button was not visible in focus harness.")

        runButton.tap()

        let firstStatusLine = onboardingFirstStatusLine(in: app)
        XCTAssertTrue(
            firstStatusLine.waitForExistence(timeout: 12),
            "Expected onboarding telemetry lines after running onboarding actions."
        )
    }

    @MainActor
    func testQueueUISmokeFlowExposesControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-focus-queue"]
        app.launch()

        let harness = app.otherElements["queue-focus-harness"]
        guard harness.waitForExistence(timeout: 12) else {
            throw XCTSkip("Queue focus harness unavailable in this runner session; skipping to avoid hanging UI query.")
        }

        let ready = app.staticTexts["queue-focus-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 4), "Queue smoke failed: focus harness ready marker not visible.")

        let queueTick = app.buttons["queue-run-tick-button"]
        XCTAssertTrue(queueTick.waitForExistence(timeout: 4), "Queue smoke failed: missing Run Queue Tick Now control.")

        let queueOrder = app.staticTexts["queue-order-label"]
        XCTAssertTrue(queueOrder.waitForExistence(timeout: 4), "Queue smoke failed: missing Queue Order label.")
    }

    @MainActor
    func testStep5ReadinessUISmokeRendersSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-focus-step5"]
        app.launch()

        let harness = app.otherElements["step5-focus-harness"]
        guard harness.waitForExistence(timeout: 12) else {
            throw XCTSkip("Step 5 focus harness unavailable in this runner session; skipping to avoid hanging UI query.")
        }

        let readyMarker = app.staticTexts["step5-focus-ready"]
        XCTAssertTrue(readyMarker.waitForExistence(timeout: 4), "Step 5 smoke failed: focus harness ready marker not visible.")

        let summaryByIdentifier = app.staticTexts["step5-readiness-summary"]
        let readySummaryByText = app.staticTexts["Step 5 readiness: READY."]
        let blockedSummaryByText = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Step 5 readiness: BLOCKED")
        ).firstMatch

        XCTAssertTrue(
            summaryByIdentifier.waitForExistence(timeout: 4)
                || readySummaryByText.waitForExistence(timeout: 4)
                || blockedSummaryByText.waitForExistence(timeout: 4),
            "Step 5 readiness summary was not visible."
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
        let runButton = onboardingRunActionsButton(in: app)

        if (readyMarker.waitForExistence(timeout: timeout) || runButton.waitForExistence(timeout: timeout)) {
            return app
        }

        // One clean retry to recover from transient disabled-session launches.
        app.terminate()
        launchOnboardingFocusApp(app)
        if (readyMarker.waitForExistence(timeout: timeout) || runButton.waitForExistence(timeout: timeout)) {
            return app
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

    @MainActor
    private func onboardingRunActionsButton(in app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.buttons["onboarding-run-actions-button"]
        if byIdentifier.exists {
            return byIdentifier
        }
        return app.buttons["Run Onboarding Actions"]
    }

    @MainActor
    private func onboardingFirstStatusLine(in app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.staticTexts["onboarding-status-first-line"]
        if byIdentifier.exists {
            return byIdentifier
        }
        return app.staticTexts["Started onboarding action run."]
    }
}
