import Foundation
import Testing
@testable import AIPace

struct AppVersionTests {
    @Test
    func parsesTagsWithAndWithoutPrefix() {
        #expect(AppVersion("v1.3.0")?.components == [1, 3, 0])
        #expect(AppVersion("1.3.0")?.components == [1, 3, 0])
        #expect(AppVersion(" 1.4 ")?.components == [1, 4])
        #expect(AppVersion("1.4.0-beta.1")?.components == [1, 4, 0])
        #expect(AppVersion("1.4.0-beta.1")?.description == "1.4.0")
    }

    @Test
    func rejectsNonNumericTags() {
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("release-2026") == nil)
        #expect(AppVersion("1.x.0") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test
    func comparesNumericallyAndPadsMissingComponents() {
        #expect(AppVersion("1.3.0")! < AppVersion("1.3.1")!)
        #expect(AppVersion("1.9.0")! < AppVersion("1.10.0")!)
        #expect(AppVersion("1.3")! == AppVersion("1.3.0")!)
        #expect(AppVersion("2.0")! > AppVersion("1.99.99")!)
        #expect(!(AppVersion("1.3.0")! < AppVersion("1.3.0")!))
    }
}

struct UpdateCheckerTests {
    @Test
    func makeReleasePicksTheDMGAssetAndItsDigest() {
        let payload = try! JSONDecoder().decode(GitHubRelease.self, from: Data(releaseJSON.utf8))
        let release = UpdateChecker.makeRelease(from: payload, repository: "owner/repo")

        #expect(release?.version.description == "1.4.0")
        #expect(release?.assetName == "AIPace-1.4.0.dmg")
        #expect(release?.downloadURL?.absoluteString == "https://github.com/owner/repo/releases/download/v1.4.0/AIPace-1.4.0.dmg")
        #expect(release?.expectedSHA256 == "8244f69b7391d53359f535477ebe0c755b04e0097c63b4f0647b89a2557aa88e")
        #expect(release?.pageURL.absoluteString == "https://github.com/owner/repo/releases/tag/v1.4.0")
    }

    @Test
    func makeReleaseResolvesWithoutAssetsAndFallsBackToATagURL() {
        let payload = GitHubRelease(tagName: "v2.0.0", htmlURL: nil, draft: nil, prerelease: nil, assets: nil)
        let release = UpdateChecker.makeRelease(from: payload, repository: "owner/repo")

        #expect(release?.downloadURL == nil)
        #expect(release?.assetName == nil)
        #expect(release?.pageURL.absoluteString == "https://github.com/owner/repo/releases/tag/v2.0.0")
    }

    @Test
    func makeReleaseRejectsANonVersionTag() {
        let payload = GitHubRelease(tagName: "nightly", htmlURL: nil, draft: nil, prerelease: nil, assets: nil)
        #expect(UpdateChecker.makeRelease(from: payload, repository: "owner/repo") == nil)
    }

    @Test
    func normalizedDigestAcceptsOnlyWellFormedSHA256() {
        let hex = String(repeating: "a", count: 64)
        #expect(UpdateChecker.normalizedDigest("sha256:\(hex.uppercased())") == hex)
        #expect(UpdateChecker.normalizedDigest("md5:\(hex)") == nil)
        #expect(UpdateChecker.normalizedDigest("sha256:abc") == nil)
        #expect(UpdateChecker.normalizedDigest(hex) == nil)
    }

    @Test
    func downloadDestinationSuffixesInsteadOfOverwriting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try UpdateChecker.downloadDestination(for: "AIPace-1.4.0.dmg", in: directory)
        #expect(first.lastPathComponent == "AIPace-1.4.0.dmg")

