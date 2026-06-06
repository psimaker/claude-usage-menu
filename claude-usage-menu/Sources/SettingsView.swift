import SwiftUI
import AppKit
import UserNotifications

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService

    // Live slider positions. Committed to the manager only when the drag ends,
    // so a gesture produces one persisted write + one menu-bar re-render instead
    // of one per step. The label reads these so the number still moves live.
    @State private var warningEdit: Double = 80
    @State private var criticalEdit: Double = 90
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined

    private var settings: AppSettings { settingsManager.settings }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                authSection
                menuBarSection
                notificationsSection
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 380)
        .frame(minHeight: 420)
        .onAppear {
            warningEdit = settings.warningThreshold
            criticalEdit = settings.criticalThreshold
            refreshNotifAuthStatus()
        }
    }

    // MARK: Sections

    private var authSection: some View {
        Section("Auth") {
            HStack {
                Image(systemName: authIcon)
                    .foregroundColor(authColor)
                Text(authText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(authBadge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(authColor.opacity(0.18))
                    .cornerRadius(4)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var menuBarSection: some View {
        Section("Menu Bar") {
            Toggle("Compact mode (45% · 78%)", isOn: binding(\.compactDisplay))
            Text(settings.compactDisplay
                 ? "Both percentages shown inline."
                 : "Labeled “5h Limit” and “Weekly Limit” columns.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Enable usage alerts", isOn: binding(\.notificationsEnabled))
                .onChange(of: settings.notificationsEnabled) { enabled in
                    if enabled { ensureNotificationAuthorization() }
                }

            if settings.notificationsEnabled && notifAuthStatus == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Notifications are turned off in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Open Settings") { openNotificationSettings() }
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading) {
                Text("Warning threshold: \(Int(warningEdit))%")
                // Persist on every value change (not just drag-end) so keyboard
                // and VoiceOver adjustments are saved too. commitWarning() also
                // clamps live, keeping the two labels consistent mid-drag.
                Slider(value: $warningEdit, in: 50...95, step: 5)
                    .onChange(of: warningEdit) { _ in commitWarning() }
                    .accessibilityValue("\(Int(warningEdit)) percent")
            }

            VStack(alignment: .leading) {
                Text("Critical threshold: \(Int(criticalEdit))%")
                Slider(value: $criticalEdit, in: 60...100, step: 5)
                    .onChange(of: criticalEdit) { _ in commitCritical() }
                    .accessibilityValue("\(Int(criticalEdit)) percent")
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.pie.fill")
                .font(.title)
                .foregroundColor(.blue)
            Text("Claude Usage Menu")
                .font(.headline)
            Spacer()
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
            Button("Reset to Defaults", role: .destructive) { resetToDefaults() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Auth row state

    // When the auth state is still .unknown but a fetch has already failed, the
    // row reflects that failure instead of claiming an in-progress check forever.
    private var authUnknownFailed: Bool {
        usageService.authState == .unknown && usageService.error != nil
    }

    private var authIcon: String {
        switch usageService.authState {
        case .ok: return "lock.fill"
        case .unknown: return authUnknownFailed ? "exclamationmark.triangle.fill" : "lock.fill"
        case .signedOut: return "lock.slash.fill"
        case .expired: return "exclamationmark.triangle.fill"
        }
    }

    private var authColor: Color {
        switch usageService.authState {
        case .ok: return .green
        case .unknown: return authUnknownFailed ? .orange : .secondary
        case .signedOut: return .red
        case .expired: return .orange
        }
    }

    private var authText: String {
        switch usageService.authState {
        case .ok: return "Using Claude Code OAuth token"
        case .unknown:
            if let err = usageService.error { return "Can't verify credentials — \(err)" }
            return "Checking Claude Code credentials…"
        case .signedOut: return "Not signed in — open Claude Code and log in"
        case .expired: return "Sign-in expired — refreshing credentials"
        }
    }

    private var authBadge: String {
        switch usageService.authState {
        case .ok: return "Auto"
        case .unknown: return authUnknownFailed ? "?" : "…"
        case .signedOut: return "Signed out"
        case .expired: return "Expired"
        }
    }

    // MARK: Bindings & commits

    /// A two-way binding straight into the source of truth, so controls never
    /// drift from the persisted settings.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settingsManager.settings[keyPath: keyPath] },
            set: { settingsManager.settings[keyPath: keyPath] = $0 }
        )
    }

    /// Commit the warning threshold, keeping warning ≤ critical so the displayed
    /// values always match the effective (used) thresholds.
    private func commitWarning() {
        settingsManager.setWarningThreshold(warningEdit)
        if criticalEdit < warningEdit {
            criticalEdit = warningEdit
            settingsManager.setCriticalThreshold(warningEdit)
        }
    }

    private func commitCritical() {
        settingsManager.setCriticalThreshold(criticalEdit)
        if warningEdit > criticalEdit {
            warningEdit = criticalEdit
            settingsManager.setWarningThreshold(criticalEdit)
        }
    }

    private func resetToDefaults() {
        settingsManager.resetToDefaults()
        warningEdit = settingsManager.settings.warningThreshold
        criticalEdit = settingsManager.settings.criticalThreshold
    }

    // MARK: Notification authorization

    private func refreshNotifAuthStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notifAuthStatus = settings.authorizationStatus }
        }
    }

    /// When alerts are switched on: prompt if the user hasn't decided yet, and
    /// otherwise refresh the known status so a denied state surfaces the warning.
    private func ensureNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                notifAuthStatus = settings.authorizationStatus
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                        refreshNotifAuthStatus()
                    }
                }
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
