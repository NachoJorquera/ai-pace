@preconcurrency import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let popoverWidth: CGFloat = 440
    private static let statusItemLengthPadding: CGFloat = 12
    private static let minimumStatusItemLength: CGFloat = 32

    private let store: UsageStore
    private let openSettings: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let logger = Logger(subsystem: "com.aipace.app", category: "StatusItem")
    private var popoverHostingController: NSHostingController<MenuContentView>?
    private var globalClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var lifecycleObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()
    private var wakeFollowupTask: Task<Void, Never>?
    private static let maxRetryAttempts = 3
    private static let retryDelay: Duration = .seconds(2)
    private var repairRetryTask: Task<Void, Never>?
    private var repairRetryAttempts = 0
    private var rebuildCount = 0
    private var statusItemCreatedAt: Date?
    private var isInRendererFallback = false
    private var isUsingFallbackLabel = false
    private lazy var repairDebouncer = StatusItemRepairDebouncer { [weak self] reason in
        self?.repairStatusItem(reason: reason)
    }

    init(store: UsageStore, openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init()
        createStatusItem(reason: .launch)
        configurePopover()
        bindStore()
        registerLifecycleRepairTriggers()
    }

    deinit {
        wakeFollowupTask?.cancel()
        repairRetryTask?.cancel()
        lifecycleObservers.forEach { observer in
            observer.center.removeObserver(observer.token)
        }
    }

    private func createStatusItem(reason: StatusItemRepairReason) {
        logger.info("Creating status item: \(reason.rawValue, privacy: .public)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Stable name = persisted position. Never rename: it is a defaults-key compatibility surface.
        item.autosaveName = "AIPaceStatusItem"
        // With an autosaveName, AppKit persists AND restores isVisible under that key. If that key ever
        // went false (an experimental build, a stray defaults write), every launch would create a hidden
        // item whose window is nil, and the retry budget would burn against an item AppKit keeps hiding.
        item.isVisible = true
        statusItem = item
        statusItemCreatedAt = Date()
        configureStatusItem(reason: reason)
    }

    private func removeStatusItem(reason: StatusItemRepairReason) {
        guard let statusItem else {
            return
        }

        logger.info("Removing status item: \(reason.rawValue, privacy: .public)")
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusItemCreatedAt = nil
    }

    private func rebuildStatusItem(reason: StatusItemRepairReason) {
        rebuildCount += 1
        let priorAge = statusItemCreatedAt.map { Date().timeIntervalSince($0) } ?? 0
        logger.info(
            "Rebuilding status item (#\(self.rebuildCount), prior age \(priorAge, format: .fixed(precision: 1))s): \(reason.rawValue, privacy: .public)"
        )
        closePopover()
        removeStatusItem(reason: reason)
        createStatusItem(reason: reason)
        verifyRebuildOutcome(reason: reason)
    }

    private func configureStatusItem(reason: StatusItemRepairReason) {
        guard let button = statusItem?.button else {
            logger.error("Status item configuration skipped because the button is unavailable: \(reason.rawValue, privacy: .public)")
            return
        }

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.title = ""
        button.image = nil
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone

        updateButtonTitle()
    }

    private func registerLifecycleRepairTriggers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStatusItemRepair(reason: .wake)
                self?.scheduleSecondWakeRepair()
            }
        }
        lifecycleObservers.append((workspaceCenter, wakeObserver))

        let displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.wakeFollowupTask?.cancel()
                self?.scheduleStatusItemRepair(reason: .displayChange)
            }
        }
        lifecycleObservers.append((NotificationCenter.default, displayObserver))
    }

    private func scheduleStatusItemRepair(reason: StatusItemRepairReason) {
        logger.info("Scheduling status item repair: \(reason.rawValue, privacy: .public)")
        if Self.resetsRetryBudget(reason) {
            repairRetryAttempts = 0
            repairRetryTask?.cancel()
        }
        repairDebouncer.schedule(reason: reason)
    }

    /// Healthy items are refreshed in place; only dead items pay for a teardown. Rebuilding a live
    /// NSStatusItem while macOS is reconnecting status item scenes is what killed the icon.
    private func repairStatusItem(reason: StatusItemRepairReason) {
        let button = statusItem?.button
        if Self.rebuildSucceeded(buttonPresent: button != nil, hasWindow: button?.window != nil) {
            logger.info("Status item healthy; refreshing content: \(reason.rawValue, privacy: .public)")
            repairRetryAttempts = 0
            repairRetryTask?.cancel()
            updateButtonTitle()
            return
        }
        rebuildStatusItem(reason: reason)
    }

    private func scheduleSecondWakeRepair() {
        wakeFollowupTask?.cancel()
        wakeFollowupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }
            self?.scheduleStatusItemRepair(reason: .wakeFollowup)
        }
    }

    private func verifyRebuildOutcome(reason: StatusItemRepairReason) {
        let button = statusItem?.button
        let buttonPresent = button != nil
        let hasWindow = button?.window != nil
        let length = statusItem?.length ?? 0
        let usesFallback = isInRendererFallback || isUsingFallbackLabel
        logger.info(
            "Status item rebuild result: reason=\(reason.rawValue, privacy: .public) button=\(buttonPresent) window=\(hasWindow) length=\(length, format: .fixed(precision: 1)) fallback=\(usesFallback)"
        )

        guard Self.rebuildSucceeded(buttonPresent: buttonPresent, hasWindow: hasWindow) else {
            scheduleRepairRetry()
            return
        }
        repairRetryAttempts = 0
        repairRetryTask?.cancel()
    }

    private func scheduleRepairRetry() {
        repairRetryAttempts += 1
        guard repairRetryAttempts <= Self.maxRetryAttempts else {
            logger.error("Status item rebuild retries exhausted; giving up until the next lifecycle trigger")
            return
        }

        logger.error("Status item rebuild produced a dead item; retry #\(self.repairRetryAttempts) of \(Self.maxRetryAttempts) in 2s")
        repairRetryTask?.cancel()
        repairRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else {
                return
            }
            self?.scheduleStatusItemRepair(reason: .retry)
        }
    }

    private func configurePopover() {
        // AppKit's semitransient behavior can close on mouse-down in the positioning window,
        // before the status button's mouse-up action runs and reopens it. Own dismissal instead.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: MenuContentView(store: store, openSettings: openSettings)
        )
        hostingController.sizingOptions = []

        popoverHostingController = hostingController
        popover.contentViewController = hostingController
        updatePopoverLayout()
    }

    private func bindStore() {
        Publishers.CombineLatest3(store.$claude, store.$codex, store.$usageDisplayPreferences)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateButtonTitle()
                self?.updatePopoverLayout()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButtonTitle()
                self?.updatePopoverLayout()
            }
            .store(in: &cancellables)

        // Recalculate countdowns locally even when provider refresh is set to Manual.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard UserDefaults.standard.bool(forKey: UsageResetTime.showInMenuBarDefaultsKey) else { return }
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)
    }

    private func updateButtonTitle() {
        guard let button = statusItem?.button else {
            logger.error("Status item update skipped because the button is unavailable")
            return
        }

        let themeID = UserDefaults.standard.string(forKey: "selectedTheme") ?? AppTheme.defaultTheme.id
        let theme = AppTheme.resolvedTheme(themeID: themeID)
        let usesUnfocusedColors = StatusItemAppearance.usesUnfocusedColors(
            darkModeWhenNotFocused: UserDefaults.standard.bool(
                forKey: StatusItemAppearance.darkModeWhenNotFocusedDefaultsKey
            ),
            isPopoverShown: popover.isShown
        )
        let view = statusLabelView(theme: theme, usesUnfocusedColors: usesUnfocusedColors)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let image = renderer.nsImage else {
            if !isInRendererFallback {
                logger.error("Status item renderer failed; applying text fallback")
            }
            applyTextFallback(to: button)
            return
        }

        if isInRendererFallback {
            logger.info("Status item renderer recovered")
            isInRendererFallback = false
        }

        image.isTemplate = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = image
        statusItem?.length = Self.statusItemLength(forContentWidth: image.size.width)
    }

    private func statusLabelView(
        theme: AppTheme? = nil,
        usesUnfocusedColors: Bool = false
    ) -> StatusItemLabelView {
        let resolvedTheme = theme ?? AppTheme.resolvedTheme(
            themeID: UserDefaults.standard.string(forKey: "selectedTheme") ?? AppTheme.defaultTheme.id
        )
        let displayMode = MenuBarDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: "menuBarDisplayMode") ?? MenuBarDisplayMode.usage.rawValue
        ) ?? .usage
        let claudeStatus = store.agentStatus(for: .claude)
        let codexStatus = store.agentStatus(for: .codex)
        let claudeName = ProviderDisplayName.menuBarName(for: .claude)
        let codexName = ProviderDisplayName.menuBarName(for: .codex)
        let showResetTime = UserDefaults.standard.bool(forKey: UsageResetTime.showInMenuBarDefaultsKey)
        let claudeText = claudeStatus.availability.showsInPopover
            ? StatusItemFormatter.text(
                prefix: claudeName,
                snapshot: store.usageDisplayPreferences.filtered(store.claude, for: .menuBar),
                mode: displayMode,
                showResetTime: showResetTime
            )
            : nil
        let codexText = codexStatus.availability.showsInPopover
            ? StatusItemFormatter.text(
                prefix: codexName,
                snapshot: store.usageDisplayPreferences.filtered(store.codex, for: .menuBar),
                mode: displayMode,
                showResetTime: showResetTime
            )
            : nil

        let usesFallbackLabel = StatusItemLabelView.resolvedFallbackText(claudeText: claudeText, codexText: codexText) != nil
        if usesFallbackLabel, !isUsingFallbackLabel {
            logger.info("Using fallback status item label")
        }
        isUsingFallbackLabel = usesFallbackLabel

        return StatusItemLabelView(
            claudeText: claudeText,
            codexText: codexText,
            theme: resolvedTheme,
            usesUnfocusedColors: usesUnfocusedColors,
            unfocusedClaudeAccent: StatusItemAppearance.unfocusedAccent(
                for: .claude,
                from: UserDefaults.standard.string(
                    forKey: StatusItemAppearance.unfocusedClaudeAccentDefaultsKey
                )
            ),
            unfocusedCodexAccent: StatusItemAppearance.unfocusedAccent(
                for: .codex,
                from: UserDefaults.standard.string(
                    forKey: StatusItemAppearance.unfocusedCodexAccentDefaultsKey
                )
            )
        )
    }

    private func applyTextFallback(to button: NSStatusBarButton) {
        isInRendererFallback = true
        button.image = nil
        button.imagePosition = .noImage
        button.title = StatusItemLabelView.defaultFallbackText
        statusItem?.length = NSStatusItem.variableLength
    }

    private func updatePopoverLayout() {
        guard let hostingController = popoverHostingController else {
            return
        }

        // Measure SwiftUI's actual layout: providers can report any number of usage windows.
        // Leave room for the popover arrow and screen edges on the display hosting the status item.
        hostingController.rootView = MenuContentView(store: store, openSettings: openSettings)
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let maximumHeight = max(1, (screen?.visibleFrame.height ?? 640) - 24)
        let fittedSize = hostingController.sizeThatFits(
            in: NSSize(width: popoverWidth, height: maximumHeight)
        )
        let size = NSSize(width: popoverWidth, height: min(ceil(fittedSize.height), maximumHeight))
        guard popover.contentSize != size || hostingController.preferredContentSize != size else {
            return
        }

        popover.contentSize = size
        hostingController.preferredContentSize = size
        hostingController.view.setFrameSize(size)
    }

    static func statusItemLength(forContentWidth width: CGFloat) -> CGFloat {
        max(width + statusItemLengthPadding, minimumStatusItemLength)
    }

    static func rebuildSucceeded(buttonPresent: Bool, hasWindow: Bool) -> Bool {
        buttonPresent && hasWindow
    }

    /// Only genuine lifecycle events grant a fresh retry budget. `.wakeFollowup` is part of the same
    /// wake settling window, and `.retry` is the budget being SPENT; letting either reset the count
    /// would re-arm the loop it bounds. Exhaustive switch: adding a reason forces a decision here.
    static func resetsRetryBudget(_ reason: StatusItemRepairReason) -> Bool {
        switch reason {
        case .launch, .wake, .displayChange:
            return true
        case .wakeFollowup, .retry:
            return false
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showContextMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            closePopover()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        updatePopoverLayout()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        updateButtonTitle()
        startPopoverDismissMonitoring()
        Task {
            await store.refreshNotificationAuthorizationState()
        }
    }

    private func showContextMenu() {
        closePopover()

        let menu = NSMenu()
        menu.delegate = self

        let optionsItem = NSMenuItem(title: "Options...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: "")
        optionsItem.target = self
        menu.addItem(optionsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AIPace", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissMonitoring()
        updateButtonTitle()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func closePopover() {
        guard popover.isShown else {
            stopPopoverDismissMonitoring()
            return
        }
        popover.performClose(nil)
        stopPopoverDismissMonitoring()
    }

    private func startPopoverDismissMonitoring() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                // AppKit invokes event monitors on the main thread. Decide during this event,
                // rather than enqueueing a close that could run after a later click opens the menu.
                MainActor.assumeIsolated {
                    guard let self,
                          !Self.shouldDeferPopoverDismissal(
                            mouseLocation: NSEvent.mouseLocation,
                            statusItemFrame: self.statusItemScreenFrame,
                            isMouseDown: true
                          ) else {
                        return
                    }
                    self.closePopover()
                }
            }
        }

        if escapeKeyMonitor == nil {
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let self, self.popover.isShown else { return false }
                    self.closePopover()
                    return true
                }
                return handled ? nil : event
            }
        }

        if appDeactivationObserver == nil {
            appDeactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A click on our icon belongs to its action, even if macOS deactivates us first.
                    // Keyboard app switching still dismisses when the pointer happens to rest here.
                    guard !Self.shouldDeferPopoverDismissal(
                        mouseLocation: NSEvent.mouseLocation,
                        statusItemFrame: self.statusItemScreenFrame,
                        isMouseDown: NSEvent.pressedMouseButtons & 0b11 != 0
                    ) else { return }
                    self.closePopover()
                }
            }
        }
    }

    private var statusItemScreenFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    static func shouldDeferPopoverDismissal(
        mouseLocation: NSPoint, statusItemFrame: NSRect?, isMouseDown: Bool
    ) -> Bool {
        isMouseDown && (statusItemFrame?.contains(mouseLocation) ?? false)
    }

    private func stopPopoverDismissMonitoring() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }

        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }

        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
            self.appDeactivationObserver = nil
        }
    }
}