        try Data("existing".utf8).write(to: first)
        let second = try UpdateChecker.downloadDestination(for: "AIPace-1.4.0.dmg", in: directory)
        #expect(second.lastPathComponent == "AIPace-1.4.0 (1).dmg")
    }

    @Test
    func sha256HexMatchesTheKnownDigest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("payload.bin")
        try Data("hello".utf8).write(to: file)

        #expect(try UpdateChecker.sha256Hex(ofFileAt: file) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    private var releaseJSON: String {
        """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/owner/repo/releases/tag/v1.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "notes.txt",
              "browser_download_url": "https://github.com/owner/repo/releases/download/v1.4.0/notes.txt",
              "digest": null
            },
            {
              "name": "AIPace-1.4.0.dmg",
              "browser_download_url": "https://github.com/owner/repo/releases/download/v1.4.0/AIPace-1.4.0.dmg",
              "digest": "sha256:8244f69b7391d53359f535477ebe0c755b04e0097c63b4f0647b89a2557aa88e"
            }
          ]
        }
        """
    }
}

struct UpdateControllerTests {
    @Test
    @MainActor
    func reportsUpToDateWhenTheLatestReleaseIsNotNewer() async {
        let controller = UpdateController(
            client: stubClient(release: makeRelease("1.3.0")),
            currentVersion: AppVersion("1.3.0")
        )

        controller.checkForUpdates()

        #expect(await waitUntil { controller.state == .upToDate })
        #expect(controller.currentVersionText == "1.3.0")
    }

    @Test
    @MainActor
    func offersTheReleaseWhenItIsNewer() async {
        let release = makeRelease("1.4.0")
        let controller = UpdateController(
            client: stubClient(release: release),
            currentVersion: AppVersion("1.3.0")
        )

        controller.checkForUpdates()

        #expect(await waitUntil { controller.state == .available(release) })
    }

    @Test
    @MainActor
    func surfacesTheErrorMessageWhenTheCheckFails() async {
        let controller = UpdateController(
            client: UpdateClient(
                fetchLatestRelease: { throw ProcessRunnerError.invalidResponse("GitHub rate limit reached.") },
                downloadAsset: { _, _ in throw ProcessRunnerError.invalidResponse("unused") }
            ),
            currentVersion: AppVersion("1.3.0")
        )

        controller.checkForUpdates()

        #expect(await waitUntil { controller.state == .failed("GitHub rate limit reached.") })
    }

    @Test
    @MainActor
    func downloadReportsProgressAndEndsOnTheSavedFile() async {
        let release = makeRelease("1.4.0")
        let destination = URL(fileURLWithPath: "/tmp/AIPace-1.4.0.dmg")
        let controller = UpdateController(
            client: UpdateClient(
                fetchLatestRelease: { release },
                downloadAsset: { _, onProgress in
                    onProgress(0.5)
                    return destination
                }
            ),
            currentVersion: AppVersion("1.3.0")
        )

        controller.download(release)

        #expect(await waitUntil { controller.state == .downloaded(destination) })
    }

    @Test
    @MainActor
    func checkingIsIgnoredWhileAnotherOperationRuns() async {
        let controller = UpdateController(
            client: UpdateClient(
                fetchLatestRelease: {
                    try? await Task.sleep(for: .seconds(5))
                    return makeRelease("9.9.9")
                },
                downloadAsset: { _, _ in throw ProcessRunnerError.invalidResponse("unused") }
            ),
            currentVersion: AppVersion("1.3.0")
        )

        controller.checkForUpdates()
        #expect(controller.isBusy)

        controller.download(makeRelease("1.4.0"))
        #expect(controller.state == .checking)
    }
}

// MARK: - Helpers

private func makeRelease(_ version: String) -> AppRelease {
    AppRelease(
        version: AppVersion(version)!,
        pageURL: URL(string: "https://github.com/owner/repo/releases/tag/v\(version)")!,
        assetName: "AIPace-\(version).dmg",
        downloadURL: URL(string: "https://github.com/owner/repo/releases/download/v\(version)/AIPace-\(version).dmg")!,
        expectedSHA256: nil
    )
}

private func stubClient(release: AppRelease) -> UpdateClient {
    UpdateClient(
        fetchLatestRelease: { release },
        downloadAsset: { _, _ in throw ProcessRunnerError.invalidResponse("unused") }
    )
}

/// The controller drives its work from a detached task, so tests poll instead of awaiting a handle.
@MainActor
private func waitUntil(timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
