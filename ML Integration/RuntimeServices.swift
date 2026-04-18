import Foundation
import CryptoKit
import Virtualization

enum RuntimeServiceError: LocalizedError {
    case unsupportedArchitecture(String)
    case checksumUnavailable
    case invalidLocalFile
    case invalidVMRequest(String)
    case virtualizationNotSupported
    case nativeInstallNotSupported
    case vmNotFound
    case qemuHookUnavailable
    case missingAssets(String)
    case commandFailed(String)
    case signatureVerificationFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let machine):
            return "Unsupported host architecture: \(machine)."
        case .checksumUnavailable:
            return "Checksum is unavailable for this artifact."
        case .invalidLocalFile:
            return "The local file does not exist."
        case .invalidVMRequest(let reason):
            return "Invalid VM request: \(reason)"
        case .virtualizationNotSupported:
            return "Virtualization.framework is not supported on this host."
        case .nativeInstallNotSupported:
            return "Native install flow is not enabled in this app build."
        case .vmNotFound:
            return "VM identifier not found in provisioning records."
        case .qemuHookUnavailable:
            return "QEMU fallback hook is not configured yet."
        case .missingAssets(let message):
            return "Missing VM assets: \(message)"
        case .commandFailed(let output):
            return "Command failed: \(output)"
        case .signatureVerificationFailed(let message):
            return "Signature verification failed: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        }
    }
}

enum ChecksumParseStrategy {
    case standardSha256SumsFile
    case directSha256File
    case fedoraChecksumFile
    case popOSDownloadPage
}

enum InstallerAutomationProfile: String {
    case ubuntuCloudInit
    case debianPreseed
    case fedoraKickstart
    case openSUSEAutoYaST
    case manualOnly
}

struct DistributionReleaseDescriptor {
    let distribution: LinuxDistribution
    let architecture: HostArchitecture
    let version: String
    let downloadURL: URL
    let mirrorURLs: [URL]
    let checksumFeedURL: URL?
    let checksumFileName: String?
    let checksumStrategy: ChecksumParseStrategy?
    let checksumSignatureURL: URL?
    let keyringFileName: String?
    let keyFingerprint: String?
}

struct CommandResult {
    let status: Int32
    let output: String
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }
}

protocol SignatureVerifying {
    func verifyDetachedSignature(dataURL: URL, signatureURL: URL, keyringURL: URL, expectedFingerprint: String?) throws -> Bool
}

struct GPGSignatureVerifier: SignatureVerifying {
    private let runner: CommandRunning

    init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func verifyDetachedSignature(dataURL: URL, signatureURL: URL, keyringURL: URL, expectedFingerprint: String?) throws -> Bool {
        guard FileManager.default.fileExists(atPath: keyringURL.path) else {
            throw RuntimeServiceError.signatureVerificationFailed("Missing keyring: \(keyringURL.path)")
        }

        let gpgvResult = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["gpgv", "--keyring", keyringURL.path, signatureURL.path, dataURL.path]
        )

        guard gpgvResult.status == 0 else {
            throw RuntimeServiceError.signatureVerificationFailed(gpgvResult.output)
        }

        guard let expectedFingerprint, !expectedFingerprint.isEmpty else {
            return true
        }

        let listResult = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["gpg", "--show-keys", "--with-colons", keyringURL.path]
        )
        guard listResult.status == 0 else {
            throw RuntimeServiceError.signatureVerificationFailed("Unable to inspect keyring fingerprint.")
        }

        let hasFingerprint = listResult.output
            .split(separator: "\n")
            .contains { line in
                line.contains("fpr:") && line.localizedCaseInsensitiveContains(expectedFingerprint)
            }

        return hasFingerprint
    }
}

protocol ArtifactDownloading {
    func downloadArtifact(primaryURL: URL, mirrorURLs: [URL], destinationURL: URL, maxRetriesPerURL: Int) async throws
}

