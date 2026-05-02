//
//  ML Integration
//  Copyright © 2026 TBDO Inc. All rights reserved.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    private static let integratedConsoleSectionID = "integrated-console-section"
    private enum DebianInstallerProfile: String, CaseIterable, Identifiable {
        case netinst = "Netinst (Default)"
        case fullDVD = "Full DVD ISO"

        var id: String { rawValue }
    }

    private enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    private enum VisualStyleMode: String, CaseIterable, Identifiable {
        case nativeMac
        case currentApp

        var id: String { rawValue }
        var title: String {
            switch self {
            case .nativeMac: return "Native macOS Material"
            case .currentApp: return "Red Contrast Style"
            }
        }
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
    @State private var customCatalogName: String = ""
    @State private var editingCustomEntryID: UUID?
    @State private var selectedInstalledVMID: UUID?
    @State private var selectedRemovalMode: RemovalMode = .installedVM
    @State private var selectedRemovalDistribution: LinuxDistribution?
    @State private var manuallySelectedInstallerDistribution: LinuxDistribution?
    @State private var activeDownloadTask: Task<Void, Never>?
    @State private var showActionAlert: Bool = false
    @State private var actionAlertTitle: String = "Status"
    @State private var actionAlertMessage: String = ""
    @State private var showQEMUSetupAlert: Bool = false
    @State private var qemuSetupAlertMessage: String = ""
    @State private var showWindowsRuntimePathAlert: Bool = false
    @State private var windowsRuntimeAlertMessage: String = ""
    @State private var useDetachedConsoleWindow: Bool = false
    @State private var showConsoleRuntimeInfo: Bool = false
    @State private var consoleRefreshToken: UUID = UUID()
    @State private var isConsoleExpanded: Bool = false
    @State private var showReportIssueSheet: Bool = false
    @State private var reportIssueTitle: String = ""
    @State private var reportIssueDetails: String = ""
    @State private var reportGitHubToken: String = ""
    @State private var reportConsentDiagnostics: Bool = true
    @State private var reportConsentHostProfile: Bool = false
    @State private var reportConsentRuntimeStatus: Bool = true
    @State private var reportConsentConfirmed: Bool = false
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("visualStyleMode") private var visualStyleModeRaw: String = VisualStyleMode.nativeMac.rawValue
    @AppStorage("lightIntensity") private var lightIntensity: Double = 1.0
    @AppStorage("a11yReduceMotion") private var a11yReduceMotion: Bool = true
    @AppStorage("a11yLargeControls") private var a11yLargeControls: Bool = false
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runtimeWorkbench = RuntimeWorkbenchViewModel()
    @StateObject private var blueprintPlanner = BlueprintPlanner()

    private enum RemovalMode: String, CaseIterable, Identifiable {
        case installedVM = "Installed VM"
        case downloadedInstaller = "Downloaded Installer"

        var id: String { rawValue }
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var visualStyleMode: VisualStyleMode {
        VisualStyleMode(rawValue: visualStyleModeRaw) ?? .nativeMac
    }

    private var useNativeMaterialStyle: Bool {
        visualStyleMode == .nativeMac
    }

    private var preferredColorSchemeOverride: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var managedVMID: UUID? {
        selectedInstalledVMID ?? runtimeWorkbench.activeVMID ?? runtimeWorkbench.lastManagedVMID
    }

    private var sectionBorderColor: Color {
        useNativeMaterialStyle ? Color.white.opacity(0.38) : Color.red.opacity(0.8)
    }

    private var isForcedLightAppearance: Bool {
        appearanceMode == .light
    }

    private var appBackgroundTopColor: Color {
        if useNativeMaterialStyle {
            return isForcedLightAppearance
                ? Color.white.opacity(0.98)
                : Color(nsColor: .windowBackgroundColor).opacity(0.94)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    private var appBackgroundBottomColor: Color {
        if useNativeMaterialStyle {
            return isForcedLightAppearance
                ? Color.white.opacity(0.94)
                : Color(nsColor: .underPageBackgroundColor).opacity(0.9)
        }
        return Color(nsColor: .underPageBackgroundColor)
    }

    private var appBackgroundHighlightColor: Color {
        useNativeMaterialStyle ? (isForcedLightAppearance ? Color.white.opacity(0.2) : Color.white.opacity(0.08)) : .clear
    }

    private var lightIntensityText: String {
        String(format: "%.2f", lightIntensity)
    }

    private var lightIntensityDimOverlayOpacity: Double {
        guard lightIntensity < 1.0 else { return 0 }
        return min(0.35, (1.0 - lightIntensity) * 0.7)
    }

    private var lightIntensityBrightenOverlayOpacity: Double {
        guard lightIntensity > 1.0 else { return 0 }
        return min(0.28, (lightIntensity - 1.0) * 0.56)
    }

    var body: some View {
        applyPresentationModifiers(to:
            NavigationStack {
            ScrollViewReader { scrollProxy in
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
                .background(useNativeMaterialStyle ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(NSColor.controlBackgroundColor)))
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                )
                .shadow(color: Color.white.opacity(0.08), radius: 1, x: 0, y: 1)
                
                Divider()
                
                // Main Content
                ScrollView {
                    VStack(spacing: 20) {
                        // VM Controls Section
                        vmManagementSectionView(scrollProxy: scrollProxy)

                        // OS Catalog Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Spacer()
                                    Text("OS Catalog")
                                        .font(.headline)
                                        .accessibilityAddTraits(.isHeader)
                                    Spacer()
                                }

                                Text("Download the installer for a listed distro, then click Install when ready.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if availableCatalogDistributions.contains(.debian) {
                                    Picker("Debian Installer Type", selection: $selectedDebianInstallerProfile) {
                                        ForEach(DebianInstallerProfile.allCases) { profile in
                                            Text(profile.rawValue).tag(profile)
                                        }
                                    }
                                    .modifier(WhiteOutlinedControl())
                                }

                                if availableCatalogDistributions.isEmpty {
                                    Text("No catalog entries are currently available for \(selectedArchitecture.rawValue).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                ForEach(availableCatalogDistributions) { distribution in
                                    let artifact = preferredArtifact(
                                        for: distribution,
                                        artifacts: runtimeWorkbench.artifacts
                                    )
                                    HStack(spacing: 8) {
                                        Button("Download \(distribution.rawValue)") {
                                            activeDownloadTask = Task {
                                                await downloadInstaller(for: distribution)
                                                presentInfo(runtimeWorkbench.downloadStatusMessage.isEmpty ? statusMessage : runtimeWorkbench.downloadStatusMessage)
                                                await MainActor.run {
                                                    activeDownloadTask = nil
                                                }
                                            }
                                        }
                                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                        .disabled(
                                            isCreatingVM
                                                || activeCatalogActionDistribution != nil
                                                || runtimeWorkbench.isDownloadInProgress
                                                || artifact == nil
                                        )

                                        Button("Install") {
                                            Task {
                                                await installDownloadedDistribution(distribution)
                                                presentInfo(statusMessage)
                                            }
                                        }
                                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                        .disabled(
                                            isCreatingVM
                                                || (distribution != .windows11 && !hasInstallSource(for: distribution))
                                                || artifact == nil
                                        )

                                        Button("Source details") {
                                            selectedSourceDetailsArtifact = preferredArtifact(
                                                for: distribution,
                                                artifacts: runtimeWorkbench.artifacts
                                            )
                                            presentInfo("Opened source details for \(distribution.rawValue).")
                                        }
                                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                        .disabled(
                                            artifact == nil
                                        )
                                    }
                                    if artifact == nil {
                                        Text("\(distribution.rawValue) catalog source is unavailable for \(selectedArchitecture.rawValue) right now.")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if let activeCatalogActionDistribution {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let fraction = runtimeWorkbench.downloadProgressFraction {
                                            ProgressView(value: fraction, total: 1.0)
                                        } else if let installFraction = runtimeWorkbench.installProgressFraction, isCreatingVM {
                                            ProgressView(value: installFraction, total: 1.0)
                                        } else {
                                            ProgressView()
                                        }
                                        Text(
                                            runtimeWorkbench.downloadProgressFraction != nil
                                                ? "Downloading \(activeCatalogActionDistribution.rawValue)..."
                                                : "Installing \(activeCatalogActionDistribution.rawValue)..."
                                        )
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        let speedText = runtimeWorkbench.downloadProgressFraction != nil
                                            ? runtimeWorkbench.downloadSpeedText
                                            : runtimeWorkbench.installSpeedText
                                        let etaText = runtimeWorkbench.downloadProgressFraction != nil
                                            ? runtimeWorkbench.downloadETAText
                                            : runtimeWorkbench.installETAText
                                        if !speedText.isEmpty {
                                            Text(speedText)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if !etaText.isEmpty {
                                            Text(etaText)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if runtimeWorkbench.isDownloadInProgress {
                                            Button("Stop Download") {
                                                let distributionLabel = activeCatalogActionDistribution.rawValue
                                                let message = runtimeWorkbench.cancelDownloadStatus(for: activeCatalogActionDistribution)
                                                traceVM("UI downloadInstaller cancel requested distribution=" + distributionLabel)
                                                runtimeWorkbench.markDownloadCancellationRequested()
                                                activeDownloadTask?.cancel()
                                                activeDownloadTask = nil
                                                presentInfo(message)
                                            }
                                            .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                        }
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

                                if !runtimeWorkbench.customCatalogEntriesForCurrentArchitecture(selectedArchitecture).isEmpty {
                                    Divider()
                                    Text("Custom OS Entries")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)

                                    ForEach(runtimeWorkbench.customCatalogEntriesForCurrentArchitecture(selectedArchitecture)) { entry in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(entry.displayName)
                                                    .font(.subheadline)
                                                Spacer()
                                                Text(entry.runtimeEngine.rawValue)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                            Text(entry.installerPath)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)

                                            HStack(spacing: 8) {
                                                Button("Install") {
                                                    Task {
                                                        await installCustomCatalogEntry(entry)
                                                    }
                                                }
                                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                                .disabled(isCreatingVM)

                                                Button("Edit") {
                                                    beginEditingCustomCatalogEntry(entry)
                                                }
                                                .buttonStyle(RedTextWhiteOutlineButtonStyle())

                                                Button("Remove Entry") {
                                                    removeCustomCatalogEntry(entry.id)
                                                }
                                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                            }
                                        }
                                    }
                                }
                            }
                            .modifier(GlassCardStyle(borderColor: sectionBorderColor))
                        }

                        integratedConsoleSectionView

                        // VM Configuration Section
                        vmConfigurationSectionView

                        // Support Section
                        supportSectionView

                        // VM Status Section
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Virtual Machines")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                
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
                                            if let runtimeLabel = runtimeLabel(for: vmID) {
                                                Text(runtimeLabel)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
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
                                        VStack(alignment: .trailing, spacing: 4) {
                                            if let runtimeLabel = runtimeLabel(for: vmID) {
                                                Text(runtimeLabel)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                            Text("Stopped")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
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
                                    .buttonStyle(RedTextWhiteOutlineButtonStyle())

                                    Button("Start Environment Testing") {
                                        _ = blueprintPlanner.startEnvironmentTestingIfReady()
                                    }
                                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
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
                    }
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical)
                }
                .tint(useNativeMaterialStyle ? .accentColor : .red)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .controlSize(a11yLargeControls ? .large : .regular)
            }
                .background(
                    LinearGradient(
                        colors: [
                        appBackgroundTopColor,
                        appBackgroundBottomColor,
                        appBackgroundHighlightColor
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            .overlay(
                Color.black
                    .opacity(lightIntensityDimOverlayOpacity)
                    .allowsHitTesting(false)
            )
            .overlay(
                Color.white
                    .opacity(lightIntensityBrightenOverlayOpacity)
                    .allowsHitTesting(false)
            )
            .preferredColorScheme(preferredColorSchemeOverride)
            .navigationTitle("ML Integration")
            .onAppear {
                Task {
                    await handleOnAppear()
                }
            }
            .onChange(of: runtimeWorkbench.installedVMEntries) { _, entries in
                handleInstalledVMEntriesChange(entries)
            }
            .onChange(of: downloadedInstallerByDistribution) { _, _ in
                handleDownloadedInstallerMapChange()
            }
            .onChange(of: selectedArchitecture) { _, _ in
                Task {
                    await handleArchitectureChange()
                }
            }
            .onChange(of: selectedCatalogDistribution) { _, distribution in
                handleCatalogDistributionChange(distribution)
            }
            .onChange(of: selectedRuntimeEngine) { _, runtime in
                Task {
                    await handleRuntimeEngineChange(runtime)
                }
            }
        }
        )
    }

    private func applyPresentationModifiers<Content: View>(to content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImportResult(result)
            }
            .alert(actionAlertTitle, isPresented: $showActionAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionAlertMessage)
            }
            .alert("QEMU Required", isPresented: $showQEMUSetupAlert) {
                qemuAlertActions
            } message: {
                qemuAlertMessageView
            }
            .alert("Windows Runtime Path Required", isPresented: $showWindowsRuntimePathAlert) {
                windowsRuntimeAlertActions
            } message: {
                windowsRuntimeAlertMessageView
            }
            .sheet(isPresented: $showReportIssueSheet) {
                reportIssueConsentSheet
            }
            .sheet(item: $selectedSourceDetailsArtifact) { artifact in
                sourceDetailsSheet(artifact)
            }
    }

    private let supportGitHubOwner = "bdbobbie"
    private let supportGitHubRepository = "ml-integration"

    private var reportIssueConsentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report Issue")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Choose what to include, confirm consent, then submit a GitHub issue.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Issue Title", text: $reportIssueTitle)
                .textFieldStyle(.roundedBorder)

            Text("Destination: \(supportGitHubOwner)/\(supportGitHubRepository)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $reportIssueDetails)
                .font(.caption)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            Toggle("Include diagnostics bundle", isOn: $reportConsentDiagnostics)
            Toggle("Include host profile information", isOn: $reportConsentHostProfile)
            Toggle("Include runtime/status messages", isOn: $reportConsentRuntimeStatus)
            Toggle("I consent to sharing selected diagnostics for support", isOn: $reportConsentConfirmed)

            if !runtimeWorkbench.escalationStatusMessage.isEmpty {
                Text(runtimeWorkbench.escalationStatusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showReportIssueSheet = false
                }
                .buttonStyle(RedTextWhiteOutlineButtonStyle())

                Button("Create Bundle + Open GitHub Issue") {
                    Task {
                        await submitIssueReport()
                    }
                }
                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                .disabled(!reportConsentConfirmed
                          || reportIssueTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    @ViewBuilder
    private var qemuAlertActions: some View {
        Button("Open QEMU Download") {
            if let url = URL(string: "https://www.qemu.org/download/") {
                NSWorkspace.shared.open(url)
            }
        }
        Button("OK", role: .cancel) {}
    }

    private var qemuAlertMessageView: some View {
        Text(qemuSetupAlertMessage)
    }

    @ViewBuilder
    private var windowsRuntimeAlertActions: some View {
        Button("Switch To Linux Runtime") {
            selectedCatalogDistribution = .ubuntu
            selectedRuntimeEngine = .appleVirtualization
            statusMessage = "Switched to Linux runtime selection. Install a Linux distribution and start VM."
            presentInfo(statusMessage)
        }
        Button("Configure External Runtime") {
            if let url = URL(string: "https://support.microsoft.com/en-us/windows/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips-cd15fd62-9b34-4b78-b0bc-121baa3c568c") {
                NSWorkspace.shared.open(url)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var windowsRuntimeAlertMessageView: some View {
        Text(windowsRuntimeAlertMessage)
    }

    @ViewBuilder
    private func sourceDetailsSheet(_ artifact: DistributionArtifact) -> some View {
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

            HStack {
                Spacer()
                Button("Close") {
                    selectedSourceDetailsArtifact = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(minWidth: 520)
    }

    private func handleOnAppear() async {
        await runtimeWorkbench.restoreVMRegistryState()
        await MainActor.run {
            runtimeWorkbench.refreshDownloadedInstallerPresence()
            selectedInstalledVMID = runtimeWorkbench.activeVMID
                ?? runtimeWorkbench.lastManagedVMID
                ?? runtimeWorkbench.installedVMEntries.first?.id
            selectedRemovalDistribution = LinuxDistribution.allCases.first {
                downloadedInstallerByDistribution[$0] != nil
            }
        }
        await refreshCatalogAvailability(force: true)
        await MainActor.run {
            selectedRemovalDistribution = LinuxDistribution.allCases.first {
                downloadedInstallerByDistribution[$0] != nil
            }
        }
        if requiresQEMURuntimeProbe(selectedRuntimeEngine) {
            _ = await runtimeWorkbench.probeQEMUAvailability(for: selectedArchitecture)
        }
    }

    private func handleInstalledVMEntriesChange(_ entries: [VMRegistryEntry]) {
        if let selectedInstalledVMID, entries.contains(where: { $0.id == selectedInstalledVMID }) {
            return
        }
        selectedInstalledVMID = entries.first?.id
    }

    private func handleDownloadedInstallerMapChange() {
        if let selectedRemovalDistribution,
           downloadedInstallerByDistribution[selectedRemovalDistribution] != nil {
            return
        }
        selectedRemovalDistribution = LinuxDistribution.allCases.first {
            downloadedInstallerByDistribution[$0] != nil
        }
    }

    private func handleArchitectureChange() async {
        await refreshCatalogAvailability(force: true)
        if requiresQEMURuntimeProbe(selectedRuntimeEngine) {
            _ = await runtimeWorkbench.probeQEMUAvailability(for: selectedArchitecture)
        }
    }

    private func handleCatalogDistributionChange(_ distribution: LinuxDistribution) {
        if distribution == .windows11 {
            selectedRuntimeEngine = .windowsDedicated
        } else if selectedRuntimeEngine == .windowsDedicated {
            selectedRuntimeEngine = .appleVirtualization
        }
    }

    private func handleRuntimeEngineChange(_ runtime: RuntimeEngine) async {
        guard requiresQEMURuntimeProbe(runtime) else { return }
        _ = await runtimeWorkbench.probeQEMUAvailability(for: selectedArchitecture)
    }

    private var inferredSecurityFlowReady: Bool {
        let signatureFailed = runtimeWorkbench.signatureStatusMessage.localizedCaseInsensitiveContains("failed")
            || runtimeWorkbench.signatureStatusMessage.localizedCaseInsensitiveContains("not verified")
        let keyringFailed = runtimeWorkbench.keyringStatusMessage.localizedCaseInsensitiveContains("failed")
            || runtimeWorkbench.keyringStatusMessage.localizedCaseInsensitiveContains("error")
        return !(signatureFailed || keyringFailed)
    }

    private func runtimeLabel(for vmID: UUID) -> String? {
        guard let engine = runtimeWorkbench.installedVMEntries.first(where: { $0.id == vmID })?.runtimeEngine else {
            return nil
        }
        switch engine {
        case .appleVirtualization:
            return "Apple Runtime"
        case .qemuFallback:
            return "QEMU Runtime"
        case .windowsDedicated:
            return "Windows Runtime"
        case .nativeInstall:
            return "Native Runtime"
        }
    }

    private func requiresQEMURuntimeProbe(_ runtime: RuntimeEngine) -> Bool {
        runtime == .qemuFallback
    }

    private func windowsInstallerMarkerURL() -> URL {
        RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(".windows11-installer-path", isDirectory: false)
    }

    private func persistedWindowsInstallerPath() -> String? {
        let markerURL = windowsInstallerMarkerURL()
        guard let data = try? Data(contentsOf: markerURL),
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func persistWindowsInstallerPath(_ path: String) {
        let markerURL = windowsInstallerMarkerURL()
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = path.data(using: .utf8) {
                try data.write(to: markerURL, options: [.atomic])
            }
        } catch {
            traceVM("UI windows installer marker write failed error=\(error.localizedDescription)")
        }
    }

    private func clearPersistedWindowsInstallerPath() {
        try? FileManager.default.removeItem(at: windowsInstallerMarkerURL())
    }

    private func downloadInstaller(for distribution: LinuxDistribution) async {
        traceVM("UI downloadInstaller begin distribution=\(distribution.rawValue)")
        activeCatalogActionDistribution = distribution
        defer { activeCatalogActionDistribution = nil }
        if distribution == .windows11 {
            presentInfo("Windows 11 can be downloaded, installed, and run without entering a license initially. Microsoft may later request activation and will provide steps to obtain a license if needed.")
        }

        selectedCatalogDistribution = distribution
        statusMessage = "Fetching catalog for \(distribution.rawValue)..."
        await runtimeWorkbench.refreshCatalog(for: selectedArchitecture, force: true)
        updateAvailableDistributionsFromCurrentArtifacts()

        guard let artifact = preferredArtifact(for: distribution, artifacts: runtimeWorkbench.artifacts) else {
            statusMessage = "No online artifact found for \(distribution.rawValue) on \(selectedArchitecture.rawValue)."
            traceVM("UI downloadInstaller no artifact distribution=\(distribution.rawValue)")
            presentError(statusMessage)
            return
        }

        if artifact.downloadURL.pathExtension.lowercased() != "iso" {
            let opened = NSWorkspace.shared.open(artifact.downloadURL)
            if opened {
                statusMessage = "Opened official \(distribution.rawValue) page. Complete Microsoft prompts, download the ISO, click Browse in VM Configuration, then Install."
                traceVM("UI downloadInstaller opened external source distribution=\(distribution.rawValue) url=\(artifact.downloadURL.absoluteString)")
                presentInfo(statusMessage)
            } else {
                statusMessage = "Could not open official \(distribution.rawValue) download page. URL: \(artifact.downloadURL.absoluteString)"
                traceVM("UI downloadInstaller failed opening external source distribution=\(distribution.rawValue) url=\(artifact.downloadURL.absoluteString)")
                presentError(statusMessage)
            }
            return
        }

        if let existingPath = existingDownloadedInstallerPath(for: distribution) {
            let isValid = await runtimeWorkbench.validateInstallerFile(for: artifact, localPath: existingPath)
            if isValid {
                downloadedInstallerByDistribution[distribution] = existingPath
                installerImagePath = existingPath
                statusMessage = "Found existing \(distribution.rawValue) installer."
                traceVM("UI downloadInstaller existing installer distribution=\(distribution.rawValue) path=\(existingPath)")
                presentInfo(statusMessage)
                return
            }

            do {
                try FileManager.default.removeItem(atPath: existingPath)
                traceVM("UI downloadInstaller removed invalid installer distribution=\(distribution.rawValue) path=\(existingPath)")
            } catch {
                traceVM("UI downloadInstaller failed removing invalid installer distribution=\(distribution.rawValue) path=\(existingPath) error=\(error.localizedDescription)")
            }
            downloadedInstallerByDistribution[distribution] = nil
            if installerImagePath == existingPath {
                installerImagePath = ""
            }
        }

        statusMessage = "Downloading \(distribution.rawValue) installer..."
        await runtimeWorkbench.downloadArtifact(artifact)
        if !runtimeWorkbench.downloadedInstallerPath.isEmpty {
            downloadedInstallerByDistribution[distribution] = runtimeWorkbench.downloadedInstallerPath
            installerImagePath = runtimeWorkbench.downloadedInstallerPath
            statusMessage = "Downloaded \(distribution.rawValue) installer."
            traceVM("UI downloadInstaller success distribution=\(distribution.rawValue) path=\(runtimeWorkbench.downloadedInstallerPath)")
        } else if !runtimeWorkbench.downloadStatusMessage.isEmpty {
            statusMessage = runtimeWorkbench.downloadStatusMessage
            traceVM("UI downloadInstaller finished with status distribution=\(distribution.rawValue) status=\(statusMessage)")
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
        refreshDownloadedInstallerCache()

        if !availableCatalogDistributions.contains(selectedCatalogDistribution),
           let fallback = availableCatalogDistributions.first {
            selectedCatalogDistribution = fallback
        }
    }

    private func updateAvailableDistributionsFromCurrentArtifacts() {
        availableCatalogDistributions = LinuxDistribution.allCases.filter { $0 != .windows11 }
    }

    private func refreshDownloadedInstallerCache() {
        for distribution in availableCatalogDistributions {
            if let existingPath = existingDownloadedInstallerPath(for: distribution) {
                downloadedInstallerByDistribution[distribution] = existingPath
                if selectedCatalogDistribution == distribution {
                    installerImagePath = existingPath
                }
            } else {
                downloadedInstallerByDistribution[distribution] = nil
            }
        }
    }

    private func existingDownloadedInstallerPath(for distribution: LinuxDistribution) -> String? {
        if distribution == .windows11 {
            if let markedPath = persistedWindowsInstallerPath(),
               FileManager.default.fileExists(atPath: markedPath) {
                return markedPath
            }
            let downloadsURL = RuntimeEnvironment.mlIntegrationRootURL()
                .appendingPathComponent("downloads", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: downloadsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }
            let winCandidates = files.filter {
                let lower = $0.lastPathComponent.lowercased()
                return $0.pathExtension.lowercased() == "iso"
                    && (lower.contains("win11") || lower.contains("windows11") || lower.contains("windows 11"))
            }
            guard !winCandidates.isEmpty else {
                return nil
            }
            return winCandidates.sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }.first?.path
        }

        guard let artifact = preferredArtifact(for: distribution, artifacts: runtimeWorkbench.artifacts) else {
            return nil
        }

        let downloadsURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("downloads", isDirectory: true)
        let candidate = downloadsURL.appendingPathComponent(artifact.downloadURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
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
        case .fedora, .openSUSE, .popOS, .nixOS, .windows11:
            return candidates.first
        }
    }

    private func installDownloadedDistribution(_ distribution: LinuxDistribution) async {
        traceVM("UI installDownloadedDistribution begin distribution=\(distribution.rawValue)")
        activeCatalogActionDistribution = distribution
        defer { activeCatalogActionDistribution = nil }

        await runtimeWorkbench.reconcileManagedVMIdentifiers()

        if distribution == .windows11,
           runtimeWorkbench.installedVMEntries.contains(where: { $0.distribution == .windows11 }) {
            statusMessage = "Windows 11 VM is already installed. Use Start VM, or remove existing Windows VM before reinstalling."
            presentInfo(statusMessage)
            return
        }

        isCreatingVM = true
        defer { isCreatingVM = false }

        let downloadedPath: String
        if let existingPath = downloadedInstallerByDistribution[distribution], !existingPath.isEmpty {
            downloadedPath = existingPath
        } else if manuallySelectedInstallerDistribution == distribution,
                  isLocalISOPath(installerImagePath) {
            do {
                let importedPath = try importInstallerIntoManagedDownloads(
                    distribution: distribution,
                    sourcePath: installerImagePath
                )
                downloadedInstallerByDistribution[distribution] = importedPath
                installerImagePath = importedPath
                runtimeWorkbench.refreshDownloadedInstallerPresence()
                downloadedPath = importedPath
                traceVM("UI installDownloadedDistribution imported manual installer distribution=\(distribution.rawValue) path=\(importedPath)")
                presentInfo("Imported \(distribution.rawValue) installer into app downloads folder.")
            } catch {
                statusMessage = "Could not import installer into app downloads folder: \(error.localizedDescription)"
                traceVM("UI installDownloadedDistribution import failed distribution=\(distribution.rawValue) error=\(error.localizedDescription)")
                presentError(statusMessage)
                return
            }
        } else {
            if distribution == .windows11 {
                selectedCatalogDistribution = distribution
                statusMessage = ""
                traceVM("UI installDownloadedDistribution requesting file picker distribution=\(distribution.rawValue)")
                await MainActor.run {
                    showFilePicker = true
                }
                return
            }
            statusMessage = "Download \(distribution.rawValue) first, or click Browse while \(distribution.rawValue) is selected to choose its ISO before installing."
            traceVM("UI installDownloadedDistribution missing downloaded path distribution=\(distribution.rawValue)")
            presentError(statusMessage)
            return
        }
        guard FileManager.default.fileExists(atPath: downloadedPath) else {
            downloadedInstallerByDistribution[distribution] = nil
            if installerImagePath == downloadedPath {
                installerImagePath = ""
            }
            statusMessage = "Installer file is missing. Please download \(distribution.rawValue) again."
            traceVM("UI installDownloadedDistribution installer missing distribution=\(distribution.rawValue) path=\(downloadedPath)")
            presentError(statusMessage)
            return
        }
        if let artifact = preferredArtifact(for: distribution, artifacts: runtimeWorkbench.artifacts) {
            let isValid = await runtimeWorkbench.validateInstallerFile(for: artifact, localPath: downloadedPath)
            guard isValid else {
                statusMessage = runtimeWorkbench.checksumStatusMessage.isEmpty
                    ? "Installer validation failed. Please download \(distribution.rawValue) again."
                    : runtimeWorkbench.checksumStatusMessage
                traceVM("UI installDownloadedDistribution installer invalid distribution=\(distribution.rawValue) path=\(downloadedPath)")
                presentError(statusMessage)
                return
            }
        }

        selectedCatalogDistribution = distribution
        if distribution == .windows11 {
            selectedRuntimeEngine = .windowsDedicated
        } else if selectedRuntimeEngine == .windowsDedicated {
            selectedRuntimeEngine = .appleVirtualization
        }
        installerImagePath = downloadedPath
        statusMessage = "Installing \(distribution.rawValue)..."
        if distribution == .windows11 {
            presentInfo("Proceeding with Windows 11 install without a license key is supported. Microsoft may request activation later and will provide information on obtaining a license.")
        }
        let installVMName = makeCatalogVMName(for: distribution)

        await runtimeWorkbench.scaffoldInstall(
            distribution: distribution,
            architecture: selectedArchitecture,
            runtime: selectedRuntimeEngine,
            vmName: installVMName,
            installerImagePath: downloadedPath,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        if runtimeWorkbench.installLifecycleState == .ready {
            selectedInstalledVMID = runtimeWorkbench.activeVMID
            statusMessage = "\(distribution.rawValue) downloaded and VM scaffold installed as \(installVMName)."
            traceVM("UI installDownloadedDistribution success distribution=\(distribution.rawValue)")
        } else {
            statusMessage = runtimeWorkbench.vmStatusMessage
            traceVM("UI installDownloadedDistribution failed distribution=\(distribution.rawValue) status=\(statusMessage)")
            presentError(statusMessage)
        }
    }

    private func hasInstallSource(for distribution: LinuxDistribution) -> Bool {
        if let existing = downloadedInstallerByDistribution[distribution], !existing.isEmpty {
            return true
        }
        return manuallySelectedInstallerDistribution == distribution && isLocalISOPath(installerImagePath)
    }

    private func isLocalISOPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = URL(fileURLWithPath: trimmed)
        return url.pathExtension.lowercased() == "iso" && FileManager.default.fileExists(atPath: url.path)
    }

    private func importInstallerIntoManagedDownloads(distribution: LinuxDistribution, sourcePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines))
        return try importInstallerIntoManagedDownloads(distribution: distribution, sourceURL: sourceURL)
    }

    private func importInstallerIntoManagedDownloads(distribution: LinuxDistribution, sourceURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "ContentView.ImportInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected installer file no longer exists."])
        }
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let downloadsURL = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

        let destinationURL = downloadsURL.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            return destinationURL.path
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        if distribution == .windows11 {
            persistWindowsInstallerPath(destinationURL.path)
        }
        return destinationURL.path
    }

    private func removeSelectedResource() async {
        switch selectedRemovalMode {
        case .installedVM:
            guard let vmID = selectedInstalledVMID else {
                presentError("Select an installed VM to remove.")
                return
            }
            presentInfo("Removing selected installed VM...")
            await runtimeWorkbench.selectManagedVM(vmID)
            await runtimeWorkbench.uninstallActiveVM(removeArtifacts: true)
            await runtimeWorkbench.reconcileManagedVMIdentifiers()
            selectedInstalledVMID = runtimeWorkbench.installedVMEntries.first?.id
            presentInfo(
                runtimeWorkbench.cleanupStatusMessage.isEmpty
                    ? "Removal completed."
                    : runtimeWorkbench.cleanupStatusMessage
            )
        case .downloadedInstaller:
            guard let distribution = selectedRemovalDistribution,
                  let path = downloadedInstallerByDistribution[distribution]
            else {
                presentError("Select a downloaded installer to remove.")
                return
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                downloadedInstallerByDistribution[distribution] = nil
                if distribution == .windows11 {
                    clearPersistedWindowsInstallerPath()
                }
                if installerImagePath == path {
                    installerImagePath = ""
                }
                runtimeWorkbench.refreshDownloadedInstallerPresence()
                selectedRemovalDistribution = LinuxDistribution.allCases.first { downloadedInstallerByDistribution[$0] != nil }
                let message = "Removed downloaded installer for \(distribution.rawValue)."
                statusMessage = message
                presentInfo(message)
            } catch {
                let message = "Failed removing \(distribution.rawValue) installer: \(error.localizedDescription)"
                statusMessage = message
                presentError(message)
            }
        }
    }

    private func makeCatalogVMName(for distribution: LinuxDistribution) -> String {
        let lower = distribution.rawValue.lowercased()
        let compact = lower
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let base = "\(compact)-vm"
        let existing = Set(runtimeWorkbench.installedVMEntries.map(\.vmName))
        if !existing.contains(base) {
            return base
        }
        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    private func scrollToIntegratedConsole(_ scrollProxy: ScrollViewProxy) {
        if a11yReduceMotion {
            scrollProxy.scrollTo(Self.integratedConsoleSectionID, anchor: .top)
        } else {
            withAnimation {
                scrollProxy.scrollTo(Self.integratedConsoleSectionID, anchor: .top)
            }
        }
    }

    private func vmManagementSectionView(scrollProxy: ScrollViewProxy) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("VM Management")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 8) {
                    Button("Open VM Log") {
                        Task {
                            presentInfo("Opening VM debug log...")
                            await openDebugTraceLog()
                        }
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())

                    Button("Create New VM") {
                        isCreatingVM = true
                        statusMessage = "Creating VM..."
                        presentInfo("Creating VM scaffold...")
                        Task {
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
                            presentInfo(statusMessage)
                            isCreatingVM = false
                        }
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
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
                        Text(statusMessage.contains("Error") ? "Error: \(statusMessage)" : "Status: \(statusMessage)")
                            .font(.caption)
                            .foregroundColor(statusMessage.contains("Error") ? .red : .green)
                            .accessibilityLabel(statusMessage.contains("Error") ? "Error status" : "Status")
                            .accessibilityValue(statusMessage)
                    }

                    let hasManagedVM = !runtimeWorkbench.installedVMEntries.isEmpty
                    let canRemoveVM = hasManagedVM || runtimeWorkbench.hasDownloadedInstallers
                    Spacer()
                        .frame(height: 8)
                    if hasManagedVM {
                        HStack(alignment: .top, spacing: 12) {
                            Picker("Installed OS", selection: $selectedInstalledVMID) {
                                ForEach(runtimeWorkbench.installedVMEntries) { entry in
                                    Text("\(entry.distribution.rawValue) • \(entry.vmName)")
                                        .tag(Optional(entry.id))
                                }
                            }
                            .modifier(WhiteOutlinedControl())
                            .onChange(of: selectedInstalledVMID) { _, selectedID in
                                Task {
                                    await runtimeWorkbench.selectManagedVM(selectedID)
                                }
                            }
                            .frame(minWidth: 320, maxWidth: 420, alignment: .leading)

                            HStack(spacing: 8) {
                                Button("Start VM") {
                                    Task {
                                        presentInfo("Starting VM...")
                                        await runtimeWorkbench.selectManagedVM(selectedInstalledVMID)
                                        if let selectedID = selectedInstalledVMID,
                                           let entry = runtimeWorkbench.installedVMEntries.first(where: { $0.id == selectedID }),
                                           requiresQEMURuntimeProbe(entry.runtimeEngine) {
                                            let qemuReady = await runtimeWorkbench.probeQEMUAvailability(for: entry.architecture)
                                            if !qemuReady {
                                                presentError(runtimeWorkbench.qemuRuntimeStatusMessage)
                                                return
                                            }
                                        }
                                        await runtimeWorkbench.startActiveVM()
                                        if runtimeWorkbench.vmRuntimeState == .running,
                                           let vmID = runtimeWorkbench.activeVMID ?? runtimeWorkbench.lastManagedVMID {
                                            await MainActor.run {
                                                if useDetachedConsoleWindow {
                                                    _ = VMConsoleWindowManager.shared.focusConsole(vmID: vmID)
                                                } else {
                                                    VMConsoleWindowManager.shared.closeConsoleWindowIfPresent(vmID: vmID)
                                                    if VMConsoleWindowManager.shared.embeddedConsoleContainer(vmID: vmID) == nil {
                                                        _ = VMConsoleWindowManager.shared.focusConsole(vmID: vmID)
                                                    }
                                                    consoleRefreshToken = UUID()
                                                    scrollToIntegratedConsole(scrollProxy)
                                                }
                                            }
                                        }
                                        presentInfo(runtimeWorkbench.vmRuntimeStatusMessage)
                                    }
                                }
                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                .disabled(!hasManagedVM || isCreatingVM)

                                Button("Stop VM") {
                                    Task {
                                        presentInfo("Stopping VM...")
                                        await runtimeWorkbench.selectManagedVM(selectedInstalledVMID)
                                        await runtimeWorkbench.stopActiveVM()
                                        if let vmID = runtimeWorkbench.activeVMID ?? runtimeWorkbench.lastManagedVMID {
                                            await MainActor.run {
                                                VMConsoleWindowManager.shared.closeConsoleWindowIfPresent(vmID: vmID)
                                                consoleRefreshToken = UUID()
                                            }
                                        }
                                        presentInfo(runtimeWorkbench.vmRuntimeStatusMessage)
                                    }
                                }
                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                .disabled(!hasManagedVM || isCreatingVM)

                                Button("Restart VM") {
                                    Task {
                                        presentInfo("Restarting VM...")
                                        await runtimeWorkbench.selectManagedVM(selectedInstalledVMID)
                                        await runtimeWorkbench.restartActiveVM()
                                        if runtimeWorkbench.vmRuntimeState == .running,
                                           let vmID = runtimeWorkbench.activeVMID ?? runtimeWorkbench.lastManagedVMID {
                                            await MainActor.run {
                                                if useDetachedConsoleWindow {
                                                    _ = VMConsoleWindowManager.shared.focusConsole(vmID: vmID)
                                                } else {
                                                    VMConsoleWindowManager.shared.closeConsoleWindowIfPresent(vmID: vmID)
                                                    if VMConsoleWindowManager.shared.embeddedConsoleContainer(vmID: vmID) == nil {
                                                        _ = VMConsoleWindowManager.shared.focusConsole(vmID: vmID)
                                                    }
                                                    consoleRefreshToken = UUID()
                                                }
                                            }
                                        }
                                        presentInfo(runtimeWorkbench.vmRuntimeStatusMessage)
                                    }
                                }
                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                .disabled(!hasManagedVM || isCreatingVM)
                            }
                        }
                    }

                    Spacer()
                        .frame(height: 8)

                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(height: 3)
                        .padding(.horizontal, 8)

                    Spacer()
                        .frame(height: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Remove Type", selection: $selectedRemovalMode) {
                            ForEach(RemovalMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .modifier(WhiteOutlinedControl())

                        if selectedRemovalMode == .installedVM {
                            Picker("Installed VM", selection: $selectedInstalledVMID) {
                                ForEach(runtimeWorkbench.installedVMEntries) { entry in
                                    Text("\(entry.distribution.rawValue) • \(entry.vmName)")
                                        .tag(Optional(entry.id))
                                }
                            }
                            .modifier(WhiteOutlinedControl())
                        } else {
                            Picker("Downloaded Installer", selection: $selectedRemovalDistribution) {
                                ForEach(LinuxDistribution.allCases.filter { downloadedInstallerByDistribution[$0] != nil }) { distribution in
                                    Text(distribution.rawValue).tag(Optional(distribution))
                                }
                            }
                            .modifier(WhiteOutlinedControl())
                        }

                        Button("Remove Selected") {
                            Task {
                                await removeSelectedResource()
                            }
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .disabled(
                            isCreatingVM
                                || !canRemoveVM
                                || (selectedRemovalMode == .installedVM && selectedInstalledVMID == nil)
                                || (selectedRemovalMode == .downloadedInstaller && selectedRemovalDistribution == nil)
                        )
                    }
                }
            }
            .modifier(GlassCardStyle(borderColor: sectionBorderColor))
        }
    }

    private var integratedConsoleSectionView: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Integrated Console")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityAddTraits(.isHeader)
                Text("Use this panel for one-window operation. Turn off detached mode to keep VM inside the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Toggle("Detached Console (Advanced)", isOn: $useDetachedConsoleWindow)
                        .toggleStyle(.switch)
                        .onChange(of: useDetachedConsoleWindow) { _, useDetached in
                            guard let vmID = managedVMID else { return }
                            if !useDetached {
                                VMConsoleWindowManager.shared.closeConsoleWindowIfPresent(vmID: vmID)
                                consoleRefreshToken = UUID()
                            } else {
                                openDetachedConsole(vmID: vmID)
                            }
                        }

                    Toggle("Show Runtime Info", isOn: $showConsoleRuntimeInfo)
                        .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Console Controls")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Click inside the VM display to capture keyboard/mouse. Press Control + Option to release.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let vmID = managedVMID {
                        HStack {
                            Button("Refresh Embedded Console") {
                                consoleRefreshToken = UUID()
                            }
                            .buttonStyle(RedTextWhiteOutlineButtonStyle())
                            .disabled(useDetachedConsoleWindow)

                            Button("Open Detached Console") {
                                openDetachedConsole(vmID: vmID)
                            }
                            .buttonStyle(RedTextWhiteOutlineButtonStyle())
                        }
                    }

                    if showConsoleRuntimeInfo {
                        let runtimeStatus = runtimeWorkbench.vmRuntimeStatusMessage
                        let integrationStatus = runtimeWorkbench.integrationStatusMessage
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Runtime: " + runtimeStatus)
                                .font(.caption)
                            if !integrationStatus.isEmpty {
                                Text("Integration: " + integrationStatus)
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }

                Group {
                    if useDetachedConsoleWindow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detached mode is enabled.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Use “Open Detached Console” to show VM display in a separate window.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let vmID = managedVMID {
                        IntegratedConsoleContainer(vmID: vmID, refreshToken: consoleRefreshToken)
                            .frame(maxWidth: .infinity, minHeight: isConsoleExpanded ? 640 : 360)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    isConsoleExpanded.toggle()
                                } label: {
                                    Image(systemName: isConsoleExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                        .font(.caption)
                                }
                                .buttonStyle(RedTextWhiteOutlineButtonStyle())
                                .accessibilityLabel(isConsoleExpanded ? "Minimize integrated console" : "Expand integrated console")
                                .accessibilityHint("Toggles the embedded console size.")
                                .padding(8)
                            }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No managed VM selected.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Create or install a VM, then click Start VM to render the integrated console here.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .modifier(GlassCardStyle(borderColor: sectionBorderColor))
        }
        .id(Self.integratedConsoleSectionID)
    }

    private var vmConfigurationSectionView: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("VM Configuration")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityAddTraits(.isHeader)

                Text("Use this section for custom Linux installers not listed in OS Catalog.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Custom OS Catalog Name", text: $customCatalogName)
                        .modifier(WhiteOutlinedControl())
                    TextField("VM Name", text: $vmName)
                        .modifier(WhiteOutlinedControl())

                    HStack {
                        TextField("Installer Image Path (ISO)", text: $installerImagePath)
                            .modifier(WhiteOutlinedControl())
                        Button("Browse") {
                            showFilePicker = true
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    }

                    Picker("Architecture", selection: $selectedArchitecture) {
                        Text("Apple Silicon").tag(HostArchitecture.appleSilicon)
                        Text("Intel").tag(HostArchitecture.intel)
                    }
                    .modifier(WhiteOutlinedControl())
                    Picker("Distribution", selection: $selectedCatalogDistribution) {
                        Text("Ubuntu").tag(LinuxDistribution.ubuntu)
                        Text("Fedora").tag(LinuxDistribution.fedora)
                        Text("Debian").tag(LinuxDistribution.debian)
                        Text("Pop!_OS").tag(LinuxDistribution.popOS)
                        Text("NixOS").tag(LinuxDistribution.nixOS)
                        Text("openSUSE").tag(LinuxDistribution.openSUSE)
                    }
                    .modifier(WhiteOutlinedControl())
                    Button("Use Unlisted/Other ISO (Generic Linux Profile)") {
                        selectedCatalogDistribution = .ubuntu
                        selectedRuntimeEngine = .appleVirtualization
                        presentInfo("Using generic Linux profile for unlisted ISO. You can still add it to OS Catalog and install from your selected ISO path.")
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    Picker("Runtime Engine", selection: $selectedRuntimeEngine) {
                        if selectedCatalogDistribution == .windows11 {
                            Text("Windows Dedicated Runtime").tag(RuntimeEngine.windowsDedicated)
                            Text("QEMU Fallback").tag(RuntimeEngine.qemuFallback)
                        } else {
                            Text("Apple Virtualization").tag(RuntimeEngine.appleVirtualization)
                            Text("QEMU Fallback").tag(RuntimeEngine.qemuFallback)
                        }
                    }
                    .modifier(WhiteOutlinedControl())
                    if requiresQEMURuntimeProbe(selectedRuntimeEngine) {
                        Text(runtimeWorkbench.qemuRuntimeStatusMessage.isEmpty ? "QEMU status: checking..." : runtimeWorkbench.qemuRuntimeStatusMessage)
                            .font(.caption)
                            .foregroundColor((runtimeWorkbench.isQEMUAvailable ?? false) ? .green : .orange)
                    }

                    HStack {
                        Button("Probe ISO Metadata") {
                            probeInstallerMetadata()
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                        .disabled(!isLocalISOPath(installerImagePath))

                        Button(editingCustomEntryID == nil ? "Add To OS Catalog" : "Save Custom Entry") {
                            addOrUpdateCustomCatalogEntry()
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                        .disabled(!isLocalISOPath(installerImagePath) || customCatalogName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if editingCustomEntryID != nil {
                            Button("Cancel Edit") {
                                clearCustomCatalogEditor()
                            }
                            .buttonStyle(RedTextWhiteOutlineButtonStyle())
                        }
                    }

                    HStack {
                        Button("Export Team Catalog") {
                            exportTeamCatalog()
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())

                        Button("Import Team Catalog") {
                            importTeamCatalog()
                        }
                        .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    }
                }
                .textFieldStyle(.roundedBorder)
                .modifier(ThinRedInputOutline(isEnabled: !useNativeMaterialStyle))
            }
            .modifier(GlassCardStyle(borderColor: sectionBorderColor))
        }
    }

    private var supportSectionView: some View {
        Section {
            VStack(alignment: .center, spacing: 12) {
                Text("Support")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    Picker("Theme", selection: $appearanceModeRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .modifier(WhiteOutlinedControl())

                    Picker("Visual Style", selection: $visualStyleModeRaw) {
                        ForEach(VisualStyleMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .modifier(WhiteOutlinedControl())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Light Intensity")
                            Spacer()
                            Text(lightIntensityText)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $lightIntensity, in: 0.70...1.30, step: 0.01)
                        Text("Lower value dims the interface; higher value brightens it.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility Options")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Toggle("Reduce motion animations", isOn: $a11yReduceMotion)
                    Toggle("Larger controls", isOn: $a11yLargeControls)
                    Text("Required accessibility semantics remain enabled at all times.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 420, alignment: .leading)

                VStack(alignment: .center, spacing: 8) {
                    Button("Run Health Check") {
                        Task {
                            presentInfo("Running health check...")
                            await runtimeWorkbench.runHealthCheck()
                            let message = runtimeWorkbench.healthStatusMessage
                            presentInfo(message)
                        }
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    .frame(maxWidth: 260)

                    Button("Run Integration Validation") {
                        Task {
                            presentInfo("Running integration validation...")
                            await runtimeWorkbench.runHealthCheck()

                            let report = runtimeWorkbench.healthReport
                            let failedLines = report.filter { line in
                                line.localizedCaseInsensitiveContains("FAIL")
                                    || line.localizedCaseInsensitiveContains("ERROR")
                            }
                            let hasFailures = !failedLines.isEmpty

                            let summary = hasFailures
                                ? "Integration validation completed with failures. Review Health Report for FAIL entries."
                                : "Integration validation completed successfully. All checks passed."

                            if hasFailures {
                                traceVM("Integration validation FAIL. \(failedLines.count) failing checks.")
                                for line in failedLines {
                                    traceVM("Integration validation detail: \(line)")
                                }
                            } else {
                                traceVM("Integration validation PASS. \(report.count) checks evaluated.")
                            }

                            presentInfo(summary)
                        }
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    .frame(maxWidth: 260)

                    Button("Apply Auto-Heal") {
                        Task {
                            presentInfo("Applying auto-heal...")
                            await runtimeWorkbench.applyAutoHeal()
                            let message = runtimeWorkbench.healthStatusMessage
                            presentInfo(message)
                        }
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    .frame(maxWidth: 260)

                    Button("Report Issue") {
                        prepareReportIssueDraftIfNeeded()
                        showReportIssueSheet = true
                    }
                    .buttonStyle(RedTextWhiteOutlineButtonStyle())
                    .frame(maxWidth: 260)
                }

                if !runtimeWorkbench.healthStatusMessage.isEmpty {
                    let healthMessage = runtimeWorkbench.healthStatusMessage
                    let isHealthWarning = healthMessage.localizedCaseInsensitiveContains("failed")
                    let healthDisplay = isHealthWarning ? "Warning: " + healthMessage : "Status: " + healthMessage
                    Text(healthDisplay)
                        .font(.caption)
                        .foregroundColor(isHealthWarning ? .red : .secondary)
                        .accessibilityLabel(isHealthWarning ? "Health warning" : "Health status")
                        .accessibilityValue(healthMessage)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        Text("Health Report")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityAddTraits(.isHeader)
                        HStack {
                            Spacer()
                            Button("Copy Health Report") {
                                let text = runtimeWorkbench.healthReport.joined(separator: "\n")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                presentInfo(text.isEmpty ? "No health report lines to copy." : "Health report copied to clipboard.")
                            }
                            .buttonStyle(RedTextWhiteOutlineButtonStyle())
                            .disabled(runtimeWorkbench.healthReport.isEmpty)
                        }
                    }

                    if runtimeWorkbench.healthReport.isEmpty {
                        Text("No health report available yet. Run Health Check first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        TextEditor(text: .constant(runtimeWorkbench.healthReport.joined(separator: "\n")))
                            .font(.caption.monospaced())
                            .frame(minHeight: 140)
                            .textSelection(.enabled)
                            .accessibilityLabel("Health report details")
                            .accessibilityHint("Selectable diagnostic report text.")
                    }
                }
            }
            .modifier(GlassCardStyle(borderColor: sectionBorderColor))
        }
    }

    private func prepareReportIssueDraftIfNeeded() {
        if reportGitHubToken.isEmpty {
            reportGitHubToken = runtimeWorkbench.loadStoredGitHubToken()
        }

        if reportIssueTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reportIssueTitle = "ML Integration issue report"
        }

        if reportIssueDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reportIssueDetails = "Describe what happened, expected behavior, and exact steps to reproduce."
        }
    }

    private func composedReportIssueDetails() -> String {
        var lines: [String] = []
        lines.append(reportIssueDetails.trimmingCharacters(in: .whitespacesAndNewlines))

        if reportConsentRuntimeStatus {
            lines.append("")
            lines.append("Runtime status: \(runtimeWorkbench.vmRuntimeStatusMessage)")
            lines.append("Integration status: \(runtimeWorkbench.integrationStatusMessage)")
            lines.append("Health status: \(runtimeWorkbench.healthStatusMessage)")
            lines.append("VM status: \(runtimeWorkbench.vmStatusMessage)")
        }

        if reportConsentHostProfile, let profile = runtimeWorkbench.hostProfile {
            lines.append("")
            lines.append("Host profile:")
            lines.append("- Architecture: \(profile.architecture.rawValue)")
            lines.append("- CPU cores: \(profile.cpuCores)")
            lines.append("- Memory (GB): \(profile.memoryGB)")
            lines.append("- macOS version: \(profile.macOSVersion)")
        }

        return lines.joined(separator: "\n")
    }

    private func submitIssueReport() async {
        if reportGitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reportGitHubToken = runtimeWorkbench.loadStoredGitHubToken()
        }

        let details = composedReportIssueDetails()
        let hasToken = !reportGitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasToken {
            await runtimeWorkbench.escalateToDevelopers(
                issueTitle: reportIssueTitle,
                issueDetails: details,
                githubOwner: supportGitHubOwner,
                githubRepository: supportGitHubRepository,
                githubToken: reportGitHubToken,
                supportEmail: "",
                sendGitHubIssue: true,
                sendEmail: false,
                includeDiagnostics: reportConsentDiagnostics
            )

            let status = runtimeWorkbench.escalationStatusMessage
            if let issueURL = runtimeWorkbench.lastEscalationIssueURL {
                NSWorkspace.shared.open(issueURL)
                presentInfo(status)
                showReportIssueSheet = false
            } else {
                presentError(status.isEmpty ? "Issue reporting failed." : status)
            }
            return
        }

        await openFallbackBrowserIssue(title: reportIssueTitle, details: details)
    }

    private func openFallbackBrowserIssue(title: String, details: String) async {
        var finalDetails = details
        var diagnosticsPath: String?

        if reportConsentDiagnostics {
            do {
                let diagnosticsURL = try runtimeWorkbench.createIssueDiagnosticsBundle(title: title, details: details)
                diagnosticsPath = diagnosticsURL.path
                finalDetails += "\n\nDiagnostics bundle created at:\n\(diagnosticsURL.path)\nPlease attach this file to the GitHub issue."
            } catch {
                finalDetails += "\n\nDiagnostics bundle creation failed: \(error.localizedDescription)"
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalDetails, forType: .string)

        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://github.com/\(supportGitHubOwner)/\(supportGitHubRepository)/issues/new?title=\(encodedTitle)"

        guard let issueURL = URL(string: urlString) else {
            presentError("Could not build GitHub issue URL.")
            return
        }

        let opened = NSWorkspace.shared.open(issueURL)
        guard opened else {
            presentError("Could not open GitHub issue page in browser.")
            return
        }

        if let diagnosticsPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: diagnosticsPath)])
            presentInfo("GitHub issue page opened. Issue details were copied to clipboard and diagnostics file is selected in Finder.")
        } else {
            presentInfo("GitHub issue page opened. Issue details were copied to clipboard.")
        }
        showReportIssueSheet = false
    }

    private func addOrUpdateCustomCatalogEntry() {
        do {
            if let id = editingCustomEntryID {
                try runtimeWorkbench.updateCustomCatalogEntry(
                    id: id,
                    displayName: customCatalogName,
                    installerPath: installerImagePath,
                    architecture: selectedArchitecture,
                    runtimeEngine: selectedRuntimeEngine,
                    baseDistribution: selectedCatalogDistribution
                )
                presentInfo("Updated \(customCatalogName) in OS Catalog.")
            } else {
                try runtimeWorkbench.addCustomCatalogEntry(
                    displayName: customCatalogName,
                    installerPath: installerImagePath,
                    architecture: selectedArchitecture,
                    runtimeEngine: selectedRuntimeEngine,
                    baseDistribution: selectedCatalogDistribution
                )
                presentInfo("Added \(customCatalogName) to OS Catalog.")
            }
            clearCustomCatalogEditor()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func removeCustomCatalogEntry(_ id: UUID) {
        do {
            try runtimeWorkbench.removeCustomCatalogEntry(id: id)
            presentInfo("Removed custom OS entry.")
            if editingCustomEntryID == id {
                clearCustomCatalogEditor()
            }
        } catch {
            presentError("Failed to remove custom entry: \(error.localizedDescription)")
        }
    }

    private func beginEditingCustomCatalogEntry(_ entry: CustomCatalogEntry) {
        editingCustomEntryID = entry.id
        customCatalogName = entry.displayName
        installerImagePath = entry.installerPath
        selectedArchitecture = entry.architecture
        selectedRuntimeEngine = entry.runtimeEngine
        selectedCatalogDistribution = entry.baseDistribution
        manuallySelectedInstallerDistribution = entry.baseDistribution
    }

    private func clearCustomCatalogEditor() {
        editingCustomEntryID = nil
        customCatalogName = ""
    }

    private func installCustomCatalogEntry(_ entry: CustomCatalogEntry) async {
        guard runtimeWorkbench.validateCustomInstallerPath(entry.installerPath) else {
            presentError("Custom entry installer path is missing or invalid. Update the entry with a valid ISO.")
            return
        }

        isCreatingVM = true
        defer { isCreatingVM = false }
        statusMessage = "Installing \(entry.displayName)..."

        await runtimeWorkbench.scaffoldInstall(
            distribution: entry.baseDistribution,
            architecture: entry.architecture,
            runtime: entry.runtimeEngine,
            vmName: makeCustomVMName(from: entry.displayName),
            installerImagePath: entry.installerPath,
            kernelImagePath: "",
            initialRamdiskPath: ""
        )

        if runtimeWorkbench.installLifecycleState == .ready {
            selectedInstalledVMID = runtimeWorkbench.activeVMID
            presentInfo("\(entry.displayName) installed and scaffolded.")
        } else {
            presentError(runtimeWorkbench.vmStatusMessage)
        }
    }

    private func makeCustomVMName(from displayName: String) -> String {
        let compact = displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "!", with: "")
        let base = compact.isEmpty ? "custom-linux-vm" : "\(compact)-vm"
        let existing = Set(runtimeWorkbench.installedVMEntries.map(\.vmName))
        if !existing.contains(base) {
            return base
        }
        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    private func probeInstallerMetadata() {
        guard isLocalISOPath(installerImagePath) else {
            presentError("Pick a valid ISO file first.")
            return
        }
        if let suggested = runtimeWorkbench.suggestedDistributionForInstaller(installerImagePath) {
            selectedCatalogDistribution = suggested
            presentInfo("ISO probe suggested distribution: \(suggested.rawValue).")
        } else {
            presentInfo("ISO probe could not confidently determine a distribution. Keep your selected distribution.")
        }
    }

    private func exportTeamCatalog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mlintegration-custom-os-catalog.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try runtimeWorkbench.exportCustomCatalog(to: url)
            presentInfo("Exported custom OS catalog to \(url.path).")
        } catch {
            presentError("Failed to export custom OS catalog: \(error.localizedDescription)")
        }
    }

    private func importTeamCatalog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try runtimeWorkbench.importCustomCatalog(from: url, merge: true)
            presentInfo("Imported custom OS catalog from \(url.lastPathComponent).")
        } catch {
            presentError("Failed to import custom OS catalog: \(error.localizedDescription)")
        }
    }

    private func handleFileImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let managedPath = try importInstallerIntoManagedDownloads(
                    distribution: selectedCatalogDistribution,
                    sourceURL: url
                )
                installerImagePath = managedPath
                manuallySelectedInstallerDistribution = selectedCatalogDistribution
                downloadedInstallerByDistribution[selectedCatalogDistribution] = managedPath
                runtimeWorkbench.refreshDownloadedInstallerPresence()
                statusMessage = "Selected and imported installer: \(URL(fileURLWithPath: managedPath).lastPathComponent)"

                if selectedCatalogDistribution == .windows11 {
                    Task {
                        await installDownloadedDistribution(.windows11)
                        if !statusMessage.isEmpty {
                            await MainActor.run {
                                presentInfo(statusMessage)
                            }
                        }
                    }
                }
            } catch {
                statusMessage = "Could not import installer into app downloads folder: \(error.localizedDescription)"
                presentError(statusMessage)
            }
        case .failure(let error):
            statusMessage = "File selection error: \(error.localizedDescription)"
            presentError(statusMessage)
        }
    }

    @MainActor
    private func presentError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.localizedCaseInsensitiveContains("qemu-system-aarch64")
            || trimmed.localizedCaseInsensitiveContains("qemu fallback hook")
            || trimmed.localizedCaseInsensitiveContains("install qemu")
        {
            qemuSetupAlertMessage = trimmed
            showQEMUSetupAlert = true
            return
        }
        if trimmed.localizedCaseInsensitiveContains("windows 11 cannot be launched reliably")
            || trimmed.localizedCaseInsensitiveContains("windows-capable external runtime path")
        {
            windowsRuntimeAlertMessage = trimmed
            showWindowsRuntimePathAlert = true
            return
        }
        actionAlertTitle = "Action Failed"
        actionAlertMessage = trimmed
        if showActionAlert {
            showActionAlert = false
            DispatchQueue.main.async {
                showActionAlert = true
            }
        } else {
            showActionAlert = true
        }
    }

    @MainActor
    private func presentInfo(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actionAlertTitle = "Status"
        actionAlertMessage = trimmed
        if showActionAlert {
            showActionAlert = false
            DispatchQueue.main.async {
                showActionAlert = true
            }
        } else {
            showActionAlert = true
        }
    }

    @MainActor
    private func openDetachedConsole(vmID: UUID) {
        traceVM(
            "UI openDetachedConsole requested vmID=\(vmID.uuidString) " +
            "runtimeState=\(runtimeWorkbench.vmRuntimeState.rawValue)"
        )
        let focused = VMConsoleWindowManager.shared.focusConsole(vmID: vmID)
        if focused {
            traceVM("UI openDetachedConsole focused vmID=\(vmID.uuidString)")
            presentInfo("Detached console opened.")
            return
        }

        let message: String
        if runtimeWorkbench.vmRuntimeState == .running || runtimeWorkbench.vmRuntimeState == .starting {
            message = "Detached console session is unavailable right now. Restart VM and try again."
        } else {
            message = "Start VM first, then open detached console."
        }
        traceVM("UI openDetachedConsole unavailable vmID=\(vmID.uuidString) message=\(message)")
        presentError(message)
    }

    private func openDebugTraceLog() async {
        let logPath = await DebugTraceLogger.shared.path()
        let logURL = URL(fileURLWithPath: logPath)

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: Data())
            }

            if NSWorkspace.shared.open(logURL) {
                statusMessage = "Opened VM debug log: \(logPath)"
            } else {
                statusMessage = "Could not open VM debug log: \(logPath)"
                presentError(statusMessage)
            }
        } catch {
            statusMessage = "Failed to prepare VM debug log: \(error.localizedDescription)"
            presentError(statusMessage)
        }
    }
}

struct IntegratedConsoleContainer: NSViewRepresentable {
    let vmID: UUID
    let refreshToken: UUID

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = VMConsoleWindowManager.shared.embeddedConsoleContainer(vmID: vmID) else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        if container.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            container.removeFromSuperview()
            container.frame = nsView.bounds
            container.autoresizingMask = [.width, .height]
            nsView.addSubview(container)
        } else {
            container.frame = nsView.bounds
        }

        _ = refreshToken
    }
}

private struct RedTextWhiteOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.01))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct GlassCardStyle: ViewModifier {
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                    .padding(1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
    }
}

private struct WhiteOutlinedControl: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white, lineWidth: 1)
            )
    }
}

private struct ThinRedInputOutline: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
            )
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
}
