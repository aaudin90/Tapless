import Foundation
import Testing
@testable import TapLessDomain

private final class StubUpdater: AppUpdater, @unchecked Sendable {
    private let lock = NSLock()
    private let release: AppRelease?
    private var _calls = 0

    init(release: AppRelease?) {
        self.release = release
    }

    var calls: Int { lock.withLock { _calls } }

    func latestRelease() async throws -> AppRelease? {
        lock.withLock { _calls += 1 }
        return release
    }

    func prepare(_ release: AppRelease, replacing current: URL) async throws -> URL { current }

    func scheduleInstall(staged: URL, replacing current: URL, afterExitOf pid: Int32) throws {}
}

private func release(_ tag: String) -> AppRelease {
    AppRelease(version: AppVersion(tag)!, tag: tag, notes: "", pageURL: URL(string: "https://example.com/r")!,
               archiveURL: URL(string: "https://example.com/TapLess.zip")!, checksumURL: nil)
}

@Suite struct AppVersionTests {
    @Test func parsesTagWithPrefix() {
        #expect(AppVersion("v0.8.0")?.components == [0, 8, 0])
        #expect(AppVersion(" 1.2 ")?.components == [1, 2])
        #expect(AppVersion("V3")?.components == [3])
    }

    @Test func rejectsNonVersions() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
        #expect(AppVersion("0.8.0-beta") == nil)
        #expect(AppVersion("0..8") == nil)
        #expect(AppVersion("latest") == nil)
    }

    @Test func comparesNumerically() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("1.0")! > AppVersion("0.99")!)
        #expect(AppVersion("0.8")! == AppVersion("0.8.0")!)
        #expect(Set([AppVersion("0.8")!, AppVersion("0.8.0")!]).count == 1)
        #expect(AppVersion("0.8.1")!.description == "0.8.1")
    }
}

@Suite struct CheckUpdateUseCaseTests {
    private let config = makeConfig(harnesses: [:], variants: [])

    @Test func newerReleaseIsOffered() async throws {
        let update = CheckUpdateUseCase(updater: StubUpdater(release: release("v0.8.0")), currentVersion: "0.7.0", config: config)
        #expect(try await update.check()?.tag == "v0.8.0")
    }

    @Test func sameOrOlderReleaseIsNotOffered() async throws {
        let same = CheckUpdateUseCase(updater: StubUpdater(release: release("v0.7")), currentVersion: "0.7.0", config: config)
        #expect(try await same.check() == nil)
        let older = CheckUpdateUseCase(updater: StubUpdater(release: release("v0.6.0")), currentVersion: "0.7.0", config: config)
        #expect(try await older.check() == nil)
    }

    @Test func unknownVersionSkipsRequest() async throws {
        let updater = StubUpdater(release: release("v9.0.0"))
        let update = CheckUpdateUseCase(updater: updater, currentVersion: nil, config: config)
        #expect(!update.isAvailable)
        #expect(try await update.check() == nil)
        #expect(updater.calls == 0)
    }

    @Test func checksAutomaticallyFollowsConfig() {
        var enabled = config
        enabled.general.checkUpdates = true
        #expect(CheckUpdateUseCase(updater: StubUpdater(release: nil), currentVersion: "0.7.0", config: enabled).checksAutomatically)
        #expect(!CheckUpdateUseCase(updater: StubUpdater(release: nil), currentVersion: "0.7.0", config: config).checksAutomatically)
    }
}
