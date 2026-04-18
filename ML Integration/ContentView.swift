//
//  ML Integration
//  Copyright © 2026 TBDO Inc. All rights reserved.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum DebianInstallerProfile: String, CaseIterable, Identifiable {
        case netinst = "Netinst (Default)"
        case fullDVD = "Full DVD ISO"

        var id: String { rawValue }
    }

    @State private var selectedArchitecture: HostArchitecture = .appleSilicon
    @State private var selectedCatalogDistribution: LinuxDistribution = .ubuntu
    @State private var selectedRuntimeEngine: RuntimeEngine = .appleVirtualization
    @State private var vmName: String = "default-linux-vm"
    @State private var statusMessage: String = ""
    @State private var isCreatingVM: Bool = false
    @State private var installerImagePath: String = ""
    @State private var showFilePicker: Bool = false
    @State private var activeCatalogActionDistribution: LinuxDistribution?
    @State private var downloadedInstallerByDistribution: [LinuxDistribution: String] = [:]
    @State private var availableCatalogDistributions: [LinuxDistribution] = []
    @State private var selectedDebianInstallerProfile: DebianInstallerProfile = .netinst
    @State private var selectedSourceDetailsArtifact: DistributionArtifact?
    @State private var showErrorAlert: Bool = false
    @State private var errorAlertMessage: String = ""

    @StateObject private var runtimeWorkbench = RuntimeWorkbenchViewModel()
    @StateObject private var blueprintPlanner = BlueprintPlanner()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ML Integration")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Linux Virtualization Manager")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("© 2026 TBDO Inc.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Main Content
                ScrollView {
                    VStack(spacing: 20) {
                        // VM Controls Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("VM Management")
                                    .font(.headline)
                                
                                VStack(spacing: 8) {
                                    Button("Create New VM") {
                                        isCreatingVM = true
                                        statusMessage = "Creating VM..."
                                        Task {
                                            do {
                                                let resolvedInstallerPath: String
                                                let trimmedManualPath = installerImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
                                                if !trimmedManualPath.isEmpty {
                                                    resolvedInstallerPath = trimmedManualPath
                                                } else {
                                                    resolvedInstallerPath = downloadedInstallerByDistribution[selectedCatalogDistribution]
                                                        ?? runtimeWorkbench.downloadedInstallerPath
                                                }

                                                await runtimeWorkbench.scaffoldInstall(
                                                    distribution: selectedCatalogDistribution,
                                                    architecture: selectedArchitecture,
                                                    runtime: selectedRuntimeEngine,
                                                    vmName: vmName,
                                                    installerImagePath: resolvedInstallerPath,
                                                    kernelImagePath: "",
                                                    initialRamdiskPath: ""
                                                )
                                                statusMessage = "VM creation initiated successfully"
                                            } catch {
                                                let message = "Error creating VM: \(error.localizedDescription)"
                                                statusMessage = message
                                                presentError(message)
                                            }
                                            isCreatingVM = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        runtimeWorkbench.activeVMID != nil
                                            || isCreatingVM
                                            || (
                                                installerImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                    && downloadedInstallerByDistribution[selectedCatalogDistribution] == nil
                                                    && runtimeWorkbench.downloadedInstallerPath.isEmpty
                                            )
                                    )
                                    
                                    if !statusMessage.isEmpty {
                                        Text(statusMessage)
                                            .font(.caption)
                                            .foregroundColor(statusMessage.contains("Error") ? .red : .green)
                                    }
                                    
                                    if let vmID = runtimeWorkbench.activeVMID {
                                        HStack(spacing: 8) {
                                            Button("Start VM") {
                                                Task {
                                                    await runtimeWorkbench.startActiveVM()
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            
                                            Button("Stop VM") {
                                                Task {
                                                    await runtimeWorkbench.stopActiveVM()
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            
                                            Button("Restart VM") {
                                                Task {
                                                    await runtimeWorkbench.restartActiveVM()
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                        
                                        Divider()
                                        
                                        Button("Remove VM") {
                                            Task {
                                                await runtimeWorkbench.uninstallActiveVM(removeArtifacts: true)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .foregroundColor(.red)
                                    }
                                }
                            }
                        }

                        // OS Catalog Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("OS Catalog")
                                    .font(.headline)

                                Text("Download the installer for a listed distro, then click Install when ready.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if availableCatalogDistributions.contains(.debian) {
                                    Picker("Debian Installer Type", selection: $selectedDebianInstallerProfile) {
                                        ForEach(DebianInstallerProfile.allCases) { profile in
                                            Text(profile.rawValue).tag(profile)
                                        }
                                    }
                                }

                                if availableCatalogDistributions.isEmpty {
                                    Text("No catalog entries are currently available for \(selectedArchitecture.rawValue).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                ForEach(availableCatalogDistributions) { distribution in
                                    HStack(spacing: 8) {
                                        Button("Download \(distribution.rawValue)") {
                                            Task {
                                                await downloadInstaller(for: distribution)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isCreatingVM || activeCatalogActionDistribution != nil)

                                        Button("Install") {
                                            Task {
                                                await installDownloadedDistribution(distribution)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(
                                            runtimeWorkbench.activeVMID != nil
                                                || isCreatingVM
                                                || downloadedInstallerByDistribution[distribution] == nil
                                        )

                                        Button("Source details") {
                                            selectedSourceDetailsArtifact = preferredArtifact(
                                                for: distribution,
                                                artifacts: runtimeWorkbench.artifacts
                                            )
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(
                                            preferredArtifact(
                                                for: distribution,
                                                artifacts: runtimeWorkbench.artifacts
                                            ) == nil
                                        )
                                    }
                                }

                                if let activeCatalogActionDistribution {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text("Working on \(activeCatalogActionDistribution.rawValue)...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if !runtimeWorkbench.downloadStatusMessage.isEmpty {
                                    Text(runtimeWorkbench.downloadStatusMessage)
                                        .font(.caption)
                                        .foregroundColor(
                                            runtimeWorkbench.downloadStatusMessage.localizedCaseInsensitiveContains("failed")
                                                ? .red
                                                : .green
                                        )
                                }
                            }
                        }

                        // VM Configuration Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("VM Configuration")
                                    .font(.headline)

                                Text("Use this section for custom Linux installers not listed in OS Catalog.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("VM Name", text: $vmName)

                                    HStack {
                                        TextField("Installer Image Path (ISO)", text: $installerImagePath)
                                        Button("Browse") {
                                            showFilePicker = true
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Picker("Architecture", selection: $selectedArchitecture) {
                                        Text("Apple Silicon").tag(HostArchitecture.appleSilicon)
                                        Text("Intel").tag(HostArchitecture.intel)
                                    }
                                    Picker("Distribution", selection: $selectedCatalogDistribution) {
                                        Text("Ubuntu").tag(LinuxDistribution.ubuntu)
                                        Text("Fedora").tag(LinuxDistribution.fedora)
                                        Text("Debian").tag(LinuxDistribution.debian)
                                        Text("Pop!_OS").tag(LinuxDistribution.popOS)
                                        Text("openSUSE").tag(LinuxDistribution.openSUSE)
                                    }
                                    Picker("Runtime Engine", selection: $selectedRuntimeEngine) {
                                        Text("Apple Virtualization").tag(RuntimeEngine.appleVirtualization)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                        }

                        // Support Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Support")
                                    .font(.headline)
                                
                                VStack(spacing: 8) {
                                    Button("Run Health Check") {
                                        Task {
                                            await runtimeWorkbench.runHealthCheck()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button("Report Issue") {
                                        // Open support dialog
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        // VM Status Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Virtual Machines")
                                    .font(.headline)
                                
                                if let vmID = runtimeWorkbench.activeVMID {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Active VM")
                                                .font(.subheadline)
                                            Text(vmID.uuidString)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("Status")
                                                .font(.caption)
                                            Text(runtimeWorkbench.installLifecycleState.rawValue)
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(8)
                                } else if let vmID = runtimeWorkbench.lastManagedVMID {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Last Managed VM")
                                                .font(.subheadline)
                                            Text(vmID.uuidString)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text("Stopped")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                    .padding()
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(8)
                                } else {
                                    Text("No VMs created yet")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding()
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(8)
                                }
                            }
                        }

                        // Live Preflight Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Live Readiness Preflight")
                                    .font(.headline)

                                Text(blueprintPlanner.readinessProgressSummary)
                                    .font(.subheadline)
                                    .foregroundColor(blueprintPlanner.isReadyForEnvironmentTesting ? .green : .orange)

                                if !blueprintPlanner.preflightStatusMessage.isEmpty {
                                    Text(blueprintPlanner.preflightStatusMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                HStack(spacing: 8) {
                                    Button("Run Live Preflight") {
                                        Task {
                                            await runtimeWorkbench.detectHost()
                                            await runtimeWorkbench.refreshCatalog(for: selectedArchitecture, force: true)

                                            let snapshot = runtimeWorkbench.makePreflightSnapshot()
                                            blueprintPlanner.applyPreflightScan(snapshot)
                                            blueprintPlanner.autoSyncChecklist(
                                                with: ReadinessChecklistSignals(
                                                    snapshot: snapshot,
                                                    preflightEvidenceExists: !blueprintPlanner.lastPreflightEvidencePath.isEmpty,
                                                    securityFlowReady: inferredSecurityFlowReady,
                                                    buildPassed: nil,
                                                    testsPassed: nil
                                                )
                                            )
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Start Environment Testing") {
                                        _ = blueprintPlanner.startEnvironmentTestingIfReady()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!blueprintPlanner.isReadyForEnvironmentTesting)
                                }

                                if !blueprintPlanner.environmentTestStartStatusMessage.isEmpty {
                                    Text(blueprintPlanner.environmentTestStartStatusMessage)
                                        .font(.caption)
                                        .foregroundColor(blueprintPlanner.environmentTestingStarted ? .green : .orange)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(blueprintPlanner.readinessCriteria) { criterion in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(criterion.isSatisfied ? "✓" : "•")
                                                .foregroundColor(criterion.isSatisfied ? .green : .orange)
                                            Text(criterion.title)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("ML Integration")
            .onAppear {
                Task {
                    await runtimeWorkbench.restoreVMRegistryState()
                    await refreshCatalogAvailability(force: true)
                }
            }
            .onChange(of: selectedArchitecture) { _, _ in
                Task {
                    await refreshCatalogAvailability(force: true)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        installerImagePath = url.path
                        statusMessage = "Selected installer: \(url.lastPathComponent)"
                    }
                case .failure(let error):
                    statusMessage = "File selection error: \(error.localizedDescription)"
                    presentError(statusMessage)
                }
            }
            .alert("Action Failed", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorAlertMessage)
            }
            .sheet(item: $selectedSourceDetailsArtifact) { artifact in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source details")
                        .font(.headline)
                    Text("\(artifact.distribution.rawValue) • \(artifact.version)")
                        .font(.subheadline)

                    Text("Architecture: \(artifact.architecture.rawValue)")
                        .font(.caption)
                    Text("Download URL:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(artifact.downloadURL.absoluteString)
                        .font(.caption)
                        .textSelection(.enabled)

                    Text("Mirrors: \(artifact.mirrorURLs.count)")
                        .font(.caption)
                    Text("Checksum: \(artifact.checksumSHA256.isEmpty ? "Unavailable" : "Available")")
                        .font(.caption)
                    Text("Signature expected: \(artifact.signatureExpected ? "Yes" : "No")")
                        .font(.caption)
                    Text("Signature verified at source: \(artifact.signatureVerifiedAtSource ? "Yes" : "No")")
                        .font(.caption)
                }
                .padding(16)
                .frame(minWidth: 520)
            }
        }
    }

    private var inferredSecurityFlowReady: Bool {
        let signatureFailed = runtimeWorkbench.signatureStatusMessage.localizedCaseInsensitiveContains("failed")
            || runtimeWorkbench.signatureStatusMessage.localizedCaseInsensitiveContains("not verified")
        let keyringFailed = runtimeWorkbench.keyringStatusMessage.localizedCaseInsensitiveContains("failed")
            || runtimeWorkbench.keyringStatusMessage.localizedCaseInsensitiveContains("error")
        return !(signatureFailed || keyringFailed)
    }

    private func downloadInstaller(for distribution: LinuxDistribution) async {
        activeCatalogActionDistribution = distribution
        defer { activeCatalogActionDistribution = nil }

        selectedCatalogDistribution = distribution
        statusMessage = "Fetching catalog for \(distribution.rawValue)..."
        await runtimeWorkbench.refreshCatalog(for: selectedArchitecture, force: true)
        updateAvailableDistributionsFromCurrentArtifacts()

        guard let artifact = preferredArtifact(for: distribution, artifacts: runtimeWorkbench.artifacts) else {
            statusMessage = "No online artifact found for \(distribution.rawValue) on \(selectedArchitecture.rawValue)."
            presentError(statusMessage)
            return
        }

        statusMessage = "Downloading \(distribution.rawValue) installer..."
        await runtimeWorkbench.downloadArtifact(artifact)
        if !runtimeWorkbench.downloadedInstallerPath.isEmpty {
            downloadedInstallerByDistribution[distribution] = runtimeWorkbench.downloadedInstallerPath
            installerImagePath = runtimeWorkbench.downloadedInstallerPath
            statusMessage = "Downloaded \(distribution.rawValue) installer."
        } else if !runtimeWorkbench.downloadStatusMessage.isEmpty {
            statusMessage = runtimeWorkbench.downloadStatusMessage
            if statusMessage.localizedCaseInsensitiveContains("failed")
                || statusMessage.localizedCaseInsensitiveContains("unavailable")
                || statusMessage.localizedCaseInsensitiveContains("no ")
            {
                presentError(statusMessage)
            }
        }
    }

    private func refreshCatalogAvailability(force: Bool) async {
        await runtimeWorkbench.refreshCatalog(for: selectedArchitecture, force: force)
        updateAvailableDistributionsFromCurrentArtifacts()

        if !availableCatalogDistributions.contains(selectedCatalogDistribution),
           let fallback = availableCatalogDistributions.first {
            selectedCatalogDistribution = fallback
        }
    }

    private func updateAvailableDistributionsFromCurrentArtifacts() {
        let available = Set(runtimeWorkbench.artifacts.map(\.distribution))
        availableCatalogDistributions = LinuxDistribution.allCases.filter { available.contains($0) }
    }

    private func preferredArtifact(
        for distribution: LinuxDistribution,
        artifacts: [DistributionArtifact]
    ) -> DistributionArtifact? {
        let candidates = artifacts.filter {
            $0.distribution == distribution && $0.architecture == selectedArchitecture
        }
        guard !candidates.isEmpty else { return nil }

        switch distribution {
        case .ubuntu:
            let lts = candidates.filter { $0.version.localizedCaseInsensitiveContains("LTS") }
            return (lts.isEmpty ? candidates : lts).first
        case .debian:
            switch selectedDebianInstallerProfile {
            case .netinst:
                return candidates.first {
                    $0.downloadURL.lastPathComponent.localizedCaseInsensitiveContains("netinst")
                } ?? candidates.first
            case .fullDVD:
                return candidates.first {
                    $0.downloadURL.lastPathComponent.localizedCaseInsensitiveContains("DVD")
                        || $0.version.localizedCaseInsensitiveContains("full DVD")
                } ?? candidates.first
            }
        case .fedora, .openSUSE, .popOS:
            return candidates.first
        }
    }

    private func installDownloadedDistribution(_ distribution: LinuxDistribution) async {
        isCreatingVM = true
        defer { isCreatingVM = false }

        guard let downloadedPath = downloadedInstallerByDistribution[distribution], !downloadedPath.isEmpty else {
            statusMessage = "Download \(distribution.rawValue) first, then install."
            presentError(statusMessage)
            return
        }

        selectedCatalogDistribution = distribution
        installerImagePath = downloadedPath
        statusMessage = "Installing \(distribution.rawValue)..."

        await runtimeWorkbench.scaffoldInstall(
            distribution: distribution,
            architecture: selectedArchitecture,
            runtime: selectedRuntimeEngine,
            vmName: vmName,
            installerImagePath: downloadedPath,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        if runtimeWorkbench.installLifecycleState == .ready {
            statusMessage = "\(distribution.rawValue) downloaded and VM scaffold installed."
        } else {
            statusMessage = runtimeWorkbench.vmStatusMessage
            presentError(statusMessage)
        }
    }

    private func presentError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorAlertMessage = trimmed
        showErrorAlert = true
    }
}

#Preview {
    ContentView()
}
