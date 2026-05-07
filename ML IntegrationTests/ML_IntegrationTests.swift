import XCTest
@testable import ML_Integration

final class ML_IntegrationTests: XCTestCase {
    private func makeTemporaryInstallerImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-test-installer-\(UUID().uuidString).iso")
        try Data("mock-installer".utf8).write(to: url)
        return url
    }

    @MainActor
    func testReadinessGateIsNoGoWhenAnyCriteriaUnsatisfied() {
        let planner = BlueprintPlanner()
        XCTAssertFalse(planner.isReadyForEnvironmentTesting)
        XCTAssertTrue(planner.readinessProgressSummary.contains("/10"))
    }

    @MainActor
    func testReadinessGateBecomesGoWhenAllCriteriaSatisfied() {
        let planner = BlueprintPlanner()
        for criterion in planner.readinessCriteria {
            planner.setReadinessCriterion(id: criterion.id, isSatisfied: true)
        }

        XCTAssertTrue(planner.isReadyForEnvironmentTesting)
        XCTAssertEqual(planner.readinessProgressSummary, "10/10 criteria satisfied")
    }

    @MainActor
    func testPreflightScanMarksEnvironmentPrereqsSatisfiedForCapableHost() {
        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "test"),
            virtualizationSupported: true,
            catalogHasArtifacts: true,
            catalogErrorMessage: "",
            installLifecycleState: .ready,
            hasManagedVM: true,
            testRootOverrideEnabled: true,
            currentRunID: UUID()
        )

        planner.applyPreflightScan(snapshot)

        let prereq = planner.readinessCriteria.first { $0.id == "environment-prereqs" }
        let blockers = planner.readinessCriteria.first { $0.id == "blockers-cleared" }
        XCTAssertEqual(prereq?.isSatisfied, true)
        XCTAssertEqual(blockers?.isSatisfied, true)
        XCTAssertTrue(planner.preflightStatusMessage.contains("passed"))
    }

    @MainActor
    func testPreflightScanMarksEnvironmentPrereqsUnsatisfiedForWeakHost() {
        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .intel, cpuCores: 1, memoryGB: 4, macOSVersion: "test"),
            virtualizationSupported: false,
            catalogHasArtifacts: false,
            catalogErrorMessage: "Catalog fetch failed",
            installLifecycleState: .failed,
            hasManagedVM: false,
            testRootOverrideEnabled: false,
            currentRunID: nil
        )

        planner.applyPreflightScan(snapshot)

        let prereq = planner.readinessCriteria.first { $0.id == "environment-prereqs" }
        let blockers = planner.readinessCriteria.first { $0.id == "blockers-cleared" }
        XCTAssertEqual(prereq?.isSatisfied, false)
        XCTAssertEqual(blockers?.isSatisfied, false)
        XCTAssertTrue(planner.preflightFindings.contains { $0.hasPrefix("WARN") })
    }

    @MainActor
    func testPreflightScanPersistsEvidenceArtifact() throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-preflight-evidence-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "test"),
            virtualizationSupported: true,
            catalogHasArtifacts: true,
            catalogErrorMessage: "",
            installLifecycleState: .ready,
            hasManagedVM: true,
            testRootOverrideEnabled: true,
            currentRunID: UUID()
        )

        planner.applyPreflightScan(snapshot)
        XCTAssertFalse(planner.lastPreflightEvidencePath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planner.lastPreflightEvidencePath))

        let data = try Data(contentsOf: URL(fileURLWithPath: planner.lastPreflightEvidencePath))
        let evidence = try JSONDecoder().decode(ReadinessScanEvidence.self, from: data)
        XCTAssertEqual(evidence.snapshot.virtualizationSupported, true)
        XCTAssertEqual(evidence.readinessSummary, planner.readinessProgressSummary)
    }

    @MainActor
    func testChecklistAutoSyncUpdatesCoreCriteria() {
        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "test"),
            virtualizationSupported: true,
            catalogHasArtifacts: true,
            catalogErrorMessage: "",
            installLifecycleState: .ready,
            hasManagedVM: true,
            testRootOverrideEnabled: true,
            currentRunID: UUID()
        )

        planner.autoSyncChecklist(
            with: ReadinessChecklistSignals(
                snapshot: snapshot,
                preflightEvidenceExists: true,
                securityFlowReady: true,
                buildPassed: true,
                testsPassed: true
            )
        )

        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "environment-prereqs" })?.isSatisfied ?? false)
        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "lifecycle-states" })?.isSatisfied ?? false)
        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "observability-enabled" })?.isSatisfied ?? false)
        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "automation-passing" })?.isSatisfied ?? false)
        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "blockers-cleared" })?.isSatisfied ?? false)
    }

    @MainActor
    func testChecklistAutoSyncMarksFailuresWhenSignalsAreBad() {
        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .intel, cpuCores: 1, memoryGB: 4, macOSVersion: "test"),
            virtualizationSupported: false,
            catalogHasArtifacts: false,
            catalogErrorMessage: "catalog failed",
            installLifecycleState: .failed,
            hasManagedVM: false,
            testRootOverrideEnabled: false,
            currentRunID: nil
        )

        planner.autoSyncChecklist(
            with: ReadinessChecklistSignals(
                snapshot: snapshot,
                preflightEvidenceExists: true,
                securityFlowReady: false,
                buildPassed: false,
                testsPassed: false
            )
        )

        XCTAssertFalse(planner.readinessCriteria.first(where: { $0.id == "environment-prereqs" })?.isSatisfied ?? true)
        XCTAssertFalse(planner.readinessCriteria.first(where: { $0.id == "lifecycle-states" })?.isSatisfied ?? true)
        XCTAssertFalse(planner.readinessCriteria.first(where: { $0.id == "security-flow" })?.isSatisfied ?? true)
        XCTAssertFalse(planner.readinessCriteria.first(where: { $0.id == "automation-passing" })?.isSatisfied ?? true)
        XCTAssertFalse(planner.readinessCriteria.first(where: { $0.id == "blockers-cleared" })?.isSatisfied ?? true)
    }

    @MainActor
    func testChecklistAutoSyncKeepsTestModeSatisfiedInNormalRuntimeMode() {
        let planner = BlueprintPlanner()
        planner.setReadinessCriterion(id: "test-mode", isSatisfied: true)

        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "test"),
            virtualizationSupported: true,
            catalogHasArtifacts: true,
            catalogErrorMessage: "",
            installLifecycleState: .ready,
            hasManagedVM: true,
            testRootOverrideEnabled: false,
            currentRunID: UUID()
        )

        planner.autoSyncChecklist(
            with: ReadinessChecklistSignals(
                snapshot: snapshot,
                preflightEvidenceExists: true,
                securityFlowReady: true,
                buildPassed: nil,
                testsPassed: nil
            )
        )

        XCTAssertTrue(planner.readinessCriteria.first(where: { $0.id == "test-mode" })?.isSatisfied ?? false)
    }

    @MainActor
    func testLivePreflightSignalsCanReachGoInNormalRuntimeMode() {
        let planner = BlueprintPlanner()
        let snapshot = ReadinessPreflightSnapshot(
            hostProfile: HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "test"),
            virtualizationSupported: true,
            catalogHasArtifacts: true,
            catalogErrorMessage: "",
            installLifecycleState: .ready,
            hasManagedVM: true,
            testRootOverrideEnabled: false,
            currentRunID: UUID()
        )

        planner.applyPreflightScan(snapshot)
        planner.autoSyncChecklist(
            with: ReadinessChecklistSignals(
                snapshot: snapshot,
                preflightEvidenceExists: true,
                securityFlowReady: true,
                buildPassed: nil,
                testsPassed: nil
            )
        )

        XCTAssertTrue(planner.isReadyForEnvironmentTesting)
        XCTAssertTrue(planner.startEnvironmentTestingIfReady())
        XCTAssertTrue(planner.environmentTestingStarted)
    }

    @MainActor
    func testStartEnvironmentTestingBlocksOnNoGoAndPersistsDecisionReport() {
        let planner = BlueprintPlanner()
        let started = planner.startEnvironmentTestingIfReady()

        XCTAssertFalse(started)
        XCTAssertFalse(planner.environmentTestingStarted)
        XCTAssertTrue(planner.environmentTestStartStatusMessage.contains("NO-GO"))
        XCTAssertFalse(planner.lastGoNoGoReportPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planner.lastGoNoGoReportPath))
    }

    @MainActor
    func testStartEnvironmentTestingAllowsGoWhenAllCriteriaSatisfied() {
        let planner = BlueprintPlanner()
        for criterion in planner.readinessCriteria {
            planner.setReadinessCriterion(id: criterion.id, isSatisfied: true)
        }

        let started = planner.startEnvironmentTestingIfReady()

        XCTAssertTrue(started)
        XCTAssertTrue(planner.environmentTestingStarted)
        XCTAssertTrue(planner.environmentTestStartStatusMessage.contains("GO"))
        XCTAssertFalse(planner.lastGoNoGoReportPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planner.lastGoNoGoReportPath))
    }

    @MainActor
    func testPhaseMilestonesDefaultToPending() {
        let planner = BlueprintPlanner()
        XCTAssertEqual(planner.phaseMilestones.count, 2)
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-1" })?.status, .pending)
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-2" })?.status, .pending)
        XCTAssertEqual(planner.phaseProgressSummary, "0/2 phases complete")
    }

    @MainActor
    func testPhaseMilestonesAdvanceWithReadinessSignals() {
        let planner = BlueprintPlanner()

        planner.syncPhaseMilestones(
            coherenceReady: true,
            deviceMediaReady: false,
            displayV2Ready: false
        )
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-1" })?.status, .inProgress)
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-2" })?.status, .inProgress)

        planner.syncPhaseMilestones(
            coherenceReady: true,
            deviceMediaReady: true,
            displayV2Ready: true
        )
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-1" })?.status, .complete)
        XCTAssertEqual(planner.phaseMilestones.first(where: { $0.id == "phase-2" })?.status, .complete)
        XCTAssertEqual(planner.phaseProgressSummary, "2/2 phases complete")
    }

    @MainActor
    func testDeliveryActionItemsDefaultToPending() {
        let planner = BlueprintPlanner()
        XCTAssertFalse(planner.deliveryActionItems.isEmpty)
        XCTAssertTrue(planner.deliveryActionItems.allSatisfy { $0.status == .pending })
        XCTAssertTrue(planner.deliveryActionProgressSummary.contains("0/"))
    }

    @MainActor
    func testDeliveryActionItemsSyncToInProgressFromGateSignals() {
        let planner = BlueprintPlanner()
        planner.syncDeliveryActionItems(
            plannerReady: true,
            phaseSweepReady: true,
            phase2DisplayReady: true
        )

        XCTAssertEqual(
            planner.deliveryActionItems.first(where: { $0.id == "linux-window-coherence" })?.status,
            .inProgress
        )
        XCTAssertEqual(
            planner.deliveryActionItems.first(where: { $0.id == "multi-display-runtime" })?.status,
            .inProgress
        )
        XCTAssertEqual(
            planner.deliveryActionItems.first(where: { $0.id == "device-passthrough" })?.status,
            .inProgress
        )
    }

    @MainActor
    func testCompleteDeliveryActionMarksItemCompleteAndUpdatesProgress() {
        let planner = BlueprintPlanner()
        XCTAssertEqual(planner.deliveryActionProgressSummary, "0/9 delivery actions complete")

        let completed = planner.completeDeliveryAction(id: "linux-window-coherence")
        XCTAssertTrue(completed)
        XCTAssertEqual(
            planner.deliveryActionItems.first(where: { $0.id == "linux-window-coherence" })?.status,
            .complete
        )
        XCTAssertEqual(planner.deliveryActionProgressSummary, "1/9 delivery actions complete")
    }

    @MainActor
    func testCompleteDeliveryActionReturnsFalseForUnknownID() {
        let planner = BlueprintPlanner()
        let completed = planner.completeDeliveryAction(id: "does-not-exist")
        XCTAssertFalse(completed)
        XCTAssertEqual(planner.deliveryActionProgressSummary, "0/9 delivery actions complete")
    }

    @MainActor
    func testResetDeliveryActionToPendingRevertsStatusAndProgress() {
        let planner = BlueprintPlanner()
        _ = planner.completeDeliveryAction(id: "linux-window-coherence")
        XCTAssertEqual(planner.deliveryActionProgressSummary, "1/9 delivery actions complete")

        let reset = planner.resetDeliveryActionToPending(id: "linux-window-coherence")
        XCTAssertTrue(reset)
        XCTAssertEqual(
            planner.deliveryActionItems.first(where: { $0.id == "linux-window-coherence" })?.status,
            .pending
        )
        XCTAssertEqual(planner.deliveryActionProgressSummary, "0/9 delivery actions complete")
    }

    @MainActor
    func testResetDeliveryActionToPendingReturnsFalseForUnknownID() {
        let planner = BlueprintPlanner()
        let reset = planner.resetDeliveryActionToPending(id: "does-not-exist")
        XCTAssertFalse(reset)
        XCTAssertEqual(planner.deliveryActionProgressSummary, "0/9 delivery actions complete")
    }

    @MainActor
    func testResetAllDeliveryActionsToPendingClearsProgress() {
        let planner = BlueprintPlanner()
        _ = planner.completeDeliveryAction(id: "linux-window-coherence")
        _ = planner.completeDeliveryAction(id: "launcher-integration")
        XCTAssertEqual(planner.deliveryActionProgressSummary, "2/9 delivery actions complete")

        planner.resetAllDeliveryActionsToPending()
        XCTAssertTrue(planner.deliveryActionItems.allSatisfy { $0.status == .pending })
        XCTAssertEqual(planner.deliveryActionProgressSummary, "0/9 delivery actions complete")
    }

    @MainActor
    func testPhaseStateReportExportPersistsArtifact() throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-phase-state-export-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let planner = BlueprintPlanner()
        planner.syncPhaseMilestones(coherenceReady: true, deviceMediaReady: true, displayV2Ready: false)

        let url = planner.exportPhaseStateReport()
        XCTAssertNotNil(url)
        XCTAssertFalse(planner.lastPhaseStateReportPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planner.lastPhaseStateReportPath))
        XCTAssertTrue(planner.phaseStateExportStatusMessage.contains("exported"))
    }

    @MainActor
    func testPhaseStateReportExportContainsMilestonesAndReadiness() throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-phase-state-content-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let planner = BlueprintPlanner()
        planner.syncPhaseMilestones(coherenceReady: true, deviceMediaReady: false, displayV2Ready: true)
        _ = planner.exportPhaseStateReport()

        let data = try Data(contentsOf: URL(fileURLWithPath: planner.lastPhaseStateReportPath))
        let report = try JSONDecoder().decode(PhaseStateReport.self, from: data)

        XCTAssertEqual(report.phaseMilestones.count, 2)
        XCTAssertTrue(report.readinessSummary.contains("/10"))
        XCTAssertEqual(report.phaseMilestones.first(where: { $0.id == "phase-2" })?.status, .inProgress)
    }

    @MainActor
    func testChronicleBackfillIsAppliedOnce() throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-chronicle-backfill-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let store = DevelopmentChronicleStore()
        let baselineCount = store.entries.count

        store.backfillSessionMilestonesIfNeeded()
        let firstPassCount = store.entries.count
        XCTAssertGreaterThan(firstPassCount, baselineCount)

        store.backfillSessionMilestonesIfNeeded()
        let secondPassCount = store.entries.count
        XCTAssertEqual(secondPassCount, firstPassCount)
        XCTAssertTrue(store.entries.contains { $0.relatedStageID == "backfill-2026-04-runtime-readiness" })
    }

    func testDownloaderFallsBackToMirrorWhenPrimaryFails() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        let session = URLSession(configuration: config)
        let downloader = ResumableArtifactDownloader(session: session)

        let primary = URL(string: "https://primary.example.com/file.iso")!
        let mirror = URL(string: "https://mirror.example.com/file.iso")!

        URLProtocolMock.requestHandler = { request in
            if request.url?.host == "primary.example.com" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("mirror-data".utf8)
            )
        }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-fallback-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await downloader.downloadArtifact(
            primaryURL: primary,
            mirrorURLs: [mirror],
            destinationURL: destination,
            maxRetriesPerURL: 1
        )

        let output = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: output, encoding: .utf8), "mirror-data")
    }

    func testDownloaderResumesFromPartialFileUsingRangeHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        let session = URLSession(configuration: config)
        let downloader = ResumableArtifactDownloader(session: session)

        let fileURL = URL(string: "https://mirror.example.com/resume.iso")!
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: destination) }

        try Data("hello ".utf8).write(to: destination)

        URLProtocolMock.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=6-")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!,
                Data("world".utf8)
            )
        }

        try await downloader.downloadArtifact(
            primaryURL: fileURL,
            mirrorURLs: [],
            destinationURL: destination,
            maxRetriesPerURL: 1
        )

        let output = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: output, encoding: .utf8), "hello world")
    }

    @MainActor
    func testCatalogRefreshRespectsMonitoringIntervalUnlessForced() async {
        let catalog = MockCatalogService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: catalog,
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.refreshCatalog(for: .appleSilicon)
        await viewModel.refreshCatalog(for: .appleSilicon)
        await viewModel.refreshCatalog(for: .appleSilicon, force: true)

        XCTAssertEqual(catalog.fetchCount, 2)
    }

    @MainActor
    func testScaffoldInstallFailsWhenInstallerMissing() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm",
            installerImagePath: "",
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertTrue(viewModel.vmStatusMessage.contains("Provide installer image path"))
        XCTAssertEqual(viewModel.installLifecycleState, .failed)
        XCTAssertTrue(viewModel.installLifecycleDetail.contains("Provide installer image path"))
    }

    @MainActor
    func testScaffoldInstallRejectsUnsupportedInAppDistribution() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .popOS,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-unsupported",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertEqual(viewModel.installLifecycleState, .failed)
        XCTAssertTrue(viewModel.vmStatusMessage.contains("Ubuntu, Fedora, and Debian"))
    }

    @MainActor
    func testIntegrationFailsWithoutActiveVM() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.configureSharedResources()
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("No VM is selected"))
    }

    @MainActor
    func testHealthCheckFailsWithoutActiveVM() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.runHealthCheck()
        XCTAssertTrue(viewModel.healthStatusMessage.contains("No VM is selected"))
    }

    @MainActor
    func testPrepareCoherenceEssentialsConfiguresSharedClipboardAndLauncher() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let integrationService = MockIntegrationService()

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: integrationService,
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-coherence",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.prepareCoherenceEssentials()

        XCTAssertEqual(integrationService.sharedResourcesCalls, 1)
        XCTAssertEqual(integrationService.launcherCalls, 1)
        XCTAssertTrue(viewModel.coherenceSharedFoldersReady)
        XCTAssertTrue(viewModel.coherenceClipboardReady)
        XCTAssertTrue(viewModel.coherenceLauncherReady)
        XCTAssertTrue(viewModel.coherenceWindowPolicyReady)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("Coherence essentials ready"))
        XCTAssertTrue(viewModel.coherenceStatusSummary.contains("Window policy: ready"))
    }

    @MainActor
    func testPrepareCoherenceEssentialsStopsWhenSharedResourcesFail() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let integrationService = MockIntegrationService()
        integrationService.failSharedResources = true

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: integrationService,
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-coherence-fail",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.prepareCoherenceEssentials()

        XCTAssertEqual(integrationService.sharedResourcesCalls, 0)
        XCTAssertEqual(integrationService.launcherCalls, 0)
        XCTAssertFalse(viewModel.coherenceSharedFoldersReady)
        XCTAssertFalse(viewModel.coherenceClipboardReady)
        XCTAssertFalse(viewModel.coherenceLauncherReady)
        XCTAssertFalse(viewModel.coherenceWindowPolicyReady)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("shared resources"))
    }

    @MainActor
    func testPrepareCoherenceEssentialsFailsWhenWindowPolicyArtifactsAreMissing() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let integrationService = MockIntegrationService()
        integrationService.emitWindowCoherenceArtifacts = false

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: integrationService,
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-coherence-window-policy-missing",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.prepareCoherenceEssentials()

        XCTAssertTrue(viewModel.coherenceSharedFoldersReady)
        XCTAssertTrue(viewModel.coherenceClipboardReady)
        XCTAssertTrue(viewModel.coherenceLauncherReady)
        XCTAssertFalse(viewModel.coherenceWindowPolicyReady)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("window policy verification"))
        XCTAssertTrue(viewModel.coherenceStatusSummary.contains("Window policy: pending"))
    }

    @MainActor
    func testAssessDeviceMediaReadinessMarksAllReadyOnCapableHost() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.assessDeviceMediaReadiness()

        XCTAssertTrue(viewModel.deviceAudioReady)
        XCTAssertTrue(viewModel.deviceMicReady)
        XCTAssertTrue(viewModel.deviceCameraReady)
        XCTAssertTrue(viewModel.deviceUSBReady)
        XCTAssertTrue(viewModel.deviceMediaStatusSummary.contains("Audio: ready"))
    }

    @MainActor
    func testAssessDeviceMediaReadinessMarksPendingOnWeakHost() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockWeakHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.assessDeviceMediaReadiness()

        XCTAssertFalse(viewModel.deviceAudioReady)
        XCTAssertFalse(viewModel.deviceMicReady)
        XCTAssertFalse(viewModel.deviceCameraReady)
        XCTAssertFalse(viewModel.deviceUSBReady)
        XCTAssertTrue(viewModel.deviceMediaStatusSummary.contains("pending"))
    }

    @MainActor
    func testAssessDisplayPlanReadinessMarksV2ReadyOnCapableHost() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.assessDisplayPlanReadiness()

        XCTAssertEqual(viewModel.v1DisplayCountLocked, 1)
        XCTAssertEqual(viewModel.v2DisplayTargetCount, 3)
        XCTAssertTrue(viewModel.v2MultiDisplayPlanReady)
        XCTAssertTrue(viewModel.displayPlanStatusSummary.contains("v1 locked to 1 display"))
    }

    @MainActor
    func testAssessDisplayPlanReadinessMarksV2PendingOnWeakHost() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockWeakHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.assessDisplayPlanReadiness()

        XCTAssertEqual(viewModel.v1DisplayCountLocked, 1)
        XCTAssertEqual(viewModel.v2DisplayTargetCount, 3)
        XCTAssertFalse(viewModel.v2MultiDisplayPlanReady)
        XCTAssertTrue(viewModel.displayPlanStatusSummary.contains("pending"))
    }

    @MainActor
    func testObservabilityCapturesCoherenceAndReadinessStages() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let observability = MockObservabilityStore()

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            observability: observability
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-observability",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.prepareCoherenceEssentials()
        await viewModel.assessDeviceMediaReadiness()
        await viewModel.assessDisplayPlanReadiness()

        let stages = await observability.events.map(\.stage)
        XCTAssertTrue(stages.contains(.coherenceEssentials))
        XCTAssertTrue(stages.contains(.deviceMediaReadiness))
        XCTAssertTrue(stages.contains(.displayPlanReadiness))
    }

    @MainActor
    func testRunPhaseSweepReturnsAggregateSummary() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-sweep",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        let summary = await viewModel.runPhaseSweep()
        XCTAssertTrue(summary.contains("Sweep complete"))
        XCTAssertTrue(summary.contains("Coherence"))
        XCTAssertTrue(summary.contains("Device/Media"))
        XCTAssertTrue(summary.contains("Display v2"))
    }

    @MainActor
    func testCurrentPhaseReadinessReflectsAssessedState() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-readiness",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.prepareCoherenceEssentials()
        await viewModel.assessDeviceMediaReadiness()
        await viewModel.assessDisplayPlanReadiness()

        let readiness = viewModel.currentPhaseReadiness()
        XCTAssertTrue(readiness.coherenceReady)
        XCTAssertTrue(readiness.deviceMediaReady)
        XCTAssertTrue(readiness.displayV2Ready)
    }

    @MainActor
    func testPhaseReadinessSummaryUsesPrefixAndStatuses() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-summary",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        _ = await viewModel.runPhaseSweep()
        let summary = viewModel.phaseReadinessSummary(prefix: "Snapshot")
        XCTAssertTrue(summary.contains("Snapshot"))
        XCTAssertTrue(summary.contains("Coherence: ready"))
        XCTAssertTrue(summary.contains("Device/Media: ready"))
        XCTAssertTrue(summary.contains("Display v2: ready"))
    }

    @MainActor
    func testPhaseSweepGateTransitionsFromNoGoToGo() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-gate",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertFalse(viewModel.isPhaseSweepReadyForEnvironmentTesting())
        _ = await viewModel.runPhaseSweep()
        XCTAssertTrue(viewModel.isPhaseSweepReadyForEnvironmentTesting())
    }

    @MainActor
    func testPhaseReadinessSummaryShowsPendingBeforeSweep() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-pending",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        let summary = viewModel.phaseReadinessSummary(prefix: "Gate")
        XCTAssertTrue(summary.contains("Gate"))
        XCTAssertTrue(summary.contains("Coherence: pending"))
        XCTAssertTrue(summary.contains("Device/Media: pending"))
        XCTAssertTrue(summary.contains("Display v2: pending"))
        XCTAssertFalse(viewModel.isPhaseSweepReadyForEnvironmentTesting())
    }

    @MainActor
    func testEnvironmentTestingGateSummaryReflectsPlannerAndPhaseStates() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-gate-summary",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        let pendingSummary = viewModel.environmentTestingGateSummary(plannerReady: false)
        XCTAssertTrue(pendingSummary.contains("Planner: pending"))
        XCTAssertTrue(pendingSummary.contains("Phase sweep: pending"))

        let mixedSummary = viewModel.environmentTestingGateSummary(plannerReady: true)
        XCTAssertTrue(mixedSummary.contains("Planner: ready"))
        XCTAssertTrue(mixedSummary.contains("Phase sweep: pending"))

        _ = await viewModel.runPhaseSweep()
        let goSummary = viewModel.environmentTestingGateSummary(plannerReady: true)
        XCTAssertTrue(goSummary.contains("Planner: ready"))
        XCTAssertTrue(goSummary.contains("Phase sweep: ready"))
    }

    @MainActor
    func testPhaseAndGateSummariesIncludeSchemaInvalidBlocker() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockHealth = MockHealthService()
        mockHealth.nextHealthReport = [
            "OK: Window coherence policy exists",
            "WARN: Window coherence policy schema invalid"
        ]
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: mockHealth,
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-schema-blocker",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.runHealthCheck()

        let phaseSummary = viewModel.phaseReadinessSummary(prefix: "Gate")
        XCTAssertTrue(phaseSummary.contains("Coherence policy schema: invalid"))

        let gateSummary = viewModel.environmentTestingGateSummary(plannerReady: true)
        XCTAssertTrue(gateSummary.contains("Blocker: coherence policy schema invalid"))
    }

    @MainActor
    func testEnvironmentTestingGateReadyRequiresPlannerAndPhaseSweep() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-gate-ready",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertFalse(viewModel.isEnvironmentTestingGateReady(plannerReady: false))
        XCTAssertFalse(viewModel.isEnvironmentTestingGateReady(plannerReady: true))

        _ = await viewModel.runPhaseSweep()
        XCTAssertFalse(viewModel.isEnvironmentTestingGateReady(plannerReady: false))
        XCTAssertTrue(viewModel.isEnvironmentTestingGateReady(plannerReady: true))
    }

    @MainActor
    func testAutoHealAfterScaffoldUpdatesHealthStatus() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        XCTAssertEqual(viewModel.installLifecycleState, .ready)

        await viewModel.applyAutoHeal()
        XCTAssertTrue(viewModel.healthStatusMessage.contains("Auto-heal completed"))
    }

    @MainActor
    func testAutoHealRepairsInvalidWindowPolicySchema() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-auto-heal-window-policy-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: DefaultHealthAndRepairService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-auto-heal-window-policy",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.prepareCoherenceEssentials()

        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected active VM ID after scaffold install.")
            return
        }

        let policyURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .appendingPathComponent("window-coherence-policy.json")
        try Data("{\"vmID\":\"broken\"}".utf8).write(to: policyURL, options: [.atomic])

        await viewModel.runHealthCheck()
        XCTAssertFalse(viewModel.coherenceWindowPolicySchemaValid)

        await viewModel.applyAutoHeal()
        XCTAssertTrue(viewModel.healthStatusMessage.contains("Auto-heal completed"))
        XCTAssertTrue(viewModel.coherenceWindowPolicySchemaValid)
        XCTAssertTrue(viewModel.healthReport.contains("OK: Window coherence policy schema valid"))
    }

    @MainActor
    func testVMRuntimeLifecycleStartStopRestartAfterScaffold() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-runtime",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertEqual(viewModel.vmRuntimeState, .stopped)
        await viewModel.startActiveVM()
        XCTAssertEqual(viewModel.vmRuntimeState, .running)

        await viewModel.stopActiveVM()
        XCTAssertEqual(viewModel.vmRuntimeState, .stopped)

        await viewModel.restartActiveVM()
        XCTAssertEqual(viewModel.vmRuntimeState, .running)
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("restart"))
    }

    @MainActor
    func testRuntimeFleetTrackingForManagedVMStartStop() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-fleet-a",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmA = viewModel.activeVMID else {
            XCTFail("Expected first VM id after scaffold.")
            return
        }

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-fleet-b",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmB = viewModel.activeVMID else {
            XCTFail("Expected second VM id after scaffold.")
            return
        }

        await viewModel.startManagedVM(vmA)
        XCTAssertTrue(viewModel.activeRuntimeVMIDs.contains(vmA))
        XCTAssertTrue(viewModel.runtimeFleetStatusSummary().contains("Running: 1"))

        await viewModel.startManagedVM(vmB)
        XCTAssertTrue(viewModel.activeRuntimeVMIDs.contains(vmA))
        XCTAssertFalse(viewModel.activeRuntimeVMIDs.contains(vmB))
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("Only one VM can run at a time"))

        await viewModel.stopManagedVM(vmA)
        XCTAssertFalse(viewModel.activeRuntimeVMIDs.contains(vmA))
        XCTAssertTrue(viewModel.runtimeFleetStatusSummary().contains("Running: 0"))
    }

    @MainActor
    func testStopAllRunningVMsStopsTrackedRuntimeFleet() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-stop-all",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await viewModel.startManagedVM(vmID)
        XCTAssertTrue(viewModel.activeRuntimeVMIDs.contains(vmID))

        await viewModel.stopAllRunningVMs()
        XCTAssertTrue(viewModel.activeRuntimeVMIDs.isEmpty)
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("Stopped 1 running VM"))
    }

    @MainActor
    func testStopAllRunningVMsNoopWhenNothingRunning() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.stopAllRunningVMs()
        XCTAssertEqual(viewModel.vmRuntimeStatusMessage, "No running VMs to stop.")
    }

    @MainActor
    func testStopAllRunningVMsReportsPartialFailures() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let provisioning = MockProvisioningService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: provisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-stop-fail-a",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmA = viewModel.activeVMID else {
            XCTFail("Expected first VM id after scaffold.")
            return
        }

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-stop-fail-b",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmB = viewModel.activeVMID else {
            XCTFail("Expected second VM id after scaffold.")
            return
        }

        await viewModel.startManagedVM(vmA)
        await provisioning.injectStopFailure(for: vmA)
        await viewModel.stopManagedVM(vmA)
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("Injected stop failure"))

        await viewModel.startManagedVM(vmB)
        await viewModel.stopAllRunningVMs()
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("failed to stop 1 VM"))
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("vm-stop-fail-a"))
    }

    @MainActor
    func testFleetDiagnosticsCaptureStartFailure() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let provisioning = MockProvisioningService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: provisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-start-fail",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await provisioning.injectStartFailure(for: vmID)
        await viewModel.startManagedVM(vmID)
        let diagnostic = viewModel.fleetDiagnostic(for: vmID)
        XCTAssertEqual(diagnostic?.lastAction, "start")
        XCTAssertTrue(diagnostic?.lastErrorMessage?.contains("Injected start failure") == true)
    }

    @MainActor
    func testFleetDiagnosticsCaptureStopFailure() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let provisioning = MockProvisioningService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: provisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-stop-fail-diagnostic",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await viewModel.startManagedVM(vmID)
        await provisioning.injectStopFailure(for: vmID)
        _ = await viewModel.stopManagedVM(vmID)
        let diagnostic = viewModel.fleetDiagnostic(for: vmID)
        XCTAssertEqual(diagnostic?.lastAction, "stop")
        XCTAssertTrue(diagnostic?.lastErrorMessage?.contains("Injected stop failure") == true)
    }

    @MainActor
    func testFleetEntriesFilterByRuntimeState() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-fleet-filter-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let provisioning = MockProvisioningService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: provisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-running",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let runningVM = viewModel.activeVMID else {
            XCTFail("Expected running VM id.")
            return
        }
        await viewModel.startManagedVM(runningVM)

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-failed",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let failedVM = viewModel.activeVMID else {
            XCTFail("Expected failed VM id.")
            return
        }
        await provisioning.injectStartFailure(for: failedVM)
        await viewModel.startManagedVM(failedVM)

        await viewModel.scaffoldInstall(
            distribution: .fedora,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-stopped",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let stoppedVM = viewModel.activeVMID else {
            XCTFail("Expected stopped VM id.")
            return
        }

        XCTAssertEqual(Set(viewModel.fleetEntries(filteredBy: .running).map(\.id)), [runningVM])
        XCTAssertEqual(Set(viewModel.fleetEntries(filteredBy: .failed).map(\.id)), [failedVM])
        XCTAssertEqual(Set(viewModel.fleetEntries(filteredBy: .stopped).map(\.id)), [stoppedVM])
    }

    @MainActor
    func testFleetEntriesSortByStatePriorityThenName() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-fleet-sort-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let provisioning = MockProvisioningService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: provisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "z-running",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let runningVM = viewModel.activeVMID else {
            XCTFail("Expected running VM id.")
            return
        }
        await viewModel.startManagedVM(runningVM)

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "a-failed",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let failedVM = viewModel.activeVMID else {
            XCTFail("Expected failed VM id.")
            return
        }
        await provisioning.injectStartFailure(for: failedVM)
        await viewModel.startManagedVM(failedVM)

        await viewModel.scaffoldInstall(
            distribution: .fedora,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "a-stopped",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let stoppedA = viewModel.activeVMID else {
            XCTFail("Expected first stopped VM id.")
            return
        }

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "b-stopped",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let stoppedB = viewModel.activeVMID else {
            XCTFail("Expected second stopped VM id.")
            return
        }

        let orderedNames = viewModel.fleetEntries(filteredBy: .all).map(\.vmName)
        XCTAssertEqual(orderedNames, ["z-running", "a-failed", "a-stopped", "b-stopped"])
        XCTAssertNotEqual(stoppedA, stoppedB)
    }

    @MainActor
    func testOnlyOneVMCanRunAtATimeAcrossSessions() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let sharedProvisioning = MockProvisioningService()
        let first = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: sharedProvisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        let second = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: sharedProvisioning,
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await first.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-one",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await second.scaffoldInstall(
            distribution: .fedora,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-two",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await first.startActiveVM()
        XCTAssertEqual(first.vmRuntimeState, .running)

        await second.startActiveVM()
        XCTAssertEqual(second.vmRuntimeState, .failed)
        XCTAssertTrue(second.vmRuntimeStatusMessage.contains("Only one VM can run at a time"))
    }

    @MainActor
    func testStartVMFailsWithoutActiveVM() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.startActiveVM()
        XCTAssertTrue(viewModel.vmRuntimeStatusMessage.contains("No VM is selected"))
    }

    @MainActor
    func testUninstallFailsWithoutActiveVM() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            downloader: MockDownloader()
        )

        await viewModel.uninstallActiveVM(removeArtifacts: true)
        XCTAssertTrue(viewModel.cleanupStatusMessage.contains("No VM is selected"))
    }

    @MainActor
    func testCleanupVerificationUsesLastManagedVM() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-cleanup",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.uninstallActiveVM(removeArtifacts: true)
        XCTAssertTrue(viewModel.cleanupStatusMessage.contains("Uninstall completed"))
        XCTAssertFalse(viewModel.cleanupReport.isEmpty)
        XCTAssertEqual(viewModel.installLifecycleState, .idle)

        await viewModel.verifyCleanupForLastKnownVM()
        XCTAssertTrue(viewModel.cleanupStatusMessage.contains("Cleanup verification completed"))
    }

    @MainActor
    func testEscalationRequiresTitle() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.escalateToDevelopers(
            issueTitle: "",
            issueDetails: "detail",
            githubOwner: "owner",
            githubRepository: "repo",
            githubToken: "token",
            supportEmail: "test@example.com",
            sendGitHubIssue: true,
            sendEmail: false,
            includeDiagnostics: true
        )

        XCTAssertTrue(viewModel.escalationStatusMessage.contains("requires an issue title"))
    }

    @MainActor
    func testEscalationCreatesIssueURLWithMockService() async {
        let mock = MockEscalationService()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: mock,
            downloader: MockDownloader()
        )

        await viewModel.escalateToDevelopers(
            issueTitle: "Issue",
            issueDetails: "Details",
            githubOwner: "owner",
            githubRepository: "repo",
            githubToken: "token",
            supportEmail: "support@example.com",
            sendGitHubIssue: true,
            sendEmail: true,
            includeDiagnostics: true
        )

        XCTAssertNotNil(viewModel.lastEscalationIssueURL)
        XCTAssertTrue(viewModel.escalationStatusMessage.contains("GitHub issue created"))
    }

    func testDefaultIntegrationServiceProducesPackageArtifacts() async throws {
        let service = DefaultIntegrationService()
        let vmID = UUID()

        try await service.configureSharedResources(for: vmID)
        try await service.configureLauncherEntries(for: vmID)
        try await service.enableRootlessLinuxApps(for: vmID)

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let integrationDir = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)

        let expectedFiles = [
            "shared-resources.json",
            "window-coherence-policy.json",
            "launcher-manifest.json",
            "rootless-apps.json",
            "integration-state.json",
            "host-scripts/apply-window-coherence.command",
            "host-scripts/launch-linux-terminal.command",
            "host-scripts/launch-linux-files.command",
            "host-scripts/launch-linux-browser.command",
            "host-scripts/attach-rootless.command",
            "guest-scripts/setup-shared-resources.sh",
            "guest-scripts/refresh-launchers.sh",
            "guest-scripts/bootstrap-rootless.sh"
        ]

        for relative in expectedFiles {
            let fileURL = integrationDir.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Missing integration artifact: \(relative)")
        }

        let stateURL = integrationDir.appendingPathComponent("integration-state.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try JSONDecoder().decode(IntegrationPackageState.self, from: stateData)
        XCTAssertEqual(state.vmID, vmID.uuidString)
        XCTAssertTrue(state.windowPolicyConfigPath.hasSuffix("window-coherence-policy.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.windowPolicyConfigPath))
    }

    @MainActor
    func testIntegrationCapabilitiesSyncAfterCoherencePreparation() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-capabilities-sync-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-sync",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await viewModel.prepareCoherenceEssentials()

        let capabilities = viewModel.integrationCapabilities(for: vmID)
        XCTAssertTrue(capabilities.sharedFoldersConfigured)
        XCTAssertTrue(capabilities.clipboardSyncEnabled)
        XCTAssertEqual(capabilities.launcherEntries.count, 3)
        XCTAssertTrue(capabilities.launcherEntries.contains(where: { $0.name == "Linux Terminal" }))
    }

    @MainActor
    func testIntegrationCapabilitiesRemainEmptyWhenArtifactsUnavailable() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-capabilities-missing-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let integrationService = MockIntegrationService()
        integrationService.emitWindowCoherenceArtifacts = false
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: integrationService,
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-empty",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        let capabilities = viewModel.integrationCapabilities(for: vmID)
        XCTAssertFalse(capabilities.sharedFoldersConfigured)
        XCTAssertFalse(capabilities.clipboardSyncEnabled)
        XCTAssertTrue(capabilities.launcherEntries.isEmpty)
    }

    @MainActor
    func testLaunchIntegratedAppExecutesLauncherScriptAndUpdatesDiagnostics() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-exec-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockExecutor = MockLauncherScriptExecutor()
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-exec",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)

        XCTAssertEqual(mockExecutor.executedScriptPaths.count, 1)
        XCTAssertEqual(mockExecutor.executedScriptPaths.first, launcherEntry.scriptPath)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("Launched \(launcherEntry.name)"))
        XCTAssertEqual(viewModel.launcherRunState(for: vmID)?.launcherName, launcherEntry.name)
        XCTAssertEqual(viewModel.launcherRunState(for: vmID)?.status, .succeeded)
        XCTAssertEqual(viewModel.fleetDiagnostic(for: vmID)?.lastErrorMessage, nil)
    }

    @MainActor
    func testLaunchIntegratedAppReportsMissingEntry() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-missing-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-missing",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else {
            XCTFail("Expected VM id after scaffold.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: "missing-entry")
        XCTAssertEqual(viewModel.integrationStatusMessage, "Launcher entry is no longer available for this VM.")
    }

    @MainActor
    func testLaunchIntegratedAppRetriesAndRecoversOnSecondAttempt() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-retry-recover-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockExecutor = MockLauncherScriptExecutor()
        mockExecutor.queuedErrors = [RuntimeServiceError.commandFailed("transient failure")]

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-retry-recover",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)

        XCTAssertEqual(mockExecutor.executedScriptPaths.count, 2)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("recovered on retry 2/2"))
        XCTAssertEqual(viewModel.launcherRunState(for: vmID)?.status, .succeeded)
        XCTAssertEqual(viewModel.fleetDiagnostic(for: vmID)?.lastErrorMessage, nil)
    }

    @MainActor
    func testLaunchIntegratedAppFailsAfterRetryBudgetExhausted() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-retry-fail-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockExecutor = MockLauncherScriptExecutor()
        mockExecutor.nextError = RuntimeServiceError.commandFailed("persistent failure")

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-retry-fail",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)

        XCTAssertEqual(mockExecutor.executedScriptPaths.count, 2)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("after 2 attempt(s)"))
        XCTAssertEqual(viewModel.launcherRunState(for: vmID)?.status, .failed)
        XCTAssertNotNil(viewModel.fleetDiagnostic(for: vmID)?.lastErrorMessage)
    }

    @MainActor
    func testLauncherRunHistoryRetainsLatestTenEntriesPerVM() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-history-retain-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let mockExecutor = MockLauncherScriptExecutor()

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-history-retain",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        for _ in 0..<12 {
            await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)
        }

        XCTAssertEqual(viewModel.launcherRunHistory(for: vmID).count, 10)
        XCTAssertEqual(viewModel.launcherRunState(for: vmID)?.status, .succeeded)
    }

    @MainActor
    func testLauncherRunHistoryPersistsAcrossViewModelRelaunch() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-history-persist-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let mockExecutor = MockLauncherScriptExecutor()

        let first = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await first.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-history-persist",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = first.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await first.prepareCoherenceEssentials()
        guard let launcherEntry = first.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }
        await first.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)

        let second = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        let history = second.launcherRunHistory(for: vmID)
        XCTAssertFalse(history.isEmpty)
        XCTAssertEqual(history.first?.status, .succeeded)
        XCTAssertEqual(second.launcherRunState(for: vmID)?.status, .succeeded)
    }

    @MainActor
    func testClearLauncherRunHistoryBlockedWhenNotArmed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-history-clear-blocked-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-history-clear-blocked",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }
        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)
        XCTAssertFalse(viewModel.launcherRunHistory(for: vmID).isEmpty)

        viewModel.confirmClearLauncherRunHistory(vmID: vmID)
        XCTAssertFalse(viewModel.launcherRunHistory(for: vmID).isEmpty)
        XCTAssertEqual(viewModel.integrationStatusMessage, "Launcher history clear blocked. Arm deletion first.")
    }

    @MainActor
    func testClearLauncherRunHistorySucceedsWhenArmed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-history-clear-armed-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-history-clear-armed",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }
        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)
        viewModel.armIntegrationRemediationDeletion()
        viewModel.confirmClearLauncherRunHistory(vmID: vmID)

        XCTAssertTrue(viewModel.launcherRunHistory(for: vmID).isEmpty)
        XCTAssertNil(viewModel.launcherRunState(for: vmID))
        XCTAssertFalse(viewModel.integrationRemediationDeletionArmed)
    }

    @MainActor
    func testExportLauncherRunHistoryWritesJsonArtifact() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-history-export-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-history-export",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }
        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)

        viewModel.exportLauncherRunHistory(vmID: vmID)

        let exportDir = RuntimeEnvironment.mlIntegrationRootURL().appendingPathComponent("launcher-run-history-exports", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("Exported launcher history:"))
    }

    @MainActor
    func testLauncherRunHistoryExportsDirectoryUsesTestRoot() {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-export-dir-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        let exportDirectory = viewModel.launcherRunHistoryExportsDirectory()
        XCTAssertTrue(exportDirectory.path.hasSuffix("launcher-run-history-exports"))
        XCTAssertTrue(exportDirectory.path.contains(testRoot.path))
    }

    @MainActor
    func testLauncherRunHistoryPreviewReturnsLatestThreeEntries() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-preview-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-preview",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        for _ in 0..<4 {
            await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)
        }
        let preview = viewModel.launcherRunHistoryPreview(vmID: vmID, limit: 3)
        XCTAssertEqual(preview.count, 3)
        XCTAssertTrue(preview.allSatisfy { $0.contains(launcherEntry.name) })
    }

    @MainActor
    func testLauncherRunHistoryPreviewFiltersByStatus() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-preview-filter-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let mockExecutor = MockLauncherScriptExecutor()
        mockExecutor.nextError = RuntimeServiceError.commandFailed("forced failure")

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: mockExecutor
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-preview-filter",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        guard let launcherEntry = viewModel.integrationCapabilities(for: vmID).launcherEntries.first else {
            XCTFail("Expected launcher entry after coherence preparation.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: launcherEntry.id)
        let failedPreview = viewModel.launcherRunHistoryPreview(vmID: vmID, statusFilter: .failed, limit: 3)
        let successPreview = viewModel.launcherRunHistoryPreview(vmID: vmID, statusFilter: .succeeded, limit: 3)

        XCTAssertFalse(failedPreview.isEmpty)
        XCTAssertTrue(failedPreview.allSatisfy { $0.contains("Failed") })
        XCTAssertTrue(successPreview.isEmpty)
    }

    @MainActor
    func testLauncherRunHistoryPreviewFiltersByStatusAndSearchTerm() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-launcher-preview-filter-search-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            launcherExecutor: MockLauncherScriptExecutor()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-launcher-preview-filter-search",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id after scaffold."); return }
        await viewModel.prepareCoherenceEssentials()
        let entries = viewModel.integrationCapabilities(for: vmID).launcherEntries
        guard entries.count >= 2 else {
            XCTFail("Expected at least two launcher entries.")
            return
        }

        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: entries[0].id)
        await viewModel.launchIntegratedApp(vmID: vmID, launcherEntryID: entries[1].id)

        let specific = viewModel.launcherRunHistoryPreview(
            vmID: vmID,
            statusFilter: .succeeded,
            searchTerm: entries[0].name,
            limit: 3
        )
        let missing = viewModel.launcherRunHistoryPreview(
            vmID: vmID,
            statusFilter: .succeeded,
            searchTerm: "no-match-term",
            limit: 3
        )

        XCTAssertFalse(specific.isEmpty)
        XCTAssertTrue(specific.allSatisfy { $0.localizedCaseInsensitiveContains(entries[0].name) })
        XCTAssertTrue(missing.isEmpty)
    }

    @MainActor
    func testVerifySharedFolderAndClipboardPassesWhenArtifactsValid() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-verify-io-pass-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-verify-pass",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }
        await viewModel.prepareCoherenceEssentials()

        await viewModel.verifySharedFolderAndClipboard(vmID: vmID)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("verification passed"))
        XCTAssertEqual(viewModel.fleetDiagnostic(for: vmID)?.lastAction, "verify-io")
        XCTAssertNil(viewModel.fleetDiagnostic(for: vmID)?.lastErrorMessage)
    }

    @MainActor
    func testVerifySharedFolderAndClipboardFailsWhenFolderMissing() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-verify-io-fail-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-verify-fail",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }
        await viewModel.prepareCoherenceEssentials()

        let sharedResourcesURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .appendingPathComponent("shared-resources.json")
        let data = try Data(contentsOf: sharedResourcesURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sharedFolders = object["sharedFolders"] as? [[String: Any]],
              !sharedFolders.isEmpty else {
            XCTFail("Expected sharedFolders payload.")
            return
        }
        sharedFolders[0]["hostPath"] = "/tmp/ml-integration-does-not-exist-\(UUID().uuidString)"
        object["sharedFolders"] = sharedFolders
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try mutated.write(to: sharedResourcesURL, options: [.atomic])

        await viewModel.verifySharedFolderAndClipboard(vmID: vmID)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("verification failed"))
        XCTAssertEqual(viewModel.fleetDiagnostic(for: vmID)?.lastAction, "verify-io")
        XCTAssertNotNil(viewModel.fleetDiagnostic(for: vmID)?.lastErrorMessage)
    }

    @MainActor
    func testIntegrationHealthBadgeIsHealthyWhenAllSignalsReady() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-badge-healthy-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-badge-healthy",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }
        await viewModel.prepareCoherenceEssentials()

        let badge = viewModel.integrationHealthBadge(for: vmID)
        XCTAssertEqual(badge.status, .healthy)
    }

    @MainActor
    func testIntegrationHealthBadgeIsWarningWhenPartiallyConfigured() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-badge-warning-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-badge-warning",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.configureSharedResources()
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }

        let badge = viewModel.integrationHealthBadge(for: vmID)
        XCTAssertEqual(badge.status, .warning)
    }

    @MainActor
    func testIntegrationHealthBadgeIsWarningWhenWindowPolicySchemaInvalid() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-badge-schema-warning-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-badge-schema-warning",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }
        await viewModel.prepareCoherenceEssentials()

        let policyURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .appendingPathComponent("window-coherence-policy.json")
        try Data("{\"vmID\":\"broken\"}".utf8).write(to: policyURL, options: [.atomic])

        let badge = viewModel.integrationHealthBadge(for: vmID)
        XCTAssertEqual(badge.status, .warning)
        XCTAssertTrue(badge.summary.contains("schema invalid"))
    }

    @MainActor
    func testIntegrationHealthBadgeIsErrorWhenNotConfigured() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-badge-error-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-badge-error",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }

        let badge = viewModel.integrationHealthBadge(for: vmID)
        XCTAssertEqual(badge.status, .error)
    }

    @MainActor
    func testRuntimeFleetStatusSummaryIncludesIntegrationHealthRollups() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-fleet-rollup-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-rollup-healthy",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmHealthy = viewModel.activeVMID else { XCTFail("Expected healthy VM id."); return }
        await viewModel.prepareCoherenceEssentials()

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-rollup-warning",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmWarning = viewModel.activeVMID else { XCTFail("Expected warning VM id."); return }
        await viewModel.configureSharedResources()

        await viewModel.scaffoldInstall(
            distribution: .fedora,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-rollup-error",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmError = viewModel.activeVMID else { XCTFail("Expected error VM id."); return }

        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmHealthy).status, .healthy)
        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmWarning).status, .warning)
        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmError).status, .error)

        let summary = viewModel.runtimeFleetStatusSummary()
        XCTAssertTrue(summary.contains("Healthy: 1"))
        XCTAssertTrue(summary.contains("Warning: 1"))
        XCTAssertTrue(summary.contains("Error: 1"))
    }

    @MainActor
    func testFixAllIntegrationWarningsAggregatesResultAcrossFleet() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-fix-all-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-fix-warning",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmWarning = viewModel.activeVMID else { XCTFail("Expected warning VM id."); return }
        await viewModel.configureSharedResources()

        await viewModel.scaffoldInstall(
            distribution: .debian,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-fix-error",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmError = viewModel.activeVMID else { XCTFail("Expected error VM id."); return }

        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmWarning).status, .warning)
        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmError).status, .error)

        await viewModel.fixAllIntegrationWarnings()

        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmWarning).status, .healthy)
        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmError).status, .healthy)
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("Fixed 2 VM"))
        XCTAssertTrue(viewModel.integrationStatusMessage.contains("warnings cleared"))
        XCTAssertFalse(viewModel.lastIntegrationRemediationReportPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewModel.lastIntegrationRemediationReportPath))

        let reportData = try Data(contentsOf: URL(fileURLWithPath: viewModel.lastIntegrationRemediationReportPath))
        let report = try JSONDecoder().decode(IntegrationRemediationRunReport.self, from: reportData)
        XCTAssertEqual(report.attemptedCount, 2)
        XCTAssertEqual(report.fixedCount, 2)
        XCTAssertEqual(report.remainingCount, 0)
        XCTAssertEqual(report.vmResults.count, 2)
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Attempted: 2"))
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Fixed: 2"))
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportResults.count, 2)
    }

    @MainActor
    func testFixAllIntegrationWarningsNoopWhenFleetHealthy() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-fix-all-noop-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-fix-noop",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        guard let vmID = viewModel.activeVMID else { XCTFail("Expected VM id."); return }
        await viewModel.prepareCoherenceEssentials()
        XCTAssertEqual(viewModel.integrationHealthBadge(for: vmID).status, .healthy)

        await viewModel.fixAllIntegrationWarnings()
        XCTAssertEqual(viewModel.integrationStatusMessage, "No warning/error VMs require remediation.")
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportPath.isEmpty)
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportResults.isEmpty)
    }

    @MainActor
    func testReloadLastIntegrationRemediationReportSummaryReadsSavedReport() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-remediation-summary-reload-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-reload-summary",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.configureSharedResources()
        await viewModel.fixAllIntegrationWarnings()
        XCTAssertFalse(viewModel.lastIntegrationRemediationReportPath.isEmpty)

        // Clear and force reload from disk.
        viewModel.reloadLastIntegrationRemediationReportSummary()
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Attempted:"))
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Fixed:"))
    }

    @MainActor
    func testRefreshIntegrationRemediationReportHistoryIncludesLatestReport() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-remediation-history-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-history",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.configureSharedResources()
        await viewModel.fixAllIntegrationWarnings()

        let expectedPath = viewModel.lastIntegrationRemediationReportPath
        XCTAssertFalse(expectedPath.isEmpty)

        viewModel.refreshIntegrationRemediationReportHistory()
        XCTAssertFalse(viewModel.integrationRemediationReportHistory.isEmpty)
        XCTAssertEqual(viewModel.integrationRemediationReportHistory.first?.path, expectedPath)
    }

    @MainActor
    func testLoadIntegrationRemediationReportSetsPathAndSummary() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-remediation-load-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-load-report",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.configureSharedResources()
        await viewModel.fixAllIntegrationWarnings()

        let savedPath = viewModel.lastIntegrationRemediationReportPath
        XCTAssertFalse(savedPath.isEmpty)

        // Reset then load from selected path.
        viewModel.loadIntegrationRemediationReport(atPath: savedPath)
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportPath, savedPath)
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Attempted:"))
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportSummary.contains("Remaining:"))
        XCTAssertFalse(viewModel.lastIntegrationRemediationReportResults.isEmpty)
    }

    @MainActor
    func testReloadLastIntegrationRemediationReportSummaryClearsResultsWhenNoPath() {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.reloadLastIntegrationRemediationReportSummary()
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportSummary, "")
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportResults.isEmpty)
    }

    @MainActor
    func testFilteredIntegrationRemediationReportHistoryMatchesSearchTerm() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-search-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: DefaultIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-history-search",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.configureSharedResources()
        await viewModel.fixAllIntegrationWarnings()
        viewModel.refreshIntegrationRemediationReportHistory()

        let all = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: "",
            statusFilter: .all,
            recentFirst: true
        )
        XCTAssertFalse(all.isEmpty)
        let jsonOnly = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: ".json",
            statusFilter: .all,
            recentFirst: true
        )
        XCTAssertEqual(jsonOnly.count, all.count)
        let noMatch = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: "definitely-no-match-token",
            statusFilter: .all,
            recentFirst: true
        )
        XCTAssertTrue(noMatch.isEmpty)
    }

    @MainActor
    func testIntegrationRemediationReportHistoryRetentionCapsToLimit() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-retention-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        for index in 0..<30 {
            let report = IntegrationRemediationRunReport(
                id: UUID(),
                timestampISO8601: ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(index))),
                attemptedCount: 1,
                fixedCount: 1,
                remainingCount: 0,
                vmResults: []
            )
            let data = try JSONEncoder().encode(report)
            let fileURL = reportsDirectory.appendingPathComponent(String(format: "report-%02d.json", index))
            try data.write(to: fileURL, options: [.atomic])
        }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.refreshIntegrationRemediationReportHistory()

        XCTAssertEqual(viewModel.integrationRemediationReportHistory.count, 25)
    }

    @MainActor
    func testFilteredIntegrationRemediationReportHistorySupportsStatusAndSortControls() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-controls-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let older = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 2,
            fixedCount: 2,
            remainingCount: 0,
            vmResults: []
        )
        let newer = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30)),
            attemptedCount: 2,
            fixedCount: 1,
            remainingCount: 1,
            vmResults: []
        )
        let olderURL = reportsDirectory.appendingPathComponent("older.json")
        let newerURL = reportsDirectory.appendingPathComponent("newer.json")
        try encoder.encode(older).write(to: olderURL, options: [.atomic])
        try encoder.encode(newer).write(to: newerURL, options: [.atomic])
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: olderURL.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newerURL.path)

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.refreshIntegrationRemediationReportHistory()

        let fullyFixed = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: "",
            statusFilter: .fullyFixed,
            recentFirst: true
        )
        XCTAssertTrue(fullyFixed.contains(where: { $0.fileName == "older.json" }))
        XCTAssertFalse(fullyFixed.contains(where: { $0.fileName == "newer.json" }))

        let hasRemaining = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: "",
            statusFilter: .hasRemaining,
            recentFirst: true
        )
        XCTAssertTrue(hasRemaining.contains(where: { $0.fileName == "newer.json" }))
        XCTAssertFalse(hasRemaining.contains(where: { $0.fileName == "older.json" }))

        let ascending = viewModel.filteredIntegrationRemediationReportHistory(
            searchTerm: "",
            statusFilter: .all,
            recentFirst: false
        )
        XCTAssertEqual(ascending.first?.fileName, "older.json")
    }

    @MainActor
    func testIntegrationRemediationReportsDirectoryURLUsesTestRoot() {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-reports-dir-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        let reportsDirectory = viewModel.integrationRemediationReportsDirectoryURL()
        XCTAssertTrue(reportsDirectory.path.hasSuffix("integration-remediation-reports"))
        XCTAssertTrue(reportsDirectory.path.contains(testRoot.path))
    }

    @MainActor
    func testLoadIntegrationRemediationReportInvalidPathSetsLoadFailureSummary() {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.loadIntegrationRemediationReport(atPath: "/tmp/does-not-exist-report.json")
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportPath, "/tmp/does-not-exist-report.json")
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportSummary, "Last remediation report could not be loaded.")
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportResults.isEmpty)
    }

    @MainActor
    func testImportIntegrationRemediationReportCopiesValidReportIntoManagedFolder() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-import-report-valid-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-import-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDirectory) }

        let externalReportURL = externalDirectory.appendingPathComponent("external-valid.json")
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 2,
            fixedCount: 1,
            remainingCount: 1,
            vmResults: []
        )
        try JSONEncoder().encode(report).write(to: externalReportURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.importIntegrationRemediationReport(fromPath: externalReportURL.path)

        XCTAssertTrue(viewModel.integrationRemediationHistoryDeleteStatusMessage.contains("Imported remediation report:"))
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportPath.contains("integration-remediation-reports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewModel.lastIntegrationRemediationReportPath))
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportSummary, "Attempted: 2 | Fixed: 1 | Remaining: 1")
    }

    @MainActor
    func testImportIntegrationRemediationReportBlocksMalformedJson() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-import-report-malformed-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-import-external-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDirectory) }

        let malformedURL = externalDirectory.appendingPathComponent("external-malformed.json")
        try Data("{\"broken\":".utf8).write(to: malformedURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.importIntegrationRemediationReport(fromPath: malformedURL.path)

        XCTAssertEqual(
            viewModel.integrationRemediationHistoryDeleteStatusMessage,
            "Import blocked. JSON does not match remediation report schema."
        )
        XCTAssertTrue(viewModel.integrationRemediationReportHistory.isEmpty)
    }

    @MainActor
    func testCleanupIntegrationRemediationHistoryRetainsNewestN() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-cleanup-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for index in 0..<8 {
            let report = IntegrationRemediationRunReport(
                id: UUID(),
                timestampISO8601: ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(index))),
                attemptedCount: 1,
                fixedCount: 1,
                remainingCount: 0,
                vmResults: []
            )
            let data = try encoder.encode(report)
            let fileURL = reportsDirectory.appendingPathComponent(String(format: "cleanup-%02d.json", index))
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(TimeInterval(index))], ofItemAtPath: fileURL.path)
        }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.cleanupIntegrationRemediationHistory(retainingNewest: 3)

        XCTAssertEqual(viewModel.integrationRemediationReportHistory.count, 3)
        XCTAssertTrue(viewModel.integrationRemediationHistoryCleanupStatusMessage.contains("Removed"))
        XCTAssertTrue(viewModel.integrationRemediationHistoryCleanupStatusMessage.contains("Retained newest 3"))
    }

    @MainActor
    func testCleanupIntegrationRemediationHistoryNoopWhenWithinRetention() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-cleanup-noop-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(report).write(
            to: reportsDirectory.appendingPathComponent("noop.json"),
            options: [.atomic]
        )

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.cleanupIntegrationRemediationHistory(retainingNewest: 3)
        XCTAssertEqual(viewModel.integrationRemediationReportHistory.count, 1)
        XCTAssertTrue(viewModel.integrationRemediationHistoryCleanupStatusMessage.contains("No cleanup needed"))
    }

    @MainActor
    func testRefreshIntegrationRemediationReportHistoryFlagsMalformedReports() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-history-malformed-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        let validReport = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(validReport).write(
            to: reportsDirectory.appendingPathComponent("valid.json"),
            options: [.atomic]
        )
        try Data("{\"broken\":".utf8).write(
            to: reportsDirectory.appendingPathComponent("malformed.json"),
            options: [.atomic]
        )

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.refreshIntegrationRemediationReportHistory()

        XCTAssertEqual(viewModel.malformedIntegrationRemediationReportCount, 1)
        XCTAssertTrue(viewModel.integrationRemediationReportHistory.contains(where: { $0.fileName == "malformed.json" && $0.isMalformed }))
        XCTAssertTrue(viewModel.integrationRemediationReportHistory.contains(where: { $0.fileName == "valid.json" && !$0.isMalformed }))
    }

    @MainActor
    func testDeleteIntegrationRemediationReportRemovesFileAndClearsLoadedSelection() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-report-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        let reportURL = reportsDirectory.appendingPathComponent("delete-me.json")
        try JSONEncoder().encode(report).write(to: reportURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.loadIntegrationRemediationReport(atPath: reportURL.path)
        viewModel.refreshIntegrationRemediationReportHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        viewModel.deleteIntegrationRemediationReport(atPath: reportURL.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportPath, "")
        XCTAssertEqual(viewModel.lastIntegrationRemediationReportSummary, "")
        XCTAssertTrue(viewModel.lastIntegrationRemediationReportResults.isEmpty)
        XCTAssertTrue(viewModel.integrationRemediationHistoryDeleteStatusMessage.contains("Deleted remediation report"))
    }

    @MainActor
    func testDeleteIntegrationRemediationReportRejectsOutsideReportsFolder() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-guard-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let outsideURL = testRoot.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outsideURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.deleteIntegrationRemediationReport(atPath: outsideURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertEqual(
            viewModel.integrationRemediationHistoryDeleteStatusMessage,
            "Refused to delete file outside remediation reports folder."
        )
    }

    @MainActor
    func testDeleteMalformedIntegrationRemediationReportsRemovesOnlyMalformedFiles() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-malformed-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        let validURL = reportsDirectory.appendingPathComponent("valid.json")
        let malformedURL = reportsDirectory.appendingPathComponent("malformed.json")
        let validReport = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(validReport).write(to: validURL, options: [.atomic])
        try Data("{\"oops\":".utf8).write(to: malformedURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.refreshIntegrationRemediationReportHistory()
        XCTAssertEqual(viewModel.malformedIntegrationRemediationReportCount, 1)

        viewModel.deleteMalformedIntegrationRemediationReports()

        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedURL.path))
        XCTAssertEqual(viewModel.malformedIntegrationRemediationReportCount, 0)
        XCTAssertTrue(viewModel.integrationRemediationHistoryDeleteStatusMessage.contains("Deleted 1 malformed"))
    }

    @MainActor
    func testDeleteMalformedIntegrationRemediationReportsNoopWhenNoneMalformed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-malformed-noop-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let validReport = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(validReport).write(
            to: reportsDirectory.appendingPathComponent("only-valid.json"),
            options: [.atomic]
        )

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.deleteMalformedIntegrationRemediationReports()
        XCTAssertEqual(viewModel.malformedIntegrationRemediationReportCount, 0)
        XCTAssertEqual(
            viewModel.integrationRemediationHistoryDeleteStatusMessage,
            "No malformed remediation reports to delete."
        )
    }

    @MainActor
    func testConfirmDeleteIntegrationRemediationReportBlockedWhenNotArmed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-gate-single-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let reportURL = reportsDirectory.appendingPathComponent("gated-single.json")
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.confirmDeleteIntegrationRemediationReport(atPath: reportURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertEqual(viewModel.integrationRemediationHistoryDeleteStatusMessage, "Deletion blocked. Arm deletion first.")
    }

    @MainActor
    func testConfirmDeleteIntegrationRemediationReportDeletesWhenArmed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-gate-confirm-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let reportURL = reportsDirectory.appendingPathComponent("gated-confirm.json")
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        viewModel.armIntegrationRemediationDeletion()
        viewModel.confirmDeleteIntegrationRemediationReport(atPath: reportURL.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertFalse(viewModel.integrationRemediationDeletionArmed)
    }

    @MainActor
    func testConfirmDeleteMalformedIntegrationRemediationReportsBlockedWhenNotArmed() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-gate-bulk-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let malformedURL = reportsDirectory.appendingPathComponent("gated-bulk-malformed.json")
        try Data("{\"oops\":".utf8).write(to: malformedURL, options: [.atomic])

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.confirmDeleteMalformedIntegrationRemediationReports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedURL.path))
        XCTAssertEqual(viewModel.integrationRemediationHistoryDeleteStatusMessage, "Deletion blocked. Arm deletion first.")
    }

    @MainActor
    func testIntegrationRemediationDeletionArmAutoExpires() async {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            deletionArmDurationSeconds: 1
        )

        viewModel.armIntegrationRemediationDeletion()
        XCTAssertTrue(viewModel.integrationRemediationDeletionArmed)
        XCTAssertGreaterThanOrEqual(viewModel.integrationRemediationDeletionSecondsRemaining, 1)

        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(viewModel.integrationRemediationDeletionArmed)
        XCTAssertEqual(viewModel.integrationRemediationDeletionSecondsRemaining, 0)
        XCTAssertEqual(viewModel.integrationRemediationHistoryDeleteStatusMessage, "Deletion arm expired.")
    }

    @MainActor
    func testIntegrationRemediationDeletionDisarmResetsCountdown() {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            deletionArmDurationSeconds: 5
        )

        viewModel.armIntegrationRemediationDeletion()
        XCTAssertTrue(viewModel.integrationRemediationDeletionArmed)
        viewModel.disarmIntegrationRemediationDeletion()
        XCTAssertFalse(viewModel.integrationRemediationDeletionArmed)
        XCTAssertEqual(viewModel.integrationRemediationDeletionSecondsRemaining, 0)
    }

    @MainActor
    func testIntegrationRemediationDeletionSafetyPreferencesPersistAcrossViewModels() {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-safety-prefs-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let first = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        first.configureIntegrationRemediationDeletionSafety(requireArming: false, timeoutSeconds: 60)

        let second = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        XCTAssertFalse(second.integrationRemediationRequireArming)
        XCTAssertEqual(second.integrationRemediationDeletionTimeoutSeconds, 60)
        XCTAssertEqual(second.integrationRemediationDeletionPreferenceStatusMessage, "Deletion safety preferences loaded.")
    }

    @MainActor
    func testIntegrationRemediationDeletionTimeoutNormalizesToSupportedPresets() {
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        viewModel.setIntegrationRemediationDeletionTimeout(seconds: 44)
        XCTAssertEqual(viewModel.integrationRemediationDeletionTimeoutSeconds, 30)
        XCTAssertEqual(viewModel.integrationRemediationDeletionPreferenceStatusMessage, "Deletion safety preferences saved.")
    }

    @MainActor
    func testIntegrationRemediationDeletionPreferenceStatusDefaultsWhenNoSavedFile() {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-prefs-default-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        XCTAssertEqual(
            viewModel.integrationRemediationDeletionPreferenceStatusMessage,
            "Deletion safety preferences using defaults."
        )
    }

    @MainActor
    func testIntegrationRemediationDeletionEndToEndWithPersistedSettingsAndGuardedDelete() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-delete-e2e-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous { setenv(envKey, previous, 1) } else { unsetenv(envKey) }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let reportsDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration-remediation-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let reportURL = reportsDirectory.appendingPathComponent("e2e-delete.json")
        let report = IntegrationRemediationRunReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            attemptedCount: 1,
            fixedCount: 1,
            remainingCount: 0,
            vmResults: []
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: [.atomic])

        let first = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        first.configureIntegrationRemediationDeletionSafety(requireArming: true, timeoutSeconds: 10)
        XCTAssertEqual(first.integrationRemediationDeletionPreferenceStatusMessage, "Deletion safety preferences saved.")

        let second = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        XCTAssertTrue(second.integrationRemediationRequireArming)
        XCTAssertEqual(second.integrationRemediationDeletionTimeoutSeconds, 10)
        XCTAssertEqual(second.integrationRemediationDeletionPreferenceStatusMessage, "Deletion safety preferences loaded.")

        second.confirmDeleteIntegrationRemediationReport(atPath: reportURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertEqual(second.integrationRemediationHistoryDeleteStatusMessage, "Deletion blocked. Arm deletion first.")

        second.armIntegrationRemediationDeletion()
        XCTAssertTrue(second.integrationRemediationDeletionArmed)
        XCTAssertEqual(second.integrationRemediationDeletionSecondsRemaining, 10)

        second.confirmDeleteIntegrationRemediationReport(atPath: reportURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertFalse(second.integrationRemediationDeletionArmed)
        XCTAssertEqual(second.integrationRemediationDeletionSecondsRemaining, 0)
        XCTAssertTrue(second.integrationRemediationHistoryDeleteStatusMessage.contains("Deleted remediation report:"))
    }

    func testDefaultHealthServiceReportsWindowCoherenceArtifacts() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-health-window-policy-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let vmID = UUID()
        let integrationService = DefaultIntegrationService()
        try await integrationService.configureSharedResources(for: vmID)
        try await integrationService.configureLauncherEntries(for: vmID)
        try await integrationService.enableRootlessLinuxApps(for: vmID)

        let healthService = DefaultHealthAndRepairService(integrationService: integrationService)
        let report = try await healthService.runHealthCheck(for: vmID)

        XCTAssertTrue(report.contains("OK: Window coherence policy exists"))
        XCTAssertTrue(report.contains("OK: Window coherence policy schema valid"))
        XCTAssertTrue(report.contains("OK: Host script present - apply-window-coherence.command"))
        XCTAssertFalse(report.contains(where: { $0.hasPrefix("WARN") }))
    }

    func testDefaultHealthServiceWarnsWhenWindowPolicySchemaIsInvalid() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-health-invalid-window-policy-\(UUID().uuidString)", isDirectory: true)
        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let vmID = UUID()
        let integrationService = DefaultIntegrationService()
        try await integrationService.configureSharedResources(for: vmID)
        try await integrationService.configureLauncherEntries(for: vmID)
        try await integrationService.enableRootlessLinuxApps(for: vmID)

        let policyURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .appendingPathComponent("window-coherence-policy.json")
        try Data("{\"vmID\":\"broken\"}".utf8).write(to: policyURL, options: [.atomic])

        let healthService = DefaultHealthAndRepairService(integrationService: integrationService)
        let report = try await healthService.runHealthCheck(for: vmID)

        XCTAssertTrue(report.contains("OK: Window coherence policy exists"))
        XCTAssertTrue(report.contains("WARN: Window coherence policy schema invalid"))
    }

    @MainActor
    func testRunHealthCheckSetsWindowPolicySchemaFlagWhenValid() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockHealth = MockHealthService()
        mockHealth.nextHealthReport = [
            "OK: Window coherence policy exists",
            "OK: Window coherence policy schema valid"
        ]
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: mockHealth,
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-health-valid-schema",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.runHealthCheck()

        XCTAssertTrue(viewModel.coherenceWindowPolicySchemaValid)
        XCTAssertFalse(viewModel.coherenceWindowPolicySchemaInvalid)
    }

    @MainActor
    func testRunHealthCheckClearsWindowPolicySchemaFlagWhenInvalid() async throws {
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let mockHealth = MockHealthService()
        mockHealth.nextHealthReport = [
            "OK: Window coherence policy exists",
            "WARN: Window coherence policy schema invalid"
        ]
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: mockHealth,
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-health-invalid-schema",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await viewModel.runHealthCheck()

        XCTAssertFalse(viewModel.coherenceWindowPolicySchemaValid)
        XCTAssertTrue(viewModel.coherenceWindowPolicySchemaInvalid)
    }

    func testUninstallUsesRegistryVMPathAndRemovesRegistryEntry() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let vmID = UUID()
        let vmDirectory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("vms", isDirectory: true)
            .appendingPathComponent("named-vm", isDirectory: true)
        let integrationDirectory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: integrationDirectory, withIntermediateDirectories: true)

        let registry = PersistentVMRegistryStore(baseDirectoryURL: base)
        let now = ISO8601DateFormatter().string(from: Date())
        try await registry.upsert(
            VMRegistryEntry(
                id: vmID,
                vmName: "named-vm",
                vmDirectoryPath: vmDirectory.path,
                distribution: .ubuntu,
                architecture: .appleSilicon,
                runtimeEngine: .appleVirtualization,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
        )

        let cleanup = DefaultUninstallCleanupService(registry: registry, baseDirectoryURL: base)
        try await cleanup.uninstallVM(id: vmID, removeArtifacts: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: vmDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationDirectory.path))
        let registryEntry = await registry.entry(for: vmID)
        XCTAssertNil(registryEntry)
    }

    func testEscalationServiceDoesNotClearStoredTokenOnEmptyUpdate() async throws {
        let tokenStore = InMemoryTokenStore()
        try tokenStore.saveToken("persisted-token")

        let service = DefaultEscalationService(
            githubOwner: "owner",
            githubRepository: "repo",
            githubToken: "",
            supportEmailRecipient: "",
            tokenStore: tokenStore
        )

        service.updateGitHubConfiguration(owner: "owner", repository: "repo", token: "")
        XCTAssertEqual(tokenStore.readToken(), "persisted-token")

        service.updateGitHubConfiguration(owner: "owner", repository: "repo", token: "new-token")
        XCTAssertEqual(tokenStore.readToken(), "new-token")
    }

    @MainActor
    func testRestoreRegistryStatePrunesStaleEntriesAndRestoresLatestVM() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let registry = PersistentVMRegistryStore(baseDirectoryURL: base)
        let now = ISO8601DateFormatter().string(from: Date())

        let validID = UUID()
        let staleID = UUID()

        let validVMDirectory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("vms", isDirectory: true)
            .appendingPathComponent("restored-vm", isDirectory: true)
        try FileManager.default.createDirectory(at: validVMDirectory, withIntermediateDirectories: true)

        try await registry.upsert(
            VMRegistryEntry(
                id: validID,
                vmName: "restored-vm",
                vmDirectoryPath: validVMDirectory.path,
                distribution: .ubuntu,
                architecture: .appleSilicon,
                runtimeEngine: .appleVirtualization,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
        )

        try await registry.upsert(
            VMRegistryEntry(
                id: staleID,
                vmName: "stale-vm",
                vmDirectoryPath: base.appendingPathComponent("MLIntegration/vms/stale-vm", isDirectory: true).path,
                distribution: .fedora,
                architecture: .intel,
                runtimeEngine: .qemuFallback,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
        )

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader(),
            registry: registry
        )

        await viewModel.restoreVMRegistryState()

        XCTAssertEqual(viewModel.lastManagedVMID, validID)
        XCTAssertEqual(viewModel.activeVMID, validID)
        XCTAssertTrue(viewModel.registryStatusMessage.contains("pruned 1"))

        let staleEntry = await registry.entry(for: staleID)
        XCTAssertNil(staleEntry)
    }

    func testIntegrationServiceUsesTestRootEnvironmentOverride() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-test-root-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let vmID = UUID()
        let service = DefaultIntegrationService()
        try await service.configureSharedResources(for: vmID)

        let expectedConfig = testRoot
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .appendingPathComponent("shared-resources.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedConfig.path))
    }

    func testVMRegistryUsesTestRootEnvironmentOverride() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-registry-root-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let registry = PersistentVMRegistryStore()
        let vmID = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await registry.upsert(
            VMRegistryEntry(
                id: vmID,
                vmName: "env-vm",
                vmDirectoryPath: "/tmp/env-vm",
                distribution: .ubuntu,
                architecture: .appleSilicon,
                runtimeEngine: .appleVirtualization,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
        )

        let expectedRegistry = testRoot
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("vm-registry.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRegistry.path))
    }

    func testFileRuntimeObservabilityStorePersistsRunEvents() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-observability-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }

        let store = FileRuntimeObservabilityStore()
        let vmID = UUID()
        let runID = try await store.beginRun(vmID: vmID)
        try await store.appendEvent(
            runID: runID,
            vmID: vmID,
            stage: .installValidation,
            result: .inProgress,
            message: "validating"
        )
        try await store.appendEvent(
            runID: runID,
            vmID: vmID,
            stage: .installReady,
            result: .success,
            message: "ready"
        )

        let reportURL = try await store.exportReport(runID: runID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(RuntimeRunReport.self, from: data)
        XCTAssertEqual(report.runID, runID)
        XCTAssertEqual(report.vmID, vmID)
        XCTAssertEqual(report.events.count, 2)
        XCTAssertEqual(report.events.last?.stage, .installReady)
        XCTAssertEqual(report.events.last?.result, .success)
    }

    @MainActor
    func testRuntimeSessionPersistsAndRestoresState() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-runtime-session-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        // Scaffold a VM to establish an active VM and a stopped runtime state persisted to disk.
        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-session",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertEqual(viewModel.installLifecycleState, .ready)
        XCTAssertEqual(viewModel.vmRuntimeState, .stopped)

        // Simulate relaunch by creating a fresh view model and restoring state.
        let relaunched = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        // restoreVMRegistryState also calls session restore at the end
        await relaunched.restoreVMRegistryState()

        XCTAssertNotNil(relaunched.activeVMID)
        XCTAssertEqual(relaunched.installLifecycleState, .ready)
        XCTAssertEqual(relaunched.vmRuntimeState, .stopped)
    }

    @MainActor
    func testRuntimeSessionUpdatesOnStartStop() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-runtime-session-startstop-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-session-ss",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        XCTAssertEqual(viewModel.vmRuntimeState, .stopped)

        await viewModel.startActiveVM()
        XCTAssertEqual(viewModel.vmRuntimeState, .running)

        await viewModel.stopActiveVM()
        XCTAssertEqual(viewModel.vmRuntimeState, .stopped)

        // Relaunch and ensure last state (stopped) is restored
        let relaunched = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await relaunched.restoreVMRegistryState()
        XCTAssertEqual(relaunched.vmRuntimeState, .stopped)
    }

    @MainActor
    func testRuntimeSessionClearsOnUninstall() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-runtime-session-clear-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let viewModel = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await viewModel.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-session-clear",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        // Uninstall should clear the active session persisted file
        await viewModel.uninstallActiveVM(removeArtifacts: true)
        XCTAssertEqual(viewModel.installLifecycleState, .idle)

        // Relaunch should not restore any active session
        let relaunched = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await relaunched.restoreVMRegistryState()
        // If no registry entries remain and session cleared, activeVMID may be nil or state reset
        // We assert that runtime state is not running and no misleading active session exists
        XCTAssertTrue(relaunched.activeVMID == nil || relaunched.vmRuntimeState == .stopped)
    }

    @MainActor
    func testRuntimeSessionPersistsSessionFileAndRebindsWhenPidAlive() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-runtime-session-rebind-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        // Scaffold and start VM to persist a running state with current process PID
        let vm = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )

        await vm.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-session-rebind",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )
        await vm.startActiveVM()
        XCTAssertEqual(vm.vmRuntimeState, .running)

        // Verify session file exists
        let sessionFile = testRoot
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("runtime-session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))

        // Decode session JSON and verify stored state and PID
        let raw = try Data(contentsOf: sessionFile)
        let snapshot = try JSONDecoder().decode(RuntimeSessionSnapshot.self, from: raw)
        XCTAssertEqual(snapshot.stateRaw, VMRuntimeState.running.rawValue)
        XCTAssertEqual(snapshot.processID, getpid())

        // Simulate relaunch and ensure we rebind to running PID
        let relaunched = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await relaunched.restoreVMRegistryState()
        XCTAssertEqual(relaunched.vmRuntimeState, .running)
        XCTAssertTrue(relaunched.vmRuntimeStatusMessage.localizedCaseInsensitiveContains("rebound"))
    }

    @MainActor
    func testRuntimeSessionRestoresStoppedWhenPidNotAlive() async throws {
        let envKey = RuntimeEnvironment.testRootEnvironmentVariable
        let previous = getenv(envKey).map { String(cString: $0) }
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-integration-runtime-session-deadpid-\(UUID().uuidString)", isDirectory: true)

        setenv(envKey, testRoot.path, 1)
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
            try? FileManager.default.removeItem(at: testRoot)
        }
        let installerURL = try makeTemporaryInstallerImage()
        defer { try? FileManager.default.removeItem(at: installerURL) }

        // Create a view model and scaffold to create the session file (stopped state)
        let vm = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await vm.scaffoldInstall(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            runtime: .appleVirtualization,
            vmName: "vm-session-deadpid",
            installerImagePath: installerURL.path,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        // Manually write a session snapshot with a bogus PID to simulate stale process
        let sessionPath = testRoot
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("runtime-session.json")
        let bogus = RuntimeSessionSnapshot(
            vmID: vm.activeVMID!,
            stateRaw: VMRuntimeState.running.rawValue,
            processID: Int32.max, // an invalid PID should not be alive
            lastUpdatedISO8601: ISO8601DateFormatter().string(from: Date())
        )
        let data = try JSONEncoder().encode(bogus)
        try FileManager.default.createDirectory(at: sessionPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: sessionPath)

        // Verify bogus snapshot content
        let bogusData = try Data(contentsOf: sessionPath)
        let bogusDecoded = try JSONDecoder().decode(RuntimeSessionSnapshot.self, from: bogusData)
        XCTAssertEqual(bogusDecoded.stateRaw, VMRuntimeState.running.rawValue)
        XCTAssertEqual(bogusDecoded.processID, Int32.max)

        // Relaunch and ensure state falls back to stopped with explanatory message
        let relaunched = RuntimeWorkbenchViewModel(
            hostService: MockHostService(),
            catalogService: MockCatalogService(),
            provisioningService: MockProvisioningService(),
            integrationService: MockIntegrationService(),
            healthService: MockHealthService(),
            uninstallService: MockCleanupService(),
            escalationService: MockEscalationService(),
            downloader: MockDownloader()
        )
        await relaunched.restoreVMRegistryState()
        XCTAssertEqual(relaunched.vmRuntimeState, .stopped)
        XCTAssertTrue(relaunched.vmRuntimeStatusMessage.localizedCaseInsensitiveContains("marking as stopped"))

        // Ensure restore did not mutate the persisted session file
        let afterRestoreData = try Data(contentsOf: sessionPath)
        let afterRestoreSnapshot = try JSONDecoder().decode(RuntimeSessionSnapshot.self, from: afterRestoreData)
        XCTAssertEqual(afterRestoreSnapshot.stateRaw, VMRuntimeState.running.rawValue)
        XCTAssertEqual(afterRestoreSnapshot.processID, Int32.max)
    }
}

