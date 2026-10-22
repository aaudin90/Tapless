import Foundation
import TapLessDomain

enum LLMError: LocalizedError {
    case promptFile(String)
    case schemaFile(String)
    case timeout(TimeInterval)
    case launch(String)
    case notFound(String, String)
    case failed(Int32, String)
    case killed(Int32, String)
    case emptyOutput(String)
    case badOutput(String)
    case serverUnavailable(String, String)
    case modelMissing(String)
    case http(Int, String)
    /// Вызов запрещён проверкой изоляции Codex.
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .promptFile(let s):
            return "Не удалось записать промпт: \(s)"
        case .schemaFile(let s):
            return "Схема ответа: \(s)"
        case .timeout(let t):
            return "Нет ответа за \(Int(t)) с"
        case .launch(let s):
            return "Не удалось запустить команду: \(s)"
        case .notFound(let executable, let details):
            let hint = "Программа «\(executable)» не найдена: проверьте executable в [harness] и llm.extra_path"
            return details.isEmpty ? hint : "\(hint). \(details)"
        case .failed(let code, let details):
            return details.isEmpty ? "Команда завершилась с кодом \(code)" : "Код \(code): \(details)"
        case .killed(let signal, let details):
            return details.isEmpty ? "Команда завершена сигналом \(signal)" : "Сигнал \(signal): \(details)"
        case .emptyOutput(let details):
            return details.isEmpty ? "Пустой ответ" : "Пустой ответ. \(details)"
        case .badOutput(let details):
            return "Ответ не в ожидаемом формате: \(details)"
        case .serverUnavailable(let url, let details):
            return "Ollama не отвечает по адресу \(url): запустите Ollama (приложение или «ollama serve»). \(details)"
        case .modelMissing(let model):
            return "Модели «\(model)» нет в Ollama: выполните «ollama pull \(model)»"
        case .http(let code, let details):
            return details.isEmpty ? "Ошибка HTTP \(code)" : "HTTP \(code): \(details)"
        case .blocked(let reason):
            return reason
        }
    }
}

/// LLM как внешняя CLI-программа (harness): Claude Code, OpenCode, llm, свой скрипт.
///
/// Программа запускается через shell из `[llm]`: `shell [-l] -c '"$0" "$@"' executable args…`.
/// Так работают PATH, функции и алиасы из профиля shell, а аргументы доходят до программы
/// как есть, без shell-разбора.
public struct ProcessLLMRepository: LLMRepository {
    /// Скрипт для `shell -c`: запустить `$0` с аргументами `$@`. Без `exec`, чтобы работали функции shell.
    static let launchScript = #""$0" "$@""#

    private let settings: LLMConfig
    private let runDirectory: URL
    private let defaultWorkdir: URL

