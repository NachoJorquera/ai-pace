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
        keychain: "/Users/nacho/Library/Keychains/login.keychain-db"
        version: 512
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="nacho"
            "mdat"<timedate>=0x32303236303733313134313031385A00  "20260731141018Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """

        #expect(ClaudeCredentialLoader.parseKeychainAccount(from: output) == "nacho")
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
