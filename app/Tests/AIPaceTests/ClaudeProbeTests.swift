import Foundation
import Testing
@testable import AIPace

struct ClaudeProbeTests {
    @Test
    func fetchReturnsUsageSnapshotAndDetailText() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "token",
                "refreshToken": "refresh",
                "expiresAt": 9999999999999,
                "subscriptionType": "claude_max"
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        try Data(
            """
            {
              "oauthAccount": {
                "displayName": "Ada Lovelace"
              }
            }
            """.utf8
        ).write(to: configURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let resolver = ClaudeAccountInfoResolver(configURL: configURL)
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { credentials, _ in
                Issue.record("refreshToken should not be called for fresh credentials")
                return credentials
            },
            fetchUsage: { _ in
                ClaudeUsageResponse(
                    fiveHour: ClaudeQuotaData(utilization: 25, resetsAt: "2026-04-06T12:00:00Z"),
                    sevenDay: ClaudeQuotaData(utilization: 60, resetsAt: "2026-04-12T12:00:00Z")
                )
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: resolver,
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.provider == .claude)
        #expect(snapshot.fiveHour?.usedPercentage == 25)
        #expect(snapshot.weekly?.usedPercentage == 60)
        #expect(snapshot.detail == "Max · Ada Lovelace")
        #expect(snapshot.fiveHour?.message == nil)
        #expect(snapshot.weekly?.message == nil)
    }

