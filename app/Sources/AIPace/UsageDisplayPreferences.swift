import Foundation

enum UsageDisplayDestination {
    case menuBar
    case popover
}

/// Display identity is separate from notification keys: each model can be shown independently.
struct UsageMetric: Codable, Hashable, Identifiable {
    let provider: ProviderKind
    let kind: UsageWindowKind
    let modelName: String?

    init(provider: ProviderKind, kind: UsageWindowKind, modelName: String? = nil) {
        self.provider = provider
        self.kind = kind
        self.modelName = kind == .scopedWeekly ? modelName : nil
    }

    init(provider: ProviderKind, window: UsageWindow) {
        self.init(provider: provider, kind: window.kind, modelName: window.label)
    }

    var id: String {
        "\(provider.rawValue):\(kind.rawValue):\(modelName?.lowercased() ?? "")"
    }

    func label(loc: Loc) -> String {
        guard let modelName else { return loc.windowLabel(kind) }
        return "\(modelName) · \(loc.windowLabel(.weekly))"
    }
}

struct UsageDisplayPreferences: Codable {
    static let defaultsKey = "usageDisplayPreferences"

    private(set) var hiddenMenuBarMetrics: Set<String> = []
    private(set) var hiddenPopoverMetrics: Set<String> = []
    private(set) var popoverMatchesMenuBar = true
    // Remember discovered quotas so a temporary omission does not remove their switches.
    private(set) var knownMetrics: [UsageMetric] = [
        UsageMetric(provider: .claude, kind: .fiveHour),
        UsageMetric(provider: .claude, kind: .weekly),
        UsageMetric(provider: .codex, kind: .weekly),
    ]

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func isVisible(_ metric: UsageMetric, in destination: UsageDisplayDestination) -> Bool {
        let hidden = destination == .menuBar || popoverMatchesMenuBar
            ? hiddenMenuBarMetrics : hiddenPopoverMetrics
        return !hidden.contains(metric.id)
    }

    mutating func setVisible(_ visible: Bool, metric: UsageMetric, in destination: UsageDisplayDestination) {
        if destination == .menuBar || popoverMatchesMenuBar {
            if visible { hiddenMenuBarMetrics.remove(metric.id) }
            else { hiddenMenuBarMetrics.insert(metric.id) }
        } else {
            if visible { hiddenPopoverMetrics.remove(metric.id) }
            else { hiddenPopoverMetrics.insert(metric.id) }
        }
    }

    mutating func setPopoverMatchesMenuBar(_ matches: Bool) {
        guard matches != popoverMatchesMenuBar else { return }
        if !matches {
            // Start independent editing from what the user is currently seeing.
            hiddenPopoverMetrics = hiddenMenuBarMetrics
        }
        popoverMatchesMenuBar = matches
    }

    @discardableResult
    mutating func discoverMetrics(in snapshot: ProviderSnapshot) -> Bool {
        var changed = false
        for window in snapshot.windows where window.usedPercentage != nil {
            let metric = UsageMetric(provider: snapshot.provider, window: window)
            guard !knownMetrics.contains(where: { $0.id == metric.id }) else { continue }
            knownMetrics.append(metric)
            changed = true
        }
        return changed
    }

    func filtered(_ snapshot: ProviderSnapshot, for destination: UsageDisplayDestination) -> ProviderSnapshot {
        var result = snapshot
        result.windows = snapshot.windows.filter {
            isVisible(UsageMetric(provider: snapshot.provider, window: $0), in: destination)
        }
        return result
    }
}
