import Foundation

enum HostArchitecture: String, CaseIterable, Identifiable, Codable {
    case appleSilicon = "Apple Silicon (arm64)"
    case intel = "Intel (x86_64)"

    var id: String { rawValue }
}

enum RuntimeEngine: String, CaseIterable, Identifiable, Codable {
    case appleVirtualization = "Apple Virtualization.framework"
    case qemuFallback = "QEMU Fallback"
    case nativeInstall = "Native Install (Advanced)"

    var id: String { rawValue }
}

enum IntegrationMode: String, CaseIterable, Identifiable {
    case rootlessLinuxApps = "Rootless Linux App Windows"
    case launcherOnly = "Launch Linux Apps from macOS Menu"
    case fullDesktopWindow = "Linux Desktop in Dedicated VM Window"

    var id: String { rawValue }
}

enum BlueprintStageStatus: String, CaseIterable, Identifiable {
    case planned
    case inProgress
    case blocked
    case complete

    var id: String { rawValue }
}

enum LinuxDistribution: String, CaseIterable, Identifiable, Codable {
    case ubuntu = "Ubuntu"
    case fedora = "Fedora"
    case debian = "Debian"
    case popOS = "Pop!_OS"
    case openSUSE = "openSUSE"

    var id: String { rawValue }
}

enum VMInstallLifecycleState: String, CaseIterable, Identifiable, Codable {
    case idle
    case validating
    case scaffolding
    case ready
    case failed

    var id: String { rawValue }
}

enum VMRuntimeState: String, CaseIterable, Identifiable, Codable {
    case stopped
    case starting
    case running
    case stopping
    case restarting
    case failed

    var id: String { rawValue }
}

struct HostProfile: Equatable, Codable {
    let architecture: HostArchitecture
    let cpuCores: Int
    let memoryGB: Int
    let macOSVersion: String
}

struct DistributionArtifact: Identifiable, Equatable {
    let id: String
    let distribution: LinuxDistribution
    let architecture: HostArchitecture
    let version: String
    let downloadURL: URL
    let mirrorURLs: [URL]
    let checksumSHA256: String
    let signatureExpected: Bool
    let signatureVerifiedAtSource: Bool
}

struct VMInstallAssets: Equatable {
    let vmName: String
    let vmDirectoryURL: URL
    let installerImageURL: URL?
    let kernelImageURL: URL?
    let initialRamdiskURL: URL?
    let diskImageURL: URL
    let efiVariableStoreURL: URL
    let machineIdentifierURL: URL
}

struct VMInstallRequest: Equatable {
    let distribution: LinuxDistribution
    let runtimeEngine: RuntimeEngine
    let architecture: HostArchitecture
    let cpuCores: Int
    let memoryGB: Int
    let diskGB: Int
    let enableSharedFolders: Bool
    let enableSharedClipboard: Bool
}

struct StageDefinition: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    var status: BlueprintStageStatus
    let ownedBy: String
}

struct ReadinessCriterion: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let detail: String
    var isSatisfied: Bool
}

struct ReadinessPreflightSnapshot: Equatable, Codable {
    let hostProfile: HostProfile?
    let virtualizationSupported: Bool
    let catalogHasArtifacts: Bool
    let catalogErrorMessage: String
    let installLifecycleState: VMInstallLifecycleState
    let hasManagedVM: Bool
    let testRootOverrideEnabled: Bool
    let currentRunID: UUID?
}

struct ReadinessScanEvidence: Codable, Equatable, Identifiable {
    let id: UUID
    let timestampISO8601: String
    let snapshot: ReadinessPreflightSnapshot
    let findings: [String]
    let criteria: [ReadinessCriterion]
    let isGoForEnvironmentTesting: Bool
    let readinessSummary: String
}

struct ReadinessChecklistSignals: Equatable {
    let snapshot: ReadinessPreflightSnapshot
    let preflightEvidenceExists: Bool
    let securityFlowReady: Bool
    let buildPassed: Bool?
    let testsPassed: Bool?
}

struct GoNoGoDecisionReport: Codable, Equatable, Identifiable {
    let id: UUID
    let timestampISO8601: String
    let decision: String
    let readinessSummary: String
    let unsatisfiedCriteriaIDs: [String]
    let unsatisfiedCriteriaTitles: [String]
}

struct RuntimeSessionSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let vmID: UUID
    let stateRaw: String
    let processID: Int32
    let lastUpdatedISO8601: String
    
    init(id: UUID = UUID(), vmID: UUID, stateRaw: String, processID: Int32, lastUpdatedISO8601: String) {
        self.id = id
        self.vmID = vmID
        self.stateRaw = stateRaw
        self.processID = processID
        self.lastUpdatedISO8601 = lastUpdatedISO8601
    }
}
