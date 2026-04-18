import Foundation
import Combine
import Virtualization

@MainActor
final class RuntimeWorkbenchViewModel: ObservableObject {
    @Published private(set) var hostProfile: HostProfile?
    @Published private(set) var hostErrorMessage: String = ""

    @Published private(set) var artifacts: [DistributionArtifact] = []
    @Published private(set) var catalogErrorMessage: String = ""

    @Published private(set) var checksumStatusMessage: String = ""
    @Published private(set) var signatureStatusMessage: String = ""
    @Published private(set) var keyringStatusMessage: String = ""
    @Published private(set) var requiredKeyringStatuses: [String: Bool] = [:]

    @Published private(set) var vmStatusMessage: String = ""
    @Published private(set) var installLifecycleState: VMInstallLifecycleState = .idle
    @Published private(set) var installLifecycleDetail: String = ""
    @Published private(set) var vmRuntimeState: VMRuntimeState = .stopped
    @Published private(set) var vmRuntimeStatusMessage: String = ""
    @Published private(set) var integrationStatusMessage: String = ""
    @Published private(set) var healthStatusMessage: String = ""
    @Published private(set) var healthReport: [String] = []
    @Published private(set) var cleanupStatusMessage: String = ""
    @Published private(set) var cleanupReport: [String] = []
    @Published private(set) var escalationStatusMessage: String = ""
    @Published private(set) var lastEscalationIssueURL: URL?
    @Published private(set) var registryStatusMessage: String = ""
    @Published private(set) var currentRunID: UUID?
    @Published private(set) var observabilityStatusMessage: String = ""
    @Published private(set) var lastRunReportPath: String = ""
    @Published private(set) var activeVMID: UUID?
    @Published private(set) var lastManagedVMID: UUID?

    @Published private(set) var downloadStatusMessage: String = ""
    @Published private(set) var downloadedInstallerPath: String = ""

    private let hostService: HostProfileService
    private let catalogService: DistributionCatalogService
    private let provisioningService: VMProvisioningService
    private let integrationService: IntegrationService
    private let healthService: HealthAndRepairService
    private let uninstallService: UninstallCleanupService
    private let escalationService: EscalationService
    private let downloader: ArtifactDownloading
    private let registry: VMRegistryManaging
    private let observability: RuntimeObservabilityLogging

    private var lastCatalogRefresh: Date?
    private let sourceMonitoringInterval: TimeInterval = 60 * 30
    private var cachedArtifacts: [HostArchitecture: [DistributionArtifact]] = [:]

    init(
        hostService: HostProfileService = DefaultHostProfileService(),
        catalogService: DistributionCatalogService = OfficialDistributionCatalogService(),
        provisioningService: VMProvisioningService = VMProvisioningPipelineService(),
        integrationService: IntegrationService = DefaultIntegrationService(),
        healthService: HealthAndRepairService = DefaultHealthAndRepairService(),
        uninstallService: UninstallCleanupService = DefaultUninstallCleanupService(),
        escalationService: EscalationService = DefaultEscalationService(),
        downloader: ArtifactDownloading = ResumableArtifactDownloader(),
        registry: VMRegistryManaging = PersistentVMRegistryStore(),
        observability: RuntimeObservabilityLogging = FileRuntimeObservabilityStore()
    ) {
        self.hostService = hostService
        self.catalogService = catalogService
        self.provisioningService = provisioningService
        self.integrationService = integrationService
        self.healthService = healthService
        self.uninstallService = uninstallService
        self.escalationService = escalationService
        self.downloader = downloader
        self.registry = registry
        self.observability = observability
    }

