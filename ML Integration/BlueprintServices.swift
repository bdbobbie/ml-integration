import Foundation

protocol HostProfileService {
    func detectHostProfile() async throws -> HostProfile
}

protocol DistributionCatalogService {
    func fetchSupportedDistributions() async throws -> [LinuxDistribution]
    func fetchArtifacts(for architecture: HostArchitecture) async throws -> [DistributionArtifact]
    func verifyChecksum(for artifact: DistributionArtifact, at localURL: URL) async throws -> Bool
    func verifySignature(for artifact: DistributionArtifact) async throws -> Bool
    func requiredKeyringFileNames(for distribution: LinuxDistribution) -> [String]
}

protocol VMProvisioningService {
    func validate(_ request: VMInstallRequest, assets: VMInstallAssets?) async throws
    func installVM(using request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID
    func startVM(id: UUID) async throws
    func stopVM(id: UUID) async throws
}

protocol IntegrationService {
    func configureSharedResources(for vmID: UUID) async throws
    func configureLauncherEntries(for vmID: UUID) async throws
    func enableRootlessLinuxApps(for vmID: UUID) async throws
}

protocol HealthAndRepairService {
    func runHealthCheck(for vmID: UUID) async throws -> [String]
    func applyAutomaticRepair(for vmID: UUID) async throws -> [String]
}

protocol EscalationService {
    func openGitHubIssue(title: String, details: String, logs: URL?) async throws -> URL
    func sendEmailEscalation(subject: String, body: String, attachments: [URL]) async throws
}

protocol UninstallCleanupService {
    func uninstallVM(id: UUID, removeArtifacts: Bool) async throws
    func verifyCleanup(id: UUID) async throws -> [String]
}
