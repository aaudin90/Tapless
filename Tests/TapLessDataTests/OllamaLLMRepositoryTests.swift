import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

// MARK: - Подмена транспорта

/// Ответ заглушки: статус и тело, ошибка соединения или «зависание» до отмены.
private enum StubReply {
    case response(status: Int, body: String)
    case failure(URLError.Code)
    case hang
}

/// Заглушка HTTP. Обработчики ключуются по хосту URL — у каждого теста свой хост,
/// поэтому тесты безопасно идут параллельно.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: StubReply] = [:]
    nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]
    nonisolated(unsafe) private static var paths: [String: [String]] = [:]

    static func register(host: String, reply: StubReply) {
        lock.lock(); defer { lock.unlock() }
        replies[host] = reply
        bodies[host] = []
        paths[host] = []
    }

    static func bodies(host: String) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies[host] ?? []
    }

    static func paths(host: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = Self.readBody(request)
        Self.lock.lock()
        let reply = Self.replies[host]
        Self.bodies[host, default: []].append(body)
        Self.paths[host, default: []].append(request.url?.path ?? "")
        Self.lock.unlock()

        switch reply {
        case .response(let status, let text)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang?, nil:
            break
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeSettings(timeout: Double = 30) -> LLMConfig {
    LLMConfig(harness: "ollama", model: "m", timeoutSeconds: timeout, shell: "/bin/zsh", loginShell: true,
              extraPath: [], workdir: "", inputTemplate: "{text}", stripCodeFences: false,
              basePrompt: "", revisePrompt: "", reviseTemplate: "", feedbackPrompt: "", env: [:])
}

private func uniqueHost() -> String { "h" + UUID().uuidString.lowercased() + ".test" }

private func chatReply(_ content: String) -> StubReply {
    let object: [String: Any] = ["message": ["role": "assistant", "content": content], "done": true]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return .response(status: 200, body: String(decoding: data, as: UTF8.self))
}

private func makeRequest(harness: HarnessConfig, schema: LLMSchema? = nil) -> LLMRequest {
    LLMRequest(variantKey: 1, variantName: "Тест", harnessName: "ollama", harness: harness,
               model: "gemma:test", systemPrompt: "СИСТЕМА", input: "ВВОД", schema: schema)
}

private func sentBody(host: String) throws -> [String: Any] {
    let data = try #require(StubProtocol.bodies(host: host).first)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Тесты

@Suite struct OllamaLLMRepositoryTests {
    private func run(host: String, harness: HarnessConfig, schema: LLMSchema? = nil,
                     reply: StubReply) async throws -> String {
        StubProtocol.register(host: host, reply: reply)
        let repository = OllamaLLMRepository(settings: makeSettings(), session: makeSession())
        return try await repository.complete(makeRequest(harness: harness, schema: schema))
    }

    // MARK: Тело запроса

    @Test func requestBodyBasics() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        let result = try await run(host: host, harness: harness, reply: chatReply("ответ"))
        #expect(result == "ответ")

        let body = try sentBody(host: host)
        #expect(body["model"] as? String == "gemma:test")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "СИСТЕМА"], ["role": "user", "content": "ВВОД"]])
        #expect(body["think"] == nil)
        #expect(body["keep_alive"] == nil)
        #expect(body["options"] == nil)
        #expect(body["format"] == nil)
    }

    @Test func thinkFalseAndKeepAliveSeconds() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1", think: "false", keepAlive: "-1")
        _ = try await run(host: host, harness: harness, reply: chatReply("x"))
        let body = try sentBody(host: host)
        #expect(body["think"] as? Bool == false)
        #expect(body["keep_alive"] as? Int == -1)
    }

    @Test func thinkTrueAndKeepAliveDuration() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1", think: "true", keepAlive: "30m")
        _ = try await run(host: host, harness: harness, reply: chatReply("x"))
        let body = try sentBody(host: host)
        #expect(body["think"] as? Bool == true)
        #expect(body["keep_alive"] as? String == "30m")
    }

    @Test func thinkLevelAndOptions() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1", think: "low",
                                           options: ["temperature": 0.2, "num_ctx": 8192])
        _ = try await run(host: host, harness: harness, reply: chatReply("x"))
        let body = try sentBody(host: host)
        #expect(body["think"] as? String == "low")
        let options = try #require(body["options"] as? [String: Double])
        #expect(options == ["temperature": 0.2, "num_ctx": 8192])
    }

    @Test func schemaGoesToFormat() async throws {
        let host = uniqueHost()
        let schema = LLMSchema(name: "text", config: SchemaConfig(
            json: #"{"type":"object","properties":{"text":{"type":"string"}}}"#, resultPath: "text"))
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        _ = try await run(host: host, harness: harness, schema: schema,
                          reply: chatReply(#"{"text":"ok"}"#))
        let body = try sentBody(host: host)
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["type"] as? String == "object")
        #expect(format["properties"] != nil)
    }

    @Test func urlWithAndWithoutTrailingSlash() async throws {
        for suffix in ["", "/"] {
            let host = uniqueHost()
            let harness = HarnessConfig.ollama(url: "http://\(host):1\(suffix)")
            _ = try await run(host: host, harness: harness, reply: chatReply("x"))
            #expect(StubProtocol.paths(host: host) == ["/api/chat"])
        }
    }

    // MARK: Ответ

    @Test func schemaResultPathExtractsField() async throws {
        let host = uniqueHost()
        let schema = LLMSchema(name: "text", config: SchemaConfig(
            json: #"{"type":"object"}"#, resultPath: "text"))
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        let result = try await run(host: host, harness: harness, schema: schema,
                                   reply: chatReply(#"{"text":"Готовый текст","other":1}"#))
        #expect(result == "Готовый текст")
    }

    @Test func badSchemaJSONThrowsBeforeRequest() async throws {
        let host = uniqueHost()
        let schema = LLMSchema(name: "bad", config: SchemaConfig(json: "не json"))
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        await #expect(throws: LLMError.self) {
            _ = try await run(host: host, harness: harness, schema: schema, reply: chatReply("x"))
        }
        #expect(StubProtocol.bodies(host: host).isEmpty)
    }

    // MARK: Ошибки

    @Test func notFoundMapsToModelMissing() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness,
                              reply: .response(status: 404, body: #"{"error":"model 'x' not found"}"#))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .modelMissing(let model) = error else {
                Issue.record("ожидалась modelMissing, получено \(error)")
                return
            }
            #expect(model == "gemma:test")
        }
    }

    @Test func serverErrorMapsToHTTP() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness,
                              reply: .response(status: 500, body: #"{"error":"boom"}"#))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .http(let code, let message) = error else {
                Issue.record("ожидалась http, получено \(error)")
                return
            }
            #expect(code == 500)
            #expect(message == "boom")
        }
    }

    @Test func notFoundWithoutModelTextIsHTTP() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness,
                              reply: .response(status: 404, body: #"{"error":"page gone"}"#))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .http(404, _) = error else {
                Issue.record("ожидалась http(404), получено \(error)")
                return
            }
        }
    }

    @Test func connectionFailureMapsToServerUnavailable() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness, reply: .failure(.cannotConnectToHost))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .serverUnavailable(let url, _) = error else {
                Issue.record("ожидалась serverUnavailable, получено \(error)")
                return
            }
            #expect(url == "http://\(host):1")
        }
    }

    @Test func timeoutMapsToTimeout() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness, reply: .failure(.timedOut))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .timeout = error else {
                Issue.record("ожидалась timeout, получено \(error)")
                return
            }
        }
    }

    @Test func badURLThrows() async throws {
        let repository = OllamaLLMRepository(settings: makeSettings(), session: makeSession())
        await #expect(throws: LLMError.self) {
            _ = try await repository.complete(makeRequest(harness: .ollama(url: "not a url")))
        }
        await #expect(throws: LLMError.self) {
            _ = try await repository.complete(makeRequest(harness: .ollama(url: "")))
        }
    }

    @Test func missingContentIsBadOutput() async throws {
        let host = uniqueHost()
        let harness = HarnessConfig.ollama(url: "http://\(host):1")
        do {
            _ = try await run(host: host, harness: harness,
                              reply: .response(status: 200, body: #"{"done":true}"#))
            Issue.record("ожидалась ошибка")
        } catch let error as LLMError {
            guard case .badOutput = error else {
                Issue.record("ожидалась badOutput, получено \(error)")
                return
            }
        }
    }

    @Test func cancellationThrowsCancellationError() async throws {
        let host = uniqueHost()
        StubProtocol.register(host: host, reply: .hang)
        let repository = OllamaLLMRepository(settings: makeSettings(), session: makeSession())
        let request = makeRequest(harness: .ollama(url: "http://\(host):1"))
        let task = Task { try await repository.complete(request) }
        for _ in 0..<200 where StubProtocol.bodies(host: host).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!StubProtocol.bodies(host: host).isEmpty)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("ожидалась отмена")
        } catch {
            #expect(error is CancellationError)
        }
    }

    // MARK: Помощники

    @Test func thinkHelper() {
        #expect(OllamaLLMRepository.think("") == nil)
        #expect(OllamaLLMRepository.think("  ") == nil)
        #expect(OllamaLLMRepository.think("TRUE") as? Bool == true)
        #expect(OllamaLLMRepository.think("false") as? Bool == false)
        #expect(OllamaLLMRepository.think("High") as? String == "high")
    }

    @Test func keepAliveHelper() {
        #expect(OllamaLLMRepository.keepAlive("") == nil)
        #expect(OllamaLLMRepository.keepAlive("-1") as? Int == -1)
        #expect(OllamaLLMRepository.keepAlive("0") as? Int == 0)
        #expect(OllamaLLMRepository.keepAlive("30m") as? String == "30m")
    }

    @Test func metricsHelper() {
        let text = OllamaLLMRepository.metrics(
            ["total_duration": 2_000_000_000, "load_duration": 500_000_000,
             "prompt_eval_count": 10, "prompt_eval_duration": 100_000_000,
             "eval_count": 20, "eval_duration": 1_000_000_000],
            thinking: "abc")
        #expect(text.contains("всего 2.00 с"))
        #expect(text.contains("20 ток/с"))
        #expect(text.contains("рассуждение 3 симв."))
        #expect(!OllamaLLMRepository.metrics([:], thinking: nil).contains("рассуждение"))
    }
}

