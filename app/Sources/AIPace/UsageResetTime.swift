import Foundation

enum UsageResetTime {
    static let showInMenuBarDefaultsKey = "showMenuBarResetTime"

    static func formatted(until date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.down)))
        if seconds == 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        parts.append(String(format: "%02dm", minutes % 60))
        return parts.joined(separator: " ")
    }
}
