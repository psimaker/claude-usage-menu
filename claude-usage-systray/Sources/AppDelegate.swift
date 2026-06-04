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

    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    private static let symbolPointSize: CGFloat = 8
    private static let symbolGap: CGFloat = 2

    static func image(left: Column, right: Column, height: CGFloat) -> NSImage {
        let columnGap: CGFloat = 8
        let hPad: CGFloat = 3
        let lineGap: CGFloat = 0

        let leftW = columnWidth(left)
        let rightW = columnWidth(right)
        let totalW = ceil(hPad + leftW + columnGap + rightW + hPad)

        let image = NSImage(size: NSSize(width: max(totalW, 1), height: height), flipped: false) { _ in
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
                let bottom = ((height - blockH) / 2).rounded(.down)
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

            // Subtle vertical divider between the two columns.
            let dividerX = (hPad + leftW + columnGap / 2).rounded() + 0.5
            let inset: CGFloat = 4
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: dividerX, y: inset))
            divider.line(to: NSPoint(x: dividerX, y: height - inset))
            NSColor.tertiaryLabelColor.setStroke()
            divider.lineWidth = 1
            divider.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func columnWidth(_ col: Column) -> CGFloat {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
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
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                usageService: usageService,
                settingsManager: settingsManager
            )
        )
    }

    private func setupNotifications() {
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

        // Error / loading changes must also be reflected in the menu bar.
        usageService.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)
        usageService.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)

        // Re-color when thresholds / display mode change in Settings.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification, object: nil
        )
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

        // Size the popover to its real content BEFORE showing. Otherwise the
        // SwiftUI content grows past the placeholder contentSize after the
        // popover is already on screen, and NSPopover repositions it so the top
        // is clipped above the screen edge.
        if let hosted = popover.contentViewController?.view {
            hosted.layoutSubtreeIfNeeded()
            let fitting = hosted.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                popover.contentSize = fitting
            }
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // A transient popover doesn't reliably dismiss for an accessory app;
        // a global click monitor guarantees it closes on any outside click.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    @objc private func settingsDidChange() {
        updateStatusItemAppearance()
    }

    // MARK: Menu bar appearance

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let snap = usageService.currentUsage
        let hasData = snap.hasData

        let fiveValue = hasData ? "\(snap.fiveHourUtilization)%" : "—"
        let weekValue = hasData ? "\(snap.sevenDayUtilization)%" : "—"
        let fiveColor = hasData ? usageColor(for: snap.fiveHourUtilization) : .secondaryLabelColor
        let weekColor = hasData ? usageColor(for: snap.sevenDayUtilization) : .secondaryLabelColor

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
            let fiveLabel: String
            if hasData, let reset = snap.fiveHourResetAt {
                fiveLabel = formatTimeRemaining(until: reset)
            } else {
                fiveLabel = "5h"
            }
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.image = MenuBarRenderer.image(
                left: MenuBarRenderer.Column(symbol: "arrow.clockwise", label: fiveLabel, value: fiveValue, valueColor: fiveColor),
                right: MenuBarRenderer.Column(label: "Weekly Limit", value: weekValue, valueColor: weekColor),
                height: NSStatusBar.system.thickness
            )
        }

        // Tooltip + VoiceOver reflect the live state, including failures.
        let description: String
        if let err = usageService.error, !hasData {
            description = err
        } else if !hasData {
            description = "Loading Claude usage…"
        } else {
            var text = "Claude usage — 5h \(snap.fiveHourUtilization)%"
            if let reset = snap.fiveHourResetAt {
                text += " (resets in \(formatTimeRemaining(until: reset)))"
            }
            text += ", Weekly Limit \(snap.sevenDayUtilization)%"
            if let err = usageService.error { text += " — last update failed: \(err)" }
            description = text
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func usageColor(for percentage: Int) -> NSColor {
        let critical = Int(settingsManager.settings.effectiveCriticalThreshold)
        let warning = Int(settingsManager.settings.effectiveWarningThreshold)
        if percentage >= critical { return .systemRed }
        if percentage >= warning { return .systemOrange }
        return .labelColor
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
