import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

/// Отвечает пустой строкой: настоящий вызов LLM этим тестам не нужен.
private struct SilentLLM: LLMRepository {
    func complete(_ request: LLMRequest) async throws -> String { "" }
}

@Suite final class CodexIsolationVerifierTests {
    private var directories: [URL] = []

    deinit {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir
    }

    // MARK: - Перехватчик

    @Test func captureParsesContentLengthAndChunkedBodies() throws {
        let plain = Data("POST /v1/responses HTTP/1.1\r\nContent-Length: 4\r\nX-A: b\r\n\r\nbody".utf8)
        let request = try #require(LoopbackCapture.parse(plain))
        #expect(request.method == "POST" && request.path == "/v1/responses")
        #expect(request.headers["x-a"] == "b")
        #expect(request.body == Data("body".utf8))
        #expect(LoopbackCapture.parse(plain.dropLast()) == nil)

        let chunked = Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;ext\r\nde\r\n0\r\n\r\n".utf8)
        #expect(LoopbackCapture.parse(chunked)?.body == Data("abcde".utf8))
        #expect(LoopbackCapture.parse(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab".utf8)) == nil)
    }

    @Test func captureRecordsPostAndAnswers400() async throws {
        let capture = try LoopbackCapture()
        let port = try await capture.start()
        defer { capture.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"a":1}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (_, response) = try await URLSession(configuration: configuration).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(capture.requests.first?.body == Data(#"{"a":1}"#.utf8))
    }

    // MARK: - Разбор запроса

    private static let expected = CodexIsolationVerifier.Expected(
        systemPrompt: "промпт", input: "текст", model: "luna", reasoningEffort: "none", marker: "MARKER-1")

    private static func body(extraInput: String = "", tools: String = "[]", model: String = "luna",
                             effort: String = "none") -> Data {
        Data("""
        {"model": "\(model)", "reasoning": {"effort": "\(effort)"}, "tools": \(tools), "input": [
          {"type": "additional_tools", "role": "developer", "tools": []},
          {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "промпт"}]},
          {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "текст\\n"}]}\(extraInput)
        ]}
        """.utf8)
    }

    @Test func analyzeAcceptsOnlyPromptAndText() throws {
        let findings = try CodexIsolationVerifier.analyze(body: Self.body(), expected: Self.expected)
        #expect(findings == .init(problems: [], agentsLeak: false))
    }

    @Test func analyzeReportsToolsMessagesModelAndMarker() throws {
        let extra = """
        ,{"type": "additional_tools", "tools": [{"type": "namespace", "name": "functions",
            "tools": [{"name": "request_user_input"}]}]},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md\\nMARKER-1"}]}
        """
        let findings = try CodexIsolationVerifier.analyze(
            body: Self.body(extraInput: extra, tools: #"[{"type": "function", "name": "exec"}]"#,
                            model: "sol", effort: "high"),
            expected: Self.expected)
        #expect(findings.agentsLeak)
        #expect(findings.problems == [
            "AGENTS.md из рабочей папки",
            "инструменты: exec",
            "дополнительные инструменты: functions.request_user_input",
            "лишнее сообщение user: «# AGENTS.md»",
            "модель «sol» вместо «luna»",
            "reasoning effort «high» вместо «none»",
        ])

        let empty = try CodexIsolationVerifier.analyze(body: Data(#"{"input": []}"#.utf8), expected: Self.expected)
        #expect(empty.problems == ["нет системного промпта TapLess", "нет текста TapLess"])
        #expect(throws: (any Error).self) {
            try CodexIsolationVerifier.analyze(body: Data("[]".utf8), expected: Self.expected)
        }
    }

    @Test func reasoningEffortComesFromArguments() {
        #expect(CodexIsolationVerifier.reasoningEffort(in: ["-c", #"model_reasoning_effort="none""#]) == "none")
        #expect(CodexIsolationVerifier.reasoningEffort(in: ["-c", "model_reasoning_effort=low"]) == "low")
        #expect(CodexIsolationVerifier.reasoningEffort(in: ["exec"]) == nil)
    }

    // MARK: - Проверка целиком

    /// Поддельный Codex: на `--version` печатает версию, на запуск шлёт запрос на `base_url` из своего
    /// `config.toml` и завершается с кодом 1, как настоящий Codex после ответа 400.
    /// `FAKE_MODE`: `leak` — добавить AGENTS.md рабочей папки, `tools` — инструмент, `silent` — без запроса.
    private func makeFakeCodex(in dir: URL) throws -> (script: URL, calls: URL) {
        let calls = dir.appendingPathComponent("calls.txt")
        let script = dir.appendingPathComponent("fake-codex")
        try """
        #!/bin/zsh
        if [[ "$1" == "--version" ]]; then echo "warning: wrapper"; echo "fake-codex 1.0"; exit 0; fi
        echo run >> '\(calls.path)'
        for a in "$@"; do
          case $a in model_instructions_file=*) f=${a#model_instructions_file=}; f=${f//\\"/};; esac
        done
        prompt=$(<"$f"); input=$(cat)
        [[ "$FAKE_MODE" == silent ]] && exit 1
        port=$(sed -n 's/.*127\\.0\\.0\\.1:\\([0-9]*\\).*/\\1/p' "$CODEX_HOME/config.toml")
        extra=''; tools='[]'
        [[ "$FAKE_MODE" == leak ]] && extra=",{\\"type\\":\\"message\\",\\"role\\":\\"user\\",\\"content\\":[{\\"type\\":\\"input_text\\",\\"text\\":\\"$(tr '\\n' ' ' < AGENTS.md)\\"}]}"
        [[ "$FAKE_MODE" == tools ]] && tools='[{"type":"function","name":"exec"}]'
        body="{\\"model\\":\\"luna\\",\\"tools\\":$tools,\\"input\\":[{\\"type\\":\\"message\\",\\"role\\":\\"developer\\",\\"content\\":[{\\"type\\":\\"input_text\\",\\"text\\":\\"$prompt\\"}]},{\\"type\\":\\"message\\",\\"role\\":\\"user\\",\\"content\\":[{\\"type\\":\\"input_text\\",\\"text\\":\\"$input\\"}]}$extra]}"
        curl -s -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary "$body" "http://127.0.0.1:$port/v1/responses"
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, calls)
    }

    private struct Setup {
        var codex: CodexLLMRepository
        var target: CodexTarget
        var calls: URL
        var stateFile: URL
        var homeDirectory: URL
        var settings: LLMConfig
    }

    private func makeSetup(mode: String = "", verify: CodexVerifyMode = .warn) throws -> Setup {
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // Кэш моделей есть: встроенный каталог не нужен, и поддельный Codex не зовут с debug models.
        try #"{"models": [{"slug": "luna", "tool_mode": "code_mode_only"}]}"#
            .write(to: source.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        let fake = try makeFakeCodex(in: dir)
        var settings = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults().llm
        settings.loginShell = false
        let harness = HarnessConfig(
            executable: fake.script.path,
            args: ["exec", "--model", "{model}", "-c", #"model_instructions_file="{prompt_file}""#,
                   "-c", #"model_reasoning_effort="none""#, "-"],
            env: ["CODEX_HOME": source.path, "FAKE_MODE": mode], kind: .codex, verify: verify)
        let stateFile = dir.appendingPathComponent("codex-check.json")
        let homeDirectory = dir.appendingPathComponent("codex-home")
        let codex = CodexLLMRepository(process: SilentLLM(), settings: settings, homeDirectory: homeDirectory,
                                       checkStateFile: stateFile)
        return Setup(codex: codex, target: CodexTarget(harnessName: "codex", harness: harness, model: "luna"),
                     calls: fake.calls, stateFile: stateFile, homeDirectory: homeDirectory, settings: settings)
    }

    private func runs(_ setup: Setup) -> Int {
        ((try? String(contentsOf: setup.calls, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func cleanRequestPassesAndIsNotRepeatedUntilSomethingChanges() async throws {
        let setup = try makeSetup()
        let first = try #require(await setup.codex.verifier.check([setup.target], force: false).first)
        #expect(first.status == .passed)
        #expect(first.version == "fake-codex 1.0")
        #expect(first.isNew && !first.blocking)

        let second = try #require(await setup.codex.verifier.check([setup.target], force: false).first)
        #expect(!second.isNew && second.status == .passed)
        #expect(runs(setup) == 1)

        // Итог переживает перезапуск TapLess: новый экземпляр читает state-файл.
        let restarted = CodexLLMRepository(process: SilentLLM(), settings: setup.settings,
                                           homeDirectory: setup.homeDirectory, checkStateFile: setup.stateFile)
        #expect(await restarted.verifier.check([setup.target], force: false).first?.isNew == false)
        #expect(runs(setup) == 1)

        // Другие аргументы — новая проверка; force — тоже.
        var changed = setup.target.harness
        changed.args.insert("--ephemeral", at: 1)
        let target = CodexTarget(harnessName: "codex", harness: changed, model: "luna")
        #expect(await restarted.verifier.check([target], force: false).first?.isNew == true)
        #expect(await restarted.verifier.check([target], force: true).first?.isNew == true)
        #expect(runs(setup) == 3)
    }

    @Test func agentsLeakBlocksCallsEvenInWarnMode() async throws {
        let setup = try makeSetup(mode: "leak")
        let report = try #require(await setup.codex.verifier.check([setup.target], force: false).first)
        guard case .problems(let problems) = report.status else {
            Issue.record("ожидались проблемы, а не \(report.status)")
            return
        }
        #expect(problems.first == "AGENTS.md из рабочей папки")
        #expect(report.blocking)

        let request = LLMRequest(variantKey: 1, variantName: "v", harnessName: "codex", harness: setup.target.harness,
                                 model: "luna", systemPrompt: "s", input: "i")
        await #expect(throws: (any Error).self) { try await setup.codex.complete(request) }
    }

    @Test func toolsWarnByDefaultAndBlockInBlockMode() async throws {
        let warn = try makeSetup(mode: "tools")
        let warned = try #require(await warn.codex.verifier.check([warn.target], force: false).first)
        #expect(warned.status == .problems(["инструменты: exec"]))
        #expect(!warned.blocking)
        let request = LLMRequest(variantKey: 1, variantName: "v", harnessName: "codex", harness: warn.target.harness,
                                 model: "luna", systemPrompt: "s", input: "i")
        #expect(try await warn.codex.complete(request) == "")

        let block = try makeSetup(mode: "tools", verify: .block)
        #expect(await block.codex.verifier.check([block.target], force: false).first?.blocking == true)
    }

    @Test func missingRequestIsUnavailableAndNotStored() async throws {
        let setup = try makeSetup(mode: "silent")
        let report = try #require(await setup.codex.verifier.check([setup.target], force: false).first)
        guard case .unavailable(let reason) = report.status else {
            Issue.record("ожидалась недоступная проверка, а не \(report.status)")
            return
        }
        #expect(reason.contains("не отправил запрос"))
        #expect(!report.blocking)
        #expect(!FileManager.default.fileExists(atPath: setup.stateFile.path))
    }

    /// Первый вызов harness без проверки при запуске запускает её в фоне; итог приходит в обработчик.
    @Test func firstCallStartsBackgroundCheck() async throws {
        let setup = try makeSetup()
        let received = AsyncStream<CodexCheckReport>.makeStream()
        await setup.codex.verifier.setReportHandler { received.continuation.yield($0) }
        let request = LLMRequest(variantKey: 1, variantName: "v", harnessName: "codex", harness: setup.target.harness,
                                 model: "luna", systemPrompt: "s", input: "i")
        #expect(try await setup.codex.complete(request) == "")
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next()?.status == .passed)

        // Повторный вызов в те же сутки проверку не повторяет.
        _ = try await setup.codex.complete(request)
        #expect(runs(setup) == 1)
    }
}
