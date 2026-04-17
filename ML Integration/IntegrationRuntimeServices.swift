import Foundation

enum IntegrationRuntimeError: LocalizedError {
    case vmNotSelected
    case scriptGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .vmNotSelected:
            return "No VM is selected. Scaffold a VM pipeline first."
        case .scriptGenerationFailed(let details):
            return "Integration script generation failed: \(details)"
        }
    }
}

struct IntegrationPackageState: Codable {
    let vmID: String
    let generatedAtISO8601: String
    let sharedResourcesConfigPath: String
    let launcherManifestPath: String
    let rootlessConfigPath: String
    let hostScripts: [String]
    let guestScripts: [String]
}

final class DefaultIntegrationService: IntegrationService {
    func configureSharedResources(for vmID: UUID) async throws {
        let package = try packageDirectory(for: vmID)
        let sharedDir = package.sharedDirectory

        let docs = sharedDir.appendingPathComponent("Documents", isDirectory: true)
        let downloads = sharedDir.appendingPathComponent("Downloads", isDirectory: true)
        let projects = sharedDir.appendingPathComponent("Projects", isDirectory: true)

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "vmID": vmID.uuidString,
            "sharedFolders": [
                ["hostPath": docs.path, "guestMount": "/mnt/host/Documents", "mode": "rw"],
                ["hostPath": downloads.path, "guestMount": "/mnt/host/Downloads", "mode": "rw"],
                ["hostPath": projects.path, "guestMount": "/mnt/host/Projects", "mode": "rw"]
            ],
            "clipboardSharing": true,
            "dragDropSharing": true,
            "syncPolicy": [
                "mode": "on-demand",
                "conflictResolution": "newest-wins"
            ],
            "securityPolicy": [
                "allowedRoots": [docs.path, downloads.path, projects.path],
                "alertOnExternalMount": true
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let configURL = package.integrationDirectory.appendingPathComponent("shared-resources.json")
        try data.write(to: configURL, options: [.atomic])

        let guestScript = """
        #!/bin/sh
        set -eu

        mkdir -p /mnt/host/Documents /mnt/host/Downloads /mnt/host/Projects

        if command -v mount >/dev/null 2>&1; then
          mountpoint -q /mnt/host/Documents || sudo mount -t virtiofs host-home /mnt/host/Documents || true
          mountpoint -q /mnt/host/Downloads || sudo mount -t virtiofs host-home /mnt/host/Downloads || true
          mountpoint -q /mnt/host/Projects || sudo mount -t virtiofs host-home /mnt/host/Projects || true
        fi

        echo "Shared resource mounts attempted."
        """

        try writeExecutableScript(
            guestScript,
            to: package.guestScriptsDirectory.appendingPathComponent("setup-shared-resources.sh")
        )

        try writePackageState(for: vmID, in: package)
    }

    func configureLauncherEntries(for vmID: UUID) async throws {
        let package = try packageDirectory(for: vmID)

        let terminalScriptURL = package.hostScriptsDirectory.appendingPathComponent("launch-linux-terminal.command")
        let filesScriptURL = package.hostScriptsDirectory.appendingPathComponent("launch-linux-files.command")
        let browserScriptURL = package.hostScriptsDirectory.appendingPathComponent("launch-linux-browser.command")

        let terminalScript = launcherScript(
            vmID: vmID,
            appCommand: "x-terminal-emulator || gnome-terminal || konsole || xfce4-terminal"
        )
        let filesScript = launcherScript(
            vmID: vmID,
            appCommand: "xdg-open /home/linux || nautilus || dolphin || thunar"
        )
        let browserScript = launcherScript(
            vmID: vmID,
            appCommand: "xdg-open https://www.example.com"
        )

        try writeExecutableScript(terminalScript, to: terminalScriptURL)
        try writeExecutableScript(filesScript, to: filesScriptURL)
        try writeExecutableScript(browserScript, to: browserScriptURL)

        let manifest: [String: Any] = [
            "vmID": vmID.uuidString,
            "entries": [
                ["name": "Linux Terminal", "script": terminalScriptURL.path, "category": "System"],
                ["name": "Linux Files", "script": filesScriptURL.path, "category": "System"],
                ["name": "Linux Browser", "script": browserScriptURL.path, "category": "Web"]
            ],
            "executionModel": [
                "transport": "ssh",
                "user": "linux",
                "port": 2222,
                "strictHostKeyChecking": "accept-new"
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: package.integrationDirectory.appendingPathComponent("launcher-manifest.json"),
            options: [.atomic]
        )

        let guestLauncherInstall = """
        #!/bin/sh
        set -eu

        if command -v update-desktop-database >/dev/null 2>&1; then
          update-desktop-database ~/.local/share/applications || true
        fi

        echo "Launcher metadata refresh complete."
        """

        try writeExecutableScript(
            guestLauncherInstall,
            to: package.guestScriptsDirectory.appendingPathComponent("refresh-launchers.sh")
        )

        try writePackageState(for: vmID, in: package)
    }

    func enableRootlessLinuxApps(for vmID: UUID) async throws {
        let package = try packageDirectory(for: vmID)

        let rootlessPayload: [String: Any] = [
            "vmID": vmID.uuidString,
            "mode": "coherence-like",
            "transportOrder": ["xpra", "spice"],
            "network": [
                "guestSSHPort": 2222,
                "xpraPort": 14500
            ],
            "guestRequirements": [
                "openssh-server",
                "xpra",
                "spice-vdagent",
                "xauth"
            ],
            "safety": [
                "requireExplicitUserActionForAppLaunch": true,
                "auditRootlessLaunches": true
            ]
        ]

        let rootlessData = try JSONSerialization.data(withJSONObject: rootlessPayload, options: [.prettyPrinted, .sortedKeys])
        try rootlessData.write(
            to: package.integrationDirectory.appendingPathComponent("rootless-apps.json"),
            options: [.atomic]
        )

        let guestBootstrap = """
        #!/bin/sh
        set -eu

        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update
          sudo apt-get install -y openssh-server xpra spice-vdagent xauth
        elif command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y openssh-server xpra spice-vdagent xauth
        elif command -v zypper >/dev/null 2>&1; then
          sudo zypper --non-interactive install openssh xpra spice-vdagent xauth
        fi

        sudo systemctl enable ssh || true
        sudo systemctl restart ssh || true

        echo "Guest rootless prerequisites attempted."
        """

        let hostAttach = """
        #!/bin/sh
        set -eu

        VM_ID="\(vmID.uuidString)"
        GUEST_USER="linux"
        SSH_PORT="2222"
        XPRA_PORT="14500"

        echo "Preparing rootless session for VM ${VM_ID}"

        if ! command -v xpra >/dev/null 2>&1; then
          echo "xpra is not installed on host. Install xpra for rootless windows."
          exit 1
        fi

        ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT}" "${GUEST_USER}@127.0.0.1" \
          "xpra start :100 --bind-tcp=0.0.0.0:${XPRA_PORT} --start=\"xterm\" --daemon=no" || true

        xpra attach "tcp:127.0.0.1:${XPRA_PORT}" || true
        """

        try writeExecutableScript(
            guestBootstrap,
            to: package.guestScriptsDirectory.appendingPathComponent("bootstrap-rootless.sh")
        )
        try writeExecutableScript(
            hostAttach,
            to: package.hostScriptsDirectory.appendingPathComponent("attach-rootless.command")
        )

        try writePackageState(for: vmID, in: package)
    }

    private func launcherScript(vmID: UUID, appCommand: String) -> String {
        """
        #!/bin/sh
        set -eu

        VM_ID="\(vmID.uuidString)"
        GUEST_USER="linux"
        SSH_PORT="2222"

        echo "Launching Linux app for VM ${VM_ID}..."
        ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT}" "${GUEST_USER}@127.0.0.1" "\(appCommand)" || true
        """
    }

    private func writeExecutableScript(_ body: String, to url: URL) throws {
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw IntegrationRuntimeError.scriptGenerationFailed(error.localizedDescription)
        }
    }

    private func writePackageState(for vmID: UUID, in package: IntegrationPackageDirectories) throws {
        let formatter = ISO8601DateFormatter()

        let hostListing = try? FileManager.default.contentsOfDirectory(at: package.hostScriptsDirectory, includingPropertiesForKeys: nil)
        let hostScripts = (hostListing ?? []).map { $0.path }.sorted()

        let guestListing = try? FileManager.default.contentsOfDirectory(at: package.guestScriptsDirectory, includingPropertiesForKeys: nil)
        let guestScripts = (guestListing ?? []).map { $0.path }.sorted()

        let state = IntegrationPackageState(
            vmID: vmID.uuidString,
            generatedAtISO8601: formatter.string(from: Date()),
            sharedResourcesConfigPath: package.integrationDirectory.appendingPathComponent("shared-resources.json").path,
            launcherManifestPath: package.integrationDirectory.appendingPathComponent("launcher-manifest.json").path,
            rootlessConfigPath: package.integrationDirectory.appendingPathComponent("rootless-apps.json").path,
            hostScripts: hostScripts,
            guestScripts: guestScripts
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: package.integrationDirectory.appendingPathComponent("integration-state.json"), options: [.atomic])
    }

    private func packageDirectory(for vmID: UUID) throws -> IntegrationPackageDirectories {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let integrationDirectory = base
            .appendingPathComponent("MLIntegration", isDirectory: true)
            .appendingPathComponent("integration", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)

        let sharedDirectory = integrationDirectory.appendingPathComponent("shared", isDirectory: true)
        let hostScriptsDirectory = integrationDirectory.appendingPathComponent("host-scripts", isDirectory: true)
        let guestScriptsDirectory = integrationDirectory.appendingPathComponent("guest-scripts", isDirectory: true)

        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostScriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guestScriptsDirectory, withIntermediateDirectories: true)

        return IntegrationPackageDirectories(
            integrationDirectory: integrationDirectory,
            sharedDirectory: sharedDirectory,
            hostScriptsDirectory: hostScriptsDirectory,
            guestScriptsDirectory: guestScriptsDirectory
        )
    }
}

private struct IntegrationPackageDirectories {
    let integrationDirectory: URL
    let sharedDirectory: URL
    let hostScriptsDirectory: URL
    let guestScriptsDirectory: URL
}