    func restoreVMRegistryState() async {
        do {
            let runID = try await observability.beginRun(vmID: nil)
            currentRunID = runID
            try await observability.appendEvent(
                runID: runID,
                vmID: nil,
                stage: .registryRestore,
                result: .inProgress,
                message: "Starting registry restore."
            )
        } catch {
            observabilityStatusMessage = "Observability init failed: \(error.localizedDescription)"
        }

        let entries = await registry.allEntries()
        if entries.isEmpty {
            registryStatusMessage = "VM registry is empty."
            installLifecycleState = .idle
            installLifecycleDetail = "No persisted VM install scaffolds were found."
            await logRunEvent(stage: .registryRestore, result: .success, vmID: nil, message: "Registry restore finished with no entries.")
            return
        }

        let integrationRoot = baseDirectory()
            .appendingPathComponent("integration", isDirectory: true)

        var validEntries: [VMRegistryEntry] = []
        var prunedCount = 0

        for entry in entries {
            let vmExists = FileManager.default.fileExists(atPath: entry.vmDirectoryPath)
            let integrationPath = integrationRoot
                .appendingPathComponent(entry.id.uuidString, isDirectory: true)
                .path
            let integrationExists = FileManager.default.fileExists(atPath: integrationPath)

            if vmExists || integrationExists {
                validEntries.append(entry)
            } else {
                do {
                    try await registry.remove(id: entry.id)
                    prunedCount += 1
                } catch {
                    registryStatusMessage = "Registry reconciliation failed: \(error.localizedDescription)"
                    await logRunEvent(stage: .registryRestore, result: .failed, vmID: entry.id, message: error.localizedDescription)
                    return
                }
            }
        }

        if let latest = validEntries.first {
            lastManagedVMID = latest.id
            if FileManager.default.fileExists(atPath: latest.vmDirectoryPath) {
                activeVMID = latest.id
                installLifecycleState = .ready
                installLifecycleDetail = "Restored VM scaffold from registry for \(latest.vmName)."
                vmRuntimeState = .stopped
                vmRuntimeStatusMessage = "Restored VM scaffold is currently stopped."
            }
        } else {
            installLifecycleState = .idle
            installLifecycleDetail = "No valid VM scaffold entries were restored."
            vmRuntimeState = .stopped
        }

        registryStatusMessage = "Registry restored \(validEntries.count) VM entries, pruned \(prunedCount) stale entries."
        await logRunEvent(
            stage: .registryRestore,
            result: .success,
            vmID: activeVMID,
            message: "Registry restored \(validEntries.count) entries and pruned \(prunedCount)."
        )
    }

    func loadStoredGitHubToken() -> String {
        guard let credentialService = escalationService as? EscalationCredentialManageable else {
            escalationStatusMessage = "Stored token management is unavailable in current escalation service."
            return ""
        }

        let token = credentialService.loadStoredGitHubToken() ?? ""
        escalationStatusMessage = token.isEmpty
            ? "No stored GitHub token found."
            : "Loaded stored GitHub token from Keychain."
        return token
    }

    func saveGitHubTokenToKeychain(_ token: String) {
        guard let credentialService = escalationService as? EscalationCredentialManageable else {
            escalationStatusMessage = "Stored token management is unavailable in current escalation service."
            return
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            escalationStatusMessage = "Cannot save an empty GitHub token."
            return
        }

        do {
            try credentialService.saveGitHubToken(trimmed)
            escalationStatusMessage = "GitHub token saved to Keychain."
        } catch {
            escalationStatusMessage = "Failed to save GitHub token: \(error.localizedDescription)"
        }
    }

    func clearStoredGitHubToken() {
        guard let credentialService = escalationService as? EscalationCredentialManageable else {
            escalationStatusMessage = "Stored token management is unavailable in current escalation service."
            return
        }

        do {
            try credentialService.clearStoredGitHubToken()
            escalationStatusMessage = "Stored GitHub token removed from Keychain."
        } catch {
            escalationStatusMessage = "Failed to clear stored GitHub token: \(error.localizedDescription)"
        }
    }

    func exportCurrentRunReport() async {
        guard let runID = currentRunID else {
            observabilityStatusMessage = "No run is active yet."
            lastRunReportPath = ""
            return
        }

        do {
            let reportURL = try await observability.exportReport(runID: runID)
            lastRunReportPath = reportURL.path
            observabilityStatusMessage = "Run report ready: \(reportURL.path)"
        } catch {
            observabilityStatusMessage = "Run report export failed: \(error.localizedDescription)"
            lastRunReportPath = ""
        }
    }

