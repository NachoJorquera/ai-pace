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

    static func text(prefix: String, snapshot: ProviderSnapshot, mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .usage:
            return compose(prefix, usageText(for: snapshot))
        case .remaining:
            return compose(prefix, remainingText(for: snapshot))
        case .insight:
            return compose(prefix, insightText(for: snapshot))
        case .usageAndInsight:
            return compose(prefix, usageText(for: snapshot), insightText(for: snapshot))
        case .remainingAndInsight:
            return compose(prefix, remainingText(for: snapshot), insightText(for: snapshot))
        }
    }

    /// One value per reported window, so the label grows and shrinks with the provider's quota count.
    private static func usageText(for snapshot: ProviderSnapshot) -> String {
        snapshot.windows.map { compactValue(for: $0) }.joined(separator: "/")
    }

    private static func remainingText(for snapshot: ProviderSnapshot) -> String {
        snapshot.windows.map { compactRemainingValue(for: $0) }.joined(separator: "/")
    }

    private static func insightText(for snapshot: ProviderSnapshot) -> String {
        guard let weekly = snapshot.weekly else {
            return "--"
        }
        return WeeklyPacing.formattedDelta(for: weekly) ?? "--"
    }

    private static func compose(_ prefix: String, _ parts: String...) -> String {
        ([prefix] + parts.filter { !$0.isEmpty }).joined(separator: " ")
    }
}
