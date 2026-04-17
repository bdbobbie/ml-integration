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

struct HostProfile: Equatable {
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
