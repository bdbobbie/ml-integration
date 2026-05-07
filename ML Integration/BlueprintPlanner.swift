import Foundation
import Combine

@MainActor
final class BlueprintPlanner: ObservableObject {
    @Published private(set) var supportedArchitectures: [HostArchitecture] = HostArchitecture.allCases
    @Published private(set) var preferredRuntimeByArchitecture: [HostArchitecture: RuntimeEngine] = [
        .appleSilicon: .appleVirtualization,
        .intel: .appleVirtualization
    ]
    @Published private(set) var fallbackRuntime: RuntimeEngine = .qemuFallback
    @Published private(set) var supportedDistributions: [LinuxDistribution] = LinuxDistribution.allCases
    @Published private(set) var integrationModes: [IntegrationMode] = IntegrationMode.allCases
    @Published private(set) var stages: [StageDefinition] = []
    @Published private(set) var readinessCriteria: [ReadinessCriterion] = []
    @Published private(set) var phaseMilestones: [PhaseMilestone] = []
    @Published private(set) var deliveryActionItems: [DeliveryActionItem] = []
    @Published private(set) var preflightStatusMessage: String = ""
    @Published private(set) var preflightFindings: [String] = []
    @Published private(set) var lastPreflightEvidencePath: String = ""
    @Published private(set) var checklistAutoSyncStatusMessage: String = ""
    @Published private(set) var environmentTestStartStatusMessage: String = ""
    @Published private(set) var lastGoNoGoReportPath: String = ""
    @Published private(set) var phaseStateExportStatusMessage: String = ""
    @Published private(set) var lastPhaseStateReportPath: String = ""
    @Published private(set) var environmentTestingStarted: Bool = false

    init() {
        stages = [
            StageDefinition(
                id: "catalog-and-installer",
                title: "1) Distro Catalog + Installer",
                summary: "Detect host architecture, curate trusted distro artifacts, verify checksums, and create VM installs.",
                status: .planned,
                ownedBy: "Core VM"
            ),
            StageDefinition(
                id: "resource-sharing",
                title: "2) Resource Sharing + Launcher",
                summary: "Enable shared folders, clipboard, drag/drop flow, and Linux app launch from macOS menus.",
                status: .planned,
                ownedBy: "Integration"
            ),
            StageDefinition(
                id: "health-and-healing",
                title: "3) Health + Auto-Heal",
                summary: "Run diagnostics, detect common breakage, and apply scripted recovery with rollback checkpoints.",
                status: .planned,
                ownedBy: "Reliability"
            ),
            StageDefinition(
                id: "uninstall-cleanup",
                title: "4) Uninstall + Cleanup",
                summary: "Remove VM disks, mounts, launch entries, and configuration artifacts with post-check report.",
                status: .planned,
                ownedBy: "Lifecycle"
            ),
            StageDefinition(
                id: "escalation",
                title: "5) Developer Escalation",
                summary: "If self-heal fails, submit logs via GitHub Issue API and optional email escalation.",
                status: .planned,
                ownedBy: "Support"
            )
        ]

        readinessCriteria = [
            ReadinessCriterion(
                id: "scope-frozen",
                title: "Scope frozen for v0 test pass",
                detail: "The initial in-scope features are locked and documented.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "github-and-ci",
                title: "GitHub and CI are configured",
                detail: "Remote exists, CI workflow is committed, and issue templates are present.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "test-mode",
                title: "Deterministic test mode is active",
                detail: "Runtime paths are isolated using test root configuration.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "lifecycle-states",
                title: "Installer lifecycle states are implemented",
                detail: "idle/validating/scaffolding/ready/failed transitions are available.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "security-flow",
                title: "Credential and signature flows validated",
                detail: "Keychain token management and signature failure behavior are verified.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "matrix-ready",
                title: "Host and distro matrix is prepared",
                detail: "Apple Silicon + Intel hosts and target distro list are ready for runs.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "automation-passing",
                title: "Automated tests are passing",
                detail: "Build and tests pass in local and CI environments.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "observability-enabled",
                title: "Observability reporting is enabled",
                detail: "Run IDs and stage-level report export are operational.",
                isSatisfied: true
            ),
            ReadinessCriterion(
                id: "environment-prereqs",
                title: "Test environment prerequisites are satisfied",
                detail: "Virtualization support, resources, and key prerequisites are available.",
                isSatisfied: false
            ),
            ReadinessCriterion(
                id: "blockers-cleared",
                title: "No blocker-severity issues remain",
                detail: "Open defects are triaged and blockers are resolved before test start.",
                isSatisfied: false
            )
        ]

        phaseMilestones = [
            PhaseMilestone(
                id: "phase-1",
                title: "Phase 1 - Coherence Essentials",
                summary: "Shared folders, clipboard sync, launcher integration, and baseline device/display readiness checks.",
                status: .pending
            ),
            PhaseMilestone(
                id: "phase-2",
                title: "Phase 2 - Multi-Display Expansion",
                summary: "Scale from v1 single display to planned multi-display target with readiness gates.",
                status: .pending
            )
        ]

        deliveryActionItems = [
            DeliveryActionItem(
                id: "linux-window-coherence",
                title: "Linux app window coherence",
                acceptanceCriteria: "Linux app windows behave as first-class macOS windows with stable focus, resize, and z-order behavior.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "launcher-integration",
                title: "Launcher integration end-to-end",
                acceptanceCriteria: "Installed Linux apps can be discovered and launched via macOS-integrated launcher surfaces.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "clipboard-folders",
                title: "Clipboard and shared folders validation",
                acceptanceCriteria: "Bidirectional clipboard and shared-folder flows pass deterministic integration checks.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "multi-vm-concurrency",
                title: "Multi-VM concurrent orchestration",
                acceptanceCriteria: "Multiple VMs can run concurrently with explicit resource arbitration and lifecycle safety checks.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "multi-display-runtime",
                title: "Multi-display runtime implementation",
                acceptanceCriteria: "v2 target display configuration is runnable and validated, not only planned/readiness-flagged.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "device-passthrough",
                title: "USB/audio/mic/camera passthrough hardening",
                acceptanceCriteria: "Media and USB passthrough includes permission handling, failure recovery, and run-level verification.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "linux-app-onboarding",
                title: "Linux app onboarding UX",
                acceptanceCriteria: "Users can install, launch, and manage Linux apps through guided in-app workflows.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "ci-stability",
                title: "CI/workflow stability",
                acceptanceCriteria: "Repository CI workflow and required token scopes are stable and documented for repeatable pushes/runs.",
                status: .pending
            ),
            DeliveryActionItem(
                id: "e2e-runtime-tests",
                title: "End-to-end runtime test expansion",
                acceptanceCriteria: "Integration and UI test suites cover real runtime behaviors beyond gate/readiness state checks.",
                status: .pending
            )
        ]
    }