actor ResumableArtifactDownloader: ArtifactDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func downloadArtifact(primaryURL: URL, mirrorURLs: [URL], destinationURL: URL, maxRetriesPerURL: Int = 3) async throws {
        let candidates = [primaryURL] + mirrorURLs
        guard !candidates.isEmpty else {
            throw RuntimeServiceError.downloadFailed("No download URLs were provided.")
        }

        var lastError: Error?
        for candidate in candidates {
            for attempt in 1...max(maxRetriesPerURL, 1) {
                do {
                    try await downloadFromSingleURL(candidate, destinationURL: destinationURL)
                    return
                } catch {
                    lastError = error
                    if attempt < maxRetriesPerURL {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    }
                }
            }
        }

        throw lastError ?? RuntimeServiceError.downloadFailed("All mirrors failed.")
    }

    private func downloadFromSingleURL(_ url: URL, destinationURL: URL) async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path) {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let existingBytes = existingFileSize(at: destinationURL)
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeServiceError.downloadFailed("Invalid HTTP response from \(url.absoluteString)")
        }

        switch http.statusCode {
        case 200:
            if existingBytes > 0 {
                try? fileManager.removeItem(at: destinationURL)
            }
            try await writeBytes(bytes, to: destinationURL, append: false)
        case 206:
            try await writeBytes(bytes, to: destinationURL, append: true)
        default:
            throw RuntimeServiceError.downloadFailed("HTTP \(http.statusCode) from \(url.absoluteString)")
        }
    }

    private func writeBytes(_ bytes: URLSession.AsyncBytes, to url: URL, append: Bool) async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        if append {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }

        var buffer = Data()
        buffer.reserveCapacity(128 * 1024) // Pre-allocate larger buffer for better performance
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 128 * 1024 { // Increased buffer size for fewer writes
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }

    private func existingFileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }
}

final class DefaultHostProfileService: HostProfileService {
    func detectHostProfile() async throws -> HostProfile {
        let arch = try detectArchitecture()
        let cpu = ProcessInfo.processInfo.processorCount
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Int((Double(memoryBytes) / 1_073_741_824.0).rounded())
        let version = ProcessInfo.processInfo.operatingSystemVersionString

        return HostProfile(
            architecture: arch,
            cpuCores: cpu,
            memoryGB: max(memoryGB, 1),
            macOSVersion: version
        )
    }

    private func detectArchitecture() throws -> HostArchitecture {
        var uts = utsname()
        uname(&uts)

        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        if machine.contains("arm64") { return .appleSilicon }
        if machine.contains("x86_64") { return .intel }
        throw RuntimeServiceError.unsupportedArchitecture(machine)
    }
}

final class OfficialDistributionCatalogService: DistributionCatalogService {
    private let signatureVerifier: SignatureVerifying
    private var signatureStatusByArtifactID: [String: Bool] = [:]

    init(signatureVerifier: SignatureVerifying = GPGSignatureVerifier()) {
        self.signatureVerifier = signatureVerifier
    }

    func fetchSupportedDistributions() async throws -> [LinuxDistribution] {
        LinuxDistribution.allCases
    }

    func fetchArtifacts(for architecture: HostArchitecture) async throws -> [DistributionArtifact] {
        let descriptors = Self.releaseDescriptors.filter { $0.architecture == architecture }
        var artifacts: [DistributionArtifact] = []

        for descriptor in descriptors {
            let artifactID = "\(descriptor.distribution.rawValue)-\(architecture.rawValue)"
            let result = try await fetchChecksumAndSignature(descriptor: descriptor)
            signatureStatusByArtifactID[artifactID] = result.signatureVerified

            artifacts.append(
                DistributionArtifact(
                    id: artifactID,
                    distribution: descriptor.distribution,
                    architecture: architecture,
                    version: descriptor.version,
                    downloadURL: descriptor.downloadURL,
                    mirrorURLs: descriptor.mirrorURLs,
                    checksumSHA256: result.checksum,
                    signatureExpected: descriptor.checksumSignatureURL != nil,
                    signatureVerifiedAtSource: result.signatureVerified
                )
            )
        }

        return artifacts.sorted { $0.distribution.rawValue < $1.distribution.rawValue }
    }

