import Foundation
import CryptoKit
@preconcurrency import Virtualization
import AppKit

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

enum QEMUBinaryLocator {
    static func binaryName(for architecture: HostArchitecture) -> String {
        architecture == .appleSilicon ? "qemu-system-aarch64" : "qemu-system-x86_64"
    }

    static func locateBinaryPath(for architecture: HostArchitecture) -> String? {
        let name = binaryName(for: architecture)
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-lc",
            "PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin command -v \(name)"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let output, !output.isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }
}

struct ArtifactDownloadProgress: Sendable {
    let sourceURL: URL
    let receivedBytes: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0.0), 1.0)
    }
}

protocol CommandRunning: Sendable {
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
    func downloadArtifact(
        primaryURL: URL,
        mirrorURLs: [URL],
        destinationURL: URL,
        maxRetriesPerURL: Int,
        progressHandler: (@Sendable (ArtifactDownloadProgress) -> Void)?
    ) async throws
}

extension ArtifactDownloading {
    func downloadArtifact(
        primaryURL: URL,
        mirrorURLs: [URL],
        destinationURL: URL,
        maxRetriesPerURL: Int
    ) async throws {
        try await downloadArtifact(
            primaryURL: primaryURL,
            mirrorURLs: mirrorURLs,
            destinationURL: destinationURL,
            maxRetriesPerURL: maxRetriesPerURL,
            progressHandler: nil
        )
    }
}