    @Test
    func fetchReportsLoggedInWhenCredentialsCannotBeRead() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { credentials, _ in credentials },
            fetchUsage: { _ in
                Issue.record("fetchUsage should not be called when credentials are missing")
                return ClaudeUsageResponse(fiveHour: nil, sevenDay: nil)
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.fiveHour?.message == "Claude is logged in, but credentials could not be read from file, Keychain, or environment.")
        #expect(snapshot.weekly?.message == snapshot.fiveHour?.message)
    }

    @Test
    func fetchRetriesAfterAuthenticationFailureForRefreshableCredentials() async throws {
        actor State {
            var usageTokens: [String] = []
            var refreshCalls = 0

            func recordUsageToken(_ token: String) -> Int {
                usageTokens.append(token)
                return usageTokens.count
            }

            func recordRefresh() {
                refreshCalls += 1
            }
        }

        let state = State()
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "old-token",
                "refreshToken": "refresh-token",
                "expiresAt": 9999999999999
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { credentials, _ in
                await state.recordRefresh()
                var updated = credentials
                updated.oauth.accessToken = "new-token"
                return updated
            },
            fetchUsage: { token in
                let call = await state.recordUsageToken(token)
                if call == 1 {
                    throw ProcessRunnerError.invalidResponse("Claude authentication failed.")
                }
                return ClaudeUsageResponse(
                    fiveHour: ClaudeQuotaData(utilization: 30, resetsAt: "2026-04-06T12:00:00Z"),
                    sevenDay: ClaudeQuotaData(utilization: 55, resetsAt: "2026-04-12T12:00:00Z")
                )
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.fiveHour?.usedPercentage == 30)
        #expect(snapshot.weekly?.usedPercentage == 55)
        let usageTokens = await state.usageTokens
        let refreshCalls = await state.refreshCalls
        #expect(usageTokens == ["old-token", "new-token"])
        #expect(refreshCalls == 1)
    }

    @Test
    func liveRefreshTokenAbortsBeforeNetworkWhenKeychainAccountIsUnknown() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        // Disposable service with no item behind it, so the account is unknowable and the credential is
        // not persistable. No item is ever created, so nothing is left in the Keychain.
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

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainService: service
        )
        let credentials = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "stored-token",
                refreshToken: "stored-refresh",
                expiresAt: 1,
                subscriptionType: nil
            ),
            source: .keychain,
            fullData: ["claudeAiOauth": ["accessToken": "stored-token"]]
        )

        #expect(!loader.canPersist(credentials))

        do {
            // Reaching the network here would rotate the token pair server side and strand the keychain
            // with a dead refresh token, which is the failure this guard exists to prevent.
            _ = try await ClaudeProbe.liveRefreshToken(credentials, credentialLoader: loader)
            Issue.record("Expected the refresh to abort before issuing the network request")
        } catch let error as ProcessRunnerError {
            guard case .invalidResponse(let message) = error else {
                Issue.record("Expected an invalidResponse error, got \(error)")
                return
            }
            #expect(message.contains("Claude token refresh skipped"))
            #expect(message.contains("log in again"))
        }
    }

    @Test
    func persistRefreshedCredentialsThrowsWhenKeychainWriteFails() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil),
            keychainSaveOverride: { _ in false }
        )
        let credentials = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "stored-token",
                refreshToken: "stored-refresh",
                expiresAt: 1,
                subscriptionType: nil
            ),
            source: .keychain,
            fullData: ["claudeAiOauth": ["accessToken": "stored-token"]]
        )

        do {
            _ = try ClaudeProbe.persistRefreshedCredentials(
                ClaudeRefreshResponse(accessToken: "new-token", refreshToken: "new-refresh", expiresIn: 3600),
                into: credentials,
                credentialLoader: loader
            )
            Issue.record("Expected a failed write to surface as an error")
        } catch let error as ProcessRunnerError {
            guard case .invalidResponse(let message) = error else {
                Issue.record("Expected an invalidResponse error, got \(error)")
                return
            }
            #expect(message.contains("could not be saved"))
        }
    }

    @Test
    func persistRefreshedCredentialsReturnsUpdatedCredentialsWhenWriteSucceeds() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil),
            keychainSaveOverride: { _ in true }
        )
        let credentials = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "stored-token",
                refreshToken: "stored-refresh",
                expiresAt: 1,
                subscriptionType: nil
            ),
            source: .keychain,
            fullData: ["claudeAiOauth": ["accessToken": "stored-token"]]
        )

        let updated = try ClaudeProbe.persistRefreshedCredentials(
            ClaudeRefreshResponse(accessToken: "new-token", refreshToken: "new-refresh", expiresIn: 3600),
            into: credentials,
            credentialLoader: loader
        )

        #expect(updated.oauth.accessToken == "new-token")
        #expect(updated.oauth.refreshToken == "new-refresh")
        #expect((updated.oauth.expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000)
    }

    @Test
    func refreshErrorSurfacesInProviderSnapshotMessage() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "expired-token",
                "refreshToken": "refresh-token",
                "expiresAt": 1
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { _, _ in
                throw ProcessRunnerError.invalidResponse("Claude token was refreshed but could not be saved.")
            },
            fetchUsage: { _ in
                Issue.record("fetchUsage should not be called when the refresh failed")
                return ClaudeUsageResponse(fiveHour: nil, sevenDay: nil)
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.fiveHour?.message == "Claude token was refreshed but could not be saved.")
        #expect(snapshot.weekly?.message == snapshot.fiveHour?.message)
    }

    @Test
    func refreshRequestBodyUsesStoredScopes() {
        let body = ClaudeProbe.refreshRequestBody(
            refreshToken: "refresh-1",
            scopes: ["user:file_upload", "user:inference", "user:mcp_servers", "user:profile", "user:sessions:claude_code"]
        )

        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["refresh_token"] as? String == "refresh-1")
        #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(body["scope"] as? String == "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code")
    }

    @Test
    func refreshRequestBodyFallsBackToDefaultScopes() {
        let missing = ClaudeProbe.refreshRequestBody(refreshToken: "refresh-1", scopes: nil)
        let empty = ClaudeProbe.refreshRequestBody(refreshToken: "refresh-1", scopes: [])

        #expect(missing["scope"] as? String == "user:profile user:inference user:sessions:claude_code")
        #expect(empty["scope"] as? String == "user:profile user:inference user:sessions:claude_code")
    }

    /// Verbatim payload shape returned by the live usage endpoint, including the experimental keys, so
    /// the decoder is pinned against what the server actually sends.
    @Test
    func decodesLiveUsagePayloadIncludingScopedModelLimit() throws {
        let json = """
        {"five_hour":{"utilization":17.0,"resets_at":"2026-08-05T16:39:59.718894+00:00","limit_dollars":null},
         "seven_day":{"utilization":11.0,"resets_at":"2026-08-11T09:59:59.718914+00:00","used_dollars":null},
         "seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null,"nimbus_quill":null,
         "extra_usage":{"is_enabled":false,"monthly_limit":null},
         "limits":[
           {"kind":"session","group":"session","percent":17,"severity":"normal","resets_at":"2026-08-05T16:39:59.718894+00:00","scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":11,"severity":"normal","resets_at":"2026-08-11T09:59:59.718914+00:00","scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":10,"severity":"normal","resets_at":"2026-08-11T09:59:59.719165+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
         ],
         "spend":{"percent":0},"member_dashboard_available":false}
        """

        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))

        #expect(usage.fiveHour?.utilization == 17)
        #expect(usage.sevenDay?.utilization == 11)
        #expect(usage.limits?.count == 3)

        let scoped = ClaudeProbe().scopedWindows(from: usage)

        #expect(scoped.count == 1)
        #expect(scoped.first?.kind == .scopedWeekly)
        #expect(scoped.first?.label == "Fable")
        #expect(scoped.first?.usedPercentage == 10)
        #expect(scoped.first?.resetsAt != nil)
        #expect(scoped.first?.message == nil)
    }

    @Test
    func scopedWindowsIgnoreUnscopedKindsAndEntriesWithoutAPercent() {
        let usage = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: nil,
            limits: [
                ClaudeLimitEntry(kind: "session", percent: 17, resetsAt: nil, scope: nil),
                ClaudeLimitEntry(kind: "weekly_all", percent: 11, resetsAt: nil, scope: nil),
                ClaudeLimitEntry(
                    kind: "weekly_scoped",
                    percent: nil,
                    resetsAt: nil,
                    scope: ClaudeLimitScope(model: ClaudeLimitScopeModel(displayName: "Fable"))
                ),
            ]
        )

        #expect(ClaudeProbe().scopedWindows(from: usage).isEmpty)
    }

    @Test
    func missingLimitsDegradesToTheTwoStandardWindows() {
        let noLimits = ClaudeUsageResponse(fiveHour: nil, sevenDay: nil, limits: nil)
        let emptyLimits = ClaudeUsageResponse(fiveHour: nil, sevenDay: nil, limits: [])

        #expect(ClaudeProbe().scopedWindows(from: noLimits).isEmpty)
        #expect(ClaudeProbe().scopedWindows(from: emptyLimits).isEmpty)
    }

    /// A malformed entry drops the whole `limits` array, but must not take the response down with it:
    /// the two standard windows come from sibling keys and still work.
    @Test
    func malformedLimitsArrayIsDroppedWithoutFailingTheResponse() throws {
        let json = """
        {"five_hour":{"utilization":17.0,"resets_at":null},
         "seven_day":{"utilization":11.0,"resets_at":null},
         "limits":[
           {"kind":"weekly_scoped","percent":"not-a-number","scope":{"model":{"display_name":"Fable"}}},
           {"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Iguana"}}}
         ]}
        """

        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))

        #expect(usage.fiveHour?.utilization == 17)
        #expect(usage.sevenDay?.utilization == 11)
        #expect(usage.limits == nil)
        #expect(ClaudeProbe().scopedWindows(from: usage).isEmpty)
    }

    @Test
    func limitsOfAnUnexpectedTypeAreDiscardedWithoutFailing() throws {
        let json = """
        {"five_hour":{"utilization":17.0,"resets_at":null},"seven_day":null,"limits":{"unexpected":"object"}}
        """

        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))

        #expect(usage.fiveHour?.utilization == 17)
        #expect(usage.limits == nil)
    }

    @Test
    func fetchAppendsScopedWindowAfterTheStandardOnes() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "token-1"],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { credentials, _ in credentials },
            fetchUsage: { _ in
                ClaudeUsageResponse(
                    fiveHour: ClaudeQuotaData(utilization: 17, resetsAt: nil),
                    sevenDay: ClaudeQuotaData(utilization: 11, resetsAt: nil),
                    limits: [
                        ClaudeLimitEntry(
                            kind: "weekly_scoped",
                            percent: 10,
                            resetsAt: nil,
                            scope: ClaudeLimitScope(model: ClaudeLimitScopeModel(displayName: "Fable"))
                        ),
                    ]
                )
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.windows.map(\.kind) == [.fiveHour, .weekly, .scopedWeekly])
        #expect(snapshot.windows.map(\.usedPercentage) == [17, 11, 10])
        #expect(StatusItemFormatter.text(prefix: "Cl", snapshot: snapshot, mode: .usage) == "Cl 17/11/10")
    }
}
