import AppKit

@main
enum AIPaceApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        // NSApplication holds its delegate weakly. No SwiftUI scene is needed for this menu bar app.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = UsageStore()
    private var statusItemController: StatusItemController?
    private var optionsWindowController: OptionsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let openSettings: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.showOptionsWindow(with: self.store)
        }
        statusItemController = StatusItemController(store: store, openSettings: openSettings)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showOptionsWindow(with store: UsageStore) {
        if optionsWindowController == nil {
            optionsWindowController = OptionsWindowController(store: store)
        }
        optionsWindowController?.show()
    }
}
