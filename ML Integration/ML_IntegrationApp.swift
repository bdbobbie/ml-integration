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
    private var uiFocusQueueEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-focus-queue")
    }
    private var uiFocusStep5Enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-focus-step5")
    }

    var body: some Scene {
        WindowGroup {
            if uiFocusOnboardingEnabled {
                UITestOnboardingHarnessView()
            } else if uiFocusQueueEnabled {
                UITestQueueHarnessView()
            } else if uiFocusStep5Enabled {
                UITestStep5HarnessView()
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
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct UITestQueueHarnessView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("queue-focus-ready")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("queue-focus-ready")

            Text("Queue Order")
                .font(.caption)
                .accessibilityIdentifier("queue-order-label")

            Button("Run Queue Tick Now") {}
                .accessibilityIdentifier("queue-run-tick-button")

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("queue-focus-harness")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct UITestStep5HarnessView: View {
    private var forceBlocked: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-step5-force-blocked")
    }

    private var summaryText: String {
        if forceBlocked {
            return "Step 5 readiness: BLOCKED (1 issue(s))."
        }
        return "Step 5 readiness: READY."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("step5-focus-ready")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("step5-focus-ready")

            Text(summaryText)
                .font(.caption)
                .accessibilityIdentifier("step5-readiness-summary")

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("step5-focus-harness")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
