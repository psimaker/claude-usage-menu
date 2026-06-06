import AppKit
import SwiftUI
import UserNotifications
import Combine

// MARK: - Menu bar image renderer

/// Renders the status-item content as a custom image: two columns, each with a
/// small top line (optionally led by an SF Symbol) and a larger percentage
/// underneath — e.g. "↻ 2h 5m / 45%"  |  "Weekly Limit / 78%".
enum MenuBarRenderer {
    struct Column {
        var symbol: String? = nil   // optional SF Symbol drawn before the top-line text
        let label: String
        let value: String
        let valueColor: NSColor
    }

    private static let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    private static let symbolPointSize: CGFloat = 8
    private static let symbolGap: CGFloat = 2

    /// `leftMinWidth` lets the caller reserve a stable width for the left column
    /// so the status item doesn't visibly jitter (nudging neighbouring menu-bar
    /// icons) as the variable-width 5h countdown ticks down.
    static func image(left: Column, right: Column, height: CGFloat, leftMinWidth: CGFloat = 0) -> NSImage {
        let columnGap: CGFloat = 8
        let hPad: CGFloat = 3

        let leftW = max(columnWidth(left), leftMinWidth)
        let rightW = columnWidth(right)
        let totalW = ceil(hPad + leftW + columnGap + rightW + hPad)

        let image = NSImage(size: NSSize(width: max(totalW, 1), height: height), flipped: false) { _ in
            let lineGap: CGFloat = 0
            func draw(_ col: Column, originX: CGFloat, colW: CGFloat) {
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont, .foregroundColor: NSColor.secondaryLabelColor
                ]
                let valueAttrs: [NSAttributedString.Key: Any] = [
                    .font: valueFont, .foregroundColor: col.valueColor
                ]
                let ls = (col.label as NSString).size(withAttributes: labelAttrs)
                let vs = (col.value as NSString).size(withAttributes: valueAttrs)
                let sym = col.symbol.flatMap { symbolImage($0) }
                let symW = sym.map { $0.size.width + symbolGap } ?? 0
                let topW = symW + ls.width

                let blockH = max(ls.height, sym?.size.height ?? 0) + lineGap + vs.height
                // Clamp to a non-negative origin so a block taller than the menu
                // bar biases downward instead of clipping the top label line off
                // the top edge.
                let bottom = max(0, ((height - blockH) / 2).rounded(.down))
                let topY = bottom + vs.height + lineGap
                let topStartX = originX + (colW - topW) / 2

                if let sym = sym {
                    let symRect = NSRect(
                        x: topStartX,
                        y: topY + (ls.height - sym.size.height) / 2,
                        width: sym.size.width, height: sym.size.height
                    )
                    drawTinted(sym, in: symRect, color: .secondaryLabelColor)
                }
                (col.label as NSString).draw(at: NSPoint(x: topStartX + symW, y: topY), withAttributes: labelAttrs)
                (col.value as NSString).draw(
                    at: NSPoint(x: originX + (colW - vs.width) / 2, y: bottom), withAttributes: valueAttrs)
            }

            draw(left, originX: hPad, colW: leftW)
            draw(right, originX: hPad + leftW + columnGap, colW: rightW)

            // Subtle vertical divider between the two columns. A filled 1pt rect
            // aligned to an integer x renders crisply at any backing scale (a
            // half-point stroke straddles two device pixels on 1× displays).
            let dividerX = (hPad + leftW + columnGap / 2).rounded()
            let inset: CGFloat = 4
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(rect: NSRect(x: dividerX, y: inset, width: 1, height: max(0, height - inset * 2))).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func columnWidth(_ col: Column) -> CGFloat {
        let labelW = (col.label as NSString).size(withAttributes: [.font: labelFont]).width
        let valueW = (col.value as NSString).size(withAttributes: [.font: valueFont]).width
        let symW = col.symbol.flatMap { symbolImage($0) }.map { $0.size.width + symbolGap } ?? 0
        return max(symW + labelW, valueW)
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Draws a (template) SF Symbol tinted to `color` by recoloring its opaque pixels.
    private static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared

    private static let gateKey = "ClaudeUsageAlertGate"
    private var alertGate: AlertGate = AppDelegate.loadGate()

    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    /// Closes the popover when the user clicks anywhere outside it.
    private var clickMonitor: Any?
    /// Keeps the menu-bar "resets in …" countdown ticking between polls.
    private var menuBarTicker: Timer?

    /// Width reserved for the left column so the status item stays a stable size
    /// while the 5h countdown ticks. Sized from the widest expected countdown.
    private lazy var reservedLeftWidth: CGFloat = MenuBarRenderer.columnWidth(
        // The 5h window's countdown never exceeds "4h 59m", which is also wider
        // than the "5h" (no data) and "stale" (error) states it alternates with.
        MenuBarRenderer.Column(symbol: "arrow.clockwise", label: "4h 59m", value: "100%", valueColor: .labelColor)
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNotifications()
        observeUsage()
        usageService.startPolling()
        updateStatusItemAppearance()

        // Refresh the menu bar every 60s so the 5h countdown stays current.
        menuBarTicker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateStatusItemAppearance()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
        menuBarTicker?.invalidate()
        menuBarTicker = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            // Re-render when the menu bar switches between light and dark so the
            // baked-in colors stay correct.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.updateStatusItemAppearance()
            }
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 220)
        popover.behavior = .transient
        // Honor the system Reduce Motion accessibility setting.
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self

        let host = NSHostingController(
            rootView: MenuBarView(
                usageService: usageService,
                settingsManager: settingsManager,
                openSettings: { [weak self] in self?.openSettings() },
                dismiss: { [weak self] in self?.closePopover() }
            )
        )
        // Let SwiftUI drive the popover size live, so rows that appear after the
        // popover is on screen (Sonnet row, error line, reset lines) grow it
        // instead of being clipped. `sizingOptions` is available on the 13.0
        // deployment target.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    private func setupNotifications() {
        // Only prompt when alerts are actually enabled (the default). Settings
        // re-requests/recovers authorization when the user toggles them back on.
        guard settingsManager.settings.notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    private func observeUsage() {
        // Usage updates drive both the menu bar and the alert check.
        usageService.$currentUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.checkForNotifications()
            }
            .store(in: &cancellables)

        // Error / loading changes must also be reflected in the menu bar (the
        // staleness cue keys off `error`).
        usageService.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)
        usageService.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)

        // Re-color when an appearance-relevant setting (thresholds / display
        // mode) actually changes — driven by the settings model itself rather
        // than the global UserDefaults notification, so unrelated defaults
        // writes (e.g. the alert-gate) don't trigger a needless re-render.
        settingsManager.$settings
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    // MARK: Popover

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Activate first so the popover is presented by the active app and
        // anchors correctly under the status item.
        NSApp.activate(ignoringOtherApps: true)

        // Re-read Reduce Motion each show so a mid-session accessibility change
        // is honored without relaunching this long-lived accessory app.
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // A transient popover doesn't reliably dismiss for an accessory app;
        // a global click monitor guarantees it closes on any outside click.
        // Remove any stale monitor first so opens can never accumulate them.
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // Opening the popover is an explicit "show me current data" gesture, so
        // refresh if the snapshot is more than 30s old. The single-flight guard
        // makes this a no-op when a poll is already in flight.
        if Date().timeIntervalSince(usageService.currentUsage.lastUpdated) > 30 {
            usageService.fetchUsage()
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    /// Single source of truth for click-monitor teardown: every close path
    /// (transient self-dismiss, Esc, programmatic) funnels through here.
    func popoverDidClose(_ notification: Notification) {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: Settings window

    /// Presents Settings in its own standard window owned by the delegate, so
    /// its lifetime is fully decoupled from the transient popover (which would
    /// otherwise tear a popover-hosted sheet down on the next outside click or
    /// resign-active). Reuses a single retained instance across reopens.
    func openSettings() {
        closePopover()

        // Build a fresh hosting controller on every open so the SwiftUI view's
        // @State is re-seeded and `.onAppear` re-runs (re-reading the live
        // notification-authorization status and current thresholds) — a reused
        // window's content view never re-fires onAppear on reopen. `sizingOptions`
        // lets the window grow to fit conditional rows (e.g. the "notifications
        // blocked" warning). Both APIs are available on the 13.0 target.
        let hosting = NSHostingController(
            rootView: SettingsView(settingsManager: settingsManager, usageService: usageService)
        )
        hosting.sizingOptions = [.preferredContentSize]

        if let window = settingsWindow {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Claude Usage Menu Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false   // we retain & reuse it
            window.center()
            settingsWindow = window
        }

        // Activate before ordering front so an accessory (LSUIElement) app's
        // window reliably comes forward and can take focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar appearance

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let snap = usageService.currentUsage
        let hasData = snap.hasData
        // Data is present, the last refresh failed, AND the data is actually old:
        // show last-known numbers, dimmed, with a distinct symbol so they read as
        // stale rather than current. The age gate keeps an expected, short-lived
        // failure (e.g. a 429 backoff right after a good fetch) from looking like
        // an alarm while the numbers are still fresh.
        let stale = hasData && usageService.error != nil
            && Date().timeIntervalSince(snap.lastUpdated) > 5 * 60

        let fivePct = displayPercent(snap.fiveHourUtilization)
        let weekPct = displayPercent(snap.sevenDayUtilization)
        let fiveValue = hasData ? "\(fivePct)%" : "—"
        let weekValue = hasData ? "\(weekPct)%" : "—"

        let fiveColor: NSColor
        let weekColor: NSColor
        if !hasData || stale {
            fiveColor = .secondaryLabelColor
            weekColor = .secondaryLabelColor
        } else {
            fiveColor = usageColor(for: fivePct)
            weekColor = usageColor(for: weekPct)
        }

        if settingsManager.settings.compactDisplay {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: fiveValue,
                attributes: [.font: font, .foregroundColor: fiveColor]))
            str.append(NSAttributedString(string: " · ",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            str.append(NSAttributedString(string: weekValue,
                attributes: [.font: font, .foregroundColor: weekColor]))
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = str
        } else {
            // Left column: reset symbol + time remaining in the 5h window, % below.
            let leftSymbol = stale ? "exclamationmark.triangle" : "arrow.clockwise"
            let fiveLabel: String
            if stale {
                fiveLabel = "stale"
            } else if hasData, let reset = snap.fiveHourResetAt {
                fiveLabel = formatTimeRemaining(until: reset)
            } else {
                fiveLabel = "5h"
            }
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.image = MenuBarRenderer.image(
                left: MenuBarRenderer.Column(symbol: leftSymbol, label: fiveLabel, value: fiveValue, valueColor: fiveColor),
                right: MenuBarRenderer.Column(label: "Weekly Limit", value: weekValue, valueColor: weekColor),
                height: NSStatusBar.system.thickness,
                leftMinWidth: reservedLeftWidth
            )
        }

        // Tooltip + VoiceOver reflect the live state, including failures.
        let description: String
        if let err = usageService.error, !hasData {
            description = err
        } else if !hasData {
            description = "Loading Claude usage…"
        } else {
            var text = "Claude usage — 5h \(fivePct)%"
            if let reset = snap.fiveHourResetAt {
                text += " (resets in \(formatTimeRemaining(until: reset)))"
            }
            text += ", Weekly Limit \(weekPct)%"
            if let err = usageService.error { text += " — last update failed: \(err)" }
            description = text
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func usageColor(for percentage: Int) -> NSColor {
        switch usageLevel(percent: percentage,
                          warning: Int(settingsManager.settings.effectiveWarningThreshold),
                          critical: Int(settingsManager.settings.effectiveCriticalThreshold)) {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case .normal: return .labelColor
        }
    }

    // MARK: Notifications

    private func checkForNotifications() {
        guard settingsManager.settings.notificationsEnabled else { return }
        let snap = usageService.currentUsage
        guard snap.hasData else { return }

        let previousGate = alertGate
        let level = evaluateUsageAlert(
            usage: snap.sevenDayUtilization,
            warningThreshold: Int(settingsManager.settings.effectiveWarningThreshold),
            criticalThreshold: Int(settingsManager.settings.effectiveCriticalThreshold),
            periodResetAt: snap.sevenDayResetAt,
            gate: &alertGate
        )
        if alertGate != previousGate { saveGate() }   // avoid a UserDefaults write every poll

        switch level {
        case .critical:
            sendNotification(
                title: "Critical: Claude Usage",
                body: "You've used \(snap.sevenDayUtilization)% of your weekly quota. Consider pausing non-essential tasks.",
                isCritical: true
            )
        case .warning:
            sendNotification(
                title: "Warning: Claude Usage",
                body: "You've used \(snap.sevenDayUtilization)% of your weekly quota.",
                isCritical: false
            )
        case .none:
            break
        }
    }

    private func sendNotification(title: String, body: String, isCritical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }

    // MARK: Alert-gate persistence

    private static func loadGate() -> AlertGate {
        guard let data = UserDefaults.standard.data(forKey: gateKey),
              let gate = try? JSONDecoder().decode(AlertGate.self, from: data) else {
            return AlertGate()
        }
        return gate
    }

    private func saveGate() {
        if let data = try? JSONEncoder().encode(alertGate) {
            UserDefaults.standard.set(data, forKey: AppDelegate.gateKey)
        }
    }
}
