import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

// MARK: - Подмена транспорта

/// Заглушка HTTP. Ответы ключуются по хосту и пути; у каждого теста свой хост.
private final class UpdateStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func register(host: String, path: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        replies[host + path] = Reply(status: status, body: body, headers: headers)
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let key = host + (request.url?.path ?? "")
        Self.lock.lock()
        let reply = Self.replies[key]
        Self.requests[host, default: []].append(request)
        Self.lock.unlock()

        let status = reply?.status ?? 404
        var headers = reply?.headers ?? [:]
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply?.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateStub.self]
    return URLSession(configuration: configuration)
}

private func uniqueHost() -> String { "h" + UUID().uuidString.lowercased() + ".test" }

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapless-updater-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeUpdater(host: String, stagingRoot: URL? = nil, logFile: URL? = nil, launch: Bool = false,
                         certificate: @escaping @Sendable (URL) throws -> Data? = { _ in nil }) -> GitHubUpdater {
    GitHubUpdater(repository: "owner/repo", apiBase: URL(string: "https://\(host)")!, session: makeSession(),
                  userAgent: "TapLessTest", stagingRoot: stagingRoot,
                  logFile: logFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("tapless-update-\(UUID().uuidString).log"),
                  launchAfterInstall: launch, certificateReader: certificate)
}

private func releaseJSON(tag: String = "v0.8.0", body: String? = "Заметки", draft: Bool = false, prerelease: Bool = false,
                         assets: [String] = ["TapLess.zip", "TapLess.zip.sha256"]) -> Data {
    var object: [String: Any] = [
        "tag_name": tag,
        "html_url": "https://github.com/owner/repo/releases/tag/\(tag)",
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets.map { ["name": $0, "browser_download_url": "https://github.com/owner/repo/releases/download/\(tag)/\($0)"] },
    ]
    object["body"] = body ?? NSNull()
    return try! JSONSerialization.data(withJSONObject: object)
}

private let latestPath = "/repos/owner/repo/releases/latest"

// MARK: - Релизы