// MARK: - Маршрутизация

private final class FakeLLM: LLMRepository, @unchecked Sendable {
    let reply: String
    private let lock = NSLock()
    private var count = 0

    init(reply: String) { self.reply = reply }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    private func record() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    func complete(_ request: LLMRequest) async throws -> String {
        record()
        return reply
    }
}

@Suite struct RoutingLLMRepositoryTests {
    @Test func dispatchesByHarnessKind() async throws {
        let process = FakeLLM(reply: "process")
        let ollama = FakeLLM(reply: "ollama")
        let router = RoutingLLMRepository(process: process, ollama: ollama, codex: process)

        let cli = makeRequest(harness: HarnessConfig(executable: "x", args: []))
        #expect(try await router.complete(cli) == "process")
        #expect(process.calls == 1 && ollama.calls == 0)

        let http = makeRequest(harness: .ollama(url: "http://127.0.0.1:11434"))
        #expect(try await router.complete(http) == "ollama")
        #expect(process.calls == 1 && ollama.calls == 1)
    }
}

// MARK: - Конфиг

@Suite final class OllamaConfigTests {
    private var directories: [URL] = []

    deinit {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRepository(_ toml: String) throws -> FileConfigRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        let file = dir.appendingPathComponent("tapless.toml")
        try toml.write(to: file, atomically: true, encoding: .utf8)
        return FileConfigRepository(fileURL: file)
    }

