import AppKit
import SwiftUI
import Testing
@testable import AIPace

@MainActor
struct MenuContentViewTests {
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
