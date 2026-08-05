# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic versioning.

## [Unreleased]

## [1.1.3] - 2026-08-05

### Fixed
- Token refresh no longer deletes the Claude Code Keychain credentials (the previous save path removed the item and the re-add silently failed), which logged users out of Claude Code daily
- Credential writes now preserve all stored fields (`scopes`, `refreshTokenExpiresAt`, `rateLimitTier`, `mcpOAuth`) instead of dropping them
- Token refresh requests the originally granted OAuth scopes instead of a hardcoded subset
- Token refresh is skipped when the refreshed credentials could not be saved, so a failed write no longer invalidates the stored token; the reason is shown in the popover instead of failing silently
- Keychain credentials whose account contains non-ASCII characters are now read correctly, so those accounts can be updated too
- Menu bar icon no longer disappears permanently after display wake: healthy status items are refreshed in place instead of torn down, failed rebuilds retry with a bounded budget, and the icon keeps a stable menu bar position

## [1.1.2] - 2026-04-25

### Added
- Menu bar display name settings for Claude and Codex, limited to 7 characters each

## [1.1.1] - 2026-04-25

### Added
- Remaining percentage display options for the menu bar and popover (Thank you @cifilter)

## [1.1.0] - 2026-04-07

### Added
- Menu bar display mode that shows both usage percentages and pacing insight in the status item

## [1.0.1] - 2026-04-07

### Added
- Launch at startup option in the settings window

### Changed
- The project no longer publishes a GitHub Release workflow
- README now documents building a DMG with the current app version by default
- DMG builds now clear stale Swift module caches before release builds

## [1.0.0] - 2026-04-06

### Added
- First public release of AIPace for macOS
- Menu bar usage display for Claude and Codex `5h` and `weekly` windows
- Main popover with provider cards, pacing insights, refresh controls, and notifications
- Settings window for language, auto refresh, notification sound, menu bar display mode, and custom provider colors
- README screenshots and DMG-based install instructions

## [0.1.0] - 2026-04-06

### Added
- Initial app packaging and release workflow groundwork
