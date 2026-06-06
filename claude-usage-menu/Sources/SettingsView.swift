import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService

    // Live slider positions, persisted on every value change via commitWarning/
    // commitCritical (so keyboard and VoiceOver adjustments are saved too, not
    // just mouse drags). The labels read these so the value moves live, and the
    // commit clamps warning ≤ critical.
    @State private var warningEdit: Double = 80
    @State private var criticalEdit: Double = 90
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var launchAtLogin = false
    @State private var repoHovered = false

    private static let repositoryURL = URL(string: "https://github.com/psimaker/claude-usage-menu")!

    private var settings: AppSettings { settingsManager.settings }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                authSection
                generalSection
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
            refreshLaunchAtLogin()
        }
        // Re-read external (System Settings) state when the user returns to the
        // app, so the notification-blocked warning and the login-item toggle stay
        // correct if changed outside the app while this window stayed open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotifAuthStatus()
            refreshLaunchAtLogin()
        }
    }

    // MARK: Sections

    private var authSection: some View {
        Section("Auth") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: authIcon)
                    .foregroundColor(authColor)
                // Wrap rather than truncate: the .unknown failure case shows the
                // actual error message here, which can be long.
                Text(authText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
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

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Text("Start Claude Usage Menu automatically when you log in.")
                .font(.caption)
                .foregroundColor(.secondary)
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
                    Button("Open System Settings") { openNotificationSettings() }
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
        HStack(spacing: 10) {
            Button(action: openRepository) {
                Image("GitHubMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .foregroundColor(repoHovered ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .onHover { repoHovered = $0 }
            .help("View this project on GitHub")
            .accessibilityLabel("View this project on GitHub")

            Text("Claude Usage Menu")
                .font(.headline)
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Data from claude.ai OAuth")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(appVersion)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Reset to Defaults", role: .destructive) { resetToDefaults() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
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
        // Reset turns alerts back on; re-check/prompt authorization so we never
        // silently believe alerts work when the system would drop them.
        if settingsManager.settings.notificationsEnabled {
            ensureNotificationAuthorization()
        }
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

    private func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    // MARK: Launch at login

    private func refreshLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// Registers/unregisters the app as a login item via SMAppService (macOS 13+),
    /// then reflects the real resulting status so the toggle can't drift from
    /// reality (e.g. on failure or when approval is required in System Settings).
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Launch-at-login change failed: \(error.localizedDescription)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