actor ResumableArtifactDownloader: ArtifactDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func downloadArtifact(
        primaryURL: URL,
        mirrorURLs: [URL],
        destinationURL: URL,
        maxRetriesPerURL: Int = 3,
        progressHandler: (@Sendable (ArtifactDownloadProgress) -> Void)? = nil
    ) async throws {
        let candidates = [primaryURL] + mirrorURLs
        guard !candidates.isEmpty else {
            throw RuntimeServiceError.downloadFailed("No download URLs were provided.")
        }

        var lastError: Error?
        for candidate in candidates {
            for attempt in 1...max(maxRetriesPerURL, 1) {
                do {
                    try await downloadFromSingleURL(
                        candidate,
                        destinationURL: destinationURL,
                        progressHandler: progressHandler
                    )
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

    private func downloadFromSingleURL(
        _ url: URL,
        destinationURL: URL,
        allowRangeRetry: Bool = true,
        progressHandler: (@Sendable (ArtifactDownloadProgress) -> Void)? = nil
    ) async throws {
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
        let totalBytes = resolveTotalBytes(http: http, existingBytes: existingBytes)
        var receivedBytes: Int64 = (http.statusCode == 206) ? Int64(existingBytes) : 0
        progressHandler?(
            ArtifactDownloadProgress(
                sourceURL: url,
                receivedBytes: receivedBytes,
                totalBytes: totalBytes
            )
        )

        switch http.statusCode {
        case 200:
            if existingBytes > 0 {
                try? fileManager.removeItem(at: destinationURL)
            }
            try await writeBytes(
                bytes,
                to: destinationURL,
                append: false
            ) { delta in
                receivedBytes += delta
                progressHandler?(
                    ArtifactDownloadProgress(
                        sourceURL: url,
                        receivedBytes: receivedBytes,
                        totalBytes: totalBytes
                    )
                )
            }
        case 206:
            try await writeBytes(
                bytes,
                to: destinationURL,
                append: true
            ) { delta in
                receivedBytes += delta
                progressHandler?(
                    ArtifactDownloadProgress(
                        sourceURL: url,
                        receivedBytes: receivedBytes,
                        totalBytes: totalBytes
                    )
                )
            }
        case 416:
            // Some mirrors reject stale range offsets. Clear partial data and retry once
            // without a Range header before failing this URL.
            if existingBytes > 0, allowRangeRetry {
                try? fileManager.removeItem(at: destinationURL)
                try await downloadFromSingleURL(
                    url,
                    destinationURL: destinationURL,
                    allowRangeRetry: false,
                    progressHandler: progressHandler
                )
                return
            }
            throw RuntimeServiceError.downloadFailed("HTTP 416 from \(url.absoluteString)")
        default:
            throw RuntimeServiceError.downloadFailed("HTTP \(http.statusCode) from \(url.absoluteString)")
        }
    }

    private func writeBytes(
        _ bytes: URLSession.AsyncBytes,
        to url: URL,
        append: Bool,
        progressUpdate: ((Int64) -> Void)? = nil
    ) async throws {
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
                progressUpdate?(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            progressUpdate?(Int64(buffer.count))
        }
    }

    private func resolveTotalBytes(http: HTTPURLResponse, existingBytes: UInt64) -> Int64? {
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart),
           total > 0 {
            return total
        }

        let expected = http.expectedContentLength
        if expected > 0 {
            if http.statusCode == 206 {
                return Int64(existingBytes) + expected
            }
            return expected
        }

        return nil
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
            let resolvedDescriptor = await resolveDynamicDescriptorIfNeeded(descriptor)
            let fileToken = resolvedDescriptor.checksumFileName ?? resolvedDescriptor.downloadURL.lastPathComponent
            let artifactID = "\(descriptor.distribution.rawValue)-\(architecture.rawValue)-\(fileToken)"
            do {
                let result = try await fetchChecksumAndSignature(descriptor: resolvedDescriptor)
                signatureStatusByArtifactID[artifactID] = result.signatureVerified

                artifacts.append(
                    DistributionArtifact(
                        id: artifactID,
                        distribution: resolvedDescriptor.distribution,
                        architecture: architecture,
                        version: resolvedDescriptor.version,
                        downloadURL: resolvedDescriptor.downloadURL,
                        mirrorURLs: resolvedDescriptor.mirrorURLs,
                        checksumSHA256: result.checksum,
                        signatureExpected: resolvedDescriptor.checksumSignatureURL != nil,
                        signatureVerifiedAtSource: result.signatureVerified
                    )
                )
            } catch {
                // Keep catalog visible even if checksum/signature metadata endpoints fail.
                // Download can still proceed, and UI can warn that metadata verification is unavailable.
                signatureStatusByArtifactID[artifactID] = false
                artifacts.append(
                    DistributionArtifact(
                        id: artifactID,
                        distribution: resolvedDescriptor.distribution,
                        architecture: architecture,
                        version: resolvedDescriptor.version,
                        downloadURL: resolvedDescriptor.downloadURL,
                        mirrorURLs: resolvedDescriptor.mirrorURLs,
                        checksumSHA256: "",
                        signatureExpected: resolvedDescriptor.checksumSignatureURL != nil,
                        signatureVerifiedAtSource: false
                    )
                )
            }
        }

        return artifacts.sorted { $0.distribution.rawValue < $1.distribution.rawValue }
    }

    private func resolveDynamicDescriptorIfNeeded(_ descriptor: DistributionReleaseDescriptor) async -> DistributionReleaseDescriptor {
        guard descriptor.distribution == .debian else {
            return descriptor
        }

        guard let discoveredISOName = await discoverDebianCurrentISOName(for: descriptor) else {
            return descriptor
        }

        let directoryURL = descriptor.downloadURL.deletingLastPathComponent()
        let resolvedURL = directoryURL.appendingPathComponent(discoveredISOName)
        return DistributionReleaseDescriptor(
            distribution: descriptor.distribution,
            architecture: descriptor.architecture,
            version: descriptor.version,
            downloadURL: resolvedURL,
            mirrorURLs: descriptor.mirrorURLs,
            checksumFeedURL: descriptor.checksumFeedURL,
            checksumFileName: discoveredISOName,
            checksumStrategy: descriptor.checksumStrategy,
            checksumSignatureURL: descriptor.checksumSignatureURL,
            keyringFileName: descriptor.keyringFileName,
            keyFingerprint: descriptor.keyFingerprint
        )
    }

    private func discoverDebianCurrentISOName(for descriptor: DistributionReleaseDescriptor) async -> String? {
        let directoryURL = descriptor.downloadURL.deletingLastPathComponent()
        guard let (data, _) = try? await URLSession.shared.data(from: directoryURL) else {
            return nil
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        let archToken = descriptor.architecture == .appleSilicon ? "arm64" : "amd64"
        let profileToken = descriptor.downloadURL.lastPathComponent.localizedCaseInsensitiveContains("DVD-1")
            ? "DVD-1"
            : "netinst"
        let pattern = "debian-([0-9]+(?:\\.[0-9]+)*)-\(archToken)-\(profileToken)\\.iso"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return nil
        }

        var bestFileName: String?
        var bestVersionComponents: [Int] = []
        for match in matches {
            guard
                match.numberOfRanges >= 2,
                let versionRange = Range(match.range(at: 1), in: html),
                let fullRange = Range(match.range(at: 0), in: html)
            else { continue }
            let version = String(html[versionRange])
            let fileName = String(html[fullRange])
            let components = version.split(separator: ".").compactMap { Int($0) }
            if compareVersionComponents(components, bestVersionComponents) == .orderedDescending {
                bestVersionComponents = components
                bestFileName = fileName
            }
        }

        return bestFileName
    }

    private func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
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
            mirrorURLs: [],
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
                URL(string: "https://old-releases.ubuntu.com/releases/24.04.4/ubuntu-24.04.4-desktop-amd64.iso")!
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
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-arm64-netinst.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .debian,
            architecture: .appleSilicon,
            version: "13 (full DVD)",
            downloadURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/debian-13.0.0-arm64-DVD-1.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-arm64-DVD-1.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .debian,
            architecture: .intel,
            version: "13 (netinst)",
            downloadURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-amd64-netinst.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .debian,
            architecture: .intel,
            version: "13 (full DVD)",
            downloadURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/debian-13.0.0-amd64-DVD-1.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/SHA256SUMS"),
            checksumFileName: "debian-13.0.0-amd64-DVD-1.iso",
            checksumStrategy: .standardSha256SumsFile,
            checksumSignatureURL: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/SHA256SUMS.sign"),
            keyringFileName: "debian-archive-keyring.gpg",
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .fedora,
            architecture: .intel,
            version: "Workstation 43",
            downloadURL: URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/x86_64/iso/Fedora-Workstation-Live-43-1.6.x86_64.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/x86_64/iso/Fedora-Workstation-43-1.6-x86_64-CHECKSUM"),
            checksumFileName: "Fedora-Workstation-Live-43-1.6.x86_64.iso",
            checksumStrategy: .fedoraChecksumFile,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .fedora,
            architecture: .appleSilicon,
            version: "Workstation 43",
            downloadURL: URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/aarch64/iso/Fedora-Workstation-Live-43-1.6.aarch64.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/aarch64/iso/Fedora-Workstation-43-1.6-aarch64-CHECKSUM"),
            checksumFileName: "Fedora-Workstation-Live-43-1.6.aarch64.iso",
            checksumStrategy: .fedoraChecksumFile,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .nixOS,
            architecture: .intel,
            version: "24.11 (minimal)",
            downloadURL: URL(string: "https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-x86_64-linux.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-x86_64-linux.iso.sha256"),
            checksumFileName: "latest-nixos-minimal-x86_64-linux.iso",
            checksumStrategy: .directSha256File,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .nixOS,
            architecture: .appleSilicon,
            version: "24.11 (minimal)",
            downloadURL: URL(string: "https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-aarch64-linux.iso")!,
            mirrorURLs: [],
            checksumFeedURL: URL(string: "https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-aarch64-linux.iso.sha256"),
            checksumFileName: "latest-nixos-minimal-aarch64-linux.iso",
            checksumStrategy: .directSha256File,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .windows11,
            architecture: .intel,
            version: "Latest (Microsoft official media)",
            downloadURL: URL(string: "https://www.microsoft.com/software-download/windows11ISO")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .windows11,
            architecture: .appleSilicon,
            version: "Latest ARM64 (Microsoft official media)",
            downloadURL: URL(string: "https://www.microsoft.com/en-us/software-download/windows11ARM64")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .openSUSE,
            architecture: .intel,
            version: "Tumbleweed Current",
            downloadURL: URL(string: "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso")!,
            mirrorURLs: [],
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
            mirrorURLs: [],
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
            downloadURL: URL(string: "https://iso.pop-os.org/24.04/amd64/generic/22/pop-os_24.04_amd64_generic_22.iso")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .popOS,
            architecture: .intel,
            version: "24.04 LTS (NVIDIA)",
            downloadURL: URL(string: "https://iso.pop-os.org/24.04/amd64/nvidia/22/pop-os_24.04_amd64_nvidia_22.iso")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .popOS,
            architecture: .appleSilicon,
            version: "24.04 LTS (ARM)",
            downloadURL: URL(string: "https://iso.pop-os.org/24.04/arm64/generic/3/pop-os_24.04_arm64_generic_3.iso")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        ),
        DistributionReleaseDescriptor(
            distribution: .popOS,
            architecture: .appleSilicon,
            version: "24.04 LTS (ARM NVIDIA)",
            downloadURL: URL(string: "https://iso.pop-os.org/24.04/arm64/nvidia/3/pop-os_24.04_arm64_nvidia_3.iso")!,
            mirrorURLs: [],
            checksumFeedURL: nil,
            checksumFileName: nil,
            checksumStrategy: nil,
            checksumSignatureURL: nil,
            keyringFileName: nil,
            keyFingerprint: nil
        )
    ]
}

