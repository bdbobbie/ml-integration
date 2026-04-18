import Foundation

struct VMRegistryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let vmName: String
    let vmDirectoryPath: String
    let distribution: LinuxDistribution
    let architecture: HostArchitecture
    let runtimeEngine: RuntimeEngine
    let createdAtISO8601: String
    let updatedAtISO8601: String
}

protocol VMRegistryManaging {
    func upsert(_ entry: VMRegistryEntry) async throws
    func entry(for id: UUID) async -> VMRegistryEntry?
    func allEntries() async -> [VMRegistryEntry]
    func remove(id: UUID) async throws
}

actor PersistentVMRegistryStore: VMRegistryManaging {
    private let registryFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectoryURL: URL? = nil) {
        let base = baseDirectoryURL ?? RuntimeEnvironment.mlIntegrationRootURL().deletingLastPathComponent()

        self.registryFileURL = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("vm-registry.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func upsert(_ entry: VMRegistryEntry) async throws {
        var entries = try loadEntries()
        entries[entry.id] = entry
        try persistEntries(entries)
    }

    func entry(for id: UUID) async -> VMRegistryEntry? {
        guard let entries = try? loadEntries() else {
            return nil
        }
        return entries[id]
    }

    func allEntries() async -> [VMRegistryEntry] {
        guard let entries = try? loadEntries() else {
            return []
        }
        return entries.values.sorted { $0.updatedAtISO8601 > $1.updatedAtISO8601 }
    }

    func remove(id: UUID) async throws {
        var entries = try loadEntries()
        entries.removeValue(forKey: id)
        try persistEntries(entries)
    }

    private func loadEntries() throws -> [UUID: VMRegistryEntry] {
        guard FileManager.default.fileExists(atPath: registryFileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: registryFileURL)
        if data.isEmpty {
            return [:]
        }

        return try decoder.decode([UUID: VMRegistryEntry].self, from: data)
    }

    private func persistEntries(_ entries: [UUID: VMRegistryEntry]) throws {
        let directory = registryFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try encoder.encode(entries)
        try data.write(to: registryFileURL, options: [.atomic])
    }
}
