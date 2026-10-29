import Foundation

enum StatusItemFormatter {
    static func compactValue(for window: UsageWindow) -> String {
        guard let used = window.usedPercentage else {
            return "--"
        }
        return String(Int(used.rounded()))
    }

    static func compactRemainingValue(for window: UsageWindow) -> String {
        guard let used = window.usedPercentage else {
            return "--"
        }
        let remaining = max(0, 100 - used)
        return String(Int(remaining.rounded()))
    }

    static func text(
        prefix: String, snapshot: ProviderSnapshot, mode: MenuBarDisplayMode,
        showResetTime: Bool = false, now: Date = .now
    ) -> String {
        let usage = windowText(for: snapshot, remaining: false, showResetTime: showResetTime, now: now)
        let remaining = windowText(for: snapshot, remaining: true, showResetTime: showResetTime, now: now)
        let insight = insightText(for: snapshot, now: now)
        switch mode {
        case .usage:
            return compose(prefix, usage)
        case .remaining:
            return compose(prefix, remaining)
        case .insight:
            return compose(prefix, withResetTime(insight, window: snapshot.weekly, enabled: showResetTime, now: now))
        case .usageAndInsight:
            return compose(prefix, usage, insight)
        case .remainingAndInsight:
            return compose(prefix, remaining, insight)
        }
    }

    /// One value per reported window, so the label grows and shrinks with the provider's quota count.
    private static func windowText(
        for snapshot: ProviderSnapshot, remaining: Bool, showResetTime: Bool, now: Date
    ) -> String {
        snapshot.windows.map { window in
            let value = remaining ? compactRemainingValue(for: window) : compactValue(for: window)
            return withResetTime(value, window: window, enabled: showResetTime, now: now)
        }.joined(separator: "/")
    }

    private static func withResetTime(_ value: String, window: UsageWindow?, enabled: Bool, now: Date) -> String {
        guard enabled, let resetsAt = window?.resetsAt else { return value }
        return "\(value) (\(UsageResetTime.formatted(until: resetsAt, now: now)))"
    }

    private static func insightText(for snapshot: ProviderSnapshot, now: Date) -> String {
        guard let weekly = snapshot.weekly else {
            return ""
        }
        return WeeklyPacing.formattedDelta(for: weekly, now: now) ?? "--"
    }

    private static func compose(_ prefix: String, _ parts: String...) -> String {
        ([prefix] + parts).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
