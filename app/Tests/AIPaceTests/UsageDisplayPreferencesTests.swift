import Foundation
import Testing
@testable import AIPace

struct UsageDisplayPreferencesTests {
    @Test(arguments: 0..<16)
    func supportsEveryCombinationOfQuotas(mask: Int) {
        let snapshot = makeSnapshot(.claude, windows: [
            makeWindow(.fiveHour, used: 10),
            makeWindow(.weekly, used: 20, resetsAt: Date().addingTimeInterval(3.5 * 24 * 60 * 60)),
            makeWindow(.scopedWeekly, used: 30, label: "Fable"),
            makeWindow(.scopedWeekly, used: 40, label: "Opus"),
        ])
        var preferences = UsageDisplayPreferences()
        for (index, window) in snapshot.windows.enumerated() {
            preferences.setVisible(mask & (1 << index) != 0,
                                   metric: UsageMetric(provider: .claude, window: window), in: .menuBar)
        }

        let selected = snapshot.windows.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        let bar = preferences.filtered(snapshot, for: .menuBar)
        let menu = preferences.filtered(snapshot, for: .popover)
        #expect(bar.windows.map(\.id) == selected.map(\.id))
        #expect(menu.windows.map(\.id) == selected.map(\.id))
        #expect(snapshot.windows.count == 4)

        let usage = selected.map { StatusItemFormatter.compactValue(for: $0) }.joined(separator: "/")
        let remaining = selected.map { StatusItemFormatter.compactRemainingValue(for: $0) }.joined(separator: "/")
        #expect(StatusItemFormatter.text(prefix: "Cl", snapshot: bar, mode: .usage) == "Cl" + (usage.isEmpty ? "" : " " + usage))
        #expect(StatusItemFormatter.text(prefix: "Cl", snapshot: bar, mode: .remaining) == "Cl" + (remaining.isEmpty ? "" : " " + remaining))
        #expect(StatusItemFormatter.text(prefix: "Cl", snapshot: bar, mode: .insight) == (mask & 2 == 0 ? "Cl" : "Cl +30%"))
    }

    @Test
    func menuCanBeIndependentAndLinkedAgain() {
        let session = UsageMetric(provider: .claude, kind: .fiveHour)
        let weekly = UsageMetric(provider: .claude, kind: .weekly)
        var preferences = UsageDisplayPreferences()
        preferences.setVisible(false, metric: weekly, in: .menuBar)
        preferences.setPopoverMatchesMenuBar(false)
        #expect(!preferences.isVisible(weekly, in: .popover))

        preferences.setVisible(true, metric: weekly, in: .popover)
        preferences.setVisible(false, metric: session, in: .popover)
        #expect(!preferences.isVisible(weekly, in: .menuBar))
        #expect(preferences.isVisible(weekly, in: .popover))
        #expect(preferences.isVisible(session, in: .menuBar))
        #expect(!preferences.isVisible(session, in: .popover))

        preferences.setPopoverMatchesMenuBar(true)
        #expect(!preferences.isVisible(weekly, in: .popover))
        #expect(preferences.isVisible(session, in: .popover))
    }

    @Test
    func choicesAreSeparateForEachProviderAndModel() {
        var preferences = UsageDisplayPreferences()
        preferences.setVisible(false, metric: UsageMetric(provider: .claude, kind: .weekly), in: .menuBar)
        preferences.setVisible(false, metric: UsageMetric(provider: .claude, kind: .scopedWeekly, modelName: "Opus"), in: .menuBar)

        #expect(preferences.isVisible(UsageMetric(provider: .codex, kind: .weekly), in: .menuBar))
        #expect(preferences.isVisible(UsageMetric(provider: .claude, kind: .scopedWeekly, modelName: "Sonnet"), in: .menuBar))
        #expect(!preferences.isVisible(UsageMetric(provider: .claude, kind: .scopedWeekly, modelName: "OPUS"), in: .menuBar))
    }

    @Test
    @MainActor
    func storePersistsSelectionsAndDiscoveredMetricsAcrossRefreshesAndRelaunches() async {
        let suite = "AIPaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageMetric(provider: .claude, kind: .scopedWeekly, modelName: "Fable")
        let snapshots = [
            makeSnapshot(.claude, windows: [makeWindow(.fiveHour, used: 15), makeWindow(.scopedWeekly, used: 0, label: "Fable")]),
            makeSnapshot(.claude, fiveHourUsed: 20, weeklyUsed: 30),
        ]
        func makeStore() -> UsageStore {
            UsageStore(
                claudeProbe: ProbeStub(queue: ProbeQueue(snapshots)),
                codexProbe: ProbeStub(queue: ProbeQueue([makeSnapshot(.codex, windows: [makeWindow(.weekly, used: 5)])])),
                notificationManager: NotificationManagerSpy(),
                launchAtStartupManager: LaunchAtStartupManagerSpy(),
                userDefaults: defaults,
                startRefreshLoop: false
            )
        }
        let store = makeStore()
        await store.refresh()
        #expect(store.usageMetrics(for: .claude).map(\.kind) == [.fiveHour, .scopedWeekly, .weekly])
        store.setUsageVisible(false, metric: model, in: .menuBar)
        store.setPopoverMatchesMenuBar(false)
        store.setUsageVisible(true, metric: model, in: .popover)
        await store.refresh()

        let reloaded = makeStore().usageDisplayPreferences
        #expect(reloaded.knownMetrics.contains(model))
        #expect(reloaded.knownMetrics.filter { $0.id == model.id }.count == 1)
        #expect(!reloaded.popoverMatchesMenuBar)
        #expect(!reloaded.isVisible(model, in: .menuBar))
        #expect(reloaded.isVisible(model, in: .popover))
        #expect(store.claude.windows.count == 2)
        #expect(store.agentStatus(for: .claude).availability == .available)
    }

    @Test
    func missingOrCorruptPreferencesKeepExistingQuotasVisible() {
        let suite = "AIPaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = makeSnapshot(.claude, fiveHourUsed: 10, weeklyUsed: 20)
        #expect(UsageDisplayPreferences.load(from: defaults).filtered(snapshot, for: .menuBar).windows.count == 2)
        defaults.set(Data("invalid".utf8), forKey: UsageDisplayPreferences.defaultsKey)
        #expect(UsageDisplayPreferences.load(from: defaults).filtered(snapshot, for: .popover).windows.count == 2)
    }
}
