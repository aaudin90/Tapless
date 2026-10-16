import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

// MARK: - Подмена сервера Ollama

/// Заглушка HTTP по адресу «хост:порт»: у каждого теста свой адрес, поэтому тесты идут параллельно.
/// Сервер без ответов (`down`) отвечает ошибкой соединения.
private final class SetupStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: [String: (Int, String)]] = [:]
    nonisolated(unsafe) private static var requests: [String: [(String, Data)]] = [:]
    nonisolated(unsafe) private static var nextPort = 20000

    static func makeAddress(local: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        nextPort += 1
        return local ? "127.0.0.1:\(nextPort)" : "h\(nextPort).test:11434"
    }

    static func serve(_ address: String, _ routes: [String: (Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        servers[address] = routes
    }

    static func requests(_ address: String) -> [(String, Data)] {
        lock.lock(); defer { lock.unlock() }
        return requests[address] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let address = "\(url.host ?? ""):\(url.port ?? 0)"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.lock()
        Self.requests[address, default: []].append((url.path, body))
        let reply = Self.servers[address]?[url.path]
        Self.lock.unlock()

        guard let (status, text) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SetupStub.self]
    return URLSession(configuration: configuration)
}

private let version: (Int, String) = (200, #"{"version":"0.12.0"}"#)

private func tags(_ names: [String]) -> (Int, String) {
    let models = names.map { #"{"name":"\#($0)","model":"\#($0)"}"# }.joined(separator: ",")
    return (200, #"{"models":[\#(models)]}"#)
}

/// Установка Ollama для теста: есть ли приложение и CLI, что делает запуск.
private final class FakeInstallation: @unchecked Sendable {
    private let lock = NSLock()
    private var launches = 0
    private var launchEnv: [String: String] = [:]
    private var launchedWith: OllamaLauncher?
    let hasApp: Bool
    let hasCLI: Bool
    let onLaunch: @Sendable () -> Void

    /// Процесс, который вернёт запуск: так тест изображает упавший `ollama serve`.
    let process: OllamaServerProcess?

    init(hasApp: Bool, hasCLI: Bool = false, process: OllamaServerProcess? = nil,
         onLaunch: @escaping @Sendable () -> Void = {}) {
        self.hasApp = hasApp
        self.hasCLI = hasCLI
        self.process = process
        self.onLaunch = onLaunch
    }

    var launchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return launches
    }

    var lastEnv: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return launchEnv
    }

    var lastLauncher: OllamaLauncher? {
        lock.lock(); defer { lock.unlock() }
        return launchedWith
    }

    var installation: OllamaInstallation {
        OllamaInstallation(
            launcher: { [hasApp, hasCLI] in
                if hasApp { return .app(URL(fileURLWithPath: "/Applications/Ollama.app")) }
                return hasCLI ? .cli(URL(fileURLWithPath: "/opt/homebrew/bin/ollama")) : nil
            },
            launch: { [self] launcher, env in
                lock.lock(); launches += 1; launchEnv = env; launchedWith = launcher; lock.unlock()
                onLaunch()
                return process
            })
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LocalLLMStatus] = []

    func append(_ status: LocalLLMStatus) {
        lock.lock(); defer { lock.unlock() }
        items.append(status)
    }

    var all: [LocalLLMStatus] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

private func makeSetup(_ fake: FakeInstallation) -> OllamaSetup {
    OllamaSetup(session: makeSession(), installation: fake.installation, startTimeout: 0.5, pollInterval: 0.05)
}

// MARK: - Тесты

@Suite struct OllamaSetupTests {
    @Test func readyWhenServerUpAndModelInstalled() async {
        let address = SetupStub.makeAddress(local: true)
        SetupStub.serve(address, ["/api/version": version, "/api/tags": tags(["gemma:test"])])
        let fake = FakeInstallation(hasApp: true)
        let log = StatusLog()
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)/", model: "gemma:test")],
                                                   status: { log.append($0) })
        #expect(result == .ready)
        #expect(log.all == [.checking])
        #expect(fake.launchCount == 0)
        #expect(SetupStub.requests(address).map(\.0) == ["/api/version", "/api/tags"])
    }

    @Test func pullsMissingModelWithProgress() async throws {
        let address = SetupStub.makeAddress(local: true)
        let pull = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":300,"completed":0}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":300,"completed":150}"#,
            #"{"status":"pulling b","digest":"sha256:b","total":100,"completed":100}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":300,"completed":300}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"success"}"#,
        ].joined(separator: "\n")
        SetupStub.serve(address, ["/api/version": version, "/api/tags": tags(["other:latest"]),
                                  "/api/pull": (200, pull)])
        let log = StatusLog()
        let result = await makeSetup(FakeInstallation(hasApp: true))
            .prepare([OllamaTarget(url: "http://\(address)", model: "gemma:test")], status: { log.append($0) })
        #expect(result == .ready)
        #expect(log.all == [
            .checking,
            .downloading(model: "gemma:test", fraction: nil),
            .downloading(model: "gemma:test", fraction: 0),
            .downloading(model: "gemma:test", fraction: 0.5),
            .downloading(model: "gemma:test", fraction: 0.625),
            .downloading(model: "gemma:test", fraction: 1),
        ])
        let body = try #require(SetupStub.requests(address).first { $0.0 == "/api/pull" }?.1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gemma:test")
        #expect(json["stream"] as? Bool == true)
    }

    @Test func pullErrorIsFailure() async {
        let address = SetupStub.makeAddress(local: true)
        SetupStub.serve(address, ["/api/version": version, "/api/tags": tags([]),
                                  "/api/pull": (200, #"{"error":"pull model manifest: file does not exist"}"#)])
        let result = await makeSetup(FakeInstallation(hasApp: true))
            .prepare([OllamaTarget(url: "http://\(address)", model: "nope:1b")], status: { _ in })
        #expect(result == .failed("pull model manifest: file does not exist"))
    }

    @Test func launchesInstalledAppWhenServerDown() async {
        let address = SetupStub.makeAddress(local: true)
        let fake = FakeInstallation(hasApp: true) {
            SetupStub.serve(address, ["/api/version": version, "/api/tags": tags(["gemma:test"])])
        }
        let log = StatusLog()
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)", model: "gemma:test", parallel: 3)],
                                                   status: { log.append($0) })
        #expect(result == .ready)
        #expect(fake.launchCount == 1)
        #expect(fake.lastLauncher == .app(URL(fileURLWithPath: "/Applications/Ollama.app")))
        #expect(fake.lastEnv == ["OLLAMA_NUM_PARALLEL": "3", "OLLAMA_HOST": address,
                                 "OLLAMA_FLASH_ATTENTION": "1", "OLLAMA_KV_CACHE_TYPE": "q8_0"])
        #expect(log.all == [.checking, .starting])
    }

    @Test func appThatNeverAnswersIsNotRunning() async {
        let address = SetupStub.makeAddress(local: true)
        let fake = FakeInstallation(hasApp: true)
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)", model: "m")],
                                                   status: { _ in })
        #expect(result == .notRunning(url: "http://\(address)"))
        #expect(fake.launchCount == 1)
    }

    @Test func notInstalledWithoutAppAndCLI() async {
        let address = SetupStub.makeAddress(local: true)
        let result = await makeSetup(FakeInstallation(hasApp: false))
            .prepare([OllamaTarget(url: "http://\(address)", model: "m")], status: { _ in })
        #expect(result == .notInstalled)
    }

    @Test func servesWithCLIWithoutApp() async {
        let address = SetupStub.makeAddress(local: true)
        let fake = FakeInstallation(hasApp: false, hasCLI: true) {
            SetupStub.serve(address, ["/api/version": version, "/api/tags": tags(["m"])])
        }
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)", model: "m")],
                                                   status: { _ in })
        #expect(result == .ready)
        #expect(fake.lastLauncher == .cli(URL(fileURLWithPath: "/opt/homebrew/bin/ollama")))
        #expect(fake.lastEnv["OLLAMA_NUM_PARALLEL"] == nil)
        #expect(fake.lastEnv["OLLAMA_HOST"] == address)
    }

    @Test func serverThatExitsFailsWithoutWaitingTimeout() async {
        let address = SetupStub.makeAddress(local: true)
        let process = OllamaServerProcess(pid: 1)
        process.finished(status: 3 << 8)
        let fake = FakeInstallation(hasApp: false, hasCLI: true, process: process)
        let started = Date()
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)", model: "m")],
                                                   status: { _ in })
        guard case .failed(let message) = result else {
            Issue.record("ожидалась ошибка, а не \(result)")
            return
        }
        #expect(message.contains("код 3"))
        #expect(Date().timeIntervalSince(started) < 0.4)
    }

    @Test func serveSpawnsProcessWithFilteredEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tapless-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("ollama")
        try """
        #!/bin/sh
        echo "args=$*"
        echo "parallel=$OLLAMA_NUM_PARALLEL kv=$OLLAMA_KV_CACHE_TYPE proxy=${HTTPS_PROXY:-none}"
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = dir.appendingPathComponent("ollama.log")

        let process = try OllamaServe.start(script, ["OLLAMA_NUM_PARALLEL": "3", "OLLAMA_KV_CACHE_TYPE": "q8_0"],
                                            logFile: log,
                                            inherited: ["PATH": "/usr/bin:/bin", "HTTPS_PROXY": "http://p:1",
                                                        "OLLAMA_KV_CACHE_TYPE": "f16"])
        let deadline = Date().addingTimeInterval(5)
        while process.exitDescription == nil && Date() < deadline { usleep(20_000) }
        #expect(process.exitDescription == "код 3")
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(output.contains("args=serve"))
        #expect(output.contains("parallel=3 kv=f16 proxy=none"))
    }

    @Test func serveEnvironmentDropsProxyAndSecrets() {
        let env = OllamaServe.serverEnvironment(
            ["HOME": "/Users/u", "PATH": "/bin", "HTTPS_PROXY": "http://p:1", "http_proxy": "http://p:1",
             "API_KEY": "secret", "OLLAMA_MODELS": "/m", "OLLAMA_NUM_PARALLEL": "1"],
            ["OLLAMA_NUM_PARALLEL": "3"])
        #expect(env == ["HOME": "/Users/u", "PATH": "/bin", "OLLAMA_MODELS": "/m", "OLLAMA_NUM_PARALLEL": "3"])
    }

    @Test func serverEnvironmentHost() {
        let env = OllamaSetup.serverEnvironment(URL(string: "http://localhost")!, parallel: 2)
        #expect(env["OLLAMA_HOST"] == "localhost:11434")
        #expect(env["OLLAMA_NUM_PARALLEL"] == "2")
        #expect(OllamaSetup.serverEnvironment(URL(string: "http://[::1]:8080")!, parallel: 0)["OLLAMA_HOST"] == "[::1]:8080")
    }

    @Test func remoteServerIsNotLaunched() async {
        let address = SetupStub.makeAddress(local: false)
        let fake = FakeInstallation(hasApp: true)
        let result = await makeSetup(fake).prepare([OllamaTarget(url: "http://\(address)", model: "m")],
                                                   status: { _ in })
        #expect(result == .notRunning(url: "http://\(address)"))
        #expect(fake.launchCount == 0)
    }

    @Test func badURLIsFailure() async {
        let result = await makeSetup(FakeInstallation(hasApp: true))
            .prepare([OllamaTarget(url: "not a url", model: "m")], status: { _ in })
        #expect(result == .failed("неверный url Ollama: «not a url»"))
    }

    @Test func modelNameMatching() {
        #expect(OllamaSetup.contains(["gemma:latest"], "gemma"))
        #expect(OllamaSetup.contains(["gemma:2b"], "gemma:2b"))
        #expect(!OllamaSetup.contains(["gemma:2b"], "gemma"))
        #expect(!OllamaSetup.contains(["gemma:latest"], "gemma:2b"))
    }
}
