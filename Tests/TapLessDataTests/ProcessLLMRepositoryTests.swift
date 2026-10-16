import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

@Suite struct ProcessLLMRepositoryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepository(dir: URL, shell: String = "/bin/sh", timeout: Double = 30,
                                env: [String: String] = ["TAPLESS_TEST": "env-ok"]) -> ProcessLLMRepository {
        var settings = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults().llm
        settings.shell = shell
        settings.loginShell = false
        settings.timeoutSeconds = timeout
        settings.env = env
        return ProcessLLMRepository(settings: settings, runDirectory: dir, defaultWorkdir: dir)
    }

    /// Harness на /bin/sh: `script` получает аргументы `args` как $1, $2…
    private func shHarness(_ script: String, _ args: [String] = [], textArgs: [String] = [],
                           schemaArgs: [String] = [], input: HarnessInput = .stdin,
                           output: HarnessOutput = .text, outputPath: String = "",
                           schemaOutputPath: String = "", env: [String: String] = [:]) -> HarnessConfig {
        HarnessConfig(executable: "/bin/sh", args: ["-c", script, "sh"] + args, textArgs: textArgs,
                      schemaArgs: schemaArgs, input: input, output: output, outputPath: outputPath,
                      schemaOutputPath: schemaOutputPath, env: env)
    }

    private func request(_ harness: HarnessConfig, model: String = "it's", input: String = "вход",
                         schema: LLMSchema? = nil) -> LLMRequest {
        LLMRequest(variantKey: 3, variantName: "Тест", harnessName: "test", harness: harness,
                   model: model, systemPrompt: "СИСТЕМА", input: input, schema: schema)
    }

    @Test func passesArgumentsInputPromptAndEnvironment() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = shHarness(#"printf '%s|' "$1" "$(cat "$2")" "$3" "$TAPLESS_VARIANT" "$TAPLESS_TEST" "$H"; cat"#,
                                ["{model}", "{prompt_file}", "{system_prompt}"], env: ["H": "harness-env"])
        let output = try await makeRepository(dir: dir).complete(request(harness))
        #expect(output == "it's|СИСТЕМА|СИСТЕМА|3|env-ok|harness-env|вход")
    }

    @Test func argumentsAreNotParsedByShell() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tricky = #"a  b; $(echo x) `id` 'q' "w" \n *"#
        let harness = HarnessConfig(executable: "printf", args: ["%s", "{input}"], input: .arg)
        let output = try await makeRepository(dir: dir).complete(request(harness, input: tricky))
        #expect(output == tricky)
    }

    @Test func inputArgModeLeavesStdinEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = shHarness(#"printf '%s:' "$1"; cat; printf ':end'"#, ["{input}"], input: .arg)
        let output = try await makeRepository(dir: dir).complete(request(harness))
        #expect(output == "вход::end")
    }

    @Test func shellFunctionWorksAsExecutable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Как claude-proxy в ~/.zshenv: функция shell вместо программы.
        try #"myllm() { printf 'fn:%s:' "$1"; cat; }"#.write(
            to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let repository = makeRepository(dir: dir, shell: "/bin/zsh", env: ["ZDOTDIR": dir.path])
        let harness = HarnessConfig(executable: "myllm", args: ["{model}"])
        let output = try await repository.complete(request(harness, model: "haiku"))
        #expect(output == "fn:haiku:вход")
    }

    @Test func missingExecutableIsNotFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = HarnessConfig(executable: "tapless-no-such-program", args: [])
        do {
            _ = try await makeRepository(dir: dir).complete(request(harness))
            Issue.record("ожидали ошибку")
        } catch {
            guard case LLMError.notFound(let name, _) = error else {
                Issue.record("другая ошибка: \(error)")
                return
            }
            #expect(name == "tapless-no-such-program")
            #expect(error.localizedDescription.contains("не найдена"))
        }
    }

    @Test func textArgsWithoutSchemaAndSchemaArgsWithSchema() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = shHarness(#"printf '%s ' "$@""#, ["base"], textArgs: ["text"], schemaArgs: ["schema"])
        let repository = makeRepository(dir: dir)
        #expect(try await repository.complete(request(harness)) == "base text ")

        let schema = LLMSchema(name: "s", config: SchemaConfig(json: #"{"type":"object"}"#))
        // С схемой ответ разбирается как JSON: "base schema " — не JSON.
        await #expect(throws: LLMError.self) { try await repository.complete(request(harness, schema: schema)) }

        let jsonHarness = shHarness(#"printf '{"args":"%s"}' "$*""#, ["base"], textArgs: ["text"], schemaArgs: ["schema"])
        let structured = LLMSchema(name: "s", config: SchemaConfig(json: #"{"type":"object"}"#, resultPath: "args"))
        #expect(try await repository.complete(request(jsonHarness, schema: structured)) == "base schema")
    }

    @Test func schemaIsPassedAsTextAndFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaJSON = #"{"type":"object","properties":{"text":{"type":"string"}}}"#
        let harness = shHarness(#"[ "$1" = "$(cat "$2")" ] && printf '{"ok":"%s"}' "$TAPLESS_SCHEMA_FILE""#,
                                schemaArgs: ["{schema}", "{schema_file}"])
        let schema = LLMSchema(name: "s", config: SchemaConfig(json: schemaJSON, resultPath: "ok"))
        let output = try await makeRepository(dir: dir).complete(request(harness, schema: schema))
        #expect(output == dir.appendingPathComponent("schema-3.json").path)
    }

    @Test func schemaFromFileAndStructuredOutputInEventArray() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaFile = dir.appendingPathComponent("my-schema.json")
        try #"{"type":"object"}"#.write(to: schemaFile, atomically: true, encoding: .utf8)
        // Как claude -p --output-format json в подробном режиме: массив событий, результат — последним.
        let events = #"[{"type":"system"},{"type":"result","result":"{}","structured_output":{"text":"Готово."}}]"#
        let harness = shHarness(#"[ "$1" = "\#(schemaFile.path)" ] && printf '%s' '\#(events)'"#,
                                schemaArgs: ["{schema_file}"], schemaOutputPath: "structured_output")
        let schema = LLMSchema(name: "s", config: SchemaConfig(file: schemaFile.path, resultPath: "text"))
        #expect(try await makeRepository(dir: dir).complete(request(harness, schema: schema)) == "Готово.")
    }

    @Test func missingSchemaFileIsError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = LLMSchema(name: "s", config: SchemaConfig(file: dir.appendingPathComponent("нет.json").path))
        do {
            _ = try await makeRepository(dir: dir).complete(request(shHarness("echo hi"), schema: schema))
            Issue.record("ожидали ошибку")
        } catch {
            if case LLMError.schemaFile = error {} else { Issue.record("другая ошибка: \(error)") }
        }
    }

    @Test func jsonOutputUsesOutputPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = shHarness(#"printf '{"result":"ответ","is_error":false}'"#, output: .json, outputPath: "result")
        #expect(try await makeRepository(dir: dir).complete(request(harness)) == "ответ")
    }

    @Test func nonZeroExitIsError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: LLMError.self) {
            try await makeRepository(dir: dir).complete(request(shHarness("echo boom >&2; exit 7")))
        }
    }

    @Test func cancellationThrowsCancellationError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(dir: dir)
        let task = Task { try await repository.complete(request(shHarness("sleep 20"))) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    // MARK: - ProcessJob напрямую

    private func spec(_ command: String, input: String = "", timeout: TimeInterval = 1, workdir: URL) -> ProcessSpec {
        ProcessSpec(shell: "/bin/sh", loginShell: false, script: command, input: input,
                    environment: ["PATH": "/usr/bin:/bin"], workdir: workdir, timeout: timeout, label: "test")
    }

    private func isTimeout(_ error: Error) -> Bool {
        if case LLMError.timeout = error { return true }
        return false
    }

    private func readPid(_ file: URL) async throws -> pid_t {
        for _ in 0..<50 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LLMError.launch("pid-файл не появился")
    }

    private func expectDead(_ pid: pid_t) async throws {
        for _ in 0..<30 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        kill(pid, SIGKILL)
        Issue.record("процесс \(pid) остался жив")
    }

    @Test func timeoutKillsCommandIgnoringSigterm() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        do {
            _ = try await ProcessJob().run(spec("trap '' TERM; while true; do sleep 1; done", workdir: dir))
            Issue.record("ожидали таймаут")
        } catch {
            #expect(isTimeout(error))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func backgroundChildDoesNotBlockResultAndIsKilled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("bg.pid")
        let command = "sleep 30 & echo $! > '\(pidFile.path)'; echo hi"
        let started = Date()
        let output = try await ProcessJob().run(spec(command, timeout: 5, workdir: dir))
        #expect(output == "hi\n")
        #expect(Date().timeIntervalSince(started) < 3)
        try await expectDead(try await readPid(pidFile))
    }

    @Test func timeoutWinsOverExitCodeAfterSigterm() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await ProcessJob().run(spec("trap 'exit 3' TERM; sleep 1000 & wait", workdir: dir))
            Issue.record("ожидали таймаут")
        } catch {
            #expect(isTimeout(error))
        }
    }

    @Test func cancelKillsDescendants() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("bg.pid")
        let command = "sleep 20 & echo $! > '\(pidFile.path)'; wait"
        let job = ProcessJob()
        let task = Task { try await job.run(spec(command, timeout: 30, workdir: dir)) }
        let pid = try await readPid(pidFile)
        job.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await expectDead(pid)
    }

    @Test func cancelBeforeRunDoesNotLaunch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("started")
        let job = ProcessJob()
        job.cancel()
        await #expect(throws: CancellationError.self) {
            try await job.run(spec("touch '\(marker.path)'", workdir: dir))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func parallelJobsKeepTheirOwnPipes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<8 {
                group.addTask {
                    (index, try await ProcessJob().run(self.spec("cat", input: "вход-\(index)", timeout: 10, workdir: dir)))
                }
            }
            var all: [Int: String] = [:]
            for try await (index, output) in group { all[index] = output }
            return all
        }
        for index in 0..<8 { #expect(results[index] == "вход-\(index)") }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func largeInputAndOutputDoNotDeadlock() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = String(repeating: "0123456789abcdef", count: 128 * 1024)
        let output = try await ProcessJob().run(spec("cat", input: input, timeout: 20, workdir: dir))
        #expect(output.utf8.count == input.utf8.count)
        #expect(output == input)
    }

    @Test func missingWorkdirIsLaunchError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("нет-такой")
        do {
            _ = try await ProcessJob().run(spec("echo hi", workdir: missing))
            Issue.record("ожидали ошибку запуска")
        } catch {
            if case LLMError.launch = error {} else { Issue.record("другая ошибка: \(error)") }
        }
    }
}

