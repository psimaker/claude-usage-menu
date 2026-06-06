import Foundation

struct AppSettings: Codable, Equatable {
    var warningThreshold: Double = 80.0
    var criticalThreshold: Double = 90.0
    var notificationsEnabled: Bool = true
    /// When true the menu bar shows a tight inline `45% · 78%`.
    /// When false (default) it shows the labeled two-column "5h Limit / Weekly Limit" layout.
    var compactDisplay: Bool = false

    /// The sliders allow critical to be set below warning. Color logic checks
    /// critical first while alert logic checks warning first, so reading the raw
    /// values from different places could disagree (red color, no notification).
    /// Both always read these normalized values instead.
    var effectiveWarningThreshold: Double { min(warningThreshold, criticalThreshold) }
    var effectiveCriticalThreshold: Double { max(warningThreshold, criticalThreshold) }
}

// MARK: - Usage level + display helpers (pure, testable)

/// Threshold band a percentage falls into. The single source of truth for the
/// color (and the redundant colorblind cue) used by both the menu bar and the
/// popover, so they can never disagree.
enum UsageLevel: Equatable {
    case normal
    case warning
    case critical
}

func usageLevel(percent: Int, warning: Int, critical: Int) -> UsageLevel {
    if percent >= critical { return .critical }
    if percent >= warning { return .warning }
    return .normal
}

/// Clamps a raw utilization percentage to the 0…100 range shown to the user, so
/// a server value above 100 (over quota) never renders as a nonsensical "105%".
func displayPercent(_ raw: Int) -> Int { min(max(raw, 0), 100) }

/// A point-in-time view of the account's usage limits.
///
/// `hasData` is false for the initial placeholder shown before the first
/// successful fetch, so the UI can distinguish "no data yet" from a real 0%.
struct UsageSnapshot {
    let fiveHourUtilization: Int
    let sevenDayUtilization: Int
    let sevenDaySonnetUtilization: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let lastUpdated: Date
    let hasData: Bool

    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            fiveHourUtilization: 0,
            sevenDayUtilization: 0,
            sevenDaySonnetUtilization: nil,
            fiveHourResetAt: nil,
            sevenDayResetAt: nil,
            lastUpdated: Date(),
            hasData: false
        )
    }
}

// MARK: - Usage alert evaluation (pure, testable)

enum UsageAlertLevel: Equatable {
    case none
    case warning
    case critical
}

/// Tracks which threshold notifications have already fired for the current
/// usage period so the user is alerted at most once per crossing — but is
/// re-armed when usage drops back below a band or the period rolls over.
///
/// Persisted (Codable) so a restart mid-period does not re-notify.
struct AlertGate: Codable, Equatable {
    var warningFired: Bool = false
    var criticalFired: Bool = false
    /// Identity of the usage period these flags belong to (the seven-day
    /// reset timestamp). When it changes, the gate re-arms.
    var periodResetAt: Date? = nil
}

/// Decide whether a notification should fire right now, mutating `gate`.
///
/// Rules:
/// - A new period (different `periodResetAt`) re-arms both alerts.
/// - Dropping below the warning threshold re-arms both alerts.
/// - Dropping below the critical threshold (but still ≥ warning) re-arms the
///   critical alert so a re-crossing notifies again.
/// - Crossing critical also marks warning as fired to avoid a redundant pair.
func evaluateUsageAlert(usage: Int,
                        warningThreshold: Int,
                        criticalThreshold: Int,
                        periodResetAt: Date?,
                        gate: inout AlertGate) -> UsageAlertLevel {
    if gate.periodResetAt != periodResetAt {
        gate.periodResetAt = periodResetAt
        gate.warningFired = false
        gate.criticalFired = false
    }

    if usage < warningThreshold {
        gate.warningFired = false
        gate.criticalFired = false
        return .none
    }

    if usage < criticalThreshold {
        gate.criticalFired = false          // re-arm critical once we leave its band
        if !gate.warningFired {
            gate.warningFired = true
            return .warning
        }
        return .none
    }

    // usage >= criticalThreshold
    if !gate.criticalFired {
        gate.criticalFired = true
        gate.warningFired = true            // suppress a redundant warning alert
        return .critical
    }
    return .none
}