    /// - Parameters:
    ///   - runDirectory: куда писать системные промпты и схемы вариантов (`prompt-<N>.txt`, `schema-<N>.json`).
    ///   - defaultWorkdir: рабочая папка программы, если `llm.workdir` пустой.
    public init(settings: LLMConfig, runDirectory: URL, defaultWorkdir: URL) {
        self.settings = settings
        self.runDirectory = runDirectory
        self.defaultWorkdir = defaultWorkdir
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let label = "\(request.variantKey) \(request.variantName)"
        let harness = request.harness

        let promptFile = runDirectory.appendingPathComponent("prompt-\(request.variantKey).txt")
        do {
            try request.systemPrompt.write(to: promptFile, atomically: true, encoding: .utf8)
        } catch {
            Log.error("[\(label)] не удалось записать промпт \(promptFile.path): \(error.localizedDescription)", .llm)
            throw LLMError.promptFile(error.localizedDescription)
        }

        let schema = try request.schema.map { try resolveSchema($0, variantKey: request.variantKey) }

        var values = [
            "model": request.model,
            "prompt_file": promptFile.path,
            "system_prompt": request.systemPrompt,
            "input": request.input,
            "schema": schema?.text ?? "",
            "schema_file": schema?.file.path ?? "",
        ]
        let templates = harness.args + (schema == nil ? harness.textArgs : harness.schemaArgs)
        let arguments = templates.map { TextTools.fill($0, values) }
        let executable = harness.executable.hasPrefix("~")
            ? ShellTools.expandTilde(harness.executable)
            : harness.executable

        var tapless = [
            "TAPLESS_MODEL": request.model,
            "TAPLESS_PROMPT_FILE": promptFile.path,
            "TAPLESS_VARIANT": String(request.variantKey),
            "TAPLESS_VARIANT_NAME": request.variantName,
        ]
        if let schema { tapless["TAPLESS_SCHEMA_FILE"] = schema.file.path }
        let env = Self.environment(settings: settings, harness: harness, extra: tapless)

        let workdir = settings.workdir.isEmpty
            ? defaultWorkdir
            : URL(fileURLWithPath: ShellTools.expandTilde(settings.workdir), isDirectory: true)

        let spec = ProcessSpec(
            shell: settings.shell,
            loginShell: settings.loginShell,
            script: Self.launchScript,
            arguments: [executable] + arguments,
            input: harness.input == .stdin ? request.input : "",
            environment: env,
            workdir: workdir,
            timeout: max(5, settings.timeoutSeconds),
            label: label
        )

        Log.info("[\(label)] harness «\(request.harnessName)»: \(executable), модель \(request.model)"
                 + (request.schema.map { ", схема «\($0.name)»" } ?? "")
                 + ", вход \(harness.input.rawValue) \(Log.text(request.input))", .llm)
        // Длинные и личные значения в логе заменяются описанием.
        values["input"] = Log.text(request.input)
        values["system_prompt"] = "‹системный промпт, \(request.systemPrompt.count) симв.›"
        values["schema"] = schema.map { "‹схема \(request.schema?.name ?? ""), \($0.text.count) симв.›" } ?? ""
        let shown = templates.map { ShellTools.quote(TextTools.fill($0, values)) }.joined(separator: " ")
        Log.debug("[\(label)] \(settings.shell)\(settings.loginShell ? " -l" : "") -c '\(Self.launchScript)' "
                  + "\(ShellTools.quote(executable)) \(shown)", .llm)
        let envNames = Set(settings.env.keys).union(harness.env.keys).sorted()
        Log.debug("[\(label)] рабочая папка \(workdir.path)"
                  + (envNames.isEmpty ? "" : ", свои переменные: \(envNames.joined(separator: ", "))"), .llm)

        let started = Date()
        let job = ProcessJob()
        let stdout: String
        do {
            stdout = try await withTaskCancellationHandler {
                try await job.run(spec)
            } onCancel: {
                job.cancel()
            }
        } catch LLMError.failed(127, let details) {
            // 127 — shell не нашёл программу или функцию.
            throw LLMError.notFound(executable, details)
        }

        let result: String
        do {
            result = try HarnessOutputParser.extract(
                from: stdout,
                format: schema == nil ? harness.output : .json,
                path: schema == nil ? harness.outputPath : harness.schemaOutputPath,
                resultPath: schema?.resultPath ?? ""
            )
        } catch {
            Log.error("[\(label)] \(error.localizedDescription). stdout: \(ShellTools.lastLines(stdout, maxChars: 800))", .llm)
            throw error
        }
        Log.info(String(format: "[%@] готово за %.1f с, %ld симв.", label, Date().timeIntervalSince(started), result.count), .llm)
        return result
    }

    /// Окружение программы: окружение TapLess, `llm.extra_path` в начале PATH, `NO_COLOR`, `extra`,
    /// затем `[llm.env]` и `[harness.<имя>.env]` — переменные пользователя важнее.
    static func environment(settings: LLMConfig, harness: HarnessConfig,
                            extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = settings.extraPath.map(ShellTools.expandTilde).joined(separator: ":")
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extraPath.isEmpty ? basePath : extraPath + ":" + basePath
        env["NO_COLOR"] = "1"
        for (name, value) in extra { env[name] = value }
        for (name, value) in settings.env { env[name] = value }
        for (name, value) in harness.env { env[name] = value }
        return env
    }

    // MARK: - Схема

    private struct ResolvedSchema {
        var text: String
        var file: URL
        var resultPath: String
    }

    /// Текст схемы и файл с ней. Схема из `file` берётся как есть; из `json` — пишется в папку запусков.
    private func resolveSchema(_ schema: LLMSchema, variantKey: Int) throws -> ResolvedSchema {
        let loaded = try SchemaSource.load(schema)
        if let file = loaded.file {
            return ResolvedSchema(text: loaded.text, file: file, resultPath: schema.config.resultPath)
        }
        let file = runDirectory.appendingPathComponent("schema-\(variantKey).json")
        do {
            try loaded.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.error("Схема «\(schema.name)»: не записать \(file.path): \(error.localizedDescription)", .llm)
            throw LLMError.schemaFile("не записать \(file.path): \(error.localizedDescription)")
        }
        return ResolvedSchema(text: loaded.text, file: file, resultPath: schema.config.resultPath)
    }
}