    func makePreflightSnapshot() -> ReadinessPreflightSnapshot {
        let testRootEnabled = !(ProcessInfo.processInfo.environment[RuntimeEnvironment.testRootEnvironmentVariable] ?? "").isEmpty
        return ReadinessPreflightSnapshot(
            hostProfile: hostProfile,
            virtualizationSupported: VZVirtualMachine.isSupported,
            catalogHasArtifacts: !artifacts.isEmpty,
            catalogErrorMessage: catalogErrorMessage,
            installLifecycleState: installLifecycleState,
            hasManagedVM: (activeVMID != nil) || (lastManagedVMID != nil),
            testRootOverrideEnabled: testRootEnabled,
            currentRunID: currentRunID
        )
    }

    func detectHost() async {
        do {
            let profile = try await hostService.detectHostProfile()
            hostProfile = profile
            hostErrorMessage = ""
        } catch {
            hostErrorMessage = error.localizedDescription
        }
    }

    func refreshCatalog(for architecture: HostArchitecture, force: Bool = false) async {
        guard force || lastCatalogRefresh == nil || Date().timeIntervalSince(lastCatalogRefresh!) > sourceMonitoringInterval else {
            // Return cached artifacts if available and not forcing refresh
            if let cached = cachedArtifacts[architecture], !cached.isEmpty {
                artifacts = cached
                return
            }
            return
        }

        do {
            catalogErrorMessage = ""
            let fetched = try await catalogService.fetchArtifacts(for: architecture)
            artifacts = fetched
            cachedArtifacts[architecture] = fetched // Cache the results
            lastCatalogRefresh = Date()
        } catch {
            catalogErrorMessage = error.localizedDescription
        }
    }

    func refreshKeyringStatus(for distribution: LinuxDistribution) {
        let required = catalogService.requiredKeyringFileNames(for: distribution)
        let directory = keyringDirectoryURL()

        var statuses: [String: Bool] = [:]
        for file in required {
            let url = directory.appendingPathComponent(file)
            statuses[file] = FileManager.default.fileExists(atPath: url.path)
        }
        requiredKeyringStatuses = statuses
    }

    func setKeyringImportStatus(_ message: String) {
        keyringStatusMessage = message
    }

    func importKeyring(from sourceURL: URL, preferredFileName: String?) {
        do {
            let fileName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? preferredFileName!.trimmingCharacters(in: .whitespacesAndNewlines)
                : sourceURL.lastPathComponent

            guard !fileName.isEmpty else {
                throw RuntimeServiceError.invalidVMRequest("Unable to determine target keyring file name.")
            }

            let destinationURL = keyringDirectoryURL().appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            keyringStatusMessage = "Imported keyring: \(destinationURL.path)"
        } catch {
            keyringStatusMessage = "Import keyring failed: \(error.localizedDescription)"
        }
    }

    func verifyChecksum(artifact: DistributionArtifact, localPath: String) async {
        let trimmedPath = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = URL(fileURLWithPath: trimmedPath)

        do {
            let matches = try await catalogService.verifyChecksum(for: artifact, at: fileURL)
            checksumStatusMessage = matches
                ? "Checksum verified for \(artifact.distribution.rawValue)."
                : "Checksum mismatch for \(artifact.distribution.rawValue)."
        } catch {
            checksumStatusMessage = "Checksum verification failed: \(error.localizedDescription)"
        }
    }

    func verifySignature(artifact: DistributionArtifact) async {
        do {
            let verified = try await catalogService.verifySignature(for: artifact)
            if artifact.signatureExpected {
                signatureStatusMessage = verified
                    ? "Source signature verified for \(artifact.distribution.rawValue)."
                    : "Signature not verified for \(artifact.distribution.rawValue). Import required keyring files first."
            } else {
                signatureStatusMessage = "No signature metadata configured for \(artifact.distribution.rawValue)."
            }
        } catch {
            signatureStatusMessage = "Signature verification failed: \(error.localizedDescription)"
        }
    }