    func verifyChecksum(for artifact: DistributionArtifact, at localURL: URL) async throws -> Bool {
        guard !artifact.checksumSHA256.isEmpty else {
            throw RuntimeServiceError.checksumUnavailable
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw RuntimeServiceError.invalidLocalFile
        }

        let hash = try computeSHA256(of: localURL)
        return hash.caseInsensitiveCompare(artifact.checksumSHA256) == .orderedSame
    }

    func verifySignature(for artifact: DistributionArtifact) async throws -> Bool {
        if !artifact.signatureExpected { return true }
        return signatureStatusByArtifactID[artifact.id] ?? false
    }

    func requiredKeyringFileNames(for distribution: LinuxDistribution) -> [String] {
        Array(
            Set(
                Self.releaseDescriptors
                    .filter { $0.distribution == distribution }
                    .compactMap { $0.keyringFileName }
            )
        )
        .sorted()
    }

    private func fetchChecksumAndSignature(descriptor: DistributionReleaseDescriptor) async throws -> (checksum: String, signatureVerified: Bool) {
        guard
            let feedURL = descriptor.checksumFeedURL,
            let strategy = descriptor.checksumStrategy
        else {
            return ("", false)
        }

        let (data, _) = try await URLSession.shared.data(from: feedURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return ("", false)
        }

        let signatureVerified = try await verifyChecksumFeedSignatureIfAvailable(
            descriptor: descriptor,
            checksumData: data
        )

        let fileName = descriptor.checksumFileName ?? descriptor.downloadURL.lastPathComponent
        let checksum: String

        switch strategy {
        case .standardSha256SumsFile:
            checksum = parseStandardSha256Sums(text: text, fileName: fileName)
        case .directSha256File:
            checksum = parseDirectSha256(text: text)
        case .fedoraChecksumFile:
            checksum = parseFedoraChecksum(text: text, fileName: fileName)
        case .popOSDownloadPage:
            checksum = parsePopOSChecksum(text: text)
        }

        return (checksum, signatureVerified)
    }

    private func verifyChecksumFeedSignatureIfAvailable(
        descriptor: DistributionReleaseDescriptor,
        checksumData: Data
    ) async throws -> Bool {
        guard
            let signatureURL = descriptor.checksumSignatureURL,
            let keyringFileName = descriptor.keyringFileName
        else {
            return false
        }

        let keyringURL = try keyringDirectoryURL().appendingPathComponent(keyringFileName)
        guard FileManager.default.fileExists(atPath: keyringURL.path) else {
            return false
        }

        let (signatureData, _) = try await URLSession.shared.data(from: signatureURL)

        let tempDirectory = FileManager.default.temporaryDirectory
        let checksumFileURL = tempDirectory.appendingPathComponent(UUID().uuidString)
        let signatureFileURL = tempDirectory.appendingPathComponent(UUID().uuidString)

        try checksumData.write(to: checksumFileURL)
        try signatureData.write(to: signatureFileURL)

        defer {
            try? FileManager.default.removeItem(at: checksumFileURL)
            try? FileManager.default.removeItem(at: signatureFileURL)
        }

        return try signatureVerifier.verifyDetachedSignature(
            dataURL: checksumFileURL,
            signatureURL: signatureFileURL,
            keyringURL: keyringURL,
            expectedFingerprint: descriptor.keyFingerprint
        )
    }

