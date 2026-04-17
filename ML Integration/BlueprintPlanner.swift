import Foundation
import Combine

@MainActor
final class BlueprintPlanner: ObservableObject {
    @Published private(set) var supportedArchitectures: [HostArchitecture] = HostArchitecture.allCases
    @Published private(set) var preferredRuntimeByArchitecture: [HostArchitecture: RuntimeEngine] = [
        .appleSilicon: .appleVirtualization,
        .intel: .appleVirtualization
    ]
    @Published private(set) var fallbackRuntime: RuntimeEngine = .qemuFallback
    @Published private(set) var supportedDistributions: [LinuxDistribution] = LinuxDistribution.allCases
    @Published private(set) var integrationModes: [IntegrationMode] = IntegrationMode.allCases
    @Published private(set) var stages: [StageDefinition] = []

    init() {
        stages = [
            StageDefinition(
                id: "catalog-and-installer",
                title: "1) Distro Catalog + Installer",
                summary: "Detect host architecture, curate trusted distro artifacts, verify checksums, and create VM installs.",
                status: .planned,
                ownedBy: "Core VM"
            ),
            StageDefinition(
                id: "resource-sharing",
                title: "2) Resource Sharing + Launcher",
                summary: "Enable shared folders, clipboard, drag/drop flow, and Linux app launch from macOS menus.",
                status: .planned,
                ownedBy: "Integration"
            ),
            StageDefinition(
                id: "health-and-healing",
                title: "3) Health + Auto-Heal",
                summary: "Run diagnostics, detect common breakage, and apply scripted recovery with rollback checkpoints.",
                status: .planned,
                ownedBy: "Reliability"
            ),
            StageDefinition(
                id: "uninstall-cleanup",
                title: "4) Uninstall + Cleanup",
                summary: "Remove VM disks, mounts, launch entries, and configuration artifacts with post-check report.",
                status: .planned,
                ownedBy: "Lifecycle"
            ),
            StageDefinition(
                id: "escalation",
                title: "5) Developer Escalation",
                summary: "If self-heal fails, submit logs via GitHub Issue API and optional email escalation.",
                status: .planned,
                ownedBy: "Support"
            )
        ]
    }

    func setStageStatus(stageID: String, to newStatus: BlueprintStageStatus) -> (stage: StageDefinition, previous: BlueprintStageStatus)? {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else {
            return nil
        }

        let previous = stages[index].status
        guard previous != newStatus else {
            return nil
        }

        stages[index].status = newStatus
        return (stages[index], previous)
    }

    func recommendedDefaultRequest(for architecture: HostArchitecture) -> VMInstallRequest {
        let cpu = architecture == .appleSilicon ? 4 : 2
        let memory = architecture == .appleSilicon ? 8 : 6

        return VMInstallRequest(
            distribution: .ubuntu,
            runtimeEngine: preferredRuntimeByArchitecture[architecture] ?? .appleVirtualization,
            architecture: architecture,
            cpuCores: cpu,
            memoryGB: memory,
            diskGB: 64,
            enableSharedFolders: true,
            enableSharedClipboard: true
        )
    }
}