@Suite struct HarnessOutputParserTests {
    private func extract(_ stdout: String, path: String = "", result: String = "") throws -> String {
        try HarnessOutputParser.extract(from: stdout, format: .json, path: path, resultPath: result)
    }

    @Test func textFormatReturnsStdoutAsIs() throws {
        #expect(try HarnessOutputParser.extract(from: " a\n", format: .text, path: "x", resultPath: "y") == " a\n")
    }

    @Test func pathsWithKeysAndIndexes() throws {
        let json = #"{"items":[{"text":"первый"},{"text":"второй"}],"n":5}"#
        #expect(try extract(json, path: "items.0.text") == "первый")
        #expect(try extract(json, path: "items.-1.text") == "второй")
        #expect(try extract(json, path: "items.text") == "второй")
        #expect(try extract(json, path: "n") == "5")
    }

    @Test func jsonLinesTakeLastEventWithPath() throws {
        let lines = #"{"type":"text","part":{"text":"раз"}}"# + "\n" + #"{"type":"step"}"# + "\n"
            + #"{"type":"text","part":{"text":"два"}}"# + "\n" + #"{"type":"done"}"#
        #expect(try extract(lines, path: "part.text") == "два")
    }

    @Test func structuredOutputAsJSONString() throws {
        #expect(try extract(#"{"result":"{\"text\":\"ок\"}"}"#, path: "result", result: "text") == "ок")
    }

    @Test func objectResultIsPrettyJSON() throws {
        let output = try extract(#"{"structured_output":{"b":1,"a":"x"}}"#, path: "structured_output")
        #expect(output == "{\n  \"a\" : \"x\",\n  \"b\" : 1\n}")
    }

    @Test func errorsForBadOutput() {
        #expect(throws: LLMError.self) { try extract("не json") }
        #expect(throws: LLMError.self) { try extract(#"{"a":1}"#, path: "b") }
        #expect(throws: LLMError.self) { try extract(#"{"a":{"b":1}}"#, path: "a", result: "c") }
        #expect(throws: LLMError.self) { try extract(#"{"a":null}"#, path: "a") }
    }
}
