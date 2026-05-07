import Foundation

enum RuntimeEnvironment {
    nonisolated static let testRootEnvironmentVariable = "ML_INTEGRATION_TEST_ROOT"
    nonisolated static let uiForceSchemaInvalidVariable = "ML_INTEGRATION_UI_FORCE_SCHEMA_INVALID"
    nonisolated static let uiEnableRepairActionVariable = "ML_INTEGRATION_UI_ENABLE_REPAIR_ACTION"
    nonisolated static let uiForceSchemaInvalidArgument = "-ui-force-schema-invalid"
    nonisolated static let uiEnableRepairActionArgument = "-ui-enable-repair-action"

    nonisolated static func mlIntegrationRootURL(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> URL {
        if let configuredRoot = processInfo.environment[testRootEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredRoot.isEmpty {
            let testRoot = URL(fileURLWithPath: configuredRoot, isDirectory: true)
            return testRoot
                .standardizedFileURL
                .appendingPathComponent("MLIntegration", isDirectory: true)
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("MLIntegration", isDirectory: true)
    }
}
