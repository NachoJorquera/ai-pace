import AppKit
import CryptoKit
import Foundation

// MARK: - Version

/// Dotted numeric version, tolerant of a leading `v` and of a `-beta` style suffix (which is ignored
/// for comparison). Returns nil for anything that is not a numeric dotted version, so a malformed tag
/// never compares as "newer".
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]
    let description: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        guard !parts.isEmpty else {
            return nil
        }

        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else {
                return nil
            }
            parsed.append(value)
        }

        components = parsed
        description = core
    }

    /// The running bundle's `CFBundleShortVersionString`. Nil when running outside an app bundle
    /// (`swift run`), where there is no version to compare against.
    static var current: AppVersion? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(raw)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

// MARK: - Release model

struct AppRelease: Sendable, Equatable {
    let version: AppVersion
    let pageURL: URL
    let assetName: String?
    let downloadURL: URL?
    /// Lowercased hex SHA-256 of the asset, when GitHub reports one. Verified after download.
    let expectedSHA256: String?

    static func == (lhs: AppRelease, rhs: AppRelease) -> Bool {
        lhs.version == rhs.version && lhs.downloadURL == rhs.downloadURL && lhs.pageURL == rhs.pageURL
    }
}

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [GitHubReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

// MARK: - Client

/// Network seam for the update flow. Both closures are stubbed in tests, mirroring `ClaudeAPIClient`.
struct UpdateClient: Sendable {
    let fetchLatestRelease: @Sendable () async throws -> AppRelease
    let downloadAsset: @Sendable (AppRelease, @escaping @Sendable (Double) -> Void) async throws -> URL

    init(
        fetchLatestRelease: @escaping @Sendable () async throws -> AppRelease = UpdateChecker.liveFetchLatestRelease,
        downloadAsset: @escaping @Sendable (AppRelease, @escaping @Sendable (Double) -> Void) async throws -> URL = UpdateChecker.liveDownloadAsset
    ) {
        self.fetchLatestRelease = fetchLatestRelease
        self.downloadAsset = downloadAsset
    }
}

enum UpdateChecker {
    /// Releases live on the fork, not on `upstream`.
    static let repository = "NachoJorquera/ai-pace"

    static func latestReleaseURL(repository: String = repository) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static func liveFetchLatestRelease() async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AIPace", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProcessRunnerError.invalidResponse("Update check failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProcessRunnerError.invalidResponse("The update endpoint returned an invalid response.")
        }

        switch http.statusCode {
        case 200 ..< 300:
            break
        case 404:
            throw ProcessRunnerError.invalidResponse("No published release was found for \(repository).")
        case 403, 429:
            throw ProcessRunnerError.invalidResponse("GitHub rate limit reached. Try again in a few minutes.")
        default:
            throw ProcessRunnerError.invalidResponse("The update endpoint returned HTTP \(http.statusCode).")
        }

        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ProcessRunnerError.invalidResponse("The update endpoint returned an unreadable release payload.")
        }

        guard let release = makeRelease(from: payload, repository: repository) else {
            throw ProcessRunnerError.invalidResponse("The latest release tag `\(payload.tagName)` is not a version number.")
        }
        return release
    }

    /// Maps a GitHub payload onto `AppRelease`, picking the first `.dmg` asset. A release with no DMG
    /// still resolves, so the UI can fall back to opening the release page.
    static func makeRelease(from payload: GitHubRelease, repository: String = repository) -> AppRelease? {
        guard let version = AppVersion(payload.tagName) else {
            return nil
        }

        let pageURL = payload.htmlURL.flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repository)/releases/tag/\(payload.tagName)")!
        let asset = (payload.assets ?? []).first { $0.name.lowercased().hasSuffix(".dmg") }

        return AppRelease(
            version: version,
            pageURL: pageURL,
            assetName: asset?.name,
            downloadURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            expectedSHA256: asset?.digest.flatMap(normalizedDigest(_:))
        )
    }

    /// GitHub reports `sha256:<hex>`; anything else is ignored rather than failing the download.
    static func normalizedDigest(_ digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else {
            return nil
        }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return hex
    }

    static func liveDownloadAsset(
        _ release: AppRelease,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let downloadURL = release.downloadURL else {
            throw ProcessRunnerError.invalidResponse("This release has no downloadable disk image.")
        }

        let destination = try downloadDestination(for: release.assetName ?? downloadURL.lastPathComponent)
        let downloader = ReleaseAssetDownloader(destination: destination, onProgress: onProgress)
        let fileURL = try await downloader.download(from: downloadURL)

        guard let expected = release.expectedSHA256 else {
            return fileURL
        }

        let actual: String
        do {
            actual = try sha256Hex(ofFileAt: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ProcessRunnerError.invalidResponse("The downloaded disk image could not be verified: \(error.localizedDescription)")
        }

        guard actual == expected else {
            try? FileManager.default.removeItem(at: fileURL)
            throw ProcessRunnerError.invalidResponse("The downloaded disk image failed its checksum and was deleted. Download it from the release page instead.")
        }
        return fileURL
    }

    /// A free path inside ~/Downloads, suffixing `(n)` rather than overwriting an existing download.
    static func downloadDestination(
        for fileName: String,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder: URL
        if let directory {
            folder = directory
        } else if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            folder = downloads
        } else {
            folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }

        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download plumbing

/// Moves the finished download onto `destination` from inside the delegate callback: URLSession deletes
/// its temporary file as soon as that callback returns.
private final class ReleaseAssetDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
    }

    func download(from url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                var request = URLRequest(url: url)
                request.setValue("AIPace", forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func takeContinuation() -> CheckedContinuation<URL, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let continuation = takeContinuation() else {
            return
        }

        if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            continuation.resume(throwing: ProcessRunnerError.invalidResponse("The download failed with HTTP \(http.statusCode)."))
            return
        }

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume(returning: destination)
        } catch {
            continuation.resume(throwing: ProcessRunnerError.invalidResponse("The download could not be saved: \(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let continuation = takeContinuation() else {
            return
        }
        guard let error else {
            continuation.resume(throwing: ProcessRunnerError.invalidResponse("The download ended without producing a file."))
            return
        }
        continuation.resume(throwing: ProcessRunnerError.invalidResponse("The download failed: \(error.localizedDescription)"))
    }
}

// MARK: - Controller

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(Double)
        case downloaded(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let client: UpdateClient
    private let currentVersion: AppVersion?
    private var task: Task<Void, Never>?

    init(client: UpdateClient = UpdateClient(), currentVersion: AppVersion? = AppVersion.current) {
        self.client = client
        self.currentVersion = currentVersion
    }

    deinit {
        task?.cancel()
    }

    var currentVersionText: String {
        currentVersion?.description ?? "—"
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading:
            return true
        case .idle, .upToDate, .available, .downloaded, .failed:
            return false
        }
    }

    func checkForUpdates() {
        guard !isBusy else {
            return
        }
        state = .checking
        task?.cancel()
        task = Task { [client, currentVersion] in
            do {
                let release = try await client.fetchLatestRelease()
                guard !Task.isCancelled else {
                    return
                }
                // Without a bundle version (running from `swift run`) any published release counts as newer.
                if let currentVersion, release.version <= currentVersion {
                    state = .upToDate
                } else {
                    state = .available(release)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func download(_ release: AppRelease) {
        guard !isBusy else {
            return
        }
        state = .downloading(0)
        task?.cancel()
        task = Task { [client] in
            do {
                let fileURL = try await client.downloadAsset(release) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else {
                            return
                        }
                        self.state = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else {
                    return
                }
                state = .downloaded(fileURL)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openReleasePage(_ release: AppRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }
}
