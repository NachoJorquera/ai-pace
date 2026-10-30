import AppKit
import Foundation
import Testing
@testable import AIPace

struct StatusItemControllerTests {
    @Test
    @MainActor
    func clickingTheStatusItemLeavesDismissalToItsToggleAction() {
        // A status item can be on a display to the left of the main display.
        let frame = NSRect(x: -600, y: 980, width: 180, height: 24)
        let pointer = NSPoint(x: -500, y: 990)
        #expect(StatusItemController.shouldDeferPopoverDismissal(
            mouseLocation: pointer, statusItemFrame: frame, isMouseDown: true
        ))
        // Switching apps with the keyboard must close even if the mouse still rests on the icon.
        #expect(!StatusItemController.shouldDeferPopoverDismissal(
            mouseLocation: pointer, statusItemFrame: frame, isMouseDown: false
        ))
    }

    @Test
    @MainActor
    func outsideClicksAndUnavailableStatusItemsDoNotBlockDismissal() {
        let frame = NSRect(x: 900, y: 980, width: 180, height: 24)
        #expect(!StatusItemController.shouldDeferPopoverDismissal(
            mouseLocation: NSPoint(x: 1100, y: 990), statusItemFrame: frame, isMouseDown: true
        ))
        #expect(!StatusItemController.shouldDeferPopoverDismissal(
            mouseLocation: NSPoint(x: 950, y: 500), statusItemFrame: frame, isMouseDown: true
        ))
        #expect(!StatusItemController.shouldDeferPopoverDismissal(
            mouseLocation: NSPoint(x: 950, y: 990), statusItemFrame: nil, isMouseDown: true
        ))
    }

    @Test
    func statusItemLabelFallsBackWhenProviderTextsAreMissingOrBlank() {
        #expect(StatusItemLabelView.resolvedFallbackText(claudeText: nil, codexText: nil) == "AIPace")
        #expect(StatusItemLabelView.resolvedFallbackText(claudeText: " ", codexText: "\n") == "AIPace")
        #expect(StatusItemLabelView.resolvedFallbackText(claudeText: "Cl 12/34", codexText: nil) == nil)
        #expect(StatusItemLabelView.resolvedFallbackText(claudeText: nil, codexText: "Cx 56/78") == nil)
    }

    @Test
    func unfocusedColorsAreUsedOnlyWhenEnabledAndThePopoverIsClosed() {
        #expect(StatusItemAppearance.usesUnfocusedColors(darkModeWhenNotFocused: true, isPopoverShown: false))
        #expect(!StatusItemAppearance.usesUnfocusedColors(darkModeWhenNotFocused: true, isPopoverShown: true))
        #expect(!StatusItemAppearance.usesUnfocusedColors(darkModeWhenNotFocused: false, isPopoverShown: false))
    }

    @Test
    func unfocusedColorsHaveProviderDefaultsAndSupportOverrides() {
        let claudeAccent = StatusItemAppearance.unfocusedAccent(for: .claude)
        let codexAccent = StatusItemAppearance.unfocusedAccent(for: .codex, from: "invalid")
        let customAccent = StatusItemAppearance.unfocusedAccent(for: .claude, from: "#123ABC")

        #expect(AppColorHex.string(from: claudeAccent) == "#3F1E17")
        #expect(AppColorHex.string(from: codexAccent) == "#14263F")
        #expect(AppColorHex.string(from: customAccent) == "#123ABC")
        #expect(AppColorHex.string(from: StatusItemAppearance.unfocusedAccent(for: .codex, from: "#000000")) == "#000000")
    }

    @Test
    @MainActor
    func statusItemLengthIsClampedToMinimumVisibleWidth() {
        #expect(StatusItemController.statusItemLength(forContentWidth: 0) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 10) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 40) == 40)
    }

    @Test
    @MainActor
    func rebuildSucceededRequiresButtonAndWindow() {
        #expect(StatusItemController.rebuildSucceeded(buttonPresent: true, hasWindow: true))
        #expect(!StatusItemController.rebuildSucceeded(buttonPresent: true, hasWindow: false))
        #expect(!StatusItemController.rebuildSucceeded(buttonPresent: false, hasWindow: false))
        #expect(!StatusItemController.rebuildSucceeded(buttonPresent: false, hasWindow: true))
    }

    @Test
    @MainActor
    func onlyLifecycleTriggersResetTheRetryBudget() {
        #expect(StatusItemController.resetsRetryBudget(.launch))
        #expect(StatusItemController.resetsRetryBudget(.wake))
        #expect(StatusItemController.resetsRetryBudget(.displayChange))
        #expect(!StatusItemController.resetsRetryBudget(.wakeFollowup))
        #expect(!StatusItemController.resetsRetryBudget(.retry))
    }
}
