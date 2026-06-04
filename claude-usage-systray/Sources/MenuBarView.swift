import SwiftUI

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var showSettings = false
    @State private var now = Date()

    // Drives the live "resets in …" / "updated … ago" countdowns while open.
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var snapshot: UsageSnapshot { usageService.currentUsage }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageSection

            Divider().padding(.vertical, 4)

            actionButtons

            Divider().padding(.vertical, 4)

            quitButton
        }
        .padding(.vertical, 8)
        .frame(minWidth: 250)
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsManager: settingsManager, usageService: usageService)
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            limitRow(icon: "clock", title: "5h Limit",
                     percent: snapshot.fiveHourUtilization,
                     resetAt: snapshot.fiveHourResetAt)

            limitRow(icon: "calendar", title: "Weekly Limit",
                     percent: snapshot.sevenDayUtilization,
                     resetAt: snapshot.sevenDayResetAt)

            if let sonnet = snapshot.sevenDaySonnetUtilization {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.caption2).foregroundColor(.blue)
                    Text("Sonnet (weekly)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(sonnet)%").font(.caption).monospacedDigit().foregroundColor(.secondary)
                }
            }

            statusLine
        }
        .padding(.horizontal, 12)
    }

    private func limitRow(icon: String, title: String, percent: Int, resetAt: Date?) -> some View {
        let hasData = snapshot.hasData
        let clamped = Double(min(max(percent, 0), 100))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(hasData ? color(for: percent) : .secondary)
                    .font(.system(size: 12))
                Text(title).fontWeight(.medium)
                Spacer()
                Text(hasData ? "\(percent)%" : "—")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(hasData ? color(for: percent) : .secondary)
            }

            ProgressView(value: hasData ? clamped : 0, total: 100)
                .progressViewStyle(.linear)
                .tint(hasData ? color(for: percent) : .secondary)

            if hasData, let resetAt = resetAt {
                Text("resets in \(formatTimeRemaining(until: resetAt, from: now))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let error = usageService.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundColor(.orange)
                Text(error).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            } else if usageService.isLoading && !snapshot.hasData {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption2).foregroundColor(.secondary)
            } else if snapshot.hasData {
                Image(systemName: "checkmark.circle")
                    .font(.caption2).foregroundColor(.green)
                Text("Updated \(relativeUpdated)").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if usageService.isLoading && snapshot.hasData {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(spacing: 0) {
            actionButton(icon: "chart.bar", title: "Open Dashboard", action: openDashboard)
            actionButton(icon: "arrow.clockwise", title: "Refresh", action: refreshUsage)
            actionButton(icon: "gear", title: "Settings") { showSettings = true }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var quitButton: some View {
        Button(action: quitApp) {
            HStack {
                Image(systemName: "power").frame(width: 16)
                Text("Quit")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func color(for percent: Int) -> Color {
        let critical = Int(settingsManager.settings.effectiveCriticalThreshold)
        let warning = Int(settingsManager.settings.effectiveWarningThreshold)
        if percent >= critical { return .red }
        if percent >= warning { return .orange }
        return .primary
    }

    private var relativeUpdated: String {
        let seconds = Int(now.timeIntervalSince(snapshot.lastUpdated))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    private func openDashboard() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshUsage() {
        usageService.fetchUsage()
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