    func setStageStatus(stageID: String, to newStatus: BlueprintStageStatus) -> (stage: StageDefinition, previous: BlueprintStageStatus)? {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else {
            return nil
        }

        let previous = stages[index].status
        guard previous != newStatus else {
            return nil
        }

        stages[index].status = newStatus
        return (stages[index], previous)
    }

    func recommendedDefaultRequest(for architecture: HostArchitecture) -> VMInstallRequest {
        let cpu = architecture == .appleSilicon ? 4 : 2
        let memory = architecture == .appleSilicon ? 8 : 6

        return VMInstallRequest(
            distribution: .ubuntu,
            runtimeEngine: preferredRuntimeByArchitecture[architecture] ?? .appleVirtualization,
            architecture: architecture,
            cpuCores: cpu,
            memoryGB: memory,
            diskGB: 64,
            enableSharedFolders: true,
            enableSharedClipboard: true
        )
    }

    func setReadinessCriterion(id: String, isSatisfied: Bool) {
        guard let index = readinessCriteria.firstIndex(where: { $0.id == id }) else {
            return
        }
        readinessCriteria[index].isSatisfied = isSatisfied
    }

    var readinessProgressSummary: String {
        let satisfied = readinessCriteria.filter(\.isSatisfied).count
        return "\(satisfied)/\(readinessCriteria.count) criteria satisfied"
    }

    var phaseProgressSummary: String {
        let completed = phaseMilestones.filter { $0.status == .complete }.count
        return "\(completed)/\(phaseMilestones.count) phases complete"
    }

    var deliveryActionProgressSummary: String {
        let completed = deliveryActionItems.filter { $0.status == .complete }.count
        return "\(completed)/\(deliveryActionItems.count) delivery actions complete"
    }

    var isReadyForEnvironmentTesting: Bool {
        !readinessCriteria.isEmpty && readinessCriteria.allSatisfy(\.isSatisfied)
    }

