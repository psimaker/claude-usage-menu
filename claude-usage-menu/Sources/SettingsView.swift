import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss

    @State private var warningThreshold: Double = 80
    @State private var criticalThreshold: Double = 90
    @State private var notificationsEnabled: Bool = true
    @State private var compactDisplay: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("Auth") {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.green)
                        Text("Using Claude Code OAuth token")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Auto")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                Section("Menu Bar") {
                    Toggle("Compact mode (45% · 78%)", isOn: $compactDisplay)
                        .onChange(of: compactDisplay) { newValue in
                            settingsManager.setCompactDisplay(newValue)
                        }
                    Text(compactDisplay
                         ? "Both percentages shown inline."
                         : "Labeled “5h Limit” and “Weekly Limit” columns.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Notifications") {
                    Toggle("Enable usage alerts", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { newValue in
                            settingsManager.setNotificationsEnabled(newValue)
                        }

                    VStack(alignment: .leading) {
                        Text("Warning threshold: \(Int(warningThreshold))%")
                        Slider(value: $warningThreshold, in: 50...95, step: 5)
                            .onChange(of: warningThreshold) { newValue in
                                settingsManager.setWarningThreshold(newValue)
                            }
                    }

                    VStack(alignment: .leading) {
                        Text("Critical threshold: \(Int(criticalThreshold))%")
                        Slider(value: $criticalThreshold, in: 60...100, step: 5)
                            .onChange(of: criticalThreshold) { newValue in
                                settingsManager.setCriticalThreshold(newValue)
                            }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            footer
        }
        .frame(width: 360, height: 390)
        .onAppear { loadSettings() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.pie.fill")
                .font(.title)
                .foregroundColor(.blue)
            Text("Claude Usage Menu Settings")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("Data from claude.ai OAuth")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Reset to Defaults") { resetToDefaults() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func loadSettings() {
        warningThreshold = settingsManager.settings.warningThreshold
        criticalThreshold = settingsManager.settings.criticalThreshold
        notificationsEnabled = settingsManager.settings.notificationsEnabled
        compactDisplay = settingsManager.settings.compactDisplay
    }

    private func resetToDefaults() {
        settingsManager.resetToDefaults()
        loadSettings()
    }
}
