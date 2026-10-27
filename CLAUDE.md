# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

The SwiftPM package lives in `app/`, not the repo root. Every `swift` command must run from there.

```bash
cd app
swift build
swift test
swift test --filter ClaudeProbeTests                    # one suite
swift test --filter ClaudeProbeTests/refreshRequestBodyUsesStoredScopes   # one test
```

`./scripts/test.sh` runs the suite from the repo root and exports `DEVELOPER_DIR` first; it forwards arguments to `swift test`.

Packaging builds the `.app` bundle and a DMG into `dist/`:

```bash
./scripts/build-dmg.sh --version 1.3.0
./scripts/build-dmg.sh --version 1.3.0 --sign "Developer ID Application: ..." --notarize-profile PROFILE
```

Without `--sign` the bundle is ad-hoc signed, which is fine locally but Gatekeeper blocks it after download. The script stamps the version into the copied bundle only; the repo's `app/Sources/AIPace/Info.plist` must be bumped separately, in the same commit that closes the `[Unreleased]` section of `CHANGELOG.md`.

`swift-testing` is pinned to `"6.2.4" ..< "6.3.0"` in `Package.swift`. Do not relax it: 6.3.0 resolves to a development snapshot that fails to link `_TestingInterop` against release Swift 6.3.x toolchains, and the toolchain does not expose a bundled `Testing` module to SwiftPM at tools-version 6.2 or 6.3.

CI (`.github/workflows/ci.yml`) only runs `swift build`, not the tests.

## Architecture

A menu bar accessory app (`NSApp.setActivationPolicy(.accessory)`, no dock icon, no main window). Data flows in one direction:

```
ClaudeProbe ─┐
             ├─> UsageStore (@MainActor, ObservableObject) ─> StatusItemController ─> status item label
CodexProbe ──┘                                             └─> MenuContentView popover
```

`UsageStore.refresh()` runs both probes concurrently in a task group on a timer (default 5 min, configurable, or manual) and publishes each snapshot as soon as its own probe returns. A refresh ends only when both probes return, and `isRefreshing` blocks the next one until then, so a probe that never returns freezes updates for both providers. Both probes conform to `ProviderSnapshotFetching`, which is the seam tests inject through (`ProbeStub`, `CountingProbe`).

### Variable-length usage windows

`ProviderSnapshot.windows` is an array, not a fixed pair, because providers disagree on how many quotas they expose: Codex reports one weekly window, Claude reports two plus an optional model-scoped one. `fiveHour` and `weekly` are computed lookups over that array and return optionals.

