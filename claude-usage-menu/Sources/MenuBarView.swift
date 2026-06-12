import SwiftUI
import Combine

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    /// Opens the standalone Settings window (owned by AppDelegate).
    var openSettings: () -> Void = {}
    /// Opens the standalone About window (owned by AppDelegate).
    var openAbout: () -> Void = {}
    /// Dismisses the popover (owned by AppDelegate).
    var dismiss: () -> Void = {}
    @State private var now = Date()

    // Drives the live "Resets in …" / "Updated … ago" countdowns. It's a
    // connectable publisher (no autoconnect) started only while the popover is
    // on screen, so a closed popover doesn't wake every 15s for nothing.
    private let ticker = Timer.publish(every: 15, on: .main, in: .common)
    @State private var tickerConnection: Cancellable?

    private var snapshot: UsageSnapshot { usageService.currentUsage }

    /// Claude's brand terracotta, used as the normal-state bar fill so the card
    /// reads like CodexBar's Claude card. Warning/critical override it.
    private static let claudeTint = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)

            sectionDivider

            usageSection
                .padding(.horizontal, 14)

            sectionDivider

            actionButtons

            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

            MenuRow(icon: "power", title: "Quit", action: quitApp)
        }
        .padding(.vertical, 10)
        .frame(width: 300)
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

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Claude")
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(updatedLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                if let plan = usageService.planName {
                    Text(plan)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var updatedLine: String {
        if snapshot.hasData { return "Updated \(relativeUpdated)" }
        return usageService.isLoading ? "Loading…" : "No data yet"
    }

    // MARK: Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            metricSection(title: "Session",
                          percent: snapshot.fiveHourUtilization,
                          resetAt: snapshot.fiveHourResetAt)

            metricSection(title: "Weekly",
                          percent: snapshot.sevenDayUtilization,
                          resetAt: snapshot.sevenDayResetAt)

            if let sonnet = snapshot.sevenDaySonnetUtilization {
                // The API reports no per-window reset for the Sonnet share, so
                // the row carries the percentage only (CodexBar does the same).
                metricSection(title: "Sonnet", percent: sonnet, resetAt: nil)
            }

            if let extra = snapshot.extraUsage {
                extraUsageSection(extra)
            }

            if showsStatusLine {
                statusLine
            }
        }
    }

    /// One CodexBar-style metric block: bold title, thin bar, then a footnote
    /// line with "N% used" left and the reset countdown right.
    private func metricSection(title: String, percent: Int, resetAt: Date?) -> some View {
        let hasData = snapshot.hasData
        let shown = displayPercent(percent)
        let level = self.level(shown)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)

            UsageBar(percent: hasData ? Double(shown) : 0,
                     tint: hasData ? barTint(for: level) : .secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Redundant, non-color cue for warning/critical so the state is
                // distinguishable without relying on color alone.
                if hasData, let symbol = levelSymbol(level) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundColor(color(for: level))
                }
                Text(hasData ? "\(shown)% used" : "—")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundColor(level == .normal ? .primary : color(for: level))
                Spacer()
                if hasData, let resetAt {
                    Text(resetCaption(until: resetAt, from: now).capitalizedFirst)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        // Announce each block as one VoiceOver element with the full state,
        // since a bare bar would otherwise read as context-less progress.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(rowAccessibilityValue(hasData: hasData, percent: shown, level: level, resetAt: resetAt))
    }

    private func extraUsageSection(_ extra: ExtraUsageSnapshot) -> some View {
        let shown = displayPercent(extra.utilization)
        let used = formatCurrencyAmount(extra.usedDollars, code: extra.currencyCode)
        let limit = formatCurrencyAmount(extra.limitDollars, code: extra.currencyCode)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Extra usage")
                .font(.body)
                .fontWeight(.medium)

            UsageBar(percent: Double(shown), tint: Self.claudeTint)

            HStack(alignment: .firstTextBaseline) {
                Text("This month: \(used) / \(limit)")
                    .font(.footnote)
                Spacer()
                Text("\(shown)% used")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Extra usage")
        .accessibilityValue("\(used) of \(limit) spent this month, \(shown) percent used")
    }

    // The status line only carries the error and first-load states; the
    // success "Updated …" timestamp lives in the header.
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
            // tap during an in-flight fetch a safe no-op). Its trailing edge
            // shows a spinner while a refresh is running.
            MenuRow(icon: "arrow.clockwise", title: "Refresh",
                    trailing: AnyView(refreshTrailing), action: refreshUsage)
            MenuRow(icon: "gear", title: "Settings…", action: openSettings)
            MenuRow(icon: "info.circle", title: "About Claude Usage Menu", action: openAbout)
        }
    }

    @ViewBuilder private var refreshTrailing: some View {
        if usageService.isLoading && snapshot.hasData {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Helpers

    private func level(_ percent: Int) -> UsageLevel {
        usageLevel(percent: percent,
                   warning: Int(settingsManager.settings.effectiveWarningThreshold),
                   critical: Int(settingsManager.settings.effectiveCriticalThreshold))
    }

    private func barTint(for level: UsageLevel) -> Color {
        switch level {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return Self.claudeTint
        }
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
        // The popover is open, so the app is active: force an interactive re-read
        // (bypassing the token cache) so a tap can both pick up a rotated token and
        // surface the "Always Allow" dialog when Claude Code's rotation reset the
        // Keychain ACL. Harmless when access is already granted (no prompt shown).
        usageService.fetchUsage(forceInteractive: true)
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private extension String {
    /// "resets in 3h 53m" → "Resets in 3h 53m" for the CodexBar-style captions.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Usage bar

/// Thin rounded progress bar (track + fill) drawn in a single Canvas, modeled
/// on CodexBar's UsageProgressBar.
private struct UsageBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let clamped = min(100, max(0, percent))
            let radius = size.height / 2
            let cornerSize = CGSize(width: radius, height: radius)

            let track = Path { $0.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerSize: cornerSize) }
            context.fill(track, with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.5)))

            let fillWidth = size.width * clamped / 100
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fill = Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fill, with: .color(tint))
            }
        }
        .frame(height: 6)
        // The enclosing metric row exposes the combined VoiceOver value.
        .accessibilityHidden(true)
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
