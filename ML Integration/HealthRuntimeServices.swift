import Foundation

final class DefaultHealthAndRepairService: HealthAndRepairService {
    private let integrationService: IntegrationService

    init(integrationService: IntegrationService = DefaultIntegrationService()) {
        self.integrationService = integrationService
    }

    func runHealthCheck(for vmID: UUID) async throws -> [String] {
        let paths = integrationPaths(for: vmID)
        var report: [String] = []

        report.append(fileExists(paths.integrationDirectory)
            ? "OK: Integration directory exists"
            : "WARN: Integration directory is missing")

        report.append(fileExists(paths.sharedResourcesConfig)
            ? "OK: Shared resources config exists"
            : "WARN: Shared resources config is missing")

        report.append(fileExists(paths.windowPolicyConfig)
            ? "OK: Window coherence policy exists"
            : "WARN: Window coherence policy is missing")
        if fileExists(paths.windowPolicyConfig) {
            report.append(validateWindowPolicyFile(paths.windowPolicyConfig)
                ? "OK: Window coherence policy schema valid"
                : "WARN: Window coherence policy schema invalid")
        }

        report.append(fileExists(paths.launcherManifest)
            ? "OK: Launcher manifest exists"
            : "WARN: Launcher manifest is missing")

        report.append(fileExists(paths.rootlessConfig)
            ? "OK: Rootless config exists"
            : "WARN: Rootless config is missing")

        report.append(fileExists(paths.integrationState)
            ? "OK: Integration state exists"
            : "WARN: Integration state is missing")

        for hostScript in paths.hostScripts {
            report.append(fileExists(hostScript)
                ? "OK: Host script present - \(hostScript.lastPathComponent)"
                : "WARN: Host script missing - \(hostScript.lastPathComponent)")
        }

        for guestScript in paths.guestScripts {
            report.append(fileExists(guestScript)
                ? "OK: Guest script present - \(guestScript.lastPathComponent)"
                : "WARN: Guest script missing - \(guestScript.lastPathComponent)")
        }

        return report
    }

    func applyAutomaticRepair(for vmID: UUID) async throws -> [String] {
        var actions: [String] = []

        try await integrationService.configureSharedResources(for: vmID)
        actions.append("Applied: Regenerated shared resource package")

        try await integrationService.configureLauncherEntries(for: vmID)
        actions.append("Applied: Regenerated launcher package")

        try await integrationService.enableRootlessLinuxApps(for: vmID)
        actions.append("Applied: Regenerated rootless package")

        let postCheck = try await runHealthCheck(for: vmID)
        let warningCount = postCheck.filter { $0.hasPrefix("WARN") }.count
        actions.append("Post-check warnings: \(warningCount)")

        return actions
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func validateWindowPolicyFile(_ policyURL: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: policyURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let windowBehavior = object["windowBehavior"] as? [String: Any],
            let syncPolicy = object["syncPolicy"] as? [String: Any]
        else {
            return false
        }

        let hasFocusFlag = windowBehavior["focusFollowsHostActivation"] is Bool
        let hasZOrderFlag = windowBehavior["preserveZOrderOnAttach"] is Bool
        let hasResizeFlag = windowBehavior["allowHostDrivenResize"] is Bool
        let hasThrottle = syncPolicy["throttleMs"] is Int

        return hasFocusFlag && hasZOrderFlag && hasResizeFlag && hasThrottle
    }

    private func integrationPaths(for vmID: UUID) -> IntegrationHealthPaths {
        let integrationDirectory = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)

        return IntegrationHealthPaths(
            integrationDirectory: integrationDirectory,
            sharedResourcesConfig: integrationDirectory.appendingPathComponent("shared-resources.json"),
            windowPolicyConfig: integrationDirectory.appendingPathComponent("window-coherence-policy.json"),
            launcherManifest: integrationDirectory.appendingPathComponent("launcher-manifest.json"),
            rootlessConfig: integrationDirectory.appendingPathComponent("rootless-apps.json"),
            integrationState: integrationDirectory.appendingPathComponent("integration-state.json"),
            hostScripts: [
                integrationDirectory.appendingPathComponent("host-scripts/apply-window-coherence.command"),
                integrationDirectory.appendingPathComponent("host-scripts/launch-linux-terminal.command"),
                integrationDirectory.appendingPathComponent("host-scripts/launch-linux-files.command"),
                integrationDirectory.appendingPathComponent("host-scripts/launch-linux-browser.command"),
                integrationDirectory.appendingPathComponent("host-scripts/attach-rootless.command")
            ],
            guestScripts: [
                integrationDirectory.appendingPathComponent("guest-scripts/setup-shared-resources.sh"),
                integrationDirectory.appendingPathComponent("guest-scripts/refresh-launchers.sh"),
                integrationDirectory.appendingPathComponent("guest-scripts/bootstrap-rootless.sh")
            ]
        )
    }
}

private struct IntegrationHealthPaths {
    let integrationDirectory: URL
    let sharedResourcesConfig: URL
    let windowPolicyConfig: URL
    let launcherManifest: URL
    let rootlessConfig: URL
    let integrationState: URL
    let hostScripts: [URL]
    let guestScripts: [URL]
}
