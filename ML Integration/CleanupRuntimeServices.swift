import Foundation

final class DefaultUninstallCleanupService: UninstallCleanupService {
    private let registry: VMRegistryManaging
    private let explicitBaseDirectoryURL: URL?

    init(
        registry: VMRegistryManaging = PersistentVMRegistryStore(),
        baseDirectoryURL: URL? = nil
    ) {
        self.registry = registry
        self.explicitBaseDirectoryURL = baseDirectoryURL
    }

    func uninstallVM(id: UUID, removeArtifacts: Bool) async throws {
        let roots = await paths(for: id)

        if removeArtifacts {
            for vmDirectory in roots.vmDirectories {
                try removeIfExists(vmDirectory)
            }
            try removeIfExists(roots.integrationDirectory)
            try removeMatchingDownloads(prefix: id.uuidString)
        }

        try await registry.remove(id: id)

        let receipt: [String: Any] = [
            "vmID": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "removeArtifacts": removeArtifacts,
            "removedVMDirectories": roots.vmDirectories.map(\.path),
            "removedIntegrationDirectory": roots.integrationDirectory.path
        ]

        let receiptsDir = roots.baseDirectory
            .appendingPathComponent("cleanup-receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: receiptsDir.appendingPathComponent("\(id.uuidString).json"), options: [.atomic])
    }

    func verifyCleanup(id: UUID) async throws -> [String] {
        let roots = await paths(for: id)
        var report: [String] = []

        let staleVMPaths = roots.vmDirectories.filter { FileManager.default.fileExists(atPath: $0.path) }
        if staleVMPaths.isEmpty {
            report.append("OK: VM directory removed")
        } else {
            for path in staleVMPaths {
                report.append("WARN: VM directory still exists - \(path.path)")
            }
        }

        report.append(FileManager.default.fileExists(atPath: roots.integrationDirectory.path)
            ? "WARN: Integration directory still exists"
            : "OK: Integration directory removed")

        if await registry.entry(for: id) == nil {
            report.append("OK: VM registry entry removed")
        } else {
            report.append("WARN: VM registry entry still exists")
        }

        let receiptPath = roots.baseDirectory
            .appendingPathComponent("cleanup-receipts", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
        report.append(FileManager.default.fileExists(atPath: receiptPath.path)
            ? "OK: Cleanup receipt created"
            : "WARN: Cleanup receipt missing")

        return report
    }

    private func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func removeMatchingDownloads(prefix: String) throws {
        let downloadsDir = baseDirectory().appendingPathComponent("downloads", isDirectory: true)
        guard FileManager.default.fileExists(atPath: downloadsDir.path) else {
            return
        }

        let files = try FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.contains(prefix) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func paths(for id: UUID) async -> CleanupPaths {
        let base = baseDirectory()
        let registeredVMPath = await registry.entry(for: id).map { URL(fileURLWithPath: $0.vmDirectoryPath, isDirectory: true) }
        var vmDirectories: [URL] = []
        if let registeredVMPath {
            vmDirectories.append(registeredVMPath)
        }
        vmDirectories.append(
            base
                .appendingPathComponent("vms", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        )

        let uniqueDirectories = Array(
            Dictionary(vmDirectories.map { ($0.standardizedFileURL.path, $0) }, uniquingKeysWith: { existing, _ in existing }).values
        )

        return CleanupPaths(
            baseDirectory: base,
            vmDirectories: uniqueDirectories,
            integrationDirectory: base.appendingPathComponent("integration", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        )
    }

    private func baseDirectory() -> URL {
        if let explicitBaseDirectoryURL {
            return explicitBaseDirectoryURL.appendingPathComponent("MLIntegration", isDirectory: true)
        }
        return RuntimeEnvironment.mlIntegrationRootURL()
    }
}

private struct CleanupPaths {
    let baseDirectory: URL
    let vmDirectories: [URL]
    let integrationDirectory: URL
}