    func downloadArtifact(_ artifact: DistributionArtifact) async {
        guard artifact.downloadURL.pathExtension.lowercased() == "iso" else {
            downloadStatusMessage = "Automatic download is unavailable for this source. Open official link and set installer path manually."
            return
        }

        await logRunEvent(
            stage: .artifactDownload,
            result: .inProgress,
            vmID: activeVMID,
            message: "Downloading \(artifact.distribution.rawValue) \(artifact.version)."
        )

        do {
            let downloadsDir = try downloadsDirectory()
            let destinationURL = downloadsDir.appendingPathComponent(artifact.downloadURL.lastPathComponent)

            try await downloader.downloadArtifact(
                primaryURL: artifact.downloadURL,
                mirrorURLs: artifact.mirrorURLs,
                destinationURL: destinationURL,
                maxRetriesPerURL: 3
            )

            if !artifact.checksumSHA256.isEmpty {
                let matches = try await catalogService.verifyChecksum(for: artifact, at: destinationURL)
                guard matches else {
                    throw RuntimeServiceError.invalidVMRequest("Downloaded ISO checksum mismatch for \(artifact.distribution.rawValue).")
                }
            }

            downloadedInstallerPath = destinationURL.path
            downloadStatusMessage = "Downloaded installer: \(destinationURL.path)"
            checksumStatusMessage = artifact.checksumSHA256.isEmpty
                ? "Checksum feed unavailable; verify manually if required."
                : "Checksum verified for downloaded installer."

            await verifySignature(artifact: artifact)
            await logRunEvent(
                stage: .artifactDownload,
                result: .success,
                vmID: activeVMID,
                message: "Download succeeded at \(destinationURL.path)."
            )
        } catch {
            downloadStatusMessage = "Download failed: \(error.localizedDescription)"
            await logRunEvent(
                stage: .artifactDownload,
                result: .failed,
                vmID: activeVMID,
                message: error.localizedDescription
            )
        }
    }

    func scaffoldInstall(
        distribution: LinuxDistribution,
        architecture: HostArchitecture,
        runtime: RuntimeEngine,
        vmName: String,
        installerImagePath: String,
        kernelImagePath: String,
        initialRamdiskPath: String
    ) async {
        do {
            let runID = try await observability.beginRun(vmID: nil)
            currentRunID = runID
            observabilityStatusMessage = "Started run \(runID.uuidString)."
        } catch {
            observabilityStatusMessage = "Observability init failed: \(error.localizedDescription)"
        }

        installLifecycleState = .validating
        installLifecycleDetail = ""
        await logRunEvent(stage: .installValidation, result: .inProgress, vmID: nil, message: "Validating install request.")

        let request = VMInstallRequest(
            distribution: distribution,
            runtimeEngine: runtime,
            architecture: architecture,
            cpuCores: architecture == .appleSilicon ? 4 : 2,
            memoryGB: architecture == .appleSilicon ? 8 : 6,
            diskGB: 64,
            enableSharedFolders: true,
            enableSharedClipboard: true
        )

        do {
            let resolvedInstallerPath: String
            let trimmedManual = installerImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedManual.isEmpty {
                resolvedInstallerPath = trimmedManual
            } else if !downloadedInstallerPath.isEmpty {
                resolvedInstallerPath = downloadedInstallerPath
            } else {
                throw RuntimeServiceError.missingAssets("Provide installer image path or download an ISO from the catalog first.")
            }

            let assets = try makeAssets(
                vmName: vmName,
                installerImagePath: resolvedInstallerPath,
                kernelImagePath: kernelImagePath,
                initialRamdiskPath: initialRamdiskPath
            )

            installLifecycleState = .scaffolding
            await logRunEvent(stage: .installScaffolding, result: .inProgress, vmID: nil, message: "Scaffolding VM assets.")
            let vmID = try await provisioningService.installVM(using: request, assets: assets)
            activeVMID = vmID
            lastManagedVMID = vmID
            installLifecycleState = .ready
            installLifecycleDetail = "Install scaffold completed for VM \(vmID.uuidString)."
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "VM scaffold is ready and currently stopped."
            vmStatusMessage = "VM pipeline scaffolded with automation assets when supported. ID: \(vmID.uuidString). VM assets at: \(assets.vmDirectoryURL.path)"
            await logRunEvent(stage: .installReady, result: .success, vmID: vmID, message: installLifecycleDetail)
        } catch {
            installLifecycleState = .failed
            installLifecycleDetail = error.localizedDescription
            vmStatusMessage = "VM pipeline failed: \(error.localizedDescription)"
            await logRunEvent(stage: .installScaffolding, result: .failed, vmID: nil, message: error.localizedDescription)
        }
    }

