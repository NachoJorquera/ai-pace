import AppKit
import SwiftUI
import Testing
@testable import AIPace

@MainActor
struct MenuContentViewTests {
    @Test
    func popoverResizesForIndependentSelectionWithoutChangingProviderAvailability() {
        let suite = "AIPaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(
            notificationManager: NotificationManagerSpy(),
            launchAtStartupManager: LaunchAtStartupManagerSpy(),
            userDefaults: defaults,
            startRefreshLoop: false
        )
        store.claude = makeSnapshot(.claude, fiveHourUsed: 12, weeklyUsed: 19)
        store.codex = makeSnapshot(.codex, windows: [makeWindow(.weekly, used: 5)])
        let controller = makeHostingController(store: store)
        let size = NSSize(width: 440, height: 900)
        let full = controller.sizeThatFits(in: size)
        store.setPopoverMatchesMenuBar(false)
        store.setUsageVisible(false, metric: UsageMetric(provider: .claude, kind: .fiveHour), in: .popover)
        controller.rootView = MenuContentView(store: store, openSettings: {})
        let filtered = controller.sizeThatFits(in: size)
        #expect(filtered.width == 440)
        #expect(filtered.height < full.height)
        #expect(store.usageDisplayPreferences.filtered(store.claude, for: .menuBar).windows.count == 2)

        store.setUsageVisible(false, metric: UsageMetric(provider: .claude, kind: .weekly), in: .popover)
        controller.rootView = MenuContentView(store: store, openSettings: {})
        #expect(controller.sizeThatFits(in: size).height > 0)
        #expect(store.agentStatus(for: .claude).availability == .available)
    }

    @Test
    func popoverFitsAdditionalUsageWindowsAndShrinksWhenTheyDisappear() {
        let store = makeStore()
        store.claude = makeSnapshot(.claude, fiveHourUsed: 12, weeklyUsed: 19)
        store.codex = makeSnapshot(.codex, fiveHourUsed: 2, weeklyUsed: 6)
        let hostingController = makeHostingController(store: store)
        let availableSize = NSSize(width: 440, height: 900)
        let originalSize = hostingController.sizeThatFits(in: availableSize)

        store.claude = makeSnapshot(.claude, windows: [
            makeWindow(.fiveHour, used: 12),
            makeWindow(.weekly, used: 19),
            makeWindow(.scopedWeekly, used: 0, label: "Fable"),
        ])
        hostingController.rootView = MenuContentView(store: store, openSettings: {})
        let expandedSize = hostingController.sizeThatFits(in: availableSize)

        #expect(expandedSize.width == 440)
        #expect(expandedSize.height > originalSize.height)
        #expect(expandedSize.height > 380)
        #expect(expandedSize.height < availableSize.height)

        store.claude = makeSnapshot(.claude, fiveHourUsed: 12, weeklyUsed: 19)
        hostingController.rootView = MenuContentView(store: store, openSettings: {})
        let restoredSize = hostingController.sizeThatFits(in: availableSize)
        #expect(restoredSize == originalSize)
    }

    @Test
    func popoverFitsShortScreensByScrollingCards() {
        let store = makeStore()
        store.claude = makeSnapshot(.claude, windows: [
            makeWindow(.fiveHour, used: 12),
            makeWindow(.weekly, used: 19),
            makeWindow(.scopedWeekly, used: 0, label: "Fable"),
        ])
        store.codex = makeSnapshot(.codex, fiveHourUsed: 2, weeklyUsed: 6)
        let hostingController = makeHostingController(store: store)
        let availableSize = NSSize(width: 440, height: 300)

        let fittedSize = hostingController.sizeThatFits(in: availableSize)

        #expect(fittedSize == availableSize)
    }

    private func makeStore() -> UsageStore {
        UsageStore(
            notificationManager: NotificationManagerSpy(),
            launchAtStartupManager: LaunchAtStartupManagerSpy(),
            startRefreshLoop: false
        )
    }

    private func makeHostingController(store: UsageStore) -> NSHostingController<MenuContentView> {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: MenuContentView(store: store, openSettings: {}))
        controller.sizingOptions = []
        return controller
    }
}
