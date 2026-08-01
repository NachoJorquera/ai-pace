import Foundation
@testable import AIPace

func makeWindow(
    _ kind: UsageWindowKind,
    used: Double? = nil,
    resetsAt: Date? = nil,
    message: String? = nil
) -> UsageWindow {
    UsageWindow(kind: kind, usedPercentage: used, resetsAt: resetsAt, message: message)
}

func makeSnapshot(
    _ provider: ProviderKind,
    fiveHourUsed: Double? = nil,
    weeklyUsed: Double? = nil,
    fiveHourReset: Date? = nil,
    weeklyReset: Date? = nil,
    fiveHourMessage: String? = nil,
    weeklyMessage: String? = nil,
    detail: String? = nil
) -> ProviderSnapshot {
    ProviderSnapshot(
        provider: provider,
        fiveHour: makeWindow(.fiveHour, used: fiveHourUsed, resetsAt: fiveHourReset, message: fiveHourMessage),
        weekly: makeWindow(.weekly, used: weeklyUsed, resetsAt: weeklyReset, message: weeklyMessage),
        detail: detail
    )
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `body` with a disposable keychain service name, guaranteeing cleanup even when the test throws.
func withDisposableKeychainService(_ body: (String) throws -> Void) rethrows {
    let service = "aipace-test-\(UUID().uuidString)"
    defer {
        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", service],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )
    }
    try body(service)
}

/// Seeds a generic password item. Fails the calling test on error via `throws`.
func seedKeychainItem(service: String, account: String, secret: String) throws {
    _ = try ProcessRunner.runSync(
        executable: "/usr/bin/security",
        arguments: ["add-generic-password", "-s", service, "-a", account, "-w", secret],
        input: nil,
        timeout: 10,
        currentDirectory: nil
    )
}

/// Reads the raw secret back, trimmed. Throws when the item does not exist.
func readKeychainSecret(service: String) throws -> String {
    try ProcessRunner.runSync(
        executable: "/usr/bin/security",
        arguments: ["find-generic-password", "-s", service, "-w"],
        input: nil,
        timeout: 10,
        currentDirectory: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Reads the raw `security` attribute dump for a service, used to assert on the keychain account or
/// creation date without going through `ClaudeCredentialLoader`.
func keychainAttributes(service: String) throws -> String {
    try ProcessRunner.runSync(
        executable: "/usr/bin/security",
        arguments: ["find-generic-password", "-s", service],
        input: nil,
        timeout: 10,
        currentDirectory: nil
    )
}

/// Builds the 7-key `claudeAiOauth` + `mcpOAuth` credential blob used to seed keychain integration tests.
func makeCredentialBlobJSON(accessToken: String = "old", refreshToken: String = "old-r") -> String {
    """
    {"mcpOAuth": {"srv": {"accessToken": "mcp-1"}}, "claudeAiOauth": {"accessToken": "\(accessToken)", "refreshToken": "\(refreshToken)", "expiresAt": 1, "refreshTokenExpiresAt": 2, "scopes": ["user:inference"], "subscriptionType": "team", "rateLimitTier": "tier-1"}}
    """
}

actor ProbeQueue {
    private var snapshots: [ProviderSnapshot]

    init(_ snapshots: [ProviderSnapshot]) {
        precondition(!snapshots.isEmpty, "ProbeQueue requires at least one snapshot")
        self.snapshots = snapshots
    }

    func next() -> ProviderSnapshot {
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return snapshots.removeFirst()
    }
}

actor ProbeCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

struct ProbeStub: ProviderSnapshotFetching {
    let queue: ProbeQueue

    func fetch() async -> ProviderSnapshot {
        await queue.next()
    }
}

struct CountingProbe: ProviderSnapshotFetching {
    let snapshot: ProviderSnapshot
    let counter: ProbeCounter

    func fetch() async -> ProviderSnapshot {
        await counter.increment()
        return snapshot
    }
}

func waitUntil(
    maxAttempts: Int = 100,
    pollInterval: Duration = .milliseconds(10),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}

@MainActor
final class NotificationManagerSpy: NotificationManaging {
    var authorizationGranted = true
    var systemNotificationsDisabled = false
    private(set) var authorizationRequests = 0
    private(set) var sentKeys: [UsageWindowKey] = []
    private(set) var sentSounds: [NotificationSoundOption] = []
    private(set) var previewedSounds: [NotificationSoundOption] = []

    func notificationsDisabledInSystem() async -> Bool {
        systemNotificationsDisabled
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func sendRefreshNotification(for key: UsageWindowKey, sound: NotificationSoundOption) async {
        sentKeys.append(key)
        sentSounds.append(sound)
    }

    func preview(sound: NotificationSoundOption) {
        previewedSounds.append(sound)
    }
}

@MainActor
final class LaunchAtStartupManagerSpy: LaunchAtStartupManaging {
    var state: LaunchAtStartupState = .disabled
    var failure: Error?
    private(set) var setCalls: [Bool] = []

    func currentState() -> LaunchAtStartupState {
        state
    }

    func setEnabled(_ enabled: Bool) throws -> LaunchAtStartupState {
        setCalls.append(enabled)
        if let failure {
            throw failure
        }
        state = enabled ? .enabled : .disabled
        return state
    }
}
