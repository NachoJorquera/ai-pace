import Foundation
import Testing
@testable import AIPace

struct ClaudeCredentialLoaderTests {
    @Test
    func resolveCredentialsPrefersFileOverEnvironment() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": " file-token ",
                "refreshToken": " refresh-token ",
                "expiresAt": "12345",
                "subscriptionType": " pro ",
                "scopes": ["user:inference", "user:mcp_servers"]
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"],
            keychainLoadOverride: .success(nil)
        )

        let resolution = loader.resolveCredentials()

        #expect(resolution.credentials?.source == .file)
        #expect(resolution.credentials?.oauth.accessToken == "file-token")
        #expect(resolution.credentials?.oauth.refreshToken == "refresh-token")
        #expect(resolution.credentials?.oauth.expiresAt == 12345)
        #expect(resolution.credentials?.oauth.subscriptionType == "pro")
        #expect(resolution.credentials?.oauth.scopes == ["user:inference", "user:mcp_servers"])
    }

    @Test
    func resolveCredentialsFallsBackToEnvironment() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": " env-token \n"],
            keychainLoadOverride: .success(nil)
        )

        let resolution = loader.resolveCredentials()

        #expect(resolution.credentials?.source == .environment)
        #expect(resolution.credentials?.oauth.accessToken == "env-token")
    }

    @Test
    func needsRefreshHonorsExpiryBuffer() {
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )

        let now = Date().timeIntervalSince1970 * 1000
        let fresh = ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: now + 10 * 60 * 1000, subscriptionType: nil)
        let expiring = ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: now + 4 * 60 * 1000, subscriptionType: nil)

        #expect(!loader.needsRefresh(fresh))
        #expect(loader.needsRefresh(expiring))
        #expect(loader.needsRefresh(ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: nil, subscriptionType: nil)))
    }

    @Test
    func saveCredentialsWritesUpdatedFileContents() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "updated-token",
                refreshToken: "updated-refresh",
                expiresAt: 999,
                subscriptionType: "claude_max"
            ),
            source: .file,
            fullData: ["existing": "value"]
        )

        loader.saveCredentials(result)

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        let data = try Data(contentsOf: credentialsURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(object["claudeAiOauth"] as? [String: Any])

        #expect(object["existing"] as? String == "value")
        #expect(oauth["accessToken"] as? String == "updated-token")
        #expect(oauth["refreshToken"] as? String == "updated-refresh")
        #expect(oauth["expiresAt"] as? Double == 999)
        #expect(oauth["subscriptionType"] as? String == "claude_max")
    }

    @Test
    func saveCredentialsPreservesUnknownKeys() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "new-token",
                refreshToken: "new-refresh",
                expiresAt: 999,
                subscriptionType: "team"
            ),
            source: .file,
            fullData: [
                "mcpOAuth": ["someServer": ["accessToken": "mcp-token"]],
                "claudeAiOauth": [
                    "accessToken": "old-token",
                    "refreshToken": "old-refresh",
                    "expiresAt": 111,
                    "refreshTokenExpiresAt": 222,
                    "scopes": ["user:inference", "user:mcp_servers"],
                    "subscriptionType": "team",
                    "rateLimitTier": "default_claude_max_5x",
                ],
            ]
        )

        loader.saveCredentials(result)

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        let data = try Data(contentsOf: credentialsURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(object["claudeAiOauth"] as? [String: Any])

        #expect(object["mcpOAuth"] != nil)
        #expect(oauth["accessToken"] as? String == "new-token")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Double == 999)
        #expect(oauth["refreshTokenExpiresAt"] as? Int == 222)
        #expect(oauth["scopes"] as? [String] == ["user:inference", "user:mcp_servers"])
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_5x")
    }

    @Test
    func parseKeychainAccountExtractsAcctBlob() {
        let output = """
        keychain: "/Users/user/Library/Keychains/login.keychain-db"
        version: 512
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="user"
            "mdat"<timedate>=0x32303236303733313134313031385A00  "20260731141018Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: output) == "user")
    }

    @Test
    func parseKeychainAccountDecodesHexRenderedAccount() {
        // `security` renders any account holding a non-ASCII byte as 0x<hex> plus an escaped copy.
        let output = """
        attributes:
            "acct"<blob>=0x74C3A97374206E69C3B16F  "t\\303\\251st ni\\303\\261o"
            "svce"<blob>="Claude Code-credentials"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: output) == "tést niño")
    }

    @Test
    func parseKeychainAccountDecodesMultiByteHexAccount() {
        // Emoji and CJK accounts are 3 and 4 byte UTF-8 sequences.
        let output = """
        attributes:
            "acct"<blob>=0xE4B8ADE69687F09F9880  "\\344\\270\\255\\346\\226\\207\\360\\237\\230\\200"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: output) == "中文😀")
    }

    @Test
    func parseKeychainAccountKeepsQuotedAndRejectsMalformedForms() {
        let quotedWithSpaces = """
        attributes:
            "acct"<blob>="my account"
        """
        let embeddedSubstring = """
        attributes:
            "svce"<blob>="\\"acct\\"<blob>=\\"spoofed\\""
        """
        let emptyQuoted = """
        attributes:
            "acct"<blob>=""
        """
        let oddHex = """
        attributes:
            "acct"<blob>=0xABC  "junk"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: quotedWithSpaces) == "my account")
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: embeddedSubstring) == nil)
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: emptyQuoted) == nil)
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: oddHex) == nil)
    }

    @Test
    func parseKeychainAccountHandlesNullAndMissing() {
        let nullOutput = """
        attributes:
            "acct"<blob>=<NULL>
            "svce"<blob>="Claude Code-credentials"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: nullOutput) == nil)
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: "") == nil)
    }

    @Test
    func canPersistRequiresAResolvableKeychainAccount() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        // Disposable service with no item behind it: nothing is created, so nothing is left behind.
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
        let oauth = ClaudeOAuthCredentials(accessToken: "token", refreshToken: "refresh", expiresAt: 1, subscriptionType: nil)

        let unknownAccount = ClaudeCredentialResult(
            oauth: oauth,
            source: .keychain,
            fullData: [:],
            keychainAccount: nil
        )
        let knownAccount = ClaudeCredentialResult(
            oauth: oauth,
            source: .keychain,
            fullData: [:],
            keychainAccount: "test-account"
        )
        let fileCredentials = ClaudeCredentialResult(oauth: oauth, source: .file, fullData: [:])
        let environmentCredentials = ClaudeCredentialResult(oauth: oauth, source: .environment, fullData: [:])

        #expect(!loader.canPersist(unknownAccount))
        #expect(loader.canPersist(knownAccount))
        #expect(loader.canPersist(fileCredentials))
        #expect(loader.canPersist(environmentCredentials))
    }

    @Test
    func saveCredentialsReportsWhetherTheWriteHappened() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

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
        let oauth = ClaudeOAuthCredentials(accessToken: "token", refreshToken: "refresh", expiresAt: 999, subscriptionType: nil)

        #expect(loader.saveCredentials(ClaudeCredentialResult(oauth: oauth, source: .file, fullData: [:])))
        // No item exists for the service, so the account is unknowable and the write must be reported
        // as failed instead of silently skipped.
        #expect(
            !loader.saveCredentials(
                ClaudeCredentialResult(oauth: oauth, source: .keychain, fullData: [:], keychainAccount: nil)
            )
        )
    }

    @Test
    func saveToKeychainRoundTripPreservesItemAndAccount() throws {
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

        let seedJSON = """
        {"mcpOAuth": {"srv": {"accessToken": "mcp-1"}}, "claudeAiOauth": {"accessToken": "old", "refreshToken": "old-r", "expiresAt": 1, "refreshTokenExpiresAt": 2, "scopes": ["user:inference"], "subscriptionType": "team", "rateLimitTier": "tier-1"}}
        """
        _ = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-s", service, "-a", "test-account", "-w", seedJSON],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )

        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainService: service
        )

        let loaded = try #require(loader.loadCredentials())
        #expect(loaded.source == .keychain)
        #expect(loaded.keychainAccount == "test-account")

        let creationDateBefore = try #require(Self.keychainCreationDate(from: Self.keychainAttributes(service: service)))

        var updated = loaded
        updated.oauth.accessToken = "new-token"
        updated.oauth.refreshToken = "new-refresh"
        updated.oauth.expiresAt = 999
        loader.saveCredentials(updated)

        let rawSecret = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = try #require(JSONSerialization.jsonObject(with: Data(rawSecret.utf8)) as? [String: Any])
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

        #expect(root["mcpOAuth"] != nil)
        #expect(oauth["accessToken"] as? String == "new-token")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Double == 999)
        #expect(oauth["refreshTokenExpiresAt"] as? Int == 2)
        #expect(oauth["scopes"] as? [String] == ["user:inference"])
        #expect(oauth["rateLimitTier"] as? String == "tier-1")

        let attributes = try Self.keychainAttributes(service: service)
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: attributes) == "test-account")
        #expect(Self.keychainCreationDate(from: attributes) == creationDateBefore)
    }

    @Test
    func saveToKeychainWritesLargePayloadWithoutTruncation() throws {
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

        // The real "Claude Code-credentials" blob is ~8.4 KB, mostly MCP OAuth entries.
        let padding = String(repeating: "m", count: 8000)
        let seedRoot: [String: Any] = [
            "mcpOAuth": ["srv": ["accessToken": padding]],
            "claudeAiOauth": [
                "accessToken": "old",
                "refreshToken": "old-r",
                "expiresAt": 1,
                "refreshTokenExpiresAt": 2,
                "scopes": ["user:inference"],
                "subscriptionType": "team",
                "rateLimitTier": "tier-1",
            ],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seedRoot, options: [.sortedKeys])
        let seedJSON = try #require(String(data: seedData, encoding: .utf8))
        #expect(seedData.count > 8000)

        _ = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-s", service, "-a", "test-account", "-w", seedJSON],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )

        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainService: service
        )

        let loaded = try #require(loader.loadCredentials())
        var updated = loaded
        updated.oauth.accessToken = "new-token"
        updated.oauth.refreshToken = "new-refresh"
        updated.oauth.expiresAt = 999
        loader.saveCredentials(updated)

        let rawSecret = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // A truncated write leaves non-JSON garbage here, which is the corruption we guard against.
        #expect(rawSecret.utf8.count > 8000)
        let root = try #require(JSONSerialization.jsonObject(with: Data(rawSecret.utf8)) as? [String: Any])
        let mcp = try #require(root["mcpOAuth"] as? [String: Any])
        let server = try #require(mcp["srv"] as? [String: Any])
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

        #expect(server["accessToken"] as? String == padding)
        #expect(oauth["accessToken"] as? String == "new-token")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Double == 999)
        #expect(oauth["refreshTokenExpiresAt"] as? Int == 2)
        #expect(oauth["scopes"] as? [String] == ["user:inference"])
        #expect(oauth["rateLimitTier"] as? String == "tier-1")
    }

    @Test
    func saveToKeychainRereadsAccountInsteadOfCreatingDuplicate() throws {
        let service = "aipace-test-\(UUID().uuidString)"
        defer {
            // Delete twice: if the save wrongly created a duplicate, the first delete only removes one.
            for _ in 0..<2 {
                _ = try? ProcessRunner.runSync(
                    executable: "/usr/bin/security",
                    arguments: ["delete-generic-password", "-s", service],
                    input: nil,
                    timeout: 10,
                    currentDirectory: nil
                )
            }
        }

        _ = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: [
                "add-generic-password", "-s", service, "-a", "real-account",
                "-w", #"{"claudeAiOauth": {"accessToken": "old"}}"#,
            ],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )

        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainService: service
        )
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: "new-token", refreshToken: nil, expiresAt: 999, subscriptionType: nil),
            source: .keychain,
            fullData: ["claudeAiOauth": ["accessToken": "old"]],
            keychainAccount: nil
        )

        loader.saveCredentials(result)

        let attributes = try Self.keychainAttributes(service: service)
        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: attributes) == "real-account")

        // Removing the single item must leave nothing behind; a leftover means a duplicate was made
        // and every later load would keep reading the stale one.
        _ = try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", service],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )
        #expect(throws: ProcessRunnerError.self) {
            _ = try Self.keychainAttributes(service: service)
        }
    }

    @Test
    func saveToKeychainSkipsWriteWhenAccountCannotBeResolved() throws {
        let service = "aipace-test-\(UUID().uuidString)"
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
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
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "new-token",
                refreshToken: "new-refresh",
                expiresAt: 999,
                subscriptionType: "team"
            ),
            source: .keychain,
            fullData: ["claudeAiOauth": ["accessToken": "old"]],
            keychainAccount: nil
        )

        loader.saveCredentials(result)

        // No item existed, so the account is unknowable: the save must abort rather than guess an
        // account and create a duplicate item that later loads would read past.
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", service, "-w"],
                input: nil,
                timeout: 10,
                currentDirectory: nil
            )
        }
    }

    private static func keychainAttributes(service: String) throws -> String {
        try ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )
    }

    private static func keychainCreationDate(from attributesOutput: String) -> String? {
        for line in attributesOutput.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("\"cdat\"<timedate>=") else {
                continue
            }
            return trimmedLine
        }
        return nil
    }

    @Test
    func mapKeychainErrorCategorizesCommonFailures() throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: try makeTemporaryDirectory(),
            environment: [:],
            keychainLoadOverride: .success(nil)
        )

        switch loader.mapKeychainError(.terminated(1, "User interaction is not allowed.")) {
        case .failure(let issue):
            #expect(issue == .keychainAccessDenied)
        default:
            Issue.record("Expected access denied classification")
        }

        switch loader.mapKeychainError(.terminated(44, "The specified item could not be found in the keychain.")) {
        case .success(let credentials):
            #expect(credentials == nil)
        default:
            Issue.record("Expected missing keychain item to map to no credentials")
        }
    }
}
