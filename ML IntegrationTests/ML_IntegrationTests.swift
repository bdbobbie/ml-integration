import XCTest
@testable import ML_Integration

final class ML_IntegrationTests: XCTestCase {

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
    func testAutoHealAfterScaffoldUpdatesHealthStatus() async {
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
            installerImagePath: "/tmp/mock.iso",
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.applyAutoHeal()
        XCTAssertTrue(viewModel.healthStatusMessage.contains("Auto-heal completed"))
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
    func testCleanupVerificationUsesLastManagedVM() async {
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
            installerImagePath: "/tmp/mock.iso",
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        await viewModel.uninstallActiveVM(removeArtifacts: true)
        XCTAssertTrue(viewModel.cleanupStatusMessage.contains("Uninstall completed"))
        XCTAssertFalse(viewModel.cleanupReport.isEmpty)

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
            "launcher-manifest.json",
            "rootless-apps.json",
            "integration-state.json",
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
    func runHealthCheck(for vmID: UUID) async throws -> [String] {
        _ = vmID
        return ["OK: mock health"]
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

    func configureSharedResources(for vmID: UUID) async throws {
        _ = vmID
        sharedResourcesCalls += 1
    }

    func configureLauncherEntries(for vmID: UUID) async throws {
        _ = vmID
        launcherCalls += 1
    }

    func enableRootlessLinuxApps(for vmID: UUID) async throws {
        _ = vmID
        rootlessCalls += 1
    }
}

struct MockDownloader: ArtifactDownloading {
    func downloadArtifact(primaryURL: URL, mirrorURLs: [URL], destinationURL: URL, maxRetriesPerURL: Int) async throws {
        _ = primaryURL
        _ = mirrorURLs
        _ = maxRetriesPerURL
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
    func validate(_ request: VMInstallRequest, assets: VMInstallAssets?) async throws {
        _ = request
        guard assets?.installerImageURL != nil else {
            throw RuntimeServiceError.missingAssets("Provide installer image path or download an ISO from the catalog first.")
        }
    }

    func installVM(using request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID {
        try await validate(request, assets: assets)
        return UUID()
    }

    func startVM(id: UUID) async throws {
        _ = id
    }

    func stopVM(id: UUID) async throws {
        _ = id
    }
}
