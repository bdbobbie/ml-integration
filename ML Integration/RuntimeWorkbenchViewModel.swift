import Foundation
import Combine

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
    @Published private(set) var integrationStatusMessage: String = ""
    @Published private(set) var healthStatusMessage: String = ""
    @Published private(set) var healthReport: [String] = []
    @Published private(set) var cleanupStatusMessage: String = ""
    @Published private(set) var cleanupReport: [String] = []
    @Published private(set) var escalationStatusMessage: String = ""
    @Published private(set) var lastEscalationIssueURL: URL?
    @Published private(set) var registryStatusMessage: String = ""
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

    private var lastCatalogRefresh: Date?
    private let sourceMonitoringInterval: TimeInterval = 60 * 30

    init(
        hostService: HostProfileService = DefaultHostProfileService(),
        catalogService: DistributionCatalogService = OfficialDistributionCatalogService(),
        provisioningService: VMProvisioningService = VMProvisioningPipelineService(),
        integrationService: IntegrationService = DefaultIntegrationService(),
        healthService: HealthAndRepairService = DefaultHealthAndRepairService(),
        uninstallService: UninstallCleanupService = DefaultUninstallCleanupService(),
        escalationService: EscalationService = DefaultEscalationService(),
        downloader: ArtifactDownloading = ResumableArtifactDownloader(),
        registry: VMRegistryManaging = PersistentVMRegistryStore()
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
    }

    func restoreVMRegistryState() async {
        let entries = await registry.allEntries()
        if entries.isEmpty {
            registryStatusMessage = "VM registry is empty."
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
                    return
                }
            }
        }

        if let latest = validEntries.first {
            lastManagedVMID = latest.id
            if FileManager.default.fileExists(atPath: latest.vmDirectoryPath) {
                activeVMID = latest.id
            }
        }

        registryStatusMessage = "Registry restored \(validEntries.count) VM entries, pruned \(prunedCount) stale entries."
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
        if !force,
           let lastCatalogRefresh,
           Date().timeIntervalSince(lastCatalogRefresh) < sourceMonitoringInterval {
            return
        }

        do {
            artifacts = try await catalogService.fetchArtifacts(for: architecture)
            catalogErrorMessage = ""
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
        } catch {
            downloadStatusMessage = "Download failed: \(error.localizedDescription)"
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

            let vmID = try await provisioningService.installVM(using: request, assets: assets)
            activeVMID = vmID
            lastManagedVMID = vmID
            vmStatusMessage = "VM pipeline scaffolded with automation assets when supported. ID: \(vmID.uuidString). VM assets at: \(assets.vmDirectoryURL.path)"
        } catch {
            vmStatusMessage = "VM pipeline failed: \(error.localizedDescription)"
        }
    }

    func runHealthCheck() async {
        guard let vmID = activeVMID else {
            healthStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            healthReport = []
            return
        }

        do {
            let report = try await healthService.runHealthCheck(for: vmID)
            healthReport = report
            let warnings = report.filter { $0.hasPrefix("WARN") }.count
            healthStatusMessage = "Health check finished for VM \(vmID.uuidString). Warnings: \(warnings)."
        } catch {
            healthStatusMessage = "Health check failed: \(error.localizedDescription)"
            healthReport = []
        }
    }

    func applyAutoHeal() async {
        guard let vmID = activeVMID else {
            healthStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            return
        }

        do {
            let actions = try await healthService.applyAutomaticRepair(for: vmID)
            healthReport = actions
            healthStatusMessage = "Auto-heal completed for VM \(vmID.uuidString)."
        } catch {
            healthStatusMessage = "Auto-heal failed: \(error.localizedDescription)"
        }
    }

    func uninstallActiveVM(removeArtifacts: Bool = true) async {
        guard let vmID = activeVMID else {
            cleanupStatusMessage = IntegrationRuntimeError.vmNotSelected.localizedDescription
            cleanupReport = []
            return
        }

        do {
            try await uninstallService.uninstallVM(id: vmID, removeArtifacts: removeArtifacts)
            let report = try await uninstallService.verifyCleanup(id: vmID)
            cleanupReport = report
            cleanupStatusMessage = "Uninstall completed for VM \(vmID.uuidString)."
            lastManagedVMID = vmID
            activeVMID = nil
        } catch {
            cleanupStatusMessage = "Uninstall failed: \(error.localizedDescription)"
            cleanupReport = []
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
        } catch {
            escalationStatusMessage = "Escalation failed: \(error.localizedDescription)"
        }
    }

    private func createDiagnosticsBundle(title: String, details: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let diagnosticsDir = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let directory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func keyringDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let directory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
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

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let vmDirectory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
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

    private func baseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("MLIntegration", isDirectory: true)
    }
}