    private func keyringDirectoryURL() throws -> URL {
        let keyringDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keyringDirectory, withIntermediateDirectories: true)
        return keyringDirectory
    }

    private func parseStandardSha256Sums(text: String, fileName: String) -> String {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") { continue }
            guard trimmed.contains(fileName) else { continue }

            let hash = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            if hash.count == 64 { return hash.lowercased() }
        }
        return ""
    }

    private func parseDirectSha256(text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init) ?? ""
        return token.count == 64 ? token.lowercased() : ""
    }

    private func parseFedoraChecksum(text: String, fileName: String) -> String {
        for line in text.split(separator: "\n") {
            let candidate = String(line)
            guard candidate.contains(fileName), candidate.contains("SHA256") else { continue }
            if let hash = candidate.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines), hash.count == 64 {
                return hash.lowercased()
            }
        }
        return ""
    }

    private func parsePopOSChecksum(text: String) -> String {
        let regex = try? NSRegularExpression(pattern: "\\b[a-fA-F0-9]{64}\\b")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex?.firstMatch(in: text, options: [], range: range),
            let swiftRange = Range(match.range, in: text)
        else {
            return ""
        }

        return String(text[swiftRange]).lowercased()
    }

    private func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let releaseDescriptors: [DistributionReleaseDescriptor] = [
        DistributionReleaseDescriptor(
            distribution: .ubuntu,
            architecture: .appleSilicon,
            version: "24.04.4 LTS",
            downloadURL: URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/ubuntu-24.04.4-desktop-arm64.iso")!,
            mirrorURLs: [
                URL(string: "https://mirror.math.princeton.edu/pub/ubuntu-cdimage/ubuntu/releases/noble/release/ubuntu-24.04.4-desktop-arm64.iso")!
            ],
            checksumFeedURL: URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/SHA256SUMS"),
            checksumFileName: "ubuntu-24.04.4-desktop-arm64.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/SHA256SUMS.gpg"),
            keyringFileName: "ubuntu-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .ubuntu,
            architecture: .intel,
            version: "24.04.4 LTS",
            downloadURL: URL(string: "https://releases.ubuntu.com/noble/ubuntu-24.04.4-desktop-amd64.iso")!,
            mirrorURLs: [
                URL(string: "https://mirror.math.princeton.edu/pub/ubuntu-releases/noble/ubuntu-24.04.4-desktop-amd64.iso")!
            ],
            checksumFeedURL: URL(string: "https://releases.ubuntu.com/noble/SHA256SUMS"),
            checksumFileName: "ubuntu-24.04.4-desktop-amd64.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://releases.ubuntu.com/noble/SHA256SUMS.gpg"),
            keyringFileName: "ubuntu-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .debian,
            architecture: .appleSilicon,
            version: "13 (netinst)",
            downloadURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.0.0-arm64-netinst.iso")!,
            mirrorURLs: [
                URL(string: "https://mirror.math.princeton.edu/pub/debian-cd/current/arm64/iso-cd/debian-13.0.0-arm64-netinst.iso")!
            ],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-arm64-netinst.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .debian,
            architecture: .intel,
            version: "13 (netinst)",
            downloadURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso")!,
            mirrorURLs: [
                URL(string: "https://mirror.math.princeton.edu/pub/debian-cd/current/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso")!
            ],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-amd64-netinst.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .fedora,
            architecture: .intel,
            version: "Workstation 43",
            downloadURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-43-1.6.iso")!,
            mirrorURLs: [
                URL(string: "https://mirrors.kernel.org/fedora/releases/43/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-43-1.6.iso")!
            ],
            checksumFeedURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/x86_64/iso/Fedora-Workstation-43-1.6-x86_64-CHECKSUM"),
            checksumFileName: "Fedora-Workstation-Live-x86_64-43-1.6.iso",
            checksumStrategy: .fedoraChecksumFile,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .fedora,
            architecture: .appleSilicon,
            version: "Workstation 43",
            downloadURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/aarch64/iso/Fedora-Workstation-Live-aarch64-43-1.6.iso")!,
            mirrorURLs: [
                URL(string: "https://mirrors.kernel.org/fedora/releases/43/Workstation/aarch64/iso/Fedora-Workstation-Live-aarch64-43-1.6.iso")!
            ],
            checksumFeedURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/aarch64/iso/Fedora-Workstation-43-1.6-aarch64-CHECKSUM"),
            checksumFileName: "Fedora-Workstation-Live-aarch64-43-1.6.iso",
            checksumStrategy: .fedoraChecksumFile,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .openSUSE,
            architecture: .intel,
            version: "Tumbleweed Current",
            downloadURL: URL(string: "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso")!,
            mirrorURLs: [
                URL(string: "https://mirrors.kernel.org/opensuse/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso")!
            ],
            checksumFeedURL: URL(string: "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso.sha256"),
            checksumFileName: "openSUSE-Tumbleweed-DVD-x86_64-Current.iso",
            checksumStrategy: .directSha256File,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .openSUSE,
            architecture: .appleSilicon,
            version: "Tumbleweed Current",
            downloadURL: URL(string: "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso")!,
            mirrorURLs: [
                URL(string: "https://mirrors.kernel.org/opensuse/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso")!
            ],
            checksumFeedURL: URL(string: "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso.sha256"),
            checksumFileName: "openSUSE-Tumbleweed-DVD-aarch64-Current.iso",
            checksumStrategy: .directSha256File,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .popOS,
            architecture: .intel,
            version: "24.04 LTS",
            downloadURL: URL(string: "https://system76.com/pop/download/")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://system76.com/pop/download/"),
            checksumFileName: nil,
            checksumStrategy: .popOSDownloadPage,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .popOS,
            architecture: .appleSilicon,
            version: "24.04 LTS",
            downloadURL: URL(string: "https://system76.com/pop/download/")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://system76.com/pop/download/"),
            checksumFileName: nil,
            checksumStrategy: .popOSDownloadPage,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        )
    ]
}

