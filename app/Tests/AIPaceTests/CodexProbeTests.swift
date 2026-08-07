import Foundation
import Testing
@testable import AIPace

struct CodexProbeTests {
    @Test
    func numericValueParsesCommonJSONRepresentations() {
        let probe = CodexProbe()

        #expect(probe.numericValue(12) == 12)
        #expect(probe.numericValue("12.5") == 12.5)
        #expect(probe.numericValue(NSNumber(value: 7.25)) == 7.25)
        #expect(probe.numericValue("nope") == nil)
    }

    @Test
    func parseWindowRequiresUsedPercentAndParsesResetTimestamp() {
        let probe = CodexProbe()
        let window = probe.parseWindow([
            "usedPercent": "62.5",
            "resetsAt": 1_710_000_000,
            "windowDurationMins": 10080,
        ])

        #expect(window?.usedPercent == 62.5)
        #expect(window?.resetsAt == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(window?.windowDurationMins == 10080)
        #expect(probe.parseWindow(["resetsAt": 1_710_000_000]) == nil)
        #expect(probe.parseWindow(["usedPercent": 1])?.windowDurationMins == nil)
        #expect(probe.parseWindow(["usedPercent": 1, "windowDurationMins": "300"])?.windowDurationMins == 300)
    }

    @Test
    func weeklyOnlyPlanYieldsASingleWeeklyWindow() {
        let probe = CodexProbe()
        let resetsAt = Date(timeIntervalSince1970: 1_786_545_388)
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 42, resetsAt: resetsAt, windowDurationMins: 10080),
            secondary: nil,
            planType: "plus"
        )

        let windows = probe.usageWindows(from: limits)

        #expect(windows.count == 1)
        #expect(windows.first?.kind == .weekly)
        #expect(windows.first?.usedPercentage == 42)
        #expect(windows.first?.resetsAt == resetsAt)
    }

    @Test
    func legacyTwoWindowPlanIsClassifiedByDuration() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 10, resetsAt: nil, windowDurationMins: 300),
            secondary: CodexRateLimitWindow(usedPercent: 20, resetsAt: nil, windowDurationMins: 10080),
            planType: nil
        )

        let windows = probe.usageWindows(from: limits)

        #expect(windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(windows.map(\.usedPercentage) == [10, 20])
    }

    @Test
    func missingDurationFallsBackToPositionalMapping() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 10, resetsAt: nil, windowDurationMins: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, resetsAt: nil, windowDurationMins: nil),
            planType: nil
        )

        #expect(probe.usageWindows(from: limits).map(\.kind) == [.fiveHour, .weekly])
        #expect(CodexProbe.windowKind(forDurationMins: nil, fallback: .weekly) == .weekly)
        #expect(CodexProbe.windowKind(forDurationMins: 300, fallback: .weekly) == .fiveHour)
        #expect(CodexProbe.windowKind(forDurationMins: 1440, fallback: .fiveHour) == .weekly)
    }

    @Test
    func collidingDurationsKeepBothWindowsViaPositionalFallback() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 10, resetsAt: nil, windowDurationMins: 10080),
            secondary: CodexRateLimitWindow(usedPercent: 20, resetsAt: nil, windowDurationMins: 10080),
            planType: nil
        )

        let windows = probe.usageWindows(from: limits)

        #expect(windows.count == 2)
        #expect(windows.map(\.kind) == [.fiveHour, .weekly])
    }

    @Test
    func noReportedWindowsYieldsOneWeeklyWindowCarryingTheMessage() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(primary: nil, secondary: nil, planType: "plus")

        #expect(probe.usageWindows(from: limits).isEmpty)

        let snapshot = ProviderSnapshot(
            provider: .codex,
            windows: [UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: "No usage limits returned.")],
            detail: nil
        )

        #expect(snapshot.hasUsageData == false)
        #expect(snapshot.firstMessage == "No usage limits returned.")
    }

    @Test
    func readResponseReturnsMatchingPayload() async throws {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ignored\":true}}")
            continuation.yield("not json")
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"rateLimits\":{}}}")
            continuation.finish()
        }

        let payload = try await readResponse(withID: 2, from: stream)

        #expect(payload["id"] as? Int == 2)
        #expect((payload["result"] as? [String: Any]) != nil)
    }

    @Test
    func readResponseThrowsMatchingServerError() async {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"message\":\"No session\"}}")
            continuation.finish()
        }

        do {
            _ = try await readResponse(withID: 2, from: stream)
            Issue.record("Expected invalid response error")
        } catch let error as ProcessRunnerError {
            guard case .invalidResponse(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "No session")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
