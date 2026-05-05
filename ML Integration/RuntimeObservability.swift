import Foundation

enum RuntimeRunStage: String, Codable, CaseIterable {
    case registryRestore
    case artifactDownload
    case installValidation
    case installScaffolding
    case installReady
    case healthCheck
    case autoHeal
    case cleanup
    case escalation
    case vmRuntimeControl
}

enum RuntimeRunResult: String, Codable, CaseIterable {
    case inProgress
    case success
    case failed
}

nonisolated struct RuntimeRunEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let vmID: UUID?
    let stage: RuntimeRunStage
    let result: RuntimeRunResult
    let message: String
    let timestampISO8601: String
}

nonisolated struct RuntimeRunReport: Codable, Equatable {
    let runID: UUID
    let createdAtISO8601: String
    var updatedAtISO8601: String
    var vmID: UUID?
    var events: [RuntimeRunEvent]
}

protocol RuntimeObservabilityLogging {
    func beginRun(vmID: UUID?) async throws -> UUID
    func appendEvent(runID: UUID, vmID: UUID?, stage: RuntimeRunStage, result: RuntimeRunResult, message: String) async throws
    func exportReport(runID: UUID) async throws -> URL
}

actor FileRuntimeObservabilityStore: RuntimeObservabilityLogging {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func beginRun(vmID: UUID?) async throws -> UUID {
        let runID = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        let report = RuntimeRunReport(
            runID: runID,
            createdAtISO8601: now,
            updatedAtISO8601: now,
            vmID: vmID,
            events: []
        )
        try writeReport(report)
        return runID
    }

    func appendEvent(runID: UUID, vmID: UUID?, stage: RuntimeRunStage, result: RuntimeRunResult, message: String) async throws {
        var report = try readReport(runID: runID)
        let now = ISO8601DateFormatter().string(from: Date())
        let event = RuntimeRunEvent(
            id: UUID(),
            runID: runID,
            vmID: vmID ?? report.vmID,
            stage: stage,
            result: result,
            message: message,
            timestampISO8601: now
        )

        report.vmID = vmID ?? report.vmID
        report.updatedAtISO8601 = now
        report.events.append(event)
        try writeReport(report)
    }

    func exportReport(runID: UUID) async throws -> URL {
        let url = reportURL(for: runID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeServiceError.commandFailed("Run report not found for \(runID.uuidString).")
        }
        return url
    }

    private func readReport(runID: UUID) throws -> RuntimeRunReport {
        let url = reportURL(for: runID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeServiceError.commandFailed("Run report not found for \(runID.uuidString).")
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(RuntimeRunReport.self, from: data)
    }

    private func writeReport(_ report: RuntimeRunReport) throws {
        let url = reportURL(for: report.runID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic])
    }

    private func reportURL(for runID: UUID) -> URL {
        RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("observability", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).json", isDirectory: false)
    }
}