protocol QEMUFallbackHook: Sendable {
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

        let qemuBin = QEMUBinaryLocator.binaryName(for: request.architecture)
        let qemuBinaryPath: String
        if let located = QEMUBinaryLocator.locateBinaryPath(for: request.architecture) {
            qemuBinaryPath = located
        } else {
            let lookupResult = try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-lc",
                    "PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin command -v \(qemuBin)"
                ]
            )
            let resolved = lookupResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lookupResult.status == 0, !resolved.isEmpty else {
                throw RuntimeServiceError.commandFailed("Could not locate \(qemuBin). Install QEMU first. Output: \(lookupResult.output)")
            }
            qemuBinaryPath = resolved
        }

        let automationISO = assets.vmDirectoryURL.appendingPathComponent("automation-seed.iso")
        let hasAutomationISO = FileManager.default.fileExists(atPath: automationISO.path)

        let launchScriptURL = assets.vmDirectoryURL.appendingPathComponent("launch-qemu.sh")
        var scriptLines: [String] = [
            "#!/bin/sh",
            "set -eu",
            "\(qemuBinaryPath) \\",
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

@MainActor
final class VMConsoleWindowManager: NSObject {
    static let shared = VMConsoleWindowManager()

    private struct Session {
        let virtualMachine: VZVirtualMachine
        let virtualMachineQueue: DispatchQueue
        let consoleView: VZVirtualMachineView
        var window: NSWindow?
        var embeddedContainer: NSScrollView?
        let vmDirectoryPath: String
    }

    private var sessions: [UUID: Session] = [:]

    func startConsole(
        vmID: UUID,
        vmDirectoryPath: String,
        configuration: VZVirtualMachineConfiguration
    ) async throws {
        traceVM("VMConsoleWindowManager.startConsole begin vmID=\(vmID.uuidString) vmDirectoryPath=\(vmDirectoryPath)")

        if let existing = sessions[vmID] {
            let state = existing.virtualMachine.state
            traceVM("VMConsoleWindowManager.startConsole existing session vmID=\(vmID.uuidString) state=\(state.rawValue)")
            if state == .running || state == .paused || state == .starting || state == .resuming {
                _ = focusConsole(vmID: vmID)
                return
            }
            existing.window?.close()
            sessions[vmID] = nil
        }

        let vmQueue = DispatchQueue(label: "com.tbdo.ml-integration.vm.\(vmID.uuidString)")
        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        let consoleView = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        consoleView.virtualMachine = virtualMachine

        sessions[vmID] = Session(
            virtualMachine: virtualMachine,
            virtualMachineQueue: vmQueue,
            consoleView: consoleView,
            window: nil,
            embeddedContainer: nil,
            vmDirectoryPath: vmDirectoryPath
        )
        traceVM("VMConsoleWindowManager.startConsole session created vmID=\(vmID.uuidString)")
        try await startVirtualMachineAsync(
            vmID: vmID,
            virtualMachine: virtualMachine,
            virtualMachineQueue: vmQueue
        )
        traceVM("VMConsoleWindowManager.startConsole state vmID=\(vmID.uuidString) state=\(virtualMachine.state.rawValue)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let stateAfterDelay = virtualMachine.state
        traceVM("VMConsoleWindowManager.startConsole state+2s vmID=\(vmID.uuidString) state=\(stateAfterDelay.rawValue)")
        if stateAfterDelay == .stopped || stateAfterDelay == .error {
            sessions[vmID] = nil
            throw RuntimeServiceError.invalidVMRequest(
                "VM exited immediately after start. No bootable OS was detected. Reinstall OS or boot from installer media."
            )
        }
    }

    func stopConsole(vmID: UUID) async throws {
        traceVM("VMConsoleWindowManager.stopConsole begin vmID=\(vmID.uuidString)")
        guard let session = sessions.removeValue(forKey: vmID) else {
            traceVM("VMConsoleWindowManager.stopConsole no session vmID=\(vmID.uuidString)")
            return
        }
        let window = session.window

        // Hide/detach UI immediately so stop actions don't block on window teardown.
        if let window {
            window.orderOut(nil)
            window.contentView = nil
            traceVM("VMConsoleWindowManager.stopConsole window hidden vmID=\(vmID.uuidString)")
            DispatchQueue.main.async {
                window.close()
            }
        }
        session.embeddedContainer?.removeFromSuperview()

        nonisolated(unsafe) let virtualMachine = session.virtualMachine
        let vmQueue = session.virtualMachineQueue
        vmQueue.async {
            if virtualMachine.state == .stopped {
                traceVM("VMConsoleWindowManager.stopConsole vm already stopped vmID=\(vmID.uuidString)")
                return
            }

            if virtualMachine.canRequestStop {
                do {
                    try virtualMachine.requestStop()
                    traceVM("VMConsoleWindowManager.stopConsole requested guest stop vmID=\(vmID.uuidString)")
                } catch {
                    traceVM("VMConsoleWindowManager.stopConsole requestStop failed vmID=\(vmID.uuidString) error=\(error.localizedDescription)")
                }
            } else {
                traceVM("VMConsoleWindowManager.stopConsole requestStop unavailable vmID=\(vmID.uuidString) state=\(virtualMachine.state.rawValue)")
            }
        }

        traceVM("VMConsoleWindowManager.stopConsole return without awaiting vm stop vmID=\(vmID.uuidString)")
    }

    func focusConsole(vmID: UUID) -> Bool {
        guard var session = sessions[vmID] else { return false }
        if session.window == nil {
            session.window = makeConsoleWindow(vmID: vmID, session: session)
            sessions[vmID] = session
        } else if let existingWindow = session.window {
            attachConsoleView(session.consoleView, to: existingWindow, vmID: vmID)
        }
        guard let window = session.window else { return false }
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        traceVM("VMConsoleWindowManager.focusConsole done vmID=\(vmID.uuidString) isVisible=\(window.isVisible)")
        return true
    }

    func closeConsoleWindowIfPresent(vmID: UUID) {
        guard var session = sessions[vmID] else { return }
        session.window?.orderOut(nil)
        session.window?.close()
        session.window = nil
        sessions[vmID] = session
        traceVM("VMConsoleWindowManager.closeConsoleWindowIfPresent completed vmID=\(vmID.uuidString)")
    }

    func embeddedConsoleContainer(vmID: UUID) -> NSView? {
        guard var session = sessions[vmID] else { return nil }
        if session.embeddedContainer == nil {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = false
            scrollView.borderType = .bezelBorder
            scrollView.drawsBackground = true

            let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
            documentView.autoresizingMask = []
            session.consoleView.frame = documentView.bounds
            documentView.addSubview(session.consoleView)
            scrollView.documentView = documentView
            session.embeddedContainer = scrollView
            sessions[vmID] = session
        } else if let container = session.embeddedContainer,
                  let documentView = container.documentView {
            session.consoleView.removeFromSuperviewWithoutNeedingDisplay()
            session.consoleView.frame = documentView.bounds
            documentView.addSubview(session.consoleView)
            sessions[vmID] = session
        }

        return session.embeddedContainer
    }

    private func makeConsoleWindow(vmID: UUID, session: Session) -> NSWindow {
        traceVM("VMConsoleWindowManager.makeConsoleWindow begin vmID=\(vmID.uuidString)")
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VM Console - \(vmID.uuidString.prefix(8))"
        attachConsoleView(session.consoleView, to: window, vmID: vmID)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        traceVM("VMConsoleWindowManager.makeConsoleWindow prepared vmID=\(vmID.uuidString)")
        return window
    }

    private func attachConsoleView(_ consoleView: VZVirtualMachineView, to window: NSWindow, vmID: UUID) {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        hostView.autoresizingMask = [.width, .height]

        let headerView = NSView(frame: NSRect(x: 0, y: hostView.bounds.height - 44, width: hostView.bounds.width, height: 44))
        headerView.autoresizingMask = [.width, .minYMargin]

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeButtonPressed(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: hostView.bounds.width - 88, y: 8, width: 76, height: 28)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.identifier = NSUserInterfaceItemIdentifier(vmID.uuidString)
        headerView.addSubview(closeButton)

        let consoleFrame = NSRect(x: 0, y: 0, width: hostView.bounds.width, height: hostView.bounds.height - headerView.frame.height)
        consoleView.removeFromSuperviewWithoutNeedingDisplay()
        consoleView.frame = consoleFrame
        consoleView.autoresizingMask = [.width, .height]
        hostView.addSubview(consoleView)
        hostView.addSubview(headerView)
        window.contentView = hostView
    }

    @objc
    private func closeButtonPressed(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let vmID = UUID(uuidString: rawID)
        else {
            return
        }
        Task { @MainActor in
            try? await stopConsole(vmID: vmID)
        }
    }

    private func startVirtualMachineAsync(
        vmID: UUID,
        virtualMachine: VZVirtualMachine,
        virtualMachineQueue: DispatchQueue
    ) async throws {
        traceVM("VMConsoleWindowManager.startVirtualMachineAsync scheduled vmID=\(vmID.uuidString)")
        nonisolated(unsafe) let unsafeVirtualMachine = virtualMachine
        try await withCheckedThrowingContinuation { continuation in
            virtualMachineQueue.async {
                traceVM("VMConsoleWindowManager.startVirtualMachineAsync queue-enter vmID=\(vmID.uuidString)")
                unsafeVirtualMachine.start { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            traceVM("VMConsoleWindowManager.startVirtualMachineAsync success vmID=\(vmID.uuidString)")
                            continuation.resume()
                        case .failure(let error):
                            traceVM("VMConsoleWindowManager.startVirtualMachineAsync failure vmID=\(vmID.uuidString) error=\(error.localizedDescription)")
                            if let session = self.sessions[vmID] {
                                session.window?.close()
                            }
                            self.sessions[vmID] = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RuntimeServiceError.commandFailed("VM operation timed out after \(Int(seconds)) seconds.")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

actor VMProvisioningPipelineService: VMProvisioningService {
    private var records: [UUID: VMProvisionRecord] = [:]
    private var qemuProcesses: [UUID: Process] = [:]
    nonisolated private let qemuHook: QEMUFallbackHook
    nonisolated private let registry: VMRegistryManaging

    init(
        qemuHook: QEMUFallbackHook,
        registry: VMRegistryManaging
    ) {
        self.qemuHook = qemuHook
        self.registry = registry
    }

    func validate(_ request: VMInstallRequest, assets: VMInstallAssets?) async throws {
        guard request.cpuCores > 0 else { throw RuntimeServiceError.invalidVMRequest("CPU cores must be greater than 0.") }
        guard request.memoryGB >= 2 else { throw RuntimeServiceError.invalidVMRequest("Memory must be at least 2 GB.") }
        guard request.diskGB >= 20 else { throw RuntimeServiceError.invalidVMRequest("Disk must be at least 20 GB.") }
        try validateSupportedDistributionPolicy(request)
        try validateInstallerMediaPolicy(request: request, assets: assets)

        switch request.runtimeEngine {
        case .appleVirtualization, .windowsDedicated:
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
        guard request.cpuCores > 0 else { throw RuntimeServiceError.invalidVMRequest("CPU cores must be greater than 0.") }
        guard request.memoryGB >= 2 else { throw RuntimeServiceError.invalidVMRequest("Memory must be at least 2 GB.") }
        guard request.diskGB >= 20 else { throw RuntimeServiceError.invalidVMRequest("Disk must be at least 20 GB.") }
        try validateSupportedDistributionPolicy(request)
        try validateInstallerMediaPolicy(request: request, assets: assets)

        let vmID: UUID
        switch request.runtimeEngine {
        case .appleVirtualization, .windowsDedicated:
            guard VZVirtualMachine.isSupported else { throw RuntimeServiceError.virtualizationNotSupported }
            guard let assets else {
                throw RuntimeServiceError.missingAssets("Virtualization flow requires installer image path and VM asset paths.")
            }

            let stagedAssets = try stageInstallerImageIfNeeded(assets: assets)
            // Prepare file-backed VM assets before building/validating Virtualization config.
            // Disk image attachment validation fails if disk.img does not exist yet.
            try createVMFilesIfNeeded(request: request, assets: stagedAssets)
            _ = try buildVirtualizationConfiguration(request: request, assets: stagedAssets)

            vmID = UUID()
            records[vmID] = VMProvisionRecord(id: vmID, request: request, assets: stagedAssets, isRunning: false)
            let now = ISO8601DateFormatter().string(from: Date())
            let entry = VMRegistryEntry(
                id: vmID,
                vmName: stagedAssets.vmName,
                vmDirectoryPath: stagedAssets.vmDirectoryURL.path,
                distribution: request.distribution,
                architecture: request.architecture,
                runtimeEngine: request.runtimeEngine,
                createdAtISO8601: now,
                updatedAtISO8601: now
            )
            try await registry.upsert(entry)
            return vmID
        case .qemuFallback:
            try await validate(request, assets: assets)
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

    private func validateInstallerMediaPolicy(request: VMInstallRequest, assets: VMInstallAssets?) throws {
        guard request.distribution == .popOS else { return }
        guard let installerURL = assets?.installerImageURL else {
            throw RuntimeServiceError.missingAssets("Pop!_OS install requires an official installer ISO image.")
        }
        guard installerURL.pathExtension.lowercased() == "iso" else {
            throw RuntimeServiceError.invalidVMRequest(
                "Pop!_OS install must use installer ISO media. Kernel/initrd-only bootstrap is not supported."
            )
        }
    }

    private func validateSupportedDistributionPolicy(_ request: VMInstallRequest) throws {
        if request.runtimeEngine == .appleVirtualization || request.runtimeEngine == .qemuFallback {
            let isSupported: Bool
            switch request.distribution {
            case .ubuntu, .fedora, .debian:
                isSupported = true
            default:
                isSupported = false
            }
            guard isSupported else {
                throw RuntimeServiceError.invalidVMRequest(
                    "This build supports in-app Linux guests for Ubuntu, Fedora, and Debian only."
                )
            }
        }
    }

    private func validateRuntimeLaunchPolicy(_ request: VMInstallRequest) throws {
        if request.distribution == .windows11,
           (request.runtimeEngine == .appleVirtualization || request.runtimeEngine == .windowsDedicated) {
            throw RuntimeServiceError.invalidVMRequest(
                "Windows 11 cannot be launched reliably with the current in-app Apple Virtualization backend in this build. " +
                "Use Linux guests here, or select a Windows-capable external runtime path."
            )
        }
    }

    func startVM(id: UUID) async throws {
        traceVM("VMProvisioningPipelineService.startVM begin id=\(id.uuidString)")
        _ = await restoreRecordIfNeeded(id: id)
        guard var record = records[id] else {
            traceVM("VMProvisioningPipelineService.startVM missing record id=\(id.uuidString)")
            throw RuntimeServiceError.vmNotFound
        }
        if record.request.distribution == .windows11, record.request.runtimeEngine == .appleVirtualization {
            record = VMProvisionRecord(
                id: record.id,
                request: VMInstallRequest(
                    distribution: record.request.distribution,
                    runtimeEngine: .windowsDedicated,
                    architecture: record.request.architecture,
                    cpuCores: record.request.cpuCores,
                    memoryGB: record.request.memoryGB,
                    diskGB: record.request.diskGB,
                    enableSharedFolders: record.request.enableSharedFolders,
                    enableSharedClipboard: record.request.enableSharedClipboard
                ),
                assets: record.assets,
                isRunning: record.isRunning
            )
            records[id] = record
            traceVM("VMProvisioningPipelineService.startVM migrated runtime to windows dedicated id=\(id.uuidString)")
        }
        try validateSupportedDistributionPolicy(record.request)
        try validateRuntimeLaunchPolicy(record.request)
        if let runningRecord = records.first(where: { $0.key != id && $0.value.isRunning })?.value {
            throw RuntimeServiceError.invalidVMRequest(
                "Only one VM can run at a time in this release. Stop '\(runningRecord.assets?.vmName ?? runningRecord.id.uuidString)' first."
            )
        }

        switch record.request.runtimeEngine {
        case .appleVirtualization, .windowsDedicated:
            guard let assets = record.assets else {
                traceVM("VMProvisioningPipelineService.startVM missing assets id=\(id.uuidString)")
                throw RuntimeServiceError.missingAssets("Virtualization flow requires VM assets.")
            }
            let installerPath = assets.installerImageURL?.path ?? "nil"
            let installerExists = assets.installerImageURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let preferInstallerFirst = shouldPreferInstallerBoot(
                request: record.request,
                assets: assets,
                installerExists: installerExists
            )
            if record.request.distribution == .windows11 && preferInstallerFirst {
                try resetEFIVariableStoreIfNeeded(at: assets.efiVariableStoreURL)
            }
            traceVM(
                "VMProvisioningPipelineService.startVM media id=\(id.uuidString) " +
                "disk=\(assets.diskImageURL.lastPathComponent) installerPath=\(installerPath) installerExists=\(installerExists)"
            )
            do {
                traceVM(
                    "VMProvisioningPipelineService.startVM building configuration id=\(id.uuidString) " +
                    "bootOrder=\(preferInstallerFirst ? "installerFirst" : "diskFirst")"
                )
                let configuration = try buildVirtualizationConfiguration(
                    request: record.request,
                    assets: assets,
                    preferInstallerBoot: preferInstallerFirst
                )
                traceVM("VMProvisioningPipelineService.startVM configuration validated id=\(id.uuidString)")

                try await VMConsoleWindowManager.shared.startConsole(
                    vmID: id,
                    vmDirectoryPath: assets.vmDirectoryURL.path,
                    configuration: configuration
                )
                traceVM("VMProvisioningPipelineService.startVM console start dispatched id=\(id.uuidString)")
            } catch {
                let canRetryWithInstallerBoot =
                    error.localizedDescription.localizedCaseInsensitiveContains("No bootable OS")
                    && installerExists
                guard canRetryWithInstallerBoot else {
                    throw error
                }

                traceVM("VMProvisioningPipelineService.startVM retrying id=\(id.uuidString) bootOrder=installerFirst")
                if record.request.distribution == .windows11 {
                    try resetEFIVariableStoreIfNeeded(at: assets.efiVariableStoreURL)
                }
                let fallbackConfiguration = try buildVirtualizationConfiguration(
                    request: record.request,
                    assets: assets,
                    preferInstallerBoot: true
                )
                try await VMConsoleWindowManager.shared.startConsole(
                    vmID: id,
                    vmDirectoryPath: assets.vmDirectoryURL.path,
                    configuration: fallbackConfiguration
                )
                traceVM("VMProvisioningPipelineService.startVM fallback console start dispatched id=\(id.uuidString)")
            }

        case .qemuFallback:
            traceVM("VMProvisioningPipelineService.startVM qemu fallback begin id=\(id.uuidString)")
            try await startQEMURuntime(vmID: id, record: record)
            traceVM("VMProvisioningPipelineService.startVM qemu fallback launched id=\(id.uuidString)")
        case .nativeInstall:
            throw RuntimeServiceError.nativeInstallNotSupported
        }

        record.isRunning = true
        records[id] = record
        traceVM("VMProvisioningPipelineService.startVM complete id=\(id.uuidString)")
    }

    func stopVM(id: UUID) async throws {
        traceVM("VMProvisioningPipelineService.stopVM begin id=\(id.uuidString)")
        _ = await restoreRecordIfNeeded(id: id)
        guard var record = records[id] else {
            traceVM("VMProvisioningPipelineService.stopVM missing record id=\(id.uuidString)")
            throw RuntimeServiceError.vmNotFound
        }

        if record.request.runtimeEngine == .appleVirtualization || record.request.runtimeEngine == .windowsDedicated {
            traceVM("VMProvisioningPipelineService.stopVM dispatching stopConsole vmID=\(id.uuidString)")
            Task { @MainActor in
                do {
                    try await VMConsoleWindowManager.shared.stopConsole(vmID: id)
                    traceVM("VMProvisioningPipelineService.stopVM console stop complete id=\(id.uuidString)")
                } catch {
                    // Keep runtime control responsive even if console teardown reports an error.
                    traceVM("VMProvisioningPipelineService.stopVM console stop warning id=\(id.uuidString) error=\(error.localizedDescription)")
                }
            }
        } else if record.request.runtimeEngine == .qemuFallback {
            traceVM("VMProvisioningPipelineService.stopVM stopping qemu runtime vmID=\(id.uuidString)")
            try stopQEMURuntime(vmID: id, record: record)
            traceVM("VMProvisioningPipelineService.stopVM qemu runtime stop complete id=\(id.uuidString)")
        }

        record.isRunning = false
        records[id] = record
        traceVM("VMProvisioningPipelineService.stopVM complete id=\(id.uuidString)")
    }

    private func restoreRecordIfNeeded(id: UUID) async -> VMProvisionRecord? {
        if let existing = records[id] {
            return existing
        }

        guard let entry = await registry.entry(for: id) else {
            traceVM("VMProvisioningPipelineService.restoreRecordIfNeeded no registry entry id=\(id.uuidString)")
            return nil
        }

        let vmDirectoryURL = URL(fileURLWithPath: entry.vmDirectoryPath, isDirectory: true)
        let diskImageURL = vmDirectoryURL.appendingPathComponent("disk.img")
        let efiVariableStoreURL = vmDirectoryURL.appendingPathComponent("efi.vars")
        let machineIdentifierURL = vmDirectoryURL.appendingPathComponent("machine.id")
        let installerImageURL = resolveInstallerImageURL(vmDirectoryURL: vmDirectoryURL)

        let assets = VMInstallAssets(
            vmName: entry.vmName,
            vmDirectoryURL: vmDirectoryURL,
            installerImageURL: installerImageURL,
            kernelImageURL: nil,
            initialRamdiskURL: nil,
            diskImageURL: diskImageURL,
            efiVariableStoreURL: efiVariableStoreURL,
            machineIdentifierURL: machineIdentifierURL
        )

        var runtimeEngine = entry.runtimeEngine
        if entry.distribution == .windows11 && runtimeEngine == .appleVirtualization {
            runtimeEngine = .windowsDedicated
            let migratedEntry = VMRegistryEntry(
                id: entry.id,
                vmName: entry.vmName,
                vmDirectoryPath: entry.vmDirectoryPath,
                distribution: entry.distribution,
                architecture: entry.architecture,
                runtimeEngine: runtimeEngine,
                createdAtISO8601: entry.createdAtISO8601,
                updatedAtISO8601: ISO8601DateFormatter().string(from: Date())
            )
            try? await registry.upsert(migratedEntry)
            traceVM("VMProvisioningPipelineService.restoreRecordIfNeeded migrated registry runtime id=\(id.uuidString)")
        }

        let request = VMInstallRequest(
            distribution: entry.distribution,
            runtimeEngine: runtimeEngine,
            architecture: entry.architecture,
            cpuCores: entry.architecture == .appleSilicon ? 4 : 2,
            memoryGB: entry.architecture == .appleSilicon ? 8 : 6,
            diskGB: estimateDiskGB(diskImageURL: diskImageURL),
            enableSharedFolders: true,
            enableSharedClipboard: true
        )

        let restored = VMProvisionRecord(id: id, request: request, assets: assets, isRunning: false)
        records[id] = restored
        traceVM(
            "VMProvisioningPipelineService.restoreRecordIfNeeded restored id=\(id.uuidString) " +
            "installerPresent=\(installerImageURL != nil)"
        )
        return restored
    }

    private func resolveInstallerImageURL(vmDirectoryURL: URL) -> URL? {
        let fm = FileManager.default

        // Prefer explicitly staged installer media first.
        let stagedInstallerURL = vmDirectoryURL.appendingPathComponent("installer.iso")
        if fm.fileExists(atPath: stagedInstallerURL.path) {
            return stagedInstallerURL
        }

        // Fallback: pick VM-local ISO that is not automation seed media.
        if let vmFiles = try? fm.contentsOfDirectory(
            at: vmDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let vmISOs = vmFiles.filter {
                $0.pathExtension.lowercased() == "iso"
                && $0.lastPathComponent.localizedCaseInsensitiveCompare("automation-seed.iso") != .orderedSame
            }
            if let newestVMISO = vmISOs.sorted(
                by: {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs > rhs
                }
            ).first {
                return newestVMISO
            }
        }

        // Fallback to latest downloaded ISO in app downloads.
        let downloadsURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("downloads", isDirectory: true)
        if let downloadFiles = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let isos = downloadFiles.filter { $0.pathExtension.lowercased() == "iso" }
            if let newestDownloadISO = isos.sorted(
                by: {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs > rhs
                }
            ).first {
                return newestDownloadISO
            }
        }

        return nil
    }

    private func estimateDiskGB(diskImageURL: URL) -> Int {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: diskImageURL.path),
            let size = attrs[.size] as? NSNumber
        else {
            return 64
        }

        let bytes = max(size.doubleValue, 1)
        let gb = Int((bytes / 1_073_741_824.0).rounded(.up))
        return max(gb, 20)
    }

    private func shouldPreferInstallerBoot(
        request: VMInstallRequest,
        assets: VMInstallAssets,
        installerExists: Bool
    ) -> Bool {
        guard installerExists else { return false }
        guard request.distribution == .windows11 else { return false }
        return isLikelyFreshDiskImage(at: assets.diskImageURL)
    }

    private func isLikelyFreshDiskImage(at diskImageURL: URL) -> Bool {
        guard let values = try? diskImageURL.resourceValues(forKeys: [.fileAllocatedSizeKey]) else {
            return false
        }
        guard let allocated = values.fileAllocatedSize else {
            return false
        }
        // Sparse disk right after scaffold has very low physical allocation.
        return allocated < 1_073_741_824
    }

    private func resetEFIVariableStoreIfNeeded(at efiURL: URL) throws {
        if FileManager.default.fileExists(atPath: efiURL.path) {
            try FileManager.default.removeItem(at: efiURL)
            traceVM("VMProvisioningPipelineService.resetEFIVariableStore removed path=\(efiURL.path)")
        }
        _ = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        traceVM("VMProvisioningPipelineService.resetEFIVariableStore created path=\(efiURL.path)")
    }

    private func createVMFilesIfNeeded(request: VMInstallRequest, assets: VMInstallAssets) throws {
        traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded begin vmName=\(assets.vmName)")
        try FileManager.default.createDirectory(at: assets.vmDirectoryURL, withIntermediateDirectories: true)
        traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded vmDirectory ready path=\(assets.vmDirectoryURL.path)")

        if !FileManager.default.fileExists(atPath: assets.diskImageURL.path) {
            FileManager.default.createFile(atPath: assets.diskImageURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: assets.diskImageURL)
            try handle.truncate(atOffset: UInt64(request.diskGB) * 1_073_741_824)
            try handle.close()
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded disk created path=\(assets.diskImageURL.path)")
        } else {
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded disk exists path=\(assets.diskImageURL.path)")
        }

        if !FileManager.default.fileExists(atPath: assets.machineIdentifierURL.path) {
            let machineID = VZGenericMachineIdentifier()
            try machineID.dataRepresentation.write(to: assets.machineIdentifierURL)
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded machine id created path=\(assets.machineIdentifierURL.path)")
        } else {
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded machine id exists path=\(assets.machineIdentifierURL.path)")
        }

        if !FileManager.default.fileExists(atPath: assets.efiVariableStoreURL.path) {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: assets.efiVariableStoreURL)
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded efi vars created path=\(assets.efiVariableStoreURL.path)")
        } else {
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded efi vars exists path=\(assets.efiVariableStoreURL.path)")
        }

        // Automation media should not block installation if local tooling is unavailable.
        do {
            _ = try createAutomationSeedISOIfSupported(request: request, assets: assets)
            traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded automation seed prepared vmName=\(assets.vmName)")
        } catch {
            traceVM(
                "VMProvisioningPipelineService.createVMFilesIfNeeded automation seed skipped vmName=\(assets.vmName) " +
                "error=\(error.localizedDescription)"
            )
        }
        traceVM("VMProvisioningPipelineService.createVMFilesIfNeeded complete vmName=\(assets.vmName)")
    }

    private func startQEMURuntime(vmID: UUID, record: VMProvisionRecord) async throws {
        guard let assets = record.assets else {
            throw RuntimeServiceError.missingAssets("QEMU runtime requires VM assets.")
        }

        if let existing = qemuProcesses[vmID], existing.isRunning {
            traceVM("VMProvisioningPipelineService.startQEMURuntime already running vmID=\(vmID.uuidString)")
            return
        }

        let launchScriptURL = assets.vmDirectoryURL.appendingPathComponent("launch-qemu.sh")
        if !FileManager.default.fileExists(atPath: launchScriptURL.path) {
            traceVM(
                "VMProvisioningPipelineService.startQEMURuntime missing launch script; attempting regeneration " +
                "vmID=\(vmID.uuidString) path=\(launchScriptURL.path)"
            )
            _ = try await qemuHook.scaffoldInstall(for: record.request, assets: assets)
        }
        guard FileManager.default.fileExists(atPath: launchScriptURL.path) else {
            throw RuntimeServiceError.commandFailed("QEMU launch script missing at \(launchScriptURL.path). Reinstall VM scaffold.")
        }

        let process = Process()
        process.executableURL = launchScriptURL
        process.currentDirectoryURL = assets.vmDirectoryURL
        process.arguments = []

        let runtimeLogURL = assets.vmDirectoryURL.appendingPathComponent("qemu-runtime.log")
        if !FileManager.default.fileExists(atPath: runtimeLogURL.path) {
            FileManager.default.createFile(atPath: runtimeLogURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: runtimeLogURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { _ in
            try? logHandle.close()
        }

        try process.run()
        if !process.isRunning {
            try? logHandle.close()
            throw RuntimeServiceError.commandFailed("QEMU process exited immediately. Check \(runtimeLogURL.path).")
        }

        let pidFileURL = assets.vmDirectoryURL.appendingPathComponent("qemu.pid")
        try? "\(process.processIdentifier)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)

        qemuProcesses[vmID] = process
        traceVM(
            "VMProvisioningPipelineService.startQEMURuntime started vmID=\(vmID.uuidString) " +
            "pid=\(process.processIdentifier) script=\(launchScriptURL.path)"
        )
    }

    private func stopQEMURuntime(vmID: UUID, record: VMProvisionRecord) throws {
        guard let assets = record.assets else {
            throw RuntimeServiceError.missingAssets("QEMU runtime requires VM assets.")
        }

        let pidFileURL = assets.vmDirectoryURL.appendingPathComponent("qemu.pid")
        defer { try? FileManager.default.removeItem(at: pidFileURL) }

        if let process = qemuProcesses.removeValue(forKey: vmID) {
            if process.isRunning {
                process.terminate()
                traceVM("VMProvisioningPipelineService.stopQEMURuntime terminated in-memory process vmID=\(vmID.uuidString)")
            }
            return
        }

        guard
            let pidText = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            traceVM("VMProvisioningPipelineService.stopQEMURuntime no process handle or pid vmID=\(vmID.uuidString)")
            return
        }

        let result = kill(pid, SIGTERM)
        if result == 0 {
            traceVM("VMProvisioningPipelineService.stopQEMURuntime terminated pid vmID=\(vmID.uuidString) pid=\(pid)")
        } else {
            traceVM("VMProvisioningPipelineService.stopQEMURuntime kill failed vmID=\(vmID.uuidString) pid=\(pid) errno=\(errno)")
        }
    }

    private func stageInstallerImageIfNeeded(assets: VMInstallAssets) throws -> VMInstallAssets {
        guard let installerURL = assets.installerImageURL else {
            return assets
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assets.vmDirectoryURL, withIntermediateDirectories: true)

        let stagedInstallerURL = assets.vmDirectoryURL.appendingPathComponent("installer.iso")
        if stagedInstallerURL.path != installerURL.path {
            if !fileManager.fileExists(atPath: stagedInstallerURL.path) {
                try fileManager.copyItem(at: installerURL, to: stagedInstallerURL)
                traceVM(
                    "VMProvisioningPipelineService.stageInstallerImageIfNeeded copied source=\(installerURL.path) " +
                    "destination=\(stagedInstallerURL.path)"
                )
            } else {
                traceVM("VMProvisioningPipelineService.stageInstallerImageIfNeeded using existing staged installer path=\(stagedInstallerURL.path)")
            }
        }

        return VMInstallAssets(
            vmName: assets.vmName,
            vmDirectoryURL: assets.vmDirectoryURL,
            installerImageURL: stagedInstallerURL,
            kernelImageURL: assets.kernelImageURL,
            initialRamdiskURL: assets.initialRamdiskURL,
            diskImageURL: assets.diskImageURL,
            efiVariableStoreURL: assets.efiVariableStoreURL,
            machineIdentifierURL: assets.machineIdentifierURL
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RuntimeServiceError.commandFailed("VM stop timed out after \(Int(seconds)) seconds.")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
        case .nixOS: return .manualOnly
        case .windows11: return .manualOnly
        case .openSUSE: return .openSUSEAutoYaST
        case .popOS: return .manualOnly
        }
    }

    private func buildVirtualizationConfiguration(
        request: VMInstallRequest,
        assets: VMInstallAssets,
        preferInstallerBoot: Bool = false
    ) throws -> VZVirtualMachineConfiguration {
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
        var storageDevices: [VZStorageDeviceConfiguration] = [diskDevice]

        if let installerImageURL = assets.installerImageURL,
           FileManager.default.fileExists(atPath: installerImageURL.path) {
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: installerImageURL, readOnly: true)
            // Expose installer ISO as USB mass storage to keep firmware boot behavior consistent
            // across Linux and Windows installers.
            let isoDevice = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
            traceVM(
                "VMProvisioningPipelineService.buildVirtualizationConfiguration media " +
                "distribution=\(request.distribution.rawValue) installer=\(installerImageURL.lastPathComponent) attachment=usb-mass-storage"
            )
            if preferInstallerBoot {
                storageDevices.insert(isoDevice, at: 0)
            } else {
                // Keep installed disk first so restored VMs boot from their OS by default.
                storageDevices.append(isoDevice)
            }
        }

        let automationISO = assets.vmDirectoryURL.appendingPathComponent("automation-seed.iso")
        if FileManager.default.fileExists(atPath: automationISO.path) {
            let autoAttachment = try VZDiskImageStorageDeviceAttachment(url: automationISO, readOnly: true)
            let autoDevice = VZUSBMassStorageDeviceConfiguration(attachment: autoAttachment)
            storageDevices.append(autoDevice)
            traceVM(
                "VMProvisioningPipelineService.buildVirtualizationConfiguration media " +
                "distribution=\(request.distribution.rawValue) installer=\(automationISO.lastPathComponent) attachment=usb-mass-storage"
            )
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
