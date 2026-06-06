import SwiftUI
import Combine

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    /// Opens the standalone Settings window (owned by AppDelegate).
    var openSettings: () -> Void = {}
    /// Dismisses the popover (owned by AppDelegate).
    var dismiss: () -> Void = {}
    @State private var now = Date()

    // Drives the live "resets in …" / "updated … ago" countdowns. It's a
    // connectable publisher (no autoconnect) started only while the popover is
    // on screen, so a closed popover doesn't wake every 15s for nothing.
    private let ticker = Timer.publish(every: 15, on: .main, in: .common)
    @State private var tickerConnection: Cancellable?

    private var snapshot: UsageSnapshot { usageService.currentUsage }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageSection

            Divider().padding(.vertical, 4)

            actionButtons

            Divider().padding(.vertical, 4)

            MenuRow(icon: "power", title: "Quit", action: quitApp)
        }
        .padding(.vertical, 8)
        .frame(width: 260)
        .onReceive(ticker) { now = $0 }
        .onAppear {
            now = Date()
            tickerConnection = ticker.connect()
        }
        .onDisappear {
            tickerConnection?.cancel()
            tickerConnection = nil
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
                        .accessibilityHidden(true)
                    Text("Sonnet (weekly)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(displayPercent(sonnet))%").font(.caption).monospacedDigit().foregroundColor(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sonnet weekly usage")
                .accessibilityValue("\(displayPercent(sonnet)) percent used")
            }

            if showsStatusLine {
                statusLine
            }
        }
        .padding(.horizontal, 12)
    }

    private func limitRow(icon: String, title: String, percent: Int, resetAt: Date?) -> some View {
        let hasData = snapshot.hasData
        let shown = displayPercent(percent)
        let level = self.level(percent)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(hasData ? color(for: level) : .secondary)
                    .font(.system(size: 12))
                Text(title).fontWeight(.medium)
                Spacer()
                // Redundant, non-color cue for warning/critical so the state is
                // distinguishable without relying on color alone.
                if hasData, let symbol = levelSymbol(level) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundColor(color(for: level))
                }
                Text(hasData ? "\(shown)%" : "—")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(hasData ? color(for: level) : .secondary)
            }

            ProgressView(value: hasData ? Double(shown) : 0, total: 100)
                .progressViewStyle(.linear)
                .tint(hasData ? color(for: level) : .secondary)

            if hasData, let resetAt = resetAt {
                Text(resetCaption(until: resetAt, from: now))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        // Announce each row as one VoiceOver element with the full state, since
        // a bare ProgressView would otherwise read as context-less progress.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(rowAccessibilityValue(hasData: hasData, percent: shown, level: level, resetAt: resetAt))
    }

    // The status line now only carries the error and first-load states; the
    // success "Updated …" timestamp moved to the Refresh row (refreshTrailing),
    // so it collapses entirely once data has loaded successfully.
    private var showsStatusLine: Bool {
        usageService.error != nil || (usageService.isLoading && !snapshot.hasData)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let error = usageService.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundColor(.orange).accessibilityHidden(true)
                Text(error).font(.caption2).foregroundColor(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if usageService.isLoading {   // retry in progress
                    ProgressView().controlSize(.small)
                }
            } else {
                // isLoading && !hasData — the initial load.
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption2).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(spacing: 0) {
            MenuRow(icon: "chart.bar", title: "Open Dashboard", action: openDashboard)
            // Refresh stays a normal, always-tappable row (single-flight makes a
            // tap during an in-flight fetch a safe no-op). Its trailing edge shows
            // a spinner while refreshing, otherwise the grey "Updated …" timestamp.
            MenuRow(icon: "arrow.clockwise", title: "Refresh",
                    trailing: AnyView(refreshTrailing), action: refreshUsage)
            MenuRow(icon: "gear", title: "Settings", action: openSettings)
        }
    }

    @ViewBuilder private var refreshTrailing: some View {
        if usageService.isLoading && snapshot.hasData {
            ProgressView().controlSize(.small)
        } else if snapshot.hasData && usageService.error == nil {
            Text("Updated \(relativeUpdated)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Helpers

    private func level(_ percent: Int) -> UsageLevel {
        usageLevel(percent: percent,
                   warning: Int(settingsManager.settings.effectiveWarningThreshold),
                   critical: Int(settingsManager.settings.effectiveCriticalThreshold))
    }

    private func color(for level: UsageLevel) -> Color {
        switch level {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .primary
        }
    }

    private func levelSymbol(_ level: UsageLevel) -> String? {
        switch level {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .normal: return nil
        }
    }

    private func rowAccessibilityValue(hasData: Bool, percent: Int, level: UsageLevel, resetAt: Date?) -> String {
        guard hasData else { return "No data yet" }
        var parts = ["\(percent) percent used"]
        if let resetAt = resetAt { parts.append(resetCaption(until: resetAt, from: now)) }
        switch level {
        case .critical: parts.append("critical")
        case .warning: parts.append("warning")
        case .normal: break
        }
        return parts.joined(separator: ", ")
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
        dismiss()
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

// MARK: - Menu row

/// A full-width popover row with a hover highlight, so the actions read as
/// interactive controls rather than static text.
private struct MenuRow: View {
    let icon: String?
    let title: String
    var trailing: AnyView? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon = icon {
                        Image(systemName: icon)
                    }
                }
                .frame(width: 16)
                .accessibilityHidden(true)
                Text(title)
                Spacer()
                if let trailing = trailing {
                    trailing
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovered = $0 }
        // Clear any lingering highlight when the popover closes (AppKit won't
        // deliver a mouse-exit if the window orders out from under the cursor),
        // so a reopened popover never shows a phantom hover.
        .onDisappear { hovered = false }
    }
}
