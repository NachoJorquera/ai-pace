import SwiftUI

enum StatusItemAppearance {
    static let darkModeWhenNotFocusedDefaultsKey = "darkModeWhenNotFocused"
    static let unfocusedClaudeAccentDefaultsKey = "unfocusedClaudeAccentHex"
    static let unfocusedCodexAccentDefaultsKey = "unfocusedCodexAccentHex"

    static func usesUnfocusedColors(darkModeWhenNotFocused: Bool, isPopoverShown: Bool) -> Bool {
        darkModeWhenNotFocused && !isPopoverShown
    }

    static func unfocusedAccent(for provider: ProviderKind, from hexValue: String? = nil) -> Color {
        let defaultHex = provider == .claude ? "#3F1E17" : "#14263F"
        return AppColorHex.color(from: hexValue) ?? AppColorHex.color(from: defaultHex) ?? .black
    }
}

struct StatusItemLabelView: View {
    nonisolated static let defaultFallbackText = "AIPace"

    let claudeText: String?
    let codexText: String?
    let theme: AppTheme
    let usesUnfocusedColors: Bool
    let unfocusedClaudeAccent: Color
    let unfocusedCodexAccent: Color

    var body: some View {
        let visibleClaudeText = Self.visibleText(claudeText)
        let visibleCodexText = Self.visibleText(codexText)

        HStack(spacing: 6) {
            if let claudeText = visibleClaudeText {
                pill(
                    text: claudeText,
                    color: resolvedColor(
                        focused: theme.claudeAccent,
                        unfocused: unfocusedClaudeAccent
                    )
                )
            }
            if let codexText = visibleCodexText {
                pill(
                    text: codexText,
                    color: resolvedColor(
                        focused: theme.codexAccent,
                        unfocused: unfocusedCodexAccent
                    )
                )
            }
            if let fallbackText = Self.resolvedFallbackText(
                claudeText: visibleClaudeText,
                codexText: visibleCodexText
            ) {
                pill(
                    text: fallbackText,
                    color: resolvedColor(
                        focused: Color(red: 0.36, green: 0.38, blue: 0.42),
                        unfocused: .black
                    )
                )
            }
        }
        .frame(height: 22)
        .allowsHitTesting(false)
    }

    nonisolated static func resolvedFallbackText(claudeText: String?, codexText: String?) -> String? {
        guard visibleText(claudeText) == nil, visibleText(codexText) == nil else {
            return nil
        }
        return defaultFallbackText
    }

    private nonisolated static func visibleText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(color)
            )
    }

    private func resolvedColor(focused: Color, unfocused: Color) -> Color {
        usesUnfocusedColors ? unfocused : focused
    }
}
