//
//  ML_IntegrationApp.swift
//  ML Integration
//
//  Created by TBDO Inc on 4/17/26.
//

import SwiftUI

@main
struct ML_IntegrationApp: App {
    private var uiFocusOnboardingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-focus-onboarding")
    }

    var body: some Scene {
        WindowGroup {
            if uiFocusOnboardingEnabled {
                UITestOnboardingHarnessView()
            } else {
                ContentView()
            }
        }
    }
}

private struct UITestOnboardingHarnessView: View {
    @State private var statusLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("onboarding-focus-ready")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("onboarding-focus-ready")

            Text("Linux App Onboarding (Step 3)")
                .font(.caption)
                .accessibilityIdentifier("onboarding-step3-header")

            Button("Run Onboarding Actions") {
                statusLines = [
                    "Started onboarding action run.",
                    "Dry run: install step skipped.",
                    "Dry run: VM runtime step skipped.",
                    "Dry run: coherence step skipped.",
                    "Dry run: launcher step skipped.",
                    "Onboarding action run finished."
                ]
            }
            .accessibilityIdentifier("onboarding-run-actions-button")

            if !statusLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLines.first ?? "")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("onboarding-status-first-line")

                    ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityIdentifier("onboarding-status-lines")
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("onboarding-focus-harness")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