final class URLProtocolMock: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: RuntimeServiceError.downloadFailed("No mock handler."))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct MockHostService: HostProfileService {
    func detectHostProfile() async throws -> HostProfile {
        HostProfile(architecture: .appleSilicon, cpuCores: 8, memoryGB: 16, macOSVersion: "mock")
    }
}

struct MockWeakHostService: HostProfileService {
    func detectHostProfile() async throws -> HostProfile {
        HostProfile(architecture: .intel, cpuCores: 2, memoryGB: 4, macOSVersion: "mock-weak")
    }
}

actor MockObservabilityStore: RuntimeObservabilityLogging {
    private(set) var events: [RuntimeRunEvent] = []
    private let runID = UUID()

    func beginRun(vmID: UUID?) async throws -> UUID {
        _ = vmID
        return runID
    }

    func appendEvent(runID: UUID, vmID: UUID?, stage: RuntimeRunStage, result: RuntimeRunResult, message: String) async throws {
        events.append(
            RuntimeRunEvent(
                id: UUID(),
                runID: runID,
                vmID: vmID,
                stage: stage,
                result: result,
                message: message,
                timestampISO8601: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    func exportReport(runID: UUID) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(runID.uuidString).json")
    }
}

final class MockCatalogService: DistributionCatalogService {
    var fetchCount = 0

    func fetchSupportedDistributions() async throws -> [LinuxDistribution] {
        LinuxDistribution.allCases
    }

    func fetchArtifacts(for architecture: HostArchitecture) async throws -> [DistributionArtifact] {
        fetchCount += 1
        return [
            DistributionArtifact(
                id: "mock",
                distribution: .ubuntu,
                architecture: architecture,
                version: "mock",
                downloadURL: URL(string: "https://example.com/mock.iso")!,
                mirrorURLs: [URL(string: "https://mirror.example.com/mock.iso")!],
                checksumSHA256: "",
                signatureExpected: false,
                signatureVerifiedAtSource: false
            )
        ]
    }

    func verifyChecksum(for artifact: DistributionArtifact, at localURL: URL) async throws -> Bool {
        _ = artifact
        _ = localURL
        return true
    }

    func verifySignature(for artifact: DistributionArtifact) async throws -> Bool {
        _ = artifact
        return true
    }

    func requiredKeyringFileNames(for distribution: LinuxDistribution) -> [String] {
        switch distribution {
        case .ubuntu, .debian:
            return ["archive-keyring.gpg"]
        default:
            return []
        }
    }
}

final class MockEscalationService: EscalationService, EscalationConfigurable {
    var owner: String = ""
    var repository: String = ""
    var token: String = ""
    var recipient: String = ""

    func updateGitHubConfiguration(owner: String, repository: String, token: String) {
        self.owner = owner
        self.repository = repository
        self.token = token
    }

    func updateEmailConfiguration(recipient: String) {
        self.recipient = recipient
    }

    func openGitHubIssue(title: String, details: String, logs: URL?) async throws -> URL {
        _ = title
        _ = details
        _ = logs
        return URL(string: "https://github.com/mock/mock/issues/1")!
    }

    func sendEmailEscalation(subject: String, body: String, attachments: [URL]) async throws {
        _ = subject
        _ = body
        _ = attachments
    }
}

final class MockCleanupService: UninstallCleanupService {
    func uninstallVM(id: UUID, removeArtifacts: Bool) async throws {
        _ = id
        _ = removeArtifacts
    }

    func verifyCleanup(id: UUID) async throws -> [String] {
        _ = id
        return ["OK: cleanup verified"]
    }
}

final class MockHealthService: HealthAndRepairService {
    var nextHealthReport: [String] = ["OK: mock health"]

    func runHealthCheck(for vmID: UUID) async throws -> [String] {
        _ = vmID
        return nextHealthReport
    }

    func applyAutomaticRepair(for vmID: UUID) async throws -> [String] {
        _ = vmID
        return ["Applied: mock repair"]
    }
}

final class MockIntegrationService: IntegrationService {
    var sharedResourcesCalls = 0
    var launcherCalls = 0
    var rootlessCalls = 0
    var failSharedResources = false
    var failLauncher = false
    var emitWindowCoherenceArtifacts = true

    func configureSharedResources(for vmID: UUID) async throws {
        _ = vmID
        if failSharedResources {
            throw IntegrationRuntimeError.scriptGenerationFailed("mock shared failure")
        }
        if emitWindowCoherenceArtifacts {
            let integrationDirectory = RuntimeEnvironment.mlIntegrationRootURL()
                .appendingPathComponent("integration", isDirectory: true)
                .appendingPathComponent(vmID.uuidString, isDirectory: true)
            let hostScripts = integrationDirectory.appendingPathComponent("host-scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: hostScripts, withIntermediateDirectories: true)
            let policy = integrationDirectory.appendingPathComponent("window-coherence-policy.json")
            let script = hostScripts.appendingPathComponent("apply-window-coherence.command")
            try Data("{}".utf8).write(to: policy)
            try Data("#!/bin/sh\n".utf8).write(to: script)
        }
        sharedResourcesCalls += 1
    }

    func configureLauncherEntries(for vmID: UUID) async throws {
        _ = vmID
        if failLauncher {
            throw IntegrationRuntimeError.scriptGenerationFailed("mock launcher failure")
        }
        launcherCalls += 1
    }

    func enableRootlessLinuxApps(for vmID: UUID) async throws {
        _ = vmID
        rootlessCalls += 1
    }
}

final class MockLauncherScriptExecutor: LauncherScriptExecuting {
    var executedScriptPaths: [String] = []
    var nextError: Error?
    var nextOutput: String = ""
    var queuedErrors: [Error] = []

    func executeScript(atPath path: String) async throws -> String {
        executedScriptPaths.append(path)
        if !queuedErrors.isEmpty {
            let error = queuedErrors.removeFirst()
            throw error
        }
        if let nextError {
            throw nextError
        }
        return nextOutput
    }
}

struct MockDownloader: ArtifactDownloading {
    func downloadArtifact(
        primaryURL: URL,
        mirrorURLs: [URL],
        destinationURL: URL,
        maxRetriesPerURL: Int,
        progressHandler: (@Sendable (ArtifactDownloadProgress) -> Void)?
    ) async throws {
        _ = primaryURL
        _ = mirrorURLs
        _ = maxRetriesPerURL
        _ = progressHandler
        try Data("mock".utf8).write(to: destinationURL)
    }
}

final class InMemoryTokenStore: GitHubTokenSecureStoring {
    private var token: String?

    func readToken() -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}

actor MockProvisioningService: VMProvisioningService {
    private var statesByID: [UUID: VMRuntimeState] = [:]
    private var startFailureVMIDs: Set<UUID> = []
    private var stopFailureVMIDs: Set<UUID> = []

    func validate(_ request: VMInstallRequest, assets: VMInstallAssets?) async throws {
        if request.runtimeEngine == .appleVirtualization || request.runtimeEngine == .qemuFallback {
            let isSupported: Bool
            switch request.distribution {
            case .ubuntu, .fedora, .debian:
                isSupported = true
            default:
                isSupported = false
            }
            guard isSupported else {
                throw RuntimeServiceError.invalidVMRequest(
                    "This build supports in-app Linux guests for Ubuntu, Fedora, and Debian only."
                )
            }
        }
        guard assets?.installerImageURL != nil else {
            throw RuntimeServiceError.missingAssets("Provide installer image path or download an ISO from the catalog first.")
        }
    }

    func installVM(using request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID {
        try await validate(request, assets: assets)
        guard let assets else {
            throw RuntimeServiceError.missingAssets("Virtualization flow requires installer image path and VM asset paths.")
        }

        try FileManager.default.createDirectory(at: assets.vmDirectoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: assets.diskImageURL.path) {
            FileManager.default.createFile(atPath: assets.diskImageURL.path, contents: Data())
        }

        let vmID = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        let registry = PersistentVMRegistryStore()
        try await registry.upsert(
            VMRegistryEntry(
                id: vmID,
                vmName: assets.vmName,
                vmDirectoryPath: assets.vmDirectoryURL.path,
                distribution: request.distribution,
                architecture: request.architecture,
                runtimeEngine: request.runtimeEngine,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
        )
        statesByID[vmID] = .stopped
        return vmID
    }

    func startVM(id: UUID) async throws {
        if statesByID[id] == nil {
            throw RuntimeServiceError.vmNotFound
        }
        if startFailureVMIDs.contains(id) {
            throw RuntimeServiceError.invalidVMRequest("Injected start failure for testing.")
        }
        if statesByID.contains(where: { $0.key != id && $0.value == .running }) {
            throw RuntimeServiceError.invalidVMRequest(
                "Only one VM can run at a time in this release."
            )
        }
        statesByID[id] = .running
    }

    func stopVM(id: UUID) async throws {
        if statesByID[id] == nil {
            throw RuntimeServiceError.vmNotFound
        }
        if stopFailureVMIDs.contains(id) {
            throw RuntimeServiceError.invalidVMRequest("Injected stop failure for testing.")
        }
        statesByID[id] = .stopped
    }

    func injectStopFailure(for id: UUID) {
        stopFailureVMIDs.insert(id)
    }

    func injectStartFailure(for id: UUID) {
        startFailureVMIDs.insert(id)
    }
}
