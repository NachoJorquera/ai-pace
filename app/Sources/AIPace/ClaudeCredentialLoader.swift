import Foundation
import os

struct ClaudeOAuthCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var scopes: [String]? = nil
}

enum ClaudeCredentialSource: Sendable, Equatable {
    case file
    case keychain
    case environment
}

enum ClaudeCredentialLoadIssue: Error, Sendable, Equatable {
    case keychainAccessDenied
    case keychainFailure(String)

    var message: String {
        switch self {
        case .keychainAccessDenied:
            return "Claude Keychain access denied."
        case .keychainFailure(let message):
            return message
        }
    }
}

struct ClaudeCredentialResult: @unchecked Sendable {
    var oauth: ClaudeOAuthCredentials
    let source: ClaudeCredentialSource
    var fullData: [String: Any]
    var keychainAccount: String? = nil
}

struct ClaudeCredentialResolution {
    let credentials: ClaudeCredentialResult?
    let issue: ClaudeCredentialLoadIssue?
}

struct ClaudeCredentialLoader {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let keychainService: String
    private let keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>?
    private let keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)?
    private static let refreshBufferMs: Double = 5 * 60 * 1000
    private static let logger = Logger(subsystem: "com.aipace.app", category: "Credentials")

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "Claude Code-credentials",
        keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>? = nil,
        keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.keychainService = keychainService
        self.keychainLoadOverride = keychainLoadOverride
        self.keychainSaveOverride = keychainSaveOverride
    }

    func loadCredentials() -> ClaudeCredentialResult? {
        resolveCredentials().credentials
    }

    func resolveCredentials() -> ClaudeCredentialResolution {
        if let credentials = loadFromFile() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        let keychainResult = loadFromKeychain()
        if case .success(let credentials) = keychainResult, let credentials {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        if let credentials = loadFromEnvironment() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        switch keychainResult {
        case .success:
            return ClaudeCredentialResolution(credentials: nil, issue: nil)
        case .failure(let issue):
            return ClaudeCredentialResolution(credentials: nil, issue: issue)
        }
    }

    func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt else {
            return true
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + Self.refreshBufferMs >= expiresAt
    }

    func saveCredentials(_ result: ClaudeCredentialResult) {
        switch result.source {
        case .file:
            saveToFile(result)
        case .keychain:
            saveToKeychain(result)
        case .environment:
            return
        }
    }

    private func credentialsFileURL() -> URL {
        homeDirectory.appendingPathComponent(".claude/.credentials.json")
    }

    private func loadFromFile() -> ClaudeCredentialResult? {
        let url = credentialsFileURL()
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }
        return makeCredentialResult(from: root, source: .file)
    }

    private func loadFromKeychain() -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        if let keychainLoadOverride {
            return keychainLoadOverride
        }

        do {
            let output = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", keychainService, "-w"],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )

            guard
                let data = output.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let root = object as? [String: Any]
            else {
                return .success(nil)
            }

            guard var result = makeCredentialResult(from: root, source: .keychain) else {
                return .success(nil)
            }
            result.keychainAccount = keychainAccountFromLiveItem()
            return .success(result)
        } catch let error as ProcessRunnerError {
            return mapKeychainError(error)
        } catch {
            return .failure(.keychainFailure("Claude Keychain lookup failed: \(error.localizedDescription)"))
        }
    }

    private func loadFromEnvironment() -> ClaudeCredentialResult? {
        guard let rawToken = environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
            return nil
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: token, refreshToken: nil, expiresAt: nil, subscriptionType: nil),
            source: .environment,
            fullData: [:]
        )
    }

    private func makeCredentialResult(from root: [String: Any], source: ClaudeCredentialSource) -> ClaudeCredentialResult? {
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let rawToken = oauth["accessToken"] as? String
        else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: trimmed(oauth["refreshToken"] as? String),
                expiresAt: parseExpiresAt(oauth["expiresAt"]),
                subscriptionType: trimmed(oauth["subscriptionType"] as? String),
                scopes: parseScopes(oauth["scopes"])
            ),
            source: source,
            fullData: root
        )
    }

    private func saveToFile(_ result: ClaudeCredentialResult) {
        let url = credentialsFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let root = updatedFullData(for: result) else {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func saveToKeychain(_ result: ClaudeCredentialResult) {
        if let keychainSaveOverride {
            keychainSaveOverride(result)
            return
        }

        guard
            let root = updatedFullData(for: result),
            let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            Self.logger.error("Could not serialize credential blob for keychain save.")
            return
        }

        guard let account = resolvedKeychainAccount(result.keychainAccount) else {
            Self.logger.error("Aborting keychain credential save: could not determine the item account.")
            return
        }

        do {
            _ = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["add-generic-password", "-U", "-s", keychainService, "-a", account, "-w", json],
                input: nil,
                timeout: 10,
                currentDirectory: nil
            )
        } catch {
            Self.logger.error("Keychain credential save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `-U` matches the item to update by service *and* account, so a wrong account silently creates
    /// a duplicate that later loads would read past. Never guess: re-read the account from the live
    /// item and give up if it is still unknown.
    private func resolvedKeychainAccount(_ account: String?) -> String? {
        if let account, !account.isEmpty {
            return account
        }

        return keychainAccountFromLiveItem()
    }

    /// Single place that reads the `acct` attribute off the live item, so the parsing rules can never
    /// drift between the load path and the save path.
    private func keychainAccountFromLiveItem() -> String? {
        let attributesOutput = (try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainService],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )) ?? ""
        return Self.parseKeychainAccount(from: attributesOutput)
    }

    private func updatedFullData(for result: ClaudeCredentialResult) -> [String: Any]? {
        var root = result.fullData
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = result.oauth.accessToken
        if let refreshToken = result.oauth.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = result.oauth.expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        if let subscriptionType = result.oauth.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        root["claudeAiOauth"] = oauth
        return root
    }

    private func parseExpiresAt(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func parseScopes(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else {
            return nil
        }
        let scopes = array.compactMap { $0 as? String }
        return scopes.isEmpty ? nil : scopes
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseKeychainAccount(from attributesOutput: String) -> String? {
        let prefix = "\"acct\"<blob>="
        for line in attributesOutput.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix(prefix) else {
                continue
            }
            let value = trimmedLine.dropFirst(prefix.count)
            // `security` switches to `0x<hex>  "escaped"` whenever the account holds a non-ASCII byte,
            // so the hex form is the only readable rendering for those accounts.
            if value.hasPrefix("0x") {
                return decodeHexBlob(value.dropFirst(2))
            }
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
                return nil
            }
            let account = String(value.dropFirst().dropLast())
            return account.isEmpty ? nil : account
        }
        return nil
    }

    private static func decodeHexBlob(_ value: Substring) -> String? {
        let digits = value.prefix { $0.isHexDigit }
        guard !digits.isEmpty, digits.count % 2 == 0 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index ..< next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        while bytes.last == 0 {
            bytes.removeLast()
        }

        guard let account = String(bytes: bytes, encoding: .utf8), !account.isEmpty else {
            return nil
        }
        return account
    }

    func mapKeychainError(_ error: ProcessRunnerError) -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        guard case .terminated(_, let output) = error else {
            return .failure(.keychainFailure(error.localizedDescription))
        }

        let normalized = output.lowercased()
        if normalized.contains("could not be found in the keychain") || normalized.contains("item could not be found") {
            return .success(nil)
        }

        if normalized.contains("user interaction is not allowed")
            || normalized.contains("authorization was denied")
            || normalized.contains("user canceled")
            || normalized.contains("user cancelled") {
            return .failure(.keychainAccessDenied)
        }

        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .failure(.keychainFailure("Claude Keychain lookup failed."))
        }
        return .failure(.keychainFailure("Claude Keychain lookup failed: \(message)"))
    }
}
