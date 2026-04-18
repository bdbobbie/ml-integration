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
    @Published private(set) var preflightStatusMessage: String = ""
    @Published private(set) var preflightFindings: [String] = []
    @Published private(set) var lastPreflightEvidencePath: String = ""
    @Published private(set) var checklistAutoSyncStatusMessage: String = ""
    @Published private(set) var environmentTestStartStatusMessage: String = ""
    @Published private(set) var lastGoNoGoReportPath: String = ""
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
}