    @Test func ollamaHarnessParsesWithoutExecutable() throws {
        let repository = try makeRepository("""
        [harness.myollama]
        type = "ollama"
        model = "qwen3:4b"
        url = "http://localhost:11434"
        think = false
        keep_alive = "30m"

        [harness.myollama.options]
        temperature = 0.1
        num_ctx = 4096
        """)
        let loaded = try repository.load()
        let harness = try #require(loaded.config.harnesses["myollama"])
        #expect(harness.kind == .ollama)
        #expect(harness.model == "qwen3:4b")
        #expect(harness.url == "http://localhost:11434")
        #expect(harness.think == "false")
        #expect(harness.keepAlive == "30m")
        #expect(harness.options == ["temperature": 0.1, "num_ctx": 4096])
        #expect(harness.executable.isEmpty)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func thinkLevelStringAccepted() throws {
        let repository = try makeRepository("""
        [harness.o]
        type = "ollama"
        url = "http://localhost:11434"
        think = "low"
        """)
        let harness = try #require(try repository.load().config.harnesses["o"])
        #expect(harness.think == "low")
    }

    @Test func harnessWithoutExecutableAndTypeIsError() throws {
        let repository = try makeRepository("[harness.x]\nargs = [\"a\"]")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error.localizedDescription.contains("executable"))
        }
    }

    @Test func builtInDefaultsContainOllama() {
        let config = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
        let harness = config.harnesses["ollama"]
        #expect(harness?.kind == .ollama)
        #expect(harness?.url == "http://127.0.0.1:11434")
        #expect(harness?.think == "false")
    }
}