    func applyPreflightScan(_ snapshot: ReadinessPreflightSnapshot) {
        var findings: [String] = []

        let hostPrereqsMet: Bool
        if let host = snapshot.hostProfile {
            hostPrereqsMet = host.cpuCores >= 2 && host.memoryGB >= 8
            findings.append(hostPrereqsMet
                ? "OK: Host resources meet minimum preflight requirements."
                : "WARN: Host resources below minimum recommendation (2 cores, 8 GB RAM).")
        } else {
            hostPrereqsMet = false
            findings.append("WARN: Host profile is missing; run host detection first.")
        }

        let virtualizationReady = snapshot.virtualizationSupported
        findings.append(virtualizationReady
            ? "OK: Virtualization framework support detected."
            : "WARN: Virtualization framework support unavailable on this host.")

        let catalogReady = snapshot.catalogHasArtifacts && snapshot.catalogErrorMessage.isEmpty
        findings.append(catalogReady
            ? "OK: Artifact catalog available for current architecture."
            : "WARN: Artifact catalog unavailable or currently in error.")

        let lifecycleHealthy = snapshot.installLifecycleState != .failed
        findings.append(lifecycleHealthy
            ? "OK: Install lifecycle state is not failed."
            : "WARN: Install lifecycle is currently failed.")

        findings.append(snapshot.hasManagedVM
            ? "OK: At least one managed VM scaffold is present."
            : "WARN: No managed VM scaffold currently tracked.")

        findings.append(snapshot.testRootOverrideEnabled
            ? "OK: Test root override enabled for deterministic runs."
            : "INFO: Test root override not enabled (normal mode).")

        findings.append(snapshot.currentRunID != nil
            ? "OK: Observability run tracking is active."
            : "WARN: No active observability run ID.")

        let environmentPrereqsSatisfied = hostPrereqsMet && virtualizationReady
        setReadinessCriterion(id: "environment-prereqs", isSatisfied: environmentPrereqsSatisfied)
        setReadinessCriterion(id: "lifecycle-states", isSatisfied: lifecycleHealthy)
        setReadinessCriterion(id: "blockers-cleared", isSatisfied: catalogReady && lifecycleHealthy)

        preflightFindings = findings
        let baseStatus = environmentPrereqsSatisfied
            ? "Preflight scan passed for host prerequisites."
            : "Preflight scan found host prerequisite gaps."

        do {
            let evidenceURL = try persistPreflightEvidence(snapshot: snapshot, findings: findings)
            lastPreflightEvidencePath = evidenceURL.path
            preflightStatusMessage = "\(baseStatus) Evidence saved: \(evidenceURL.lastPathComponent)"
        } catch {
            lastPreflightEvidencePath = ""
            preflightStatusMessage = "\(baseStatus) Evidence save failed: \(error.localizedDescription)"
        }
    }

    func autoSyncChecklist(with signals: ReadinessChecklistSignals) {
        let hostSatisfies = signals.snapshot.hostProfile.map { $0.cpuCores >= 2 && $0.memoryGB >= 8 } ?? false
        let environmentReady = hostSatisfies && signals.snapshot.virtualizationSupported
        let lifecycleReady = signals.snapshot.installLifecycleState != .failed
        let catalogReady = signals.snapshot.catalogHasArtifacts && signals.snapshot.catalogErrorMessage.isEmpty
        let observabilityReady = signals.snapshot.currentRunID != nil
        let testModeReady = signals.snapshot.testRootOverrideEnabled
        let automationReady = (signals.buildPassed ?? false) && (signals.testsPassed ?? false)

        setReadinessCriterion(id: "environment-prereqs", isSatisfied: environmentReady)
        setReadinessCriterion(id: "lifecycle-states", isSatisfied: lifecycleReady)
        // Keep this criterion sticky in normal mode so production hosts are not
        // forced into test-root override just to pass readiness.
        if testModeReady {
            setReadinessCriterion(id: "test-mode", isSatisfied: true)
        }
        setReadinessCriterion(id: "observability-enabled", isSatisfied: observabilityReady)
        setReadinessCriterion(id: "security-flow", isSatisfied: signals.securityFlowReady)

        if signals.buildPassed != nil || signals.testsPassed != nil {
            setReadinessCriterion(id: "automation-passing", isSatisfied: automationReady)
        }

        let blockersCleared = catalogReady && lifecycleReady && (!signals.preflightEvidenceExists || environmentReady)
        setReadinessCriterion(id: "blockers-cleared", isSatisfied: blockersCleared)

        let buildStatus = signals.buildPassed.map { $0 ? "passed" : "failed" } ?? "unknown"
        let testStatus = signals.testsPassed.map { $0 ? "passed" : "failed" } ?? "unknown"
        checklistAutoSyncStatusMessage = "Checklist auto-sync updated from runtime signals (build: \(buildStatus), tests: \(testStatus))."
    }

    @discardableResult
    func startEnvironmentTestingIfReady() -> Bool {
        let unsatisfied = readinessCriteria.filter { !$0.isSatisfied }
        let isGo = unsatisfied.isEmpty

        do {
            let reportURL = try persistGoNoGoDecisionReport(isGo: isGo, unsatisfied: unsatisfied)
            lastGoNoGoReportPath = reportURL.path
        } catch {
            lastGoNoGoReportPath = ""
        }

        guard isGo else {
            environmentTestingStarted = false
            let names = unsatisfied.map(\.title).joined(separator: "; ")
            environmentTestStartStatusMessage = "NO-GO: environment testing is blocked until criteria are satisfied. Remaining: \(names)"
            return false
        }

        environmentTestingStarted = true
        environmentTestStartStatusMessage = "GO: environment testing has been enabled."
        return true
    }