    func startActiveVM() async {
        guard let vmID = activeVMID else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        vmRuntimeState = .starting
        await logRunEvent(stage: .vmRuntimeControl, result: .inProgress, vmID: vmID, message: "Starting VM runtime.")

        do {
            try await provisioningService.startVM(id: vmID)
            vmRuntimeState = .running
            vmRuntimeStatusMessage = "VM \(vmID.uuidString) is running."
            await logRunEvent(stage: .vmRuntimeControl, result: .success, vmID: vmID, message: vmRuntimeStatusMessage)
        } catch {
            vmRuntimeState = .failed
            vmRuntimeStatusMessage = "Start VM failed: \(error.localizedDescription)"
            await logRunEvent(stage: .vmRuntimeControl, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func stopActiveVM() async {
        guard let vmID = activeVMID else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        vmRuntimeState = .stopping
        await logRunEvent(stage: .vmRuntimeControl, result: .inProgress, vmID: vmID, message: "Stopping VM runtime.")

        do {
            try await provisioningService.stopVM(id: vmID)
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "VM \(vmID.uuidString) is stopped."
            await logRunEvent(stage: .vmRuntimeControl, result: .success, vmID: vmID, message: vmRuntimeStatusMessage)
        } catch {
            vmRuntimeState = .failed
            vmRuntimeStatusMessage = "Stop VM failed: \(error.localizedDescription)"
            await logRunEvent(stage: .vmRuntimeControl, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func restartActiveVM() async {
        guard activeVMID != nil else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        vmRuntimeState = .restarting
        await stopActiveVM()
        if vmRuntimeState == .failed { return }
        await startActiveVM()
        if vmRuntimeState == .running {
            vmRuntimeStatusMessage = "VM restart completed."
        }
    }

    func runHealthCheck() async {
        guard let vmID = activeVMID else {
            healthStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            healthReport = []
            return
        }

        await logRunEvent(stage: .healthCheck, result: .inProgress, vmID: vmID, message: "Running health checks.")

        do {
            let report = try await healthService.runHealthCheck(for: vmID)
            healthReport = report
            let warnings = report.filter { $0.hasPrefix("WARN") }.count
            healthStatusMessage = "Health check finished for VM \(vmID.uuidString). Warnings: \(warnings)."
            await logRunEvent(stage: .healthCheck, result: .success, vmID: vmID, message: healthStatusMessage)
        } catch {
            healthStatusMessage = "Health check failed: \(error.localizedDescription)"
            healthReport = []
            await logRunEvent(stage: .healthCheck, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func applyAutoHeal() async {
        guard let vmID = activeVMID else {
            healthStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        await logRunEvent(stage: .autoHeal, result: .inProgress, vmID: vmID, message: "Applying automatic repair.")

        do {
            let actions = try await healthService.applyAutomaticRepair(for: vmID)
            healthReport = actions
            healthStatusMessage = "Auto-heal completed for VM \(vmID.uuidString)."
            await logRunEvent(stage: .autoHeal, result: .success, vmID: vmID, message: healthStatusMessage)
        } catch {
            healthStatusMessage = "Auto-heal failed: \(error.localizedDescription)"
            await logRunEvent(stage: .autoHeal, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func uninstallActiveVM(removeArtifacts: Bool = true) async {
        guard let vmID = activeVMID else {
            cleanupStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            cleanupReport = []
            return
        }

        await logRunEvent(stage: .cleanup, result: .inProgress, vmID: vmID, message: "Running uninstall and cleanup.")

        do {
            try await uninstallService.uninstallVM(id: vmID, removeArtifacts: removeArtifacts)
            let report = try await uninstallService.verifyCleanup(id: vmID)
            cleanupReport = report
            cleanupStatusMessage = "Uninstall completed for VM \(vmID.uuidString)."
            lastManagedVMID = vmID
            activeVMID = nil
            installLifecycleState = .idle
            installLifecycleDetail = "No active VM install scaffold is currently selected."
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "No active VM runtime."
            await logRunEvent(stage: .cleanup, result: .success, vmID: vmID, message: cleanupStatusMessage)
        } catch {
            cleanupStatusMessage = "Uninstall failed: \(error.localizedDescription)"
            cleanupReport = []
            await logRunEvent(stage: .cleanup, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func verifyCleanupForLastKnownVM() async {
        guard let vmID = lastManagedVMID ?? activeVMID else {
            cleanupStatusMessage = "No known VM available for cleanup verification."
            cleanupReport = []
            return
        }

        do {
            cleanupReport = try await uninstallService.verifyCleanup(id: vmID)
            cleanupStatusMessage = "Cleanup verification completed for VM \(vmID.uuidString)."
        } catch {
            cleanupStatusMessage = "Cleanup verification failed: \(error.localizedDescription)"
            cleanupReport = []
        }
    }

    func escalateToDevelopers(
        issueTitle: String,
        issueDetails: String,
        githubOwner: String,
        githubRepository: String,
        githubToken: String,
        supportEmail: String,
        sendGitHubIssue: Bool,
        sendEmail: Bool,
        includeDiagnostics: Bool
    ) async {
        let title = issueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = issueDetails.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else {
            escalationStatusMessage = "Escalation requires an issue title."
            return
        }
        guard !details.isEmpty else {
            escalationStatusMessage = "Escalation requires issue details."
            return
        }

        if let configurable = escalationService as? EscalationConfigurable {
            configurable.updateGitHubConfiguration(owner: githubOwner, repository: githubRepository, token: githubToken)
            configurable.updateEmailConfiguration(recipient: supportEmail)
        }

        do {
            let diagnostics = includeDiagnostics ? try createDiagnosticsBundle(title: title, details: details) : nil
            var outcomes: [String] = []
            await logRunEvent(stage: .escalation, result: .inProgress, vmID: activeVMID, message: "Preparing escalation request.")

            if sendGitHubIssue {
                let issueURL = try await escalationService.openGitHubIssue(
                    title: title,
                    details: details,
                    logs: diagnostics
                )
                lastEscalationIssueURL = issueURL
                outcomes.append("GitHub issue created: \(issueURL.absoluteString)")
            }

            if sendEmail {
                let attachments: [URL] = diagnostics.map { [$0] } ?? []
                try await escalationService.sendEmailEscalation(
                    subject: title,
                    body: details,
                    attachments: attachments
                )
                outcomes.append("Email escalation triggered")
            }

            if outcomes.isEmpty {
                escalationStatusMessage = "No escalation channel selected."
            } else {
                escalationStatusMessage = outcomes.joined(separator: " | ")
            }
            await logRunEvent(stage: .escalation, result: .success, vmID: activeVMID, message: escalationStatusMessage)
        } catch {
            escalationStatusMessage = "Escalation failed: \(error.localizedDescription)"
            await logRunEvent(stage: .escalation, result: .failed, vmID: activeVMID, message: error.localizedDescription)
        }
    }

    private func createDiagnosticsBundle(title: String, details: String) throws -> URL {
        let diagnosticsDir = baseDirectory()
            .appendingPathComponent("diagnostics", isDirectory: true)

        try FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "title": title,
            "details": details,
            "activeVMID": activeVMID?.uuidString as Any,
            "lastManagedVMID": lastManagedVMID?.uuidString as Any,
            "vmStatus": vmStatusMessage,
            "integrationStatus": integrationStatusMessage,
            "healthStatus": healthStatusMessage,
            "cleanupStatus": cleanupStatusMessage,
            "healthReport": healthReport,
            "cleanupReport": cleanupReport
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let fileURL = diagnosticsDir.appendingPathComponent("diagnostics-\(UUID().uuidString).json")
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    func configureSharedResources() async {
        guard let vmID = activeVMID else {
            integrationStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        do {
            try await integrationService.configureSharedResources(for: vmID)
            integrationStatusMessage = "Shared resources configured for VM \(vmID.uuidString)."
        } catch {
            integrationStatusMessage = "Shared resource configuration failed: \(error.localizedDescription)"
        }
    }

    func configureLauncherEntries() async {
        guard let vmID = activeVMID else {
            integrationStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        do {
            try await integrationService.configureLauncherEntries(for: vmID)
            integrationStatusMessage = "Launcher entries configured for VM \(vmID.uuidString)."
        } catch {
            integrationStatusMessage = "Launcher configuration failed: \(error.localizedDescription)"
        }
    }

    func enableRootlessLinuxApps() async {
        guard let vmID = activeVMID else {
            integrationStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        do {
            try await integrationService.enableRootlessLinuxApps(for: vmID)
            integrationStatusMessage = "Rootless Linux app integration enabled for VM \(vmID.uuidString)."
        } catch {
            integrationStatusMessage = "Rootless integration failed: \(error.localizedDescription)"
        }
    }

    private func downloadsDirectory() throws -> URL {
        let directory = baseDirectory()
            .appendingPathComponent("downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func keyringDirectoryURL() -> URL {
        let directory = baseDirectory()
            .appendingPathComponent("keys", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeAssets(
        vmName: String,
        installerImagePath: String,
        kernelImagePath: String,
        initialRamdiskPath: String
    ) throws -> VMInstallAssets {
        let resolvedName = vmName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("VM name must not be empty.")
        }

        let vmDirectory = baseDirectory()
            .appendingPathComponent("vms", isDirectory: true)
            .appendingPathComponent(resolvedName, isDirectory: true)

        let installerURL = nonEmptyPathURL(installerImagePath)
        guard installerURL != nil else {
            throw RuntimeServiceError.missingAssets("Installer image path is required.")
        }

        let kernelURL = nonEmptyPathURL(kernelImagePath)
        let ramdiskURL = nonEmptyPathURL(initialRamdiskPath)

        return VMInstallAssets(
            vmName: resolvedName,
            vmDirectoryURL: vmDirectory,
            installerImageURL: installerURL,
            kernelImageURL: kernelURL,
            initialRamdiskURL: ramdiskURL,
            diskImageURL: vmDirectory.appendingPathComponent("disk.img"),
            efiVariableStoreURL: vmDirectory.appendingPathComponent("efi.vars"),
            machineIdentifierURL: vmDirectory.appendingPathComponent("machine.id")
        )
    }

    private func nonEmptyPathURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private func logRunEvent(
        stage: RuntimeRunStage,
        result: RuntimeRunResult,
        vmID: UUID?,
        message: String
    ) async {
        do {
            let runID: UUID
            if let currentRunID {
                runID = currentRunID
            } else {
                runID = try await observability.beginRun(vmID: vmID)
                currentRunID = runID
            }

            try await observability.appendEvent(
                runID: runID,
                vmID: vmID,
                stage: stage,
                result: result,
                message: message
            )
        } catch {
            observabilityStatusMessage = "Observability logging failed: \(error.localizedDescription)"
        }
    }

    private func baseDirectory() -> URL {
        RuntimeEnvironment.mlIntegrationRootURL()
    }
}