@Suite struct GitHubUpdaterTests {
    @Test func parsesRelease() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON())
        let release = try #require(try await makeUpdater(host: host).latestRelease())
        #expect(release.tag == "v0.8.0")
        #expect(release.version == AppVersion("0.8.0"))
        #expect(release.notes == "Заметки")
        #expect(release.pageURL.absoluteString == "https://github.com/owner/repo/releases/tag/v0.8.0")
        #expect(release.archiveURL.lastPathComponent == "TapLess.zip")
        #expect(release.checksumURL?.lastPathComponent == "TapLess.zip.sha256")
    }

    @Test func requestPathAndHeaders() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON())
        _ = try await makeUpdater(host: host).latestRelease()
        let request = try #require(UpdateStub.requests(host: host).first)
        #expect(request.url?.path == latestPath)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TapLessTest")
    }

    @Test func nullBodyBecomesEmptyNotes() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON(body: nil))
        let release = try #require(try await makeUpdater(host: host).latestRelease())
        #expect(release.notes == "")
    }

    @Test func notFoundMeansNoRelease() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, status: 404, body: Data("{\"message\":\"Not Found\"}".utf8))
        #expect(try await makeUpdater(host: host).latestRelease() == nil)
    }

    @Test func draftAndPrereleaseAreSkipped() async throws {
        let draftHost = uniqueHost()
        UpdateStub.register(host: draftHost, path: latestPath, body: releaseJSON(draft: true))
        #expect(try await makeUpdater(host: draftHost).latestRelease() == nil)
        let preHost = uniqueHost()
        UpdateStub.register(host: preHost, path: latestPath, body: releaseJSON(prerelease: true))
        #expect(try await makeUpdater(host: preHost).latestRelease() == nil)
    }

    @Test func missingArchiveIsError() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON(assets: ["other.zip"]))
        let updater = makeUpdater(host: host)
        await #expect(throws: UpdateError.noArchive(tag: "v0.8.0")) { try await updater.latestRelease() }
    }

    @Test func missingChecksumIsNil() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON(assets: ["TapLess.zip"]))
        let release = try #require(try await makeUpdater(host: host).latestRelease())
        #expect(release.checksumURL == nil)
    }

    @Test func badTagIsError() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, body: releaseJSON(tag: "nightly"))
        let updater = makeUpdater(host: host)
        await #expect(throws: UpdateError.badTag("nightly")) { try await updater.latestRelease() }
    }

    @Test func serverErrorCarriesStatusAndMessage() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, status: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let updater = makeUpdater(host: host)
        await #expect(throws: UpdateError.http(status: 500, message: "boom")) { try await updater.latestRelease() }
    }

    @Test func rateLimitIsReadable() async throws {
        let host = uniqueHost()
        UpdateStub.register(host: host, path: latestPath, status: 403, body: Data("{\"message\":\"API rate limit exceeded\"}".utf8),
                            headers: ["X-RateLimit-Remaining": "0"])
        let updater = makeUpdater(host: host)
        await #expect(throws: UpdateError.rateLimited) { try await updater.latestRelease() }
    }

    // MARK: Контрольная сумма

    @Test func checksumParsing() throws {
        let hex = String(repeating: "ab", count: 32)
        #expect(try GitHubUpdater.parseChecksum("\(hex)  TapLess.zip\n") == hex)
        #expect(try GitHubUpdater.parseChecksum(hex.uppercased()) == hex)
        #expect(throws: UpdateError.checksumFileInvalid) { try GitHubUpdater.parseChecksum("мусор") }
        #expect(throws: UpdateError.checksumFileInvalid) { try GitHubUpdater.parseChecksum("") }
        #expect(throws: UpdateError.checksumFileInvalid) { try GitHubUpdater.parseChecksum(String(repeating: "g", count: 64)) }
        #expect(throws: UpdateError.checksumFileInvalid) { try GitHubUpdater.parseChecksum("abcd") }
    }

    @Test func checksumVerification() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data("hello".utf8).write(to: file)
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        try GitHubUpdater.verifyChecksum(of: file, expected: hello)
        try GitHubUpdater.verifyChecksum(of: file, expected: hello.uppercased())
        #expect(throws: UpdateError.self) {
            try GitHubUpdater.verifyChecksum(of: file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test func checksumMismatchRemovesStaging() async throws {
        let host = uniqueHost()
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("TapLess.app")
        let staging = dir.appendingPathComponent("staging")
        UpdateStub.register(host: host, path: "/dl/TapLess.zip", body: Data("не архив".utf8))
        UpdateStub.register(host: host, path: "/dl/TapLess.zip.sha256",
                            body: Data((String(repeating: "0", count: 64) + "  TapLess.zip\n").utf8))
        let release = AppRelease(version: AppVersion("0.8.0")!, tag: "v0.8.0", notes: "",
                                 pageURL: URL(string: "https://\(host)/page")!,
                                 archiveURL: URL(string: "https://\(host)/dl/TapLess.zip")!,
                                 checksumURL: URL(string: "https://\(host)/dl/TapLess.zip.sha256")!)
        let updater = makeUpdater(host: host, stagingRoot: staging, certificate: { _ in Data([1]) })
        do {
            _ = try await updater.prepare(release, replacing: current)
            Issue.record("prepare должен был упасть")
        } catch let error as UpdateError {
            guard case .checksumMismatch = error else {
                Issue.record("ожидалась checksumMismatch, получено \(error)")
                return
            }
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func prepareRequiresChecksumAndSignature() async throws {
        let host = uniqueHost()
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("TapLess.app")
        let noChecksum = AppRelease(version: AppVersion("0.8.0")!, tag: "v0.8.0", notes: "",
                                    pageURL: URL(string: "https://\(host)/p")!,
                                    archiveURL: URL(string: "https://\(host)/a.zip")!, checksumURL: nil)
        let updater = makeUpdater(host: host, certificate: { _ in Data([1]) })
        await #expect(throws: UpdateError.checksumMissing(tag: "v0.8.0")) { try await updater.prepare(noChecksum, replacing: current) }

        let withChecksum = AppRelease(version: AppVersion("0.8.0")!, tag: "v0.8.0", notes: "",
                                      pageURL: noChecksum.pageURL, archiveURL: noChecksum.archiveURL,
                                      checksumURL: URL(string: "https://\(host)/a.sha256")!)
        let adHoc = makeUpdater(host: host, certificate: { _ in nil })
        await #expect(throws: UpdateError.adHocSigned) { try await adHoc.prepare(withChecksum, replacing: current) }
        #expect(UpdateStub.requests(host: host).isEmpty)
    }

    // MARK: Установка

    @Test func installReplacesApp() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileManager = FileManager.default
        let current = dir.appendingPathComponent("old/TapLess.app")
        let staged = dir.appendingPathComponent("staged/TapLess.app")
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        let log = dir.appendingPathComponent("logs/update.log")
        let updater = makeUpdater(host: uniqueHost(), logFile: log, launch: false)
        try updater.scheduleInstall(staged: staged, replacing: current, afterExitOf: finished.processIdentifier)

        let marker = current.appendingPathComponent("marker")
        var installed = false
        for _ in 0..<100 {
            if (try? String(contentsOf: marker, encoding: .utf8)) == "new", !fileManager.fileExists(atPath: staged.deletingLastPathComponent().path) {
                installed = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(installed)
        let leftovers = try fileManager.contentsOfDirectory(atPath: dir.appendingPathComponent("old").path)
        #expect(leftovers == ["TapLess.app"])
        #expect(fileManager.fileExists(atPath: log.path))
    }
}

// MARK: - Живая проверка

/// Запуск: `TAPLESS_LIVE_UPDATE=1 ./scripts/test.sh --filter GitHubUpdater`.
/// Нужны установленный `~/Applications/TapLess.app` и доступ к GitHub.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAPLESS_LIVE_UPDATE"] == "1"), .serialized)
struct LiveUpdateTests {
    @Test func latestReleaseAndPrepare() async throws {
        let staging = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let updater = GitHubUpdater(stagingRoot: staging)
        let release = try #require(try await updater.latestRelease())
        #expect(release.version >= AppVersion("0.7.0")!)
        #expect(release.checksumURL != nil)

        let current = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/TapLess.app")
        let app = try await updater.prepare(release, replacing: current)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        #expect(version == release.version)
    }
}
