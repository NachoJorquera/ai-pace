import AppKit
import Foundation
import Testing
@testable import AIPace

struct StatusItemControllerTests {
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
    func unfocusedColorsDefaultToBlackAndSupportOverrides() {
        let defaultAccent = StatusItemAppearance.unfocusedAccent(from: nil)
        let customAccent = StatusItemAppearance.unfocusedAccent(from: "#123ABC")

        #expect(AppColorHex.string(from: defaultAccent) == "#000000")
        #expect(AppColorHex.string(from: customAccent) == "#123ABC")
    }

    @Test
    @MainActor
    func statusItemLengthIsClampedToMinimumVisibleWidth() {
        #expect(StatusItemController.statusItemLength(forContentWidth: 0) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 10) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 40) == 52)
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
