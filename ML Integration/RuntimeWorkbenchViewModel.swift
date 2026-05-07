import Foundation
import Combine
import Virtualization
import Darwin

@MainActor
final class RuntimeWorkbenchViewModel: ObservableObject {
    struct RuntimePhaseReadiness: Equatable {
        let coherenceReady: Bool
        let deviceMediaReady: Bool
        let displayV2Ready: Bool
    }

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
    @Published private(set) var coherenceSharedFoldersReady: Bool = false
    @Published private(set) var coherenceClipboardReady: Bool = false
    @Published private(set) var coherenceLauncherReady: Bool = false
    @Published private(set) var coherenceWindowPolicyReady: Bool = false
    @Published private(set) var coherenceWindowPolicySchemaValid: Bool = false
    @Published private(set) var coherenceStatusSummary: String = "Coherence essentials not prepared."
    @Published private(set) var deviceAudioReady: Bool = false
    @Published private(set) var deviceMicReady: Bool = false
    @Published private(set) var deviceCameraReady: Bool = false
    @Published private(set) var deviceUSBReady: Bool = false
    @Published private(set) var deviceMediaStatusSummary: String = "Device/media readiness not assessed."
    @Published private(set) var v1DisplayCountLocked: Int = 1
    @Published private(set) var v2DisplayTargetCount: Int = 3
    @Published private(set) var v2MultiDisplayPlanReady: Bool = false
    @Published private(set) var displayPlanStatusSummary: String = "Display plan not assessed."
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
    @Published private(set) var installedVMEntries: [VMRegistryEntry] = []
    @Published private(set) var activeRuntimeVMIDs: [UUID] = []
    @Published private(set) var customCatalogEntries: [CustomCatalogEntry] = []

    @Published private(set) var downloadStatusMessage: String = ""
    @Published private(set) var downloadedInstallerPath: String = ""
    @Published private(set) var hasDownloadedInstallers: Bool = false
    @Published private(set) var isDownloadInProgress: Bool = false
    @Published private(set) var downloadProgressFraction: Double?
    @Published private(set) var downloadSpeedText: String = ""
    @Published private(set) var downloadETAText: String = ""
    @Published private(set) var installProgressFraction: Double?
    @Published private(set) var installSpeedText: String = ""
    @Published private(set) var installETAText: String = ""
    @Published private(set) var qemuRuntimeStatusMessage: String = ""
    @Published private(set) var isQEMUAvailable: Bool?