    func syncPhaseMilestones(
        coherenceReady: Bool,
        deviceMediaReady: Bool,
        displayV2Ready: Bool
    ) {
        var phase1Status: RoadmapPhaseStatus = .pending
        if let phase1Index = phaseMilestones.firstIndex(where: { $0.id == "phase-1" }) {
            if coherenceReady && deviceMediaReady {
                phaseMilestones[phase1Index].status = .complete
                phase1Status = .complete
            } else if coherenceReady || deviceMediaReady {
                phaseMilestones[phase1Index].status = .inProgress
                phase1Status = .inProgress
            } else {
                phaseMilestones[phase1Index].status = .pending
                phase1Status = .pending
            }
        }

        if let phase2Index = phaseMilestones.firstIndex(where: { $0.id == "phase-2" }) {
            if displayV2Ready && phase1Status == .complete {
                phaseMilestones[phase2Index].status = .complete
            } else if displayV2Ready || phase1Status == .inProgress {
                phaseMilestones[phase2Index].status = .inProgress
            } else {
                phaseMilestones[phase2Index].status = .pending
            }
        }
    }

    func syncDeliveryActionItems(
        plannerReady: Bool,
        phaseSweepReady: Bool,
        phase2DisplayReady: Bool
    ) {
        setDeliveryActionStatus(
            id: "linux-window-coherence",
            to: (plannerReady && phaseSweepReady) ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "launcher-integration",
            to: plannerReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "clipboard-folders",
            to: phaseSweepReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "multi-vm-concurrency",
            to: plannerReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "multi-display-runtime",
            to: phase2DisplayReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "device-passthrough",
            to: phaseSweepReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "linux-app-onboarding",
            to: plannerReady ? .inProgress : .pending
        )
        setDeliveryActionStatus(
            id: "ci-stability",
            to: .pending
        )
        setDeliveryActionStatus(
            id: "e2e-runtime-tests",
            to: plannerReady ? .inProgress : .pending
        )
    }

    func setDeliveryActionStatus(id: String, to status: DeliveryActionStatus) {
        guard let index = deliveryActionItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        deliveryActionItems[index].status = status
    }

    @discardableResult
    func completeDeliveryAction(id: String) -> Bool {
        guard let index = deliveryActionItems.firstIndex(where: { $0.id == id }) else {
            return false
        }
        deliveryActionItems[index].status = .complete
        return true
    }

    @discardableResult
    func exportPhaseStateReport() -> URL? {
        do {
            let url = try persistPhaseStateReport()
            lastPhaseStateReportPath = url.path
            phaseStateExportStatusMessage = "Phase state report exported: \(url.lastPathComponent)"
            return url
        } catch {
            lastPhaseStateReportPath = ""
            phaseStateExportStatusMessage = "Phase state export failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func persistPreflightEvidence(
        snapshot: ReadinessPreflightSnapshot,
        findings: [String]
    ) throws -> URL {
        let evidence = ReadinessScanEvidence(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            snapshot: snapshot,
            findings: findings,
            criteria: readinessCriteria,
            isGoForEnvironmentTesting: isReadyForEnvironmentTesting,
            readinessSummary: readinessProgressSummary
        )

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("readiness", isDirectory: true)
            .appendingPathComponent("preflight", isDirectory: true)
            .appendingPathComponent("preflight-\(timestamp)-\(evidence.id.uuidString).json", isDirectory: false)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func persistGoNoGoDecisionReport(
        isGo: Bool,
        unsatisfied: [ReadinessCriterion]
    ) throws -> URL {
        let report = GoNoGoDecisionReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            decision: isGo ? "GO" : "NO-GO",
            readinessSummary: readinessProgressSummary,
            unsatisfiedCriteriaIDs: unsatisfied.map(\.id),
            unsatisfiedCriteriaTitles: unsatisfied.map(\.title)
        )

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("readiness", isDirectory: true)
            .appendingPathComponent("go-no-go", isDirectory: true)
            .appendingPathComponent("decision-\(timestamp)-\(report.id.uuidString).json", isDirectory: false)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func persistPhaseStateReport() throws -> URL {
        let report = PhaseStateReport(
            id: UUID(),
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            readinessSummary: readinessProgressSummary,
            readinessCriteria: readinessCriteria,
            phaseMilestones: phaseMilestones,
            preflightStatusMessage: preflightStatusMessage,
            preflightFindings: preflightFindings
        )

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("readiness", isDirectory: true)
            .appendingPathComponent("phase-state", isDirectory: true)
            .appendingPathComponent("phase-state-\(timestamp)-\(report.id.uuidString).json", isDirectory: false)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }
}
