//
//  ML Integration
//  Copyright © 2026 TBDO Inc. All rights reserved.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedArchitecture: HostArchitecture = .appleSilicon
    @State private var selectedCatalogDistribution: LinuxDistribution = .ubuntu
    @State private var selectedRuntimeEngine: RuntimeEngine = .appleVirtualization
    @State private var checksumLocalPath: String = ""
    @State private var vmName: String = "default-linux-vm"
    @State private var installerImagePath: String = ""
    @State private var kernelImagePath: String = ""
    @State private var initialRamdiskPath: String = ""
    @State private var showKeyringImporter: Bool = false
    @State private var selectedKeyringTarget: String = ""

    @State private var escalationTitle: String = ""
    @State private var escalationDetails: String = ""
    @State private var githubOwner: String = ""
    @State private var githubRepository: String = ""
    @State private var githubToken: String = ""
    @State private var supportEmail: String = ""
    @State private var sendGitHubIssue: Bool = true
    @State private var sendEmailEscalation: Bool = true
    @State private var includeDiagnosticsInEscalation: Bool = true

    @State private var manualNote: String = ""
    @State private var screenshotRefsRaw: String = ""
    @State private var selectedAuthor: ChronicleAuthorTag = .developer
    @State private var selectedChapter: ChronicleChapter = .implementation
    @State private var markdownPreview: String = ""
    @State private var exportStatusMessage: String = ""
    @State private var lastExportPath: String = ""
    @State private var bookEditionDraft: String = ""
    @State private var lastLoggedVMStatus: String = ""
    @State private var lastLoggedHealthStatus: String = ""
    @State private var lastLoggedCleanupStatus: String = ""
    @State private var lastLoggedEscalationStatus: String = ""
    @State private var lastLoggedObservabilityStatus: String = ""
    @State private var lastLoggedPreflightStatus: String = ""
    @State private var importedBuildPassed: Bool = true
    @State private var importedTestsPassed: Bool = true

    @StateObject private var planner = BlueprintPlanner()
    @StateObject private var chronicle = DevelopmentChronicleStore()
    @StateObject private var runtimeWorkbench = RuntimeWorkbenchViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    Text("ML Integration")
                        .font(.largeTitle)
                    Text("Version 1.0")
                        .font(.subheadline)
                    Text("© 2026 TBDO Inc. All rights reserved.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Seamless Linux virtualization for macOS with comprehensive VM lifecycle management.")
                        .font(.body)
                }
                
                Section("Vision") {
                    Text("Blueprint for Linux VM installation and integration on Intel and Apple Silicon Macs, using virtualization-first architecture.")
                }

                Section("Host Detection") {
                    Button("Detect Host") {
                        Task {
                            await runtimeWorkbench.detectHost()
                            if let detected = runtimeWorkbench.hostProfile {
                                selectedArchitecture = detected.architecture
                            }
                        }
                    }

                    if let host = runtimeWorkbench.hostProfile {
                        labeledRow("Detected architecture", host.architecture.rawValue)
                        labeledRow("CPU cores", "\(host.cpuCores)")
                        labeledRow("Memory", "\(host.memoryGB) GB")
                        labeledRow("macOS", host.macOSVersion)
                    }

                    if !runtimeWorkbench.hostErrorMessage.isEmpty {
                        Text(runtimeWorkbench.hostErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Host + Runtime Strategy") {
                    Picker("Target Architecture", selection: $selectedArchitecture) {
                        ForEach(planner.supportedArchitectures) { architecture in
                            Text(architecture.rawValue).tag(architecture)
                        }
                    }

                    Picker("Install Runtime", selection: $selectedRuntimeEngine) {
                        ForEach(RuntimeEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }

                    labeledRow("Primary runtime", planner.preferredRuntimeByArchitecture[selectedArchitecture]?.rawValue ?? "Unknown")
                    labeledRow("Fallback runtime", planner.fallbackRuntime.rawValue)
                }

                Section("Official OS Catalog") {
                    Picker("Distribution", selection: $selectedCatalogDistribution) {
                        ForEach(planner.supportedDistributions) { distro in
                            Text(distro.rawValue).tag(distro)
                        }
                    }

                    Button("Refresh Catalog Feed") {
                        Task {
                            await runtimeWorkbench.refreshCatalog(for: selectedArchitecture, force: true)
                        }
                    }

                    if !runtimeWorkbench.catalogErrorMessage.isEmpty {
                        Text(runtimeWorkbench.catalogErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let filteredArtifacts = runtimeWorkbench.artifacts
                        .filter { $0.distribution == selectedCatalogDistribution }
                    let keyringStatuses = runtimeWorkbench.requiredKeyringStatuses

                    if !runtimeWorkbench.downloadStatusMessage.isEmpty {
                        Text(runtimeWorkbench.downloadStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !keyringStatuses.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Required keyrings for signature checks")
                                .font(.subheadline)
                            ForEach(keyringStatuses.keys.sorted(), id: \.self) { key in
                                let installed = keyringStatuses[key] ?? false
                                Text("\(installed ? "Installed" : "Missing") - \(key)")
                                    .font(.caption2)
                                    .foregroundStyle(installed ? .green : .orange)
                            }

                            if keyringStatuses.count > 1 {
                                Picker("Keyring target", selection: $selectedKeyringTarget) {
                                    ForEach(keyringStatuses.keys.sorted(), id: \.self) { key in
                                        Text(key).tag(key)
                                    }
                                }
                            }

                            Button("Import Keyring…") {
                                showKeyringImporter = true
                            }
                            .buttonStyle(.borderless)

                            if !runtimeWorkbench.keyringStatusMessage.isEmpty {
                                Text(runtimeWorkbench.keyringStatusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if filteredArtifacts.isEmpty {
                        Text("No official artifact available for the selected architecture yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredArtifacts) { artifact in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(artifact.distribution.rawValue) \(artifact.version)")
                                    .font(.headline)
                                Link("Official download", destination: artifact.downloadURL)
                                Text("Mirrors: \(artifact.mirrorURLs.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button("Verify Source Signature") {
                                    Task {
                                        await runtimeWorkbench.verifySignature(artifact: artifact)
                                    }
                                }
                                .buttonStyle(.borderless)
                                Button("Download + Verify Installer") {
                                    Task {
                                        await runtimeWorkbench.downloadArtifact(artifact)
                                        if !runtimeWorkbench.downloadedInstallerPath.isEmpty {
                                            installerImagePath = runtimeWorkbench.downloadedInstallerPath
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)

                                if artifact.checksumSHA256.isEmpty {
                                    Text("Checksum feed unavailable for this source (official page link provided).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("SHA256: \(artifact.checksumSHA256)")
                                        .font(.caption2)
                                        .textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                }

                                if artifact.signatureExpected {
                                    Text(artifact.signatureVerifiedAtSource ? "Source signature verified" : "Source signature not verified")
                                        .font(.caption2)
                                        .foregroundStyle(artifact.signatureVerifiedAtSource ? .green : .orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        TextField("Local downloaded file path for checksum verification", text: $checksumLocalPath)
                        Button("Verify Checksum for Selected Distribution") {
                            guard let artifact = filteredArtifacts.first else {
                                return
                            }
                            Task {
                                await runtimeWorkbench.verifyChecksum(
                                    artifact: artifact,
                                    localPath: checksumLocalPath
                                )
                            }
                        }

                        if !runtimeWorkbench.checksumStatusMessage.isEmpty {
                            Text(runtimeWorkbench.checksumStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !runtimeWorkbench.signatureStatusMessage.isEmpty {
                            Text(runtimeWorkbench.signatureStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("VM Pipeline Scaffold") {
                    Text("Install lifecycle: \(runtimeWorkbench.installLifecycleState.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !runtimeWorkbench.installLifecycleDetail.isEmpty {
                        Text(runtimeWorkbench.installLifecycleDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("VM runtime state: \(runtimeWorkbench.vmRuntimeState.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !runtimeWorkbench.vmRuntimeStatusMessage.isEmpty {
                        Text(runtimeWorkbench.vmRuntimeStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Start VM") {
                            Task {
                                await runtimeWorkbench.startActiveVM()
                            }
                        }
                        Button("Stop VM") {
                            Task {
                                await runtimeWorkbench.stopActiveVM()
                            }
                        }
                        Button("Restart VM") {
                            Task {
                                await runtimeWorkbench.restartActiveVM()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    if let runID = runtimeWorkbench.currentRunID {
                        Text("Run ID: \(runID.uuidString)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    Button("Export Current Run Report") {
                        Task {
                            await runtimeWorkbench.exportCurrentRunReport()
                        }
                    }
                    .buttonStyle(.borderless)
                    if !runtimeWorkbench.observabilityStatusMessage.isEmpty {
                        Text(runtimeWorkbench.observabilityStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !runtimeWorkbench.lastRunReportPath.isEmpty {
                        Text("Run report path: \(runtimeWorkbench.lastRunReportPath)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    TextField("VM name", text: $vmName)
                    TextField("Installer image path (ISO/RAW)", text: $installerImagePath)
                    if !runtimeWorkbench.downloadedInstallerPath.isEmpty {
                        Text("Downloaded installer: \(runtimeWorkbench.downloadedInstallerPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Kernel image path (optional)", text: $kernelImagePath)
                    TextField("Initial ramdisk path (optional)", text: $initialRamdiskPath)

                    Button("Scaffold VM Install Pipeline") {
                        Task {
                            await runtimeWorkbench.scaffoldInstall(
                                distribution: selectedCatalogDistribution,
                                architecture: selectedArchitecture,
                                runtime: selectedRuntimeEngine,
                                vmName: vmName,
                                installerImagePath: installerImagePath,
                                kernelImagePath: kernelImagePath,
                                initialRamdiskPath: initialRamdiskPath
                            )
                        }
                    }

                    if !runtimeWorkbench.vmStatusMessage.isEmpty {
                        Text(runtimeWorkbench.vmStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Health + Auto-Heal") {
                    if let vmID = runtimeWorkbench.activeVMID {
                        Text("Active VM: \(vmID.uuidString)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No active VM yet. Scaffold a VM install pipeline first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Run Health Check") {
                        Task {
                            await runtimeWorkbench.runHealthCheck()
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Apply Auto-Heal") {
                        Task {
                            await runtimeWorkbench.applyAutoHeal()
                        }
                    }
                    .buttonStyle(.borderless)

                    if !runtimeWorkbench.healthStatusMessage.isEmpty {
                        Text(runtimeWorkbench.healthStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(runtimeWorkbench.healthReport, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(line.hasPrefix("WARN") ? .orange : .secondary)
                    }
                }

                Section("Developer Escalation") {
                    TextField("Issue title", text: $escalationTitle)
                    TextField("Issue details", text: $escalationDetails, axis: .vertical)

                    TextField("GitHub owner", text: $githubOwner)
                    TextField("GitHub repository", text: $githubRepository)
                    SecureField("GitHub token", text: $githubToken)
                    HStack {
                        Button("Load Stored Token") {
                            githubToken = runtimeWorkbench.loadStoredGitHubToken()
                        }
                        Button("Save Token") {
                            runtimeWorkbench.saveGitHubTokenToKeychain(githubToken)
                        }
                        Button("Clear Stored Token") {
                            runtimeWorkbench.clearStoredGitHubToken()
                            githubToken = ""
                        }
                    }
                    .buttonStyle(.borderless)
                    TextField("Support email", text: $supportEmail)

                    Toggle("Create GitHub issue", isOn: $sendGitHubIssue)
                    Toggle("Send email escalation", isOn: $sendEmailEscalation)
                    Toggle("Include diagnostics bundle", isOn: $includeDiagnosticsInEscalation)

                    Button("Escalate to TBDO Team") {
                        Task {
                            await runtimeWorkbench.escalateToDevelopers(
                                issueTitle: escalationTitle,
                                issueDetails: escalationDetails,
                                githubOwner: githubOwner,
                                githubRepository: githubRepository,
                                githubToken: githubToken,
                                supportEmail: supportEmail,
                                sendGitHubIssue: sendGitHubIssue,
                                sendEmail: sendEmailEscalation,
                                includeDiagnostics: includeDiagnosticsInEscalation
                            )
                        }
                    }
                    .buttonStyle(.borderless)

                    if !runtimeWorkbench.escalationStatusMessage.isEmpty {
                        Text(runtimeWorkbench.escalationStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let issueURL = runtimeWorkbench.lastEscalationIssueURL {
                        Link("Open created GitHub issue", destination: issueURL)
                            .font(.caption)
                    }
                }

                Section("Uninstall + Cleanup") {
                    if let vmID = runtimeWorkbench.activeVMID {
                        Text("Active VM: \(vmID.uuidString)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } else if let vmID = runtimeWorkbench.lastManagedVMID {
                        Text("Last managed VM: \(vmID.uuidString)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No known VM. Scaffold a VM first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Uninstall Active VM") {
                        Task {
                            await runtimeWorkbench.uninstallActiveVM(removeArtifacts: true)
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Verify Cleanup") {
                        Task {
                            await runtimeWorkbench.verifyCleanupForLastKnownVM()
                        }
                    }
                    .buttonStyle(.borderless)

                    if !runtimeWorkbench.cleanupStatusMessage.isEmpty {
                        Text(runtimeWorkbench.cleanupStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !runtimeWorkbench.registryStatusMessage.isEmpty {
                        Text(runtimeWorkbench.registryStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(runtimeWorkbench.cleanupReport, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(line.hasPrefix("WARN") ? .orange : .secondary)
                    }
                }

                Section("Resource Sharing + Launcher") {
                    if let vmID = runtimeWorkbench.activeVMID {
                        Text("Active VM: \(vmID.uuidString)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No active VM yet. Scaffold a VM install pipeline first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Configure Shared Resources") {
                        Task {
                            await runtimeWorkbench.configureSharedResources()
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Configure Launcher Entries") {
                        Task {
                            await runtimeWorkbench.configureLauncherEntries()
                        }
                    }
                    .buttonStyle(.borderless)

                    Button("Enable Rootless Linux Apps") {
                        Task {
                            await runtimeWorkbench.enableRootlessLinuxApps()
                        }
                    }
                    .buttonStyle(.borderless)

                    if !runtimeWorkbench.integrationStatusMessage.isEmpty {
                        Text(runtimeWorkbench.integrationStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Default VM Profile") {
                    let request = planner.recommendedDefaultRequest(for: selectedArchitecture)
                    labeledRow("Distribution", request.distribution.rawValue)
                    labeledRow("CPU", "\(request.cpuCores) vCPU")
                    labeledRow("Memory", "\(request.memoryGB) GB")
                    labeledRow("Disk", "\(request.diskGB) GB")
                    labeledRow("Shared folders", request.enableSharedFolders ? "Enabled" : "Disabled")
                    labeledRow("Shared clipboard", request.enableSharedClipboard ? "Enabled" : "Disabled")
                }

                Section("Implementation Milestones") {
                    ForEach(planner.stages) { stage in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stage.title)
                                .font(.headline)
                            Text(stage.summary)
                                .font(.subheadline)
                            Text("Owner: \(stage.ownedBy) | Status: \(stage.status.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("In Progress") {
                                    updateStageStatus(stageID: stage.id, newStatus: .inProgress)
                                }
                                Button("Blocked") {
                                    updateStageStatus(stageID: stage.id, newStatus: .blocked)
                                }
                                Button("Complete") {
                                    updateStageStatus(stageID: stage.id, newStatus: .complete)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Readiness Gate") {
                    Text(planner.readinessProgressSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(planner.isReadyForEnvironmentTesting ? "GO: Ready for environment testing" : "NO-GO: Complete remaining readiness criteria")
                        .font(.subheadline)
                        .foregroundStyle(planner.isReadyForEnvironmentTesting ? .green : .orange)

                    Button("Run Preflight Scan") {
                        let snapshot = runtimeWorkbench.makePreflightSnapshot()
                        planner.applyPreflightScan(snapshot)
                        autoSyncChecklistFromRuntime()
                    }
                    .buttonStyle(.borderless)

                    Toggle("Imported build passed", isOn: $importedBuildPassed)
                    Toggle("Imported tests passed", isOn: $importedTestsPassed)
                    Button("Auto-Sync Checklist from Runtime Signals") {
                        autoSyncChecklistFromRuntime()
                    }
                    .buttonStyle(.borderless)
                    Button("Start Environment Testing") {
                        _ = planner.startEnvironmentTestingIfReady()
                    }
                    .buttonStyle(.borderless)

                    if !planner.preflightStatusMessage.isEmpty {
                        Text(planner.preflightStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !planner.lastPreflightEvidencePath.isEmpty {
                        Text("Evidence path: \(planner.lastPreflightEvidencePath)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Copy Evidence Path") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(planner.lastPreflightEvidencePath, forType: .string)
                            }
                            Button("Open Evidence Folder") {
                                let directory = URL(fileURLWithPath: planner.lastPreflightEvidencePath).deletingLastPathComponent()
                                NSWorkspace.shared.open(directory)
                            }
                        }
                        .buttonStyle(.borderless)
                    }

                    ForEach(planner.preflightFindings, id: \.self) { finding in
                        Text(finding)
                            .font(.caption2)
                            .foregroundStyle(finding.hasPrefix("WARN") ? .orange : .secondary)
                    }

                    if !planner.checklistAutoSyncStatusMessage.isEmpty {
                        Text(planner.checklistAutoSyncStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !planner.environmentTestStartStatusMessage.isEmpty {
                        Text(planner.environmentTestStartStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(planner.environmentTestingStarted ? .green : .orange)
                    }
                    if !planner.lastGoNoGoReportPath.isEmpty {
                        Text("Go/No-Go report: \(planner.lastGoNoGoReportPath)")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(planner.readinessCriteria) { criterion in
                        Toggle(
                            isOn: Binding(
                                get: { criterion.isSatisfied },
                                set: { newValue in
                                    planner.setReadinessCriterion(id: criterion.id, isSatisfied: newValue)
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(criterion.title)
                                Text(criterion.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if showInternalChronicle {
                    Section("Book Edition") {
                        TextField("Book edition (e.g., v1, v2)", text: $bookEditionDraft)
                        Button("Save Book Edition") {
                            chronicle.updateBookEdition(bookEditionDraft)
                            bookEditionDraft = chronicle.bookEdition
                            markdownPreview = chronicle.exportMarkdown()
                        }
                        Text("Current edition: \(chronicle.bookEdition)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showInternalChronicle {
                    Section("Development Chronicle") {
                        Picker("Author", selection: $selectedAuthor) {
                            ForEach(ChronicleAuthorTag.allCases) { author in
                                Text(author.rawValue).tag(author)
                            }
                        }

                        Picker("Chapter", selection: $selectedChapter) {
                            ForEach(ChronicleChapter.allCases) { chapter in
                                Text(chapter.rawValue).tag(chapter)
                            }
                        }

                        TextField("Screenshot refs (path|caption, comma-separated)", text: $screenshotRefsRaw)
                        TextField("Add a manual book note", text: $manualNote, axis: .vertical)

                        Button("Add Note (Append Only)") {
                            appendManualNote()
                        }

                        HStack {
                            Button("Export Markdown") {
                                exportMarkdownFile()
                            }
                            Button("Export PDF") {
                                exportPDFFile()
                            }
                            Button("Export DOCX") {
                                exportDOCXFile()
                            }
                        }
                        .buttonStyle(.borderless)

                        HStack {
                            Button("Copy Last Export Path") {
                                copyLastExportPath()
                            }
                            Button("Open Exports Folder") {
                                openExportsFolder()
                            }
                        }
                        .buttonStyle(.borderless)

                        Button("Refresh Book Preview") {
                            markdownPreview = chronicle.exportMarkdown()
                        }

                        if !exportStatusMessage.isEmpty {
                            Text(exportStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !markdownPreview.isEmpty {
                            TextEditor(text: .constant(markdownPreview))
                                .frame(minHeight: 220)
                                .font(.system(.footnote, design: .monospaced))
                        }

                        ForEach(Array(chronicle.entries.suffix(12).reversed())) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.chapter.rawValue) | \(entry.kind.rawValue) | \(Self.rowDateFormatter.string(from: entry.timestamp))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("[\(entry.author.rawValue)] \(entry.title)")
                                    .font(.subheadline)
                                Text(entry.details)
                                    .font(.caption)
                                if !entry.screenshotReferences.isEmpty {
                                    ForEach(entry.screenshotReferences) { ref in
                                        let caption = ref.caption.isEmpty ? "(no caption)" : ref.caption
                                        Text("Shot: \(ref.pathOrURL) | Caption: \(caption)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("ML Integration Blueprint")
            .onAppear {
                runtimeWorkbench.refreshKeyringStatus(for: selectedCatalogDistribution)
                chronicle.backfillSessionMilestonesIfNeeded()

                Task {
                    await runtimeWorkbench.restoreVMRegistryState()
                    await runtimeWorkbench.detectHost()
                    if let detected = runtimeWorkbench.hostProfile {
                        selectedArchitecture = detected.architecture
                    }
                    await runtimeWorkbench.refreshCatalog(for: selectedArchitecture)
                }

                guard showInternalChronicle else {
                    return
                }

                if markdownPreview.isEmpty {
                    markdownPreview = chronicle.exportMarkdown()
                }
                if bookEditionDraft.isEmpty {
                    bookEditionDraft = chronicle.bookEdition
                }
            }
            .onChange(of: selectedArchitecture) { _, newValue in
                Task {
                    await runtimeWorkbench.refreshCatalog(for: newValue)
                }
            }
            .onChange(of: runtimeWorkbench.vmStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .vm,
                    value: newValue,
                    title: "Runtime VM status update",
                    chapter: .implementation
                )
            }
            .onChange(of: runtimeWorkbench.healthStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .health,
                    value: newValue,
                    title: "Runtime health status update",
                    chapter: .testing
                )
            }
            .onChange(of: runtimeWorkbench.cleanupStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .cleanup,
                    value: newValue,
                    title: "Runtime cleanup status update",
                    chapter: .testing
                )
            }
            .onChange(of: runtimeWorkbench.escalationStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .escalation,
                    value: newValue,
                    title: "Runtime escalation status update",
                    chapter: .revisions
                )
            }
            .onChange(of: runtimeWorkbench.observabilityStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .observability,
                    value: newValue,
                    title: "Runtime observability status update",
                    chapter: .testing
                )
            }
            .onChange(of: planner.preflightStatusMessage) { _, newValue in
                autoLogStatus(
                    key: .preflight,
                    value: newValue,
                    title: "Readiness preflight status update",
                    chapter: .testing
                )
                autoSyncChecklistFromRuntime()
            }
            .onChange(of: selectedCatalogDistribution) { _, newValue in
                runtimeWorkbench.refreshKeyringStatus(for: newValue)
            }
            .fileImporter(
                isPresented: $showKeyringImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleImportedKeyring(result)
            }
        }
    }

    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func handleImportedKeyring(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            let needsAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fallback = runtimeWorkbench.requiredKeyringStatuses.keys.sorted().first
            let targetName = selectedKeyringTarget.isEmpty ? fallback : selectedKeyringTarget
            runtimeWorkbench.importKeyring(from: sourceURL, preferredFileName: targetName)
            runtimeWorkbench.refreshKeyringStatus(for: selectedCatalogDistribution)

        case .failure(let error):
            runtimeWorkbench.setKeyringImportStatus("Import keyring failed: \(error.localizedDescription)")
        }
    }

    private func appendManualNote() {
        let trimmed = manualNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        chronicle.log(
            kind: .note,
            author: selectedAuthor,
            chapter: selectedChapter,
            title: "Manual Note",
            details: trimmed,
            screenshotReferences: screenshotReferencesFromField
        )

        manualNote = ""
        screenshotRefsRaw = ""
        markdownPreview = chronicle.exportMarkdown()
    }

    private enum AutoLogKey {
        case vm
        case health
        case cleanup
        case escalation
        case observability
        case preflight
    }

    private func autoLogStatus(
        key: AutoLogKey,
        value: String,
        title: String,
        chapter: ChronicleChapter
    ) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let previous: String
        switch key {
        case .vm: previous = lastLoggedVMStatus
        case .health: previous = lastLoggedHealthStatus
        case .cleanup: previous = lastLoggedCleanupStatus
        case .escalation: previous = lastLoggedEscalationStatus
        case .observability: previous = lastLoggedObservabilityStatus
        case .preflight: previous = lastLoggedPreflightStatus
        }

        guard normalized != previous else { return }

        chronicle.logUniqueSystemEvent(
            title: title,
            details: normalized,
            chapter: chapter
        )

        switch key {
        case .vm: lastLoggedVMStatus = normalized
        case .health: lastLoggedHealthStatus = normalized
        case .cleanup: lastLoggedCleanupStatus = normalized
        case .escalation: lastLoggedEscalationStatus = normalized
        case .observability: lastLoggedObservabilityStatus = normalized
        case .preflight: lastLoggedPreflightStatus = normalized
        }

        if showInternalChronicle {
            markdownPreview = chronicle.exportMarkdown()
        }
    }

    private func autoSyncChecklistFromRuntime() {
        let snapshot = runtimeWorkbench.makePreflightSnapshot()
        let keyringStatuses = runtimeWorkbench.requiredKeyringStatuses
        let securityFlowReady = keyringStatuses.isEmpty || keyringStatuses.values.allSatisfy { $0 }
        let signals = ReadinessChecklistSignals(
            snapshot: snapshot,
            preflightEvidenceExists: !planner.lastPreflightEvidencePath.isEmpty,
            securityFlowReady: securityFlowReady,
            buildPassed: importedBuildPassed,
            testsPassed: importedTestsPassed
        )
        planner.autoSyncChecklist(with: signals)
    }

    private var screenshotReferencesFromField: [ScreenshotReference] {
        screenshotRefsRaw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { token in
                let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
                let path = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let caption = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return ScreenshotReference(pathOrURL: path, caption: caption)
            }
            .filter { !$0.pathOrURL.isEmpty }
    }

    private func updateStageStatus(stageID: String, newStatus: BlueprintStageStatus) {
        guard let result = planner.setStageStatus(stageID: stageID, to: newStatus) else {
            return
        }

        let title: String
        let kind: ChronicleEntryKind
        let chapter: ChronicleChapter

        if newStatus == .complete {
            title = "Milestone Completed"
            kind = .stepCompleted
            chapter = .implementation
        } else {
            title = "Milestone Status Revision"
            kind = .revision
            chapter = .revisions
        }

        guard showInternalChronicle else {
            return
        }

        chronicle.log(
            kind: kind,
            author: .system,
            chapter: chapter,
            title: title,
            details: "\(result.stage.title) changed from \(result.previous.rawValue) to \(newStatus.rawValue).",
            relatedStageID: stageID
        )

        markdownPreview = chronicle.exportMarkdown()
    }

    private func exportMarkdownFile() {
        do {
            let url = try chronicle.writeMarkdownExport()
            lastExportPath = url.path
            exportStatusMessage = "Markdown exported: \(url.path)"
        } catch {
            exportStatusMessage = "Markdown export failed: \(error.localizedDescription)"
        }
    }

    private func exportPDFFile() {
        do {
            let url = try chronicle.writePDFExport()
            lastExportPath = url.path
            exportStatusMessage = "PDF exported: \(url.path)"
        } catch {
            exportStatusMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    private func exportDOCXFile() {
        do {
            let url = try chronicle.writeDOCXExport()
            lastExportPath = url.path
            exportStatusMessage = "DOCX exported: \(url.path)"
        } catch {
            exportStatusMessage = "DOCX export failed: \(error.localizedDescription)"
        }
    }

    private func copyLastExportPath() {
        guard !lastExportPath.isEmpty else {
            exportStatusMessage = "No export file available yet. Export a file first."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastExportPath, forType: .string)
        exportStatusMessage = "Copied export path to clipboard: \(lastExportPath)"
    }

    private func openExportsFolder() {
        do {
            let folderURL = try chronicle.exportsDirectory()
            NSWorkspace.shared.open(folderURL)
            exportStatusMessage = "Opened exports folder: \(folderURL.path)"
        } catch {
            exportStatusMessage = "Unable to open exports folder: \(error.localizedDescription)"
        }
    }

    private var showInternalChronicle: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

#Preview {
    ContentView()
}