Adding a `UsageWindowKind` case ripples into exhaustive switches: `Loc.windowLabel` covers 7 languages, and `UsageWindowKey.storageKey` is persisted in UserDefaults for notification toggles (changing a kind silently orphans a user's saved toggle).

`UsageWindow.label` holds a provider-supplied display name and takes precedence over the localized kind label in the popover.

### PATH for spawned tools

`ProcessRunner` adds the user's login shell PATH to every tool it spawns. The shell runs once per app run (`cachedLoginShellPath`), because each run takes about a second, as `$SHELL -i -l +m -c 'printf %s "$PATH"'`:

- `-i` sources `.zshrc`, where tools such as nvm add their directories; `-l` alone misses them.
- `+m` turns job control off. When the app is launched from a terminal, an interactive shell with job control tries to take over that terminal and the kernel stops it (`ps` state `T`), leaving both providers on "Checking…".
- A 10 s deadline kills the shell with SIGKILL, because a stopped process keeps SIGTERM pending.

### Claude probe

Credentials resolve in a fixed order (`ClaudeCredentialLoader.resolveCredentials`): `~/.claude/.credentials.json`, then Keychain service `Claude Code-credentials` via `/usr/bin/security`, then `CLAUDE_CODE_OAUTH_TOKEN`. Only the first two are refreshable.

**A token refresh rotates the pair server side, so the stored refresh token dies the moment the request succeeds.** `canPersist(_:)` must be checked *before* refreshing; refreshing with no writable destination logs the user out of Claude Code with no way back. `saveCredentials` returns whether the write happened so callers can surface the failure instead of leaving a dead token behind. Keychain *attribute* reads (`keychainAccountFromLiveItem`) do not consult the item ACL and cannot prompt; the write does, which is why it stays on `/usr/bin/security`.

The usage endpoint (`GET https://api.anthropic.com/api/oauth/usage`) is undocumented and visibly in flux, full of null experimental keys. Consequences encoded in `ClaudeProbe`:

- `ClaudeUsageResponse.init(from:)` is hand-written so a malformed `limits` array degrades to `nil` instead of failing the whole response and taking the two working windows with it.
- Model-scoped quotas live only in the `limits` array, keyed `weekly_scoped`. The legacy per-model keys (`seven_day_opus`, `seven_day_sonnet`) are always null now.
- The model name comes from `scope.model.display_name`; `scope.model.id` is null, so never match on an id or hardcode a model name.
- **Do not filter on `is_active`.** It flips between refreshes and has been observed true on the session entry and false on both weekly entries, then the reverse. Filtering on it makes windows appear and disappear.

### Codex probe

Spawns `codex -s read-only -a never app-server` from the user's home directory (avoids workspace trust prompts) and speaks JSON-RPC over stdin/stdout: `initialize`, `initialized`, then `account/rateLimits/read`.

Current codex-cli accepts only `on-request` and `never` for `-a`. Any other value makes the process exit during argument parsing, before it answers `initialize`. Codex then drops out of the popover and Settings shows "Codex app-server closed before returning response id 1."

Window kind is derived from `windowDurationMins` (10080 = weekly, 300 = 5h), not from `primary`/`secondary` position, because Codex dropped its 5h quota and `primary` is now the weekly window. Falls back to positional mapping when the duration is absent or when both windows would classify to the same kind.

### Updates

`UpdateChecker` reads `https://api.github.com/repos/NachoJorquera/ai-pace/releases/latest`, i.e. the **fork**, which is where the DMGs are published, not `upstream`. `UpdateClient` is the injection seam (same shape as `ClaudeAPIClient`); `UpdateController` is the `@MainActor` state machine the Settings card observes, and it only ever runs on an explicit button press.

- The current version comes from `CFBundleShortVersionString`, so `AppVersion.current` is nil under `swift run` and every release then counts as newer. Only a packaged bundle compares correctly.
- `AppVersion` returns nil for any non-numeric tag, so a tag like `nightly` never compares as newer instead of crashing the check.
- The download runs through a `URLSessionDownloadDelegate` rather than `URLSession.download(for:delegate:)` because the finished file has to be moved onto its destination *inside* `didFinishDownloadingTo`; URLSession deletes the temporary file as soon as that callback returns.
- GitHub reports the asset checksum as `digest: "sha256:<hex>"`. A mismatch deletes the file and surfaces an error; a missing digest just skips verification.

### Failure handling

`UsageStore` classifies errors by **substring matching on the message string** (`classifyClaudeStatus`, `classifyCodexStatus`, `isTransientClaudeAuthFailure`). Changing the text of a `ProcessRunnerError.invalidResponse` silently breaks classification, and the popover starts showing raw errors instead of actionable states. Grep for the literal before editing a message.

`mergedSnapshot` keeps the previous snapshot when the current fetch has no data, for HTTP 429 / rate limit errors, and for one consecutive transient Claude auth failure, so a Keychain hiccup does not blank the UI.

### Status item resilience

The macOS status item is unreliable across display wake and display-configuration changes, and `StatusItemController` carries a whole line of defenses: a 500 ms `StatusItemRepairDebouncer` coalescing repair triggers, a health gate that refreshes a live item in place rather than tearing it down, a bounded retry when a rebuild produces a dead item, and a follow-up repair after wake. `item.autosaveName = "AIPaceStatusItem"` makes AppKit persist both position and `isVisible` under a stable key.

If the icon is invisible, the authoritative diagnostic is ControlCenter's own log, not the app:

```bash
/usr/bin/log show --last 2m --style compact \
  --predicate 'process == "ControlCenter" AND category == "appStatusItems"'
```

`Starting to track blocked host` means the app is toggled off in System Settings > Menu Bar and nothing on the app side can override it. `Starting to track host` with `positioning .ephemeral` means there is no saved position and the item landed in the collapsed group behind the menu bar chevron. Never delete `NSStatusItem Preferred Position AIPaceStatusItem` as a diagnostic; large values like `5728` are legitimate on multi-display setups.

## Tests

Uses swift-testing (`@Test`, `#expect`), not XCTest. `TestSupport.swift` holds the shared builders: `makeSnapshot(_:fiveHourUsed:weeklyUsed:)` for the classic two-window shape and `makeSnapshot(_:windows:)` for anything else.

`ClaudeCredentialLoaderTests` hit the **real** login keychain through `withDisposableKeychainService`, which seeds and deletes items under a UUID service name. They are slow (seconds each) and can prompt. Unit-level credential tests use the `keychainLoadOverride` / `keychainSaveOverride` injection points instead, and `ClaudeAPIClient`'s three closures stub the network.

## Repository

This is a fork of `lbybrilee/ai-pace`; `origin` is the fork and `upstream` is the read-only original. **`gh` resolves to the parent repository by default**, so `gh pr create` without `--repo` opens a public PR on someone else's repo. Verify with `gh repo set-default --view` before any `gh` command that writes.

Actions is enabled but workflows on the fork stay suspended until enabled once from the Actions tab, so pushes may produce zero CI runs.