protocol QEMUFallbackHook {
    func scaffoldInstall(for request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID
}

struct ProcessQEMUFallbackHook: QEMUFallbackHook {
    private let runner: CommandRunning

    init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func scaffoldInstall(for request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID {
        guard let assets else {
            throw RuntimeServiceError.missingAssets("QEMU flow requires VM directory and disk image paths.")
        }
        guard let installerURL = assets.installerImageURL else {
            throw RuntimeServiceError.missingAssets("QEMU flow requires installer image URL.")
        }

        try FileManager.default.createDirectory(at: assets.vmDirectoryURL, withIntermediateDirectories: true)

        let qemuBin = "qemu-system-\(request.architecture == .appleSilicon ? "aarch64" : "x86_64")"
        let whichResult = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", qemuBin]
        )
        guard whichResult.status == 0 else {
            throw RuntimeServiceError.commandFailed("Could not locate \(qemuBin). Install QEMU first. Output: \(whichResult.output)")
        }

        let automationISO = assets.vmDirectoryURL.appendingPathComponent("automation-seed.iso")
        let hasAutomationISO = FileManager.default.fileExists(atPath: automationISO.path)

        let launchScriptURL = assets.vmDirectoryURL.appendingPathComponent("launch-qemu.sh")
        var scriptLines: [String] = [
            "#!/bin/sh",
            "set -eu",
            "\(qemuBin) \\",
            "  -m \(request.memoryGB * 1024) \\",
            "  -smp \(request.cpuCores) \\",
            "  -drive file=\"\(assets.diskImageURL.path)\",if=virtio \\",
            "  -cdrom \"\(installerURL.path)\" \\",
            "  -boot d"
        ]

        if hasAutomationISO {
            scriptLines.insert("  -drive file=\"\(automationISO.path)\",media=cdrom \\", at: scriptLines.count - 1)
        }

        try scriptLines.joined(separator: "\n").write(to: launchScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchScriptURL.path)

        return UUID()
    }
}

private struct VMProvisionRecord {
    var id: UUID
    var request: VMInstallRequest
    var assets: VMInstallAssets?
    var isRunning: Bool
}

actor VMProvisioningPipelineService: VMProvisioningService {
    private var records: [UUID: VMProvisionRecord] = [:]
    private let qemuHook: QEMUFallbackHook
    private let registry: VMRegistryManaging

    init(
        qemuHook: QEMUFallbackHook = ProcessQEMUFallbackHook(),
        registry: VMRegistryManaging = PersistentVMRegistryStore()
    ) {
        self.qemuHook = qemuHook
        self.registry = registry
    }

    func validate(_ request: VMInstallRequest, assets: VMInstallAssets?) async throws {
        guard request.cpuCores > 0 else { throw RuntimeServiceError.invalidVMRequest("CPU cores must be greater than 0.") }
        guard request.memoryGB >= 2 else { throw RuntimeServiceError.invalidVMRequest("Memory must be at least 2 GB.") }
        guard request.diskGB >= 20 else { throw RuntimeServiceError.invalidVMRequest("Disk must be at least 20 GB.") }

        switch request.runtimeEngine {
        case .appleVirtualization:
            guard VZVirtualMachine.isSupported else { throw RuntimeServiceError.virtualizationNotSupported }
            guard let assets else {
                throw RuntimeServiceError.missingAssets("Virtualization flow requires installer image path and VM asset paths.")
            }
            _ = try buildVirtualizationConfiguration(request: request, assets: assets)
        case .qemuFallback:
            guard let assets else {
                throw RuntimeServiceError.missingAssets("QEMU flow requires VM asset paths.")
            }
            guard assets.installerImageURL != nil else {
                throw RuntimeServiceError.missingAssets("QEMU flow requires installer image URL.")
            }
        case .nativeInstall:
            throw RuntimeServiceError.nativeInstallNotSupported
        }
    }

    func installVM(using request: VMInstallRequest, assets: VMInstallAssets?) async throws -> UUID {
        try await validate(request, assets: assets)

        let vmID: UUID
        switch request.runtimeEngine {
        case .appleVirtualization:
            vmID = UUID()
            if let assets {
                try createVMFilesIfNeeded(request: request, assets: assets)
            }
        case .qemuFallback:
            if let assets {
                try createVMFilesIfNeeded(request: request, assets: assets)
            }
            vmID = try await qemuHook.scaffoldInstall(for: request, assets: assets)
        case .nativeInstall:
            throw RuntimeServiceError.nativeInstallNotSupported
        }

        records[vmID] = VMProvisionRecord(id: vmID, request: request, assets: assets, isRunning: false)
        if let assets {
            let now = ISO8601DateFormatter().string(from: Date())
            let entry = VMRegistryEntry(
                id: vmID,
                vmName: assets.vmName,
                vmDirectoryPath: assets.vmDirectoryURL.path,
                distribution: request.distribution,
                architecture: request.architecture,
                runtimeEngine: request.runtimeEngine,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
            try await registry.upsert(entry)
        }
        return vmID
    }

    func startVM(id: UUID) async throws {
        guard var record = records[id] else { throw RuntimeServiceError.vmNotFound }
        record.isRunning = true
        records[id] = record
    }

    func stopVM(id: UUID) async throws {
        guard var record = records[id] else { throw RuntimeServiceError.vmNotFound }
        record.isRunning = false
        records[id] = record
    }

    private func createVMFilesIfNeeded(request: VMInstallRequest, assets: VMInstallAssets) throws {
        try FileManager.default.createDirectory(at: assets.vmDirectoryURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: assets.diskImageURL.path) {
            FileManager.default.createFile(atPath: assets.diskImageURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: assets.diskImageURL)
            try handle.truncate(atOffset: UInt64(request.diskGB) * 1_073_741_824)
            try handle.close()
        }

        if !FileManager.default.fileExists(atPath: assets.machineIdentifierURL.path) {
            let machineID = VZGenericMachineIdentifier()
            try machineID.dataRepresentation.write(to: assets.machineIdentifierURL)
        }

        if !FileManager.default.fileExists(atPath: assets.efiVariableStoreURL.path) {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: assets.efiVariableStoreURL)
        }

        _ = try createAutomationSeedISOIfSupported(request: request, assets: assets)
    }

    private func createAutomationSeedISOIfSupported(request: VMInstallRequest, assets: VMInstallAssets) throws -> URL? {
        let profile = automationProfile(for: request.distribution)
        guard profile != .manualOnly else { return nil }

        let automationDirectory = assets.vmDirectoryURL.appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)

        switch profile {
        case .ubuntuCloudInit:
            let userData = """
            #cloud-config
            autoinstall:
              version: 1
              identity:
                hostname: ml-integration
                username: linux
                password: "$6$rounds=4096$abcdefghijklmnopqrst$abcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvwx"
            """
            let metaData = "instance-id: ml-integration\nlocal-hostname: ml-integration\n"
            try userData.write(to: automationDirectory.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
            try metaData.write(to: automationDirectory.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        case .debianPreseed:
            let preseed = """
            d-i debian-installer/locale string en_US
            d-i keyboard-configuration/xkb-keymap select us
            d-i netcfg/choose_interface select auto
            d-i passwd/user-fullname string Linux User
            d-i passwd/username string linux
            """
            try preseed.write(to: automationDirectory.appendingPathComponent("preseed.cfg"), atomically: true, encoding: .utf8)
        case .fedoraKickstart:
            let kickstart = """
            lang en_US.UTF-8
            keyboard us
            timezone UTC --utc
            rootpw --lock
            user --name=linux --groups=wheel --password=linux
            autopart
            reboot
            """
            try kickstart.write(to: automationDirectory.appendingPathComponent("ks.cfg"), atomically: true, encoding: .utf8)
        case .openSUSEAutoYaST:
            let autoYaST = """
            <?xml version="1.0"?>
            <profile xmlns="http://www.suse.com/1.0/yast2ns">
              <general><mode><confirm config:type="boolean">false</confirm></mode></general>
            </profile>
            """
            try autoYaST.write(to: automationDirectory.appendingPathComponent("autoinst.xml"), atomically: true, encoding: .utf8)
        case .manualOnly:
            return nil
        }

        let outputISO = assets.vmDirectoryURL.appendingPathComponent("automation-seed.iso")
        if FileManager.default.fileExists(atPath: outputISO.path) {
            try FileManager.default.removeItem(at: outputISO)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-o", outputISO.path,
            automationDirectory.path,
            "-iso",
            "-joliet"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RuntimeServiceError.commandFailed("Failed to create automation ISO: \(output)")
        }

        return outputISO
    }

    private func automationProfile(for distribution: LinuxDistribution) -> InstallerAutomationProfile {
        switch distribution {
        case .ubuntu: return .ubuntuCloudInit
        case .debian: return .debianPreseed
        case .fedora: return .fedoraKickstart
        case .openSUSE: return .openSUSEAutoYaST
        case .popOS: return .manualOnly
        }
    }

    private func buildVirtualizationConfiguration(
        request: VMInstallRequest,
        assets: VMInstallAssets
    ) throws -> VZVirtualMachineConfiguration {
        guard let installerImageURL = assets.installerImageURL else {
            throw RuntimeServiceError.missingAssets("Installer image URL is required for Virtualization flow.")
        }

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = request.cpuCores
        config.memorySize = UInt64(request.memoryGB) * 1_073_741_824

        let platform = VZGenericPlatformConfiguration()
        if FileManager.default.fileExists(atPath: assets.machineIdentifierURL.path),
           let data = try? Data(contentsOf: assets.machineIdentifierURL),
           let machine = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = machine
        } else {
            platform.machineIdentifier = VZGenericMachineIdentifier()
        }
        config.platform = platform

        let bootloader = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: assets.efiVariableStoreURL.path) {
            bootloader.variableStore = VZEFIVariableStore(url: assets.efiVariableStoreURL)
        } else {
            bootloader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: assets.efiVariableStoreURL)
        }
        config.bootLoader = bootloader

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: assets.diskImageURL, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

        let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: installerImageURL, readOnly: true)
        let isoDevice = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
        var storageDevices: [VZStorageDeviceConfiguration] = [isoDevice, diskDevice]

        let automationISO = assets.vmDirectoryURL.appendingPathComponent("automation-seed.iso")
        if FileManager.default.fileExists(atPath: automationISO.path) {
            let autoAttachment = try VZDiskImageStorageDeviceAttachment(url: automationISO, readOnly: true)
            let autoDevice = VZUSBMassStorageDeviceConfiguration(attachment: autoAttachment)
            storageDevices.append(autoDevice)
        }

        config.storageDevices = storageDevices

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1440, heightInPixels: 900)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        if request.enableSharedFolders {
            let sharedDir = VZSharedDirectory(url: FileManager.default.homeDirectoryForCurrentUser, readOnly: false)
            let singleShare = VZSingleDirectoryShare(directory: sharedDir)
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "host-home")
            fs.share = singleShare
            config.directorySharingDevices = [fs]
        }

        try config.validate()
        return config
    }
}