    var coherenceWindowPolicySchemaInvalid: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment[RuntimeEnvironment.uiForceSchemaInvalidVariable] == "1" ||
            processInfo.arguments.contains(RuntimeEnvironment.uiForceSchemaInvalidArgument) {
            return true
        }
        return healthReport.contains("WARN: Window coherence policy schema invalid")
    }

    var isUIRepairActionForceEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment[RuntimeEnvironment.uiEnableRepairActionVariable] == "1" ||
            processInfo.arguments.contains(RuntimeEnvironment.uiEnableRepairActionArgument)
    }

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
    private var activeDownloadStartDate: Date?
    private var activeInstallStartDate: Date?

    init(
        hostService: HostProfileService? = nil,
        catalogService: DistributionCatalogService? = nil,
        provisioningService: VMProvisioningService? = nil,
        integrationService: IntegrationService? = nil,
        healthService: HealthAndRepairService? = nil,
        uninstallService: UninstallCleanupService? = nil,
        escalationService: EscalationService? = nil,
        downloader: ArtifactDownloading? = nil,
        registry: VMRegistryManaging? = nil,
        observability: RuntimeObservabilityLogging? = nil
    ) {
        self.hostService = hostService ?? DefaultHostProfileService()
        self.catalogService = catalogService ?? OfficialDistributionCatalogService()
        self.provisioningService = provisioningService ?? VMProvisioningPipelineService(
            qemuHook: ProcessQEMUFallbackHook(),
            registry: PersistentVMRegistryStore()
        )
        self.integrationService = integrationService ?? DefaultIntegrationService()
        self.healthService = healthService ?? DefaultHealthAndRepairService()
        self.uninstallService = uninstallService ?? DefaultUninstallCleanupService()
        self.escalationService = escalationService ?? DefaultEscalationService()
        self.downloader = downloader ?? ResumableArtifactDownloader()
        self.registry = registry ?? PersistentVMRegistryStore()
        self.observability = observability ?? FileRuntimeObservabilityStore()

        traceVM("Build marker: VM-LAUNCH-DIAG-2026-04-23T00:00Z")
        Task {
            let logPath = await DebugTraceLogger.shared.path()
            let downloadPath = (try? self.downloadsDirectory().path) ?? "unavailable"
            await DebugTraceLogger.shared.append("RuntimeWorkbenchViewModel init complete. downloadDirectoryPath=\(downloadPath)")
            await DebugTraceLogger.shared.append("Debug trace log path: \(logPath)")
            await MainActor.run {
                self.refreshDownloadedInstallerPresence()
                self.loadCustomCatalogEntries()
            }
        }
    }

    func addCustomCatalogEntry(
        displayName: String,
        installerPath: String,
        architecture: HostArchitecture,
        runtimeEngine: RuntimeEngine,
        baseDistribution: LinuxDistribution
    ) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("Custom OS name is required.")
        }

        let trimmedPath = installerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("Installer path is required.")
        }

        let fileURL = URL(fileURLWithPath: trimmedPath)
        guard fileURL.pathExtension.lowercased() == "iso",
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RuntimeServiceError.invalidVMRequest("Installer must be an existing ISO file.")
        }

        let entry = CustomCatalogEntry(
            id: UUID(),
            displayName: trimmedName,
            installerPath: fileURL.path,
            architecture: architecture,
            runtimeEngine: runtimeEngine,
            baseDistribution: baseDistribution,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        customCatalogEntries.insert(entry, at: 0)
        try persistCustomCatalogEntries()
    }

    func removeCustomCatalogEntry(id: UUID) throws {
        customCatalogEntries.removeAll { $0.id == id }
        try persistCustomCatalogEntries()
    }

    func updateCustomCatalogEntry(
        id: UUID,
        displayName: String,
        installerPath: String,
        architecture: HostArchitecture,
        runtimeEngine: RuntimeEngine,
        baseDistribution: LinuxDistribution
    ) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("Custom OS name is required.")
        }
        let trimmedPath = installerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validateCustomInstallerPath(trimmedPath) else {
            throw RuntimeServiceError.invalidVMRequest("Installer must be an existing ISO file.")
        }
        guard let index = customCatalogEntries.firstIndex(where: { $0.id == id }) else {
            throw RuntimeServiceError.invalidVMRequest("Custom OS entry not found.")
        }
        customCatalogEntries[index] = CustomCatalogEntry(
            id: id,
            displayName: trimmedName,
            installerPath: trimmedPath,
            architecture: architecture,
            runtimeEngine: runtimeEngine,
            baseDistribution: baseDistribution,
            createdAtISO8601: customCatalogEntries[index].createdAtISO8601
        )
        try persistCustomCatalogEntries()
    }

    func validateCustomInstallerPath(_ path: String) -> Bool {
        let fileURL = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard fileURL.pathExtension.lowercased() == "iso",
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        return true
    }

    func customCatalogEntriesForCurrentArchitecture(_ architecture: HostArchitecture) -> [CustomCatalogEntry] {
        customCatalogEntries.filter { $0.architecture == architecture }
    }

    func suggestedDistributionForInstaller(_ path: String) -> LinuxDistribution? {
        let lowerPath = path.lowercased()
        if lowerPath.contains("ubuntu") { return .ubuntu }
        if lowerPath.contains("debian") { return .debian }
        if lowerPath.contains("fedora") { return .fedora }
        if lowerPath.contains("pop") { return .popOS }
        if lowerPath.contains("nixos") || lowerPath.contains("nix") { return .nixOS }
        if lowerPath.contains("opensuse") || lowerPath.contains("suse") { return .openSUSE }
        if lowerPath.contains("win11") || lowerPath.contains("windows") { return .windows11 }

        let fileURL = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        let prefixData = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        guard let text = String(data: prefixData, encoding: .ascii)?.lowercased() else {
            return nil
        }
        if text.contains("ubuntu") { return .ubuntu }
        if text.contains("debian") { return .debian }
        if text.contains("fedora") { return .fedora }
        if text.contains("pop!_os") || text.contains("pop os") { return .popOS }
        if text.contains("nixos") { return .nixOS }
        if text.contains("opensuse") { return .openSUSE }
        if text.contains("windows") { return .windows11 }
        return nil
    }

    func exportCustomCatalog(to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(customCatalogEntries)
        try data.write(to: destinationURL, options: [.atomic])
    }

    func importCustomCatalog(from sourceURL: URL, merge: Bool = true) throws {
        let data = try Data(contentsOf: sourceURL)
        let imported = try JSONDecoder().decode([CustomCatalogEntry].self, from: data)
        if merge {
            var byID: [UUID: CustomCatalogEntry] = Dictionary(uniqueKeysWithValues: customCatalogEntries.map { ($0.id, $0) })
            for entry in imported {
                byID[entry.id] = entry
            }
            customCatalogEntries = byID.values.sorted { $0.createdAtISO8601 > $1.createdAtISO8601 }
        } else {
            customCatalogEntries = imported
        }
        try persistCustomCatalogEntries()
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

        let restoredSession = restoreRuntimeSessionSnapshotIfAvailable()
        let entries = await registry.allEntries()
        if entries.isEmpty {
            registryStatusMessage = "VM registry is empty."
            activeVMID = nil
            lastManagedVMID = nil
            installedVMEntries = []
            clearRuntimeSessionSnapshot()
            installLifecycleState = .idle
            installLifecycleDetail = "No persisted VM install scaffolds were found."
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "No active VM runtime."
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
        installedVMEntries = validEntries

        registryStatusMessage = "Registry restored \(validEntries.count) VM entries, pruned \(prunedCount) stale entries."
        _ = applyRestoredRuntimeSession(restoredSession, validVMIDs: Set(validEntries.map(\.id)))
        await logRunEvent(
            stage: .registryRestore,
            result: .success,
            vmID: activeVMID,
            message: "Registry restored \(validEntries.count) entries and pruned \(prunedCount)."
        )
    }

    func reconcileManagedVMIdentifiers() async {
        let entries = await registry.allEntries()
        let installedEntries = entries.filter { FileManager.default.fileExists(atPath: $0.vmDirectoryPath) }
        installedVMEntries = installedEntries
        let validIDs = Set(installedEntries.map(\.id))
        let previousActive = activeVMID
        let previousLast = lastManagedVMID

        if let activeVMID, !validIDs.contains(activeVMID) {
            self.activeVMID = nil
        }
        if let lastManagedVMID, !validIDs.contains(lastManagedVMID) {
            self.lastManagedVMID = nil
        }
        if self.activeVMID == nil && self.lastManagedVMID == nil {
            clearRuntimeSessionSnapshot()
        }

        if previousActive != self.activeVMID || previousLast != self.lastManagedVMID {
            traceVM(
                "RuntimeWorkbenchViewModel.reconcileManagedVMIdentifiers updated " +
                "active=\(self.activeVMID?.uuidString ?? "nil") lastManaged=\(self.lastManagedVMID?.uuidString ?? "nil")"
            )
        }
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

    @discardableResult
    func probeQEMUAvailability(for architecture: HostArchitecture) async -> Bool {
        let qemuBinary = QEMUBinaryLocator.binaryName(for: architecture)
        if let locatedPath = QEMUBinaryLocator.locateBinaryPath(for: architecture) {
            isQEMUAvailable = true
            qemuRuntimeStatusMessage = "QEMU found: \(locatedPath)"
            return true
        }

        isQEMUAvailable = false
        qemuRuntimeStatusMessage = "QEMU missing: install \(qemuBinary) before using this runtime."
        return false
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
            isDownloadInProgress = true
            defer { isDownloadInProgress = false }
            let downloadsDir = try downloadsDirectory()
            let destinationURL = downloadsDir.appendingPathComponent(artifact.downloadURL.lastPathComponent)
            activeDownloadStartDate = Date()
            downloadProgressFraction = nil
            downloadSpeedText = ""
            downloadETAText = ""

            try await downloader.downloadArtifact(
                primaryURL: artifact.downloadURL,
                mirrorURLs: artifact.mirrorURLs,
                destinationURL: destinationURL,
                maxRetriesPerURL: 3,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.downloadProgressFraction = progress.fractionCompleted
                        self.downloadStatusMessage = "Downloading \(artifact.distribution.rawValue): \(self.formatDownloadProgress(progress))"
                        self.updateDownloadSpeedAndETA(progress)
                    }
                }
            )

            if !artifact.checksumSHA256.isEmpty {
                let matches = try await catalogService.verifyChecksum(for: artifact, at: destinationURL)
                guard matches else {
                    throw RuntimeServiceError.invalidVMRequest("Downloaded ISO checksum mismatch for \(artifact.distribution.rawValue).")
                }
            }

            downloadedInstallerPath = destinationURL.path
            hasDownloadedInstallers = true
            downloadProgressFraction = 1.0
            downloadSpeedText = ""
            downloadETAText = ""
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
            isDownloadInProgress = false
            downloadProgressFraction = nil
            downloadSpeedText = ""
            downloadETAText = ""
            if error is CancellationError || Task.isCancelled {
                downloadStatusMessage = "Download canceled."
            } else {
                downloadStatusMessage = "Download failed: \(error.localizedDescription)"
            }
            refreshDownloadedInstallerPresence()
            await logRunEvent(
                stage: .artifactDownload,
                result: .failed,
                vmID: activeVMID,
                message: error.localizedDescription
            )
        }
    }

    func cancelDownloadStatus(for distribution: LinuxDistribution?) -> String {
        let label = distribution?.rawValue ?? "installer"
        let percent: String
        if let fraction = downloadProgressFraction {
            percent = "\(Int((fraction * 100).rounded()))%"
        } else {
            percent = "in progress"
        }
        return "Stopping \(label) download at \(percent)..."
    }

    func markDownloadCancellationRequested() {
        downloadStatusMessage = "Download cancellation requested..."
    }

    func removeManagedVMAndDownloadedInstallers(removeArtifacts: Bool = true) async {
        let managedVMID = activeVMID ?? lastManagedVMID
        if managedVMID != nil {
            await uninstallActiveVM(removeArtifacts: removeArtifacts)
        }

        var removedDownloadCount = 0
        do {
            let downloadsDir = try downloadsDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: downloadsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "iso" {
                try FileManager.default.removeItem(at: file)
                removedDownloadCount += 1
            }
        } catch {
            cleanupStatusMessage = "Cleanup failed while removing downloaded installers: \(error.localizedDescription)"
            return
        }

        downloadedInstallerPath = ""
        refreshDownloadedInstallerPresence()
        if removedDownloadCount > 0 {
            downloadStatusMessage = "Removed \(removedDownloadCount) downloaded installer file(s)."
        } else if managedVMID == nil {
            cleanupStatusMessage = "No installed VM or downloaded installers were found."
        }
    }

    private func formatDownloadProgress(_ progress: ArtifactDownloadProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file

        let received = formatter.string(fromByteCount: progress.receivedBytes)
        if let total = progress.totalBytes, total > 0 {
            let totalText = formatter.string(fromByteCount: total)
            let percent = Int(((progress.fractionCompleted ?? 0) * 100).rounded())
            return "\(percent)% (\(received) / \(totalText))"
        }

        return "\(received) downloaded"
    }

    private func customCatalogStoreURL() -> URL {
        RuntimeEnvironment.mlIntegrationRootURL()
            .deletingLastPathComponent()
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("custom-os-catalog.json")
    }

    private func loadCustomCatalogEntries() {
        let url = customCatalogStoreURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            customCatalogEntries = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                customCatalogEntries = []
                return
            }
            customCatalogEntries = try JSONDecoder().decode([CustomCatalogEntry].self, from: data)
        } catch {
            customCatalogEntries = []
            vmStatusMessage = "Failed to load custom OS catalog: \(error.localizedDescription)"
        }
    }

    private func persistCustomCatalogEntries() throws {
        let url = customCatalogStoreURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(customCatalogEntries)
        try data.write(to: url, options: [.atomic])
    }

    private func updateDownloadSpeedAndETA(_ progress: ArtifactDownloadProgress) {
        guard let startedAt = activeDownloadStartDate else {
            downloadSpeedText = ""
            downloadETAText = ""
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else {
            downloadSpeedText = ""
            downloadETAText = ""
            return
        }

        let bytesPerSecond = Double(progress.receivedBytes) / elapsed
        let speedFormatter = ByteCountFormatter()
        speedFormatter.allowedUnits = [.useMB]
        speedFormatter.countStyle = .file
        downloadSpeedText = "Speed: \(speedFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))))/s"

        if let total = progress.totalBytes, total > progress.receivedBytes, bytesPerSecond > 0 {
            let remainingBytes = Double(total - progress.receivedBytes)
            let etaSeconds = Int(ceil(remainingBytes / bytesPerSecond))
            downloadETAText = "ETA: \(formatETA(seconds: etaSeconds))"
        } else {
            downloadETAText = "ETA: Calculating..."
        }
    }

    private func formatETA(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
        activeInstallStartDate = Date()
        installProgressFraction = 0.05
        installSpeedText = "Speed: local disk I/O"
        installETAText = "ETA: Calculating..."

        do {
            let runID = try await observability.beginRun(vmID: nil)
            currentRunID = runID
            observabilityStatusMessage = "Started run \(runID.uuidString)."
        } catch {
            observabilityStatusMessage = "Observability init failed: \(error.localizedDescription)"
        }

        installLifecycleState = .validating
        installLifecycleDetail = ""
        installProgressFraction = 0.2
        installETAText = "ETA: < 1 min"
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
            installProgressFraction = 0.65
            installETAText = "ETA: < 30s"
            await logRunEvent(stage: .installScaffolding, result: .inProgress, vmID: nil, message: "Scaffolding VM assets.")
            let vmID = try await provisioningService.installVM(using: request, assets: assets)
            activeVMID = vmID
            lastManagedVMID = vmID
            await reconcileManagedVMIdentifiers()
            installLifecycleState = .ready
            installLifecycleDetail = "Install scaffold completed for VM \(vmID.uuidString)."
            installProgressFraction = 1.0
            installETAText = "ETA: 0s"
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "VM scaffold is ready and currently stopped."
            vmStatusMessage = "VM pipeline scaffolded with automation assets when supported. ID: \(vmID.uuidString). VM assets at: \(assets.vmDirectoryURL.path)"
            persistRuntimeSessionSnapshot(vmID: vmID, state: .stopped)
            await logRunEvent(stage: .installReady, result: .success, vmID: vmID, message: installLifecycleDetail)
        } catch {
            installLifecycleState = .failed
            installLifecycleDetail = error.localizedDescription
            installProgressFraction = nil
            installETAText = ""
            vmStatusMessage = "VM pipeline failed: \(error.localizedDescription)"
            await logRunEvent(stage: .installScaffolding, result: .failed, vmID: nil, message: error.localizedDescription)
        }

        if let startedAt = activeInstallStartDate {
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.01)
            installSpeedText = "Speed: \(String(format: "%.1f", 1.0 / elapsed)) phases/s"
        }
    }

    func startActiveVM() async {
        await reconcileManagedVMIdentifiers()
        guard let vmID = activeVMID ?? lastManagedVMID else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            traceVM("startActiveVM exit no vm selected")
            return
        }
        activeVMID = vmID
        traceVM("startActiveVM requested vmID=\(vmID.uuidString)")

        vmRuntimeState = .starting
        vmRuntimeStatusMessage = "Starting VM \(vmID.uuidString)..."
        await logRunEvent(stage: .vmRuntimeControl, result: .inProgress, vmID: vmID, message: "Starting VM runtime.")

        do {
            traceVM("startActiveVM async begin vmID=\(vmID.uuidString)")
            try await provisioningService.startVM(id: vmID)
            traceVM("startActiveVM provisioningService.startVM returned vmID=\(vmID.uuidString)")
            vmRuntimeState = .running
            vmRuntimeStatusMessage = "VM \(vmID.uuidString) is running."
            if !activeRuntimeVMIDs.contains(vmID) {
                activeRuntimeVMIDs.append(vmID)
            }
            persistRuntimeSessionSnapshot(vmID: vmID, state: .running)
            await logRunEvent(stage: .vmRuntimeControl, result: .success, vmID: vmID, message: vmRuntimeStatusMessage)
        } catch {
            traceVM("startActiveVM failed vmID=\(vmID.uuidString) error=\(error.localizedDescription)")
            if case RuntimeServiceError.vmNotFound = error {
                activeVMID = nil
                lastManagedVMID = nil
                activeRuntimeVMIDs.removeAll { $0 == vmID }
                clearRuntimeSessionSnapshot()
                installLifecycleState = .idle
                installLifecycleDetail = "No VM scaffold is currently installed. Install an OS first."
            }
            vmRuntimeState = .failed
            vmRuntimeStatusMessage = "Start VM failed: \(error.localizedDescription)"
            await logRunEvent(stage: .vmRuntimeControl, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func stopActiveVM() async {
        guard let vmID = activeVMID ?? lastManagedVMID else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            traceVM("stopActiveVM exit no vm selected")
            return
        }
        activeVMID = vmID
        traceVM("stopActiveVM requested vmID=\(vmID.uuidString)")

        vmRuntimeState = .stopping
        await logRunEvent(stage: .vmRuntimeControl, result: .inProgress, vmID: vmID, message: "Stopping VM runtime.")

        traceVM("stopActiveVM dispatching provisioningService.stopVM vmID=\(vmID.uuidString)")
        Task {
            do {
                try await provisioningService.stopVM(id: vmID)
                traceVM("stopActiveVM provisioningService.stopVM returned vmID=\(vmID.uuidString)")
                await logRunEvent(stage: .vmRuntimeControl, result: .success, vmID: vmID, message: "VM \(vmID.uuidString) stop request completed.")
            } catch {
                traceVM("stopActiveVM failed vmID=\(vmID.uuidString) error=\(error.localizedDescription)")
                await logRunEvent(stage: .vmRuntimeControl, result: .failed, vmID: vmID, message: error.localizedDescription)
            }
        }

        vmRuntimeState = .stopped
        vmRuntimeStatusMessage = "VM \(vmID.uuidString) stop request dispatched."
        activeRuntimeVMIDs.removeAll { $0 == vmID }
        persistRuntimeSessionSnapshot(vmID: vmID, state: .stopped)
    }

    func restartActiveVM() async {
        guard let vmID = activeVMID ?? lastManagedVMID else {
            vmRuntimeStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }
        activeVMID = vmID

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
            coherenceWindowPolicySchemaValid = report.contains("OK: Window coherence policy schema valid")
            let warnings = report.filter { $0.hasPrefix("WARN") }.count
            healthStatusMessage = "Health check finished for VM \(vmID.uuidString). Warnings: \(warnings)."
            await logRunEvent(stage: .healthCheck, result: .success, vmID: vmID, message: healthStatusMessage)
        } catch {
            healthStatusMessage = "Health check failed: \(error.localizedDescription)"
            healthReport = []
            coherenceWindowPolicySchemaValid = false
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
            let postHealReport = try await healthService.runHealthCheck(for: vmID)
            coherenceWindowPolicySchemaValid = postHealReport.contains("OK: Window coherence policy schema valid")
            healthReport = actions + ["Post-heal verification:"] + postHealReport
            healthStatusMessage = "Auto-heal completed for VM \(vmID.uuidString)."
            await logRunEvent(stage: .autoHeal, result: .success, vmID: vmID, message: healthStatusMessage)
        } catch {
            healthStatusMessage = "Auto-heal failed: \(error.localizedDescription)"
            await logRunEvent(stage: .autoHeal, result: .failed, vmID: vmID, message: error.localizedDescription)
        }
    }

    func repairCoherencePolicy() async {
        await applyAutoHeal()
    }

    func uninstallActiveVM(removeArtifacts: Bool = true) async {
        guard let vmID = activeVMID ?? lastManagedVMID else {
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
            activeRuntimeVMIDs.removeAll { $0 == vmID }
            installLifecycleState = .idle
            installLifecycleDetail = "No active VM install scaffold is currently selected."
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "No active VM runtime."
            clearRuntimeSessionSnapshot()
            await reconcileManagedVMIdentifiers()
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

    func selectManagedVM(_ id: UUID?) async {
        await reconcileManagedVMIdentifiers()
        guard let id else { return }
        guard installedVMEntries.contains(where: { $0.id == id }) else {
            vmRuntimeStatusMessage = "Selected VM is no longer installed."
            return
        }
        activeVMID = id
        lastManagedVMID = id
        persistRuntimeSessionSnapshot(vmID: id, state: vmRuntimeState)
    }

    func startManagedVM(_ id: UUID) async {
        await selectManagedVM(id)
        await startActiveVM()
    }

    func stopManagedVM(_ id: UUID) async {
        await selectManagedVM(id)
        await stopActiveVM()
    }

    func runtimeFleetStatusSummary() -> String {
        let runningCount = activeRuntimeVMIDs.count
        return "Runtime fleet | Installed: \(installedVMEntries.count) | Running: \(runningCount)"
    }

    func isManagedVMRunning(_ id: UUID) -> Bool {
        activeRuntimeVMIDs.contains(id)
    }

    func stopAllRunningVMs() async {
        let runningVMIDs = activeRuntimeVMIDs
        guard !runningVMIDs.isEmpty else {
            vmRuntimeStatusMessage = "No running VMs to stop."
            return
        }
        for vmID in runningVMIDs {
            await stopManagedVM(vmID)
        }
        vmRuntimeStatusMessage = "Stopped \(runningVMIDs.count) running VM(s)."
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

    func createIssueDiagnosticsBundle(title: String, details: String) throws -> URL {
        try createDiagnosticsBundle(title: title, details: details)
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
            coherenceSharedFoldersReady = true
            coherenceClipboardReady = true
            updateCoherenceStatusSummary()
            integrationStatusMessage = "Shared resources configured for VM \(vmID.uuidString)."
        } catch {
            coherenceSharedFoldersReady = false
            coherenceClipboardReady = false
            updateCoherenceStatusSummary()
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
            coherenceLauncherReady = true
            updateCoherenceStatusSummary()
            integrationStatusMessage = "Launcher entries configured for VM \(vmID.uuidString)."
        } catch {
            coherenceLauncherReady = false
            updateCoherenceStatusSummary()
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

    func prepareCoherenceEssentials() async {
        guard let vmID = activeVMID else {
            integrationStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        await logRunEvent(stage: .coherenceEssentials, result: .inProgress, vmID: vmID, message: "Preparing coherence essentials.")
        integrationStatusMessage = "Preparing coherence essentials for VM \(vmID.uuidString)..."
        coherenceSharedFoldersReady = false
        coherenceClipboardReady = false
        coherenceLauncherReady = false
        coherenceWindowPolicyReady = false
        updateCoherenceStatusSummary()

        do {
            try await integrationService.configureSharedResources(for: vmID)
            coherenceSharedFoldersReady = true
            coherenceClipboardReady = true
            updateCoherenceStatusSummary()
        } catch {
            integrationStatusMessage = "Coherence setup failed at shared resources: \(error.localizedDescription)"
            updateCoherenceStatusSummary()
            await logRunEvent(stage: .coherenceEssentials, result: .failed, vmID: vmID, message: integrationStatusMessage)
            return
        }

        do {
            try await integrationService.configureLauncherEntries(for: vmID)
            coherenceLauncherReady = true
            coherenceWindowPolicyReady = verifyWindowCoherenceArtifacts(for: vmID)
            guard coherenceWindowPolicyReady else {
                integrationStatusMessage = "Coherence setup failed at window policy verification: required artifacts are missing."
                updateCoherenceStatusSummary()
                await logRunEvent(stage: .coherenceEssentials, result: .failed, vmID: vmID, message: integrationStatusMessage)
                return
            }
            integrationStatusMessage = "Coherence essentials ready for VM \(vmID.uuidString)."
            updateCoherenceStatusSummary()
            await logRunEvent(stage: .coherenceEssentials, result: .success, vmID: vmID, message: integrationStatusMessage)
        } catch {
            integrationStatusMessage = "Coherence setup failed at launcher integration: \(error.localizedDescription)"
            updateCoherenceStatusSummary()
            await logRunEvent(stage: .coherenceEssentials, result: .failed, vmID: vmID, message: integrationStatusMessage)
        }
    }

    private func updateCoherenceStatusSummary() {
        let checks = [
            coherenceSharedFoldersReady ? "Shared folders: ready" : "Shared folders: pending",
            coherenceClipboardReady ? "Clipboard sync: ready" : "Clipboard sync: pending",
            coherenceLauncherReady ? "Launcher integration: ready" : "Launcher integration: pending",
            coherenceWindowPolicyReady ? "Window policy: ready" : "Window policy: pending"
        ]
        coherenceStatusSummary = checks.joined(separator: " | ")
    }

    private func verifyWindowCoherenceArtifacts(for vmID: UUID) -> Bool {
        let integrationDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
        let policy = integrationDirectory.appendingPathComponent("window-coherence-policy.json").path
        let hostScript = integrationDirectory
            .appendingPathComponent("host-scripts", isDirectory: true)
            .appendingPathComponent("apply-window-coherence.command").path
        return FileManager.default.fileExists(atPath: policy) && FileManager.default.fileExists(atPath: hostScript)
    }

    func assessDeviceMediaReadiness() async {
        let profile: HostProfile
        if let hostProfile {
            profile = hostProfile
        } else {
            do {
                profile = try await hostService.detectHostProfile()
                hostProfile = profile
            } catch {
                deviceAudioReady = false
                deviceMicReady = false
                deviceCameraReady = false
                deviceUSBReady = false
                deviceMediaStatusSummary = "Device/media readiness failed: host profile unavailable."
                await logRunEvent(stage: .deviceMediaReadiness, result: .failed, vmID: activeVMID, message: deviceMediaStatusSummary)
                return
            }
        }

        await logRunEvent(stage: .deviceMediaReadiness, result: .inProgress, vmID: activeVMID, message: "Assessing device/media readiness.")
        let baselineReady = VZVirtualMachine.isSupported && profile.cpuCores >= 4 && profile.memoryGB >= 8
        deviceAudioReady = baselineReady
        deviceMicReady = baselineReady
        deviceCameraReady = baselineReady
        deviceUSBReady = baselineReady

        let checks = [
            deviceAudioReady ? "Audio: ready" : "Audio: pending",
            deviceMicReady ? "Mic: ready" : "Mic: pending",
            deviceCameraReady ? "Camera: ready" : "Camera: pending",
            deviceUSBReady ? "USB: ready" : "USB: pending"
        ]
        deviceMediaStatusSummary = checks.joined(separator: " | ")
        await logRunEvent(
            stage: .deviceMediaReadiness,
            result: baselineReady ? .success : .failed,
            vmID: activeVMID,
            message: deviceMediaStatusSummary
        )
    }

    func assessDisplayPlanReadiness() async {
        let profile: HostProfile
        if let hostProfile {
            profile = hostProfile
        } else {
            do {
                profile = try await hostService.detectHostProfile()
                hostProfile = profile
            } catch {
                v2MultiDisplayPlanReady = false
                displayPlanStatusSummary = "Display plan assessment failed: host profile unavailable."
                await logRunEvent(stage: .displayPlanReadiness, result: .failed, vmID: activeVMID, message: displayPlanStatusSummary)
                return
            }
        }

        await logRunEvent(stage: .displayPlanReadiness, result: .inProgress, vmID: activeVMID, message: "Assessing v1/v2 display plan readiness.")
        let canScaleBeyondV1 = profile.cpuCores >= 8 && profile.memoryGB >= 16 && VZVirtualMachine.isSupported
        v2MultiDisplayPlanReady = canScaleBeyondV1
        displayPlanStatusSummary =
            "v1 locked to \(v1DisplayCountLocked) display. " +
            "v2 target \(v2DisplayTargetCount) displays: \(canScaleBeyondV1 ? "ready" : "pending")"
        await logRunEvent(
            stage: .displayPlanReadiness,
            result: canScaleBeyondV1 ? .success : .failed,
            vmID: activeVMID,
            message: displayPlanStatusSummary
        )
    }

    func runPhaseSweep() async -> String {
        await prepareCoherenceEssentials()
        await assessDeviceMediaReadiness()
        await assessDisplayPlanReadiness()

        let summary = phaseReadinessSummary(prefix: "Sweep complete")
        integrationStatusMessage = summary
        return summary
    }

    func currentPhaseReadiness() -> RuntimePhaseReadiness {
        RuntimePhaseReadiness(
            coherenceReady: coherenceSharedFoldersReady && coherenceClipboardReady && coherenceLauncherReady && coherenceWindowPolicyReady,
            deviceMediaReady: deviceAudioReady && deviceMicReady && deviceCameraReady && deviceUSBReady,
            displayV2Ready: v2MultiDisplayPlanReady
        )
    }

    func phaseReadinessSummary(prefix: String = "Phase readiness") -> String {
        let readiness = currentPhaseReadiness()
        var summary =
            "\(prefix) | Coherence: \(readiness.coherenceReady ? "ready" : "pending") | " +
            "Device/Media: \(readiness.deviceMediaReady ? "ready" : "pending") | " +
            "Display v2: \(readiness.displayV2Ready ? "ready" : "pending")"
        if coherenceWindowPolicySchemaInvalid {
            summary += " | Coherence policy schema: invalid"
        }
        return summary
    }

    func isPhaseSweepReadyForEnvironmentTesting() -> Bool {
        let readiness = currentPhaseReadiness()
        return readiness.coherenceReady && readiness.deviceMediaReady && readiness.displayV2Ready
    }

    func environmentTestingGateSummary(plannerReady: Bool) -> String {
        let plannerStatus = plannerReady ? "ready" : "pending"
        let phaseStatus = isPhaseSweepReadyForEnvironmentTesting() ? "ready" : "pending"
        var summary = "Environment testing gate | Planner: \(plannerStatus) | Phase sweep: \(phaseStatus)"
        if coherenceWindowPolicySchemaInvalid {
            summary += " | Blocker: coherence policy schema invalid"
        }
        return summary
    }

    func isEnvironmentTestingGateReady(plannerReady: Bool) -> Bool {
        plannerReady && isPhaseSweepReadyForEnvironmentTesting()
    }

    private func downloadsDirectory() throws -> URL {
        let directory = baseDirectory()
            .appendingPathComponent("downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func refreshDownloadedInstallerPresence() {
        guard let directory = try? downloadsDirectory() else {
            hasDownloadedInstallers = false
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            hasDownloadedInstallers = false
            return
        }
        hasDownloadedInstallers = files.contains { $0.pathExtension.lowercased() == "iso" }
    }

    func validateInstallerFile(for artifact: DistributionArtifact, localPath: String) async -> Bool {
        let trimmedPath = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            checksumStatusMessage = "Installer file path is empty."
            return false
        }

        let fileURL = URL(fileURLWithPath: trimmedPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            checksumStatusMessage = "Installer file is missing at \(fileURL.path)."
            return false
        }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            // Reject tiny/incomplete ISO files before start/install.
            guard size >= 300 * 1_024 * 1_024 else {
                checksumStatusMessage = "Installer file appears incomplete (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). Re-download required."
                return false
            }
        } catch {
            checksumStatusMessage = "Installer validation failed: \(error.localizedDescription)"
            return false
        }

        if !artifact.checksumSHA256.isEmpty {
            do {
                let matches = try await catalogService.verifyChecksum(for: artifact, at: fileURL)
                checksumStatusMessage = matches
                    ? "Checksum verified for \(artifact.distribution.rawValue)."
                    : "Checksum mismatch for \(artifact.distribution.rawValue). Re-download required."
                return matches
            } catch {
                checksumStatusMessage = "Checksum verification failed: \(error.localizedDescription)"
                return false
            }
        }

        checksumStatusMessage = "No checksum feed available; size validation passed."
        return true
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
        guard let installerURL else {
            throw RuntimeServiceError.missingAssets("Installer image path is required.")
        }
        guard FileManager.default.fileExists(atPath: installerURL.path) else {
            throw RuntimeServiceError.missingAssets("Installer image is missing at path: \(installerURL.path). Re-download and try install again.")
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

    private var runtimeSessionFileURL: URL {
        baseDirectory().appendingPathComponent("runtime-session.json", isDirectory: false)
    }

    private func persistRuntimeSessionSnapshot(vmID: UUID, state: VMRuntimeState) {
        let snapshot = RuntimeSessionSnapshot(
            vmID: vmID,
            stateRaw: state.rawValue,
            processID: getpid(),
            lastUpdatedISO8601: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try FileManager.default.createDirectory(
                at: runtimeSessionFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: runtimeSessionFileURL, options: [.atomic])
        } catch {
            vmRuntimeStatusMessage = "Runtime session snapshot persistence failed: \(error.localizedDescription)"
        }
    }

    private func clearRuntimeSessionSnapshot() {
        if FileManager.default.fileExists(atPath: runtimeSessionFileURL.path) {
            try? FileManager.default.removeItem(at: runtimeSessionFileURL)
        }
    }

    private func restoreRuntimeSessionSnapshotIfAvailable() -> RuntimeSessionSnapshot? {
        guard let data = try? Data(contentsOf: runtimeSessionFileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(RuntimeSessionSnapshot.self, from: data)
    }

    @discardableResult
    private func applyRestoredRuntimeSession(_ snapshot: RuntimeSessionSnapshot?, validVMIDs: Set<UUID> = []) -> Bool {
        guard let snapshot else {
            return false
        }
        if !validVMIDs.isEmpty, !validVMIDs.contains(snapshot.vmID) {
            clearRuntimeSessionSnapshot()
            return false
        }

        activeVMID = snapshot.vmID
        if lastManagedVMID == nil {
            lastManagedVMID = snapshot.vmID
        }
        installLifecycleState = .ready
        installLifecycleDetail = "Restored runtime session for VM \(snapshot.vmID.uuidString)."

        if snapshot.stateRaw == VMRuntimeState.running.rawValue {
            if isProcessAlive(snapshot.processID) {
                vmRuntimeState = .running
                vmRuntimeStatusMessage = "Rebound to running VM process \(snapshot.processID)."
            } else {
                vmRuntimeState = .stopped
                vmRuntimeStatusMessage = "Stored VM process is no longer alive; marking as stopped."
            }
            return true
        }

        if let restoredState = VMRuntimeState(rawValue: snapshot.stateRaw) {
            vmRuntimeState = restoredState
            vmRuntimeStatusMessage = "Restored runtime session state: \(restoredState.rawValue)."
        } else {
            vmRuntimeState = .stopped
            vmRuntimeStatusMessage = "Runtime session state was invalid; marking as stopped."
        }
        return true
    }

    private func isProcessAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else {
            return false
        }

        if kill(processID, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
