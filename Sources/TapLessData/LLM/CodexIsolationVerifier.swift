import CryptoKit
import Foundation
import TOMLKit
import TapLessDomain

/// Проверка изоляции Codex: пробный запрос через harness уходит не провайдеру, а на `LoopbackCapture`.
///
/// Codex запускается с теми же аргументами, что у вариантов, с конфигом и каталогом моделей TapLess,
/// но с провайдером `tapless-verify` на `127.0.0.1`. Сервер отвечает 400, Codex сразу завершается,
/// а TapLess смотрит тело запроса: в нём должны быть только промпт и текст проверки, без инструментов
/// и чужих инструкций. В рабочей папке лежит `AGENTS.md` с меткой: метка в запросе — утечка,
/// вызовы harness блокируются при любом `verify`.
///
/// Полная проверка (~1–2 с) идёт, только если изменился отпечаток: версия Codex (`--version`),
/// каталог моделей, конфиг `CODEX_HOME`, аргументы harness или сама проверка (`checkVersion`).
/// Итоги хранятся в `stateFile` между запусками TapLess.
public actor CodexIsolationVerifier: CodexIsolationChecker {
    /// Меняется вместе с логикой проверки или конфигом Codex: тогда все harness проверяются заново.
    static let checkVersion = "1"
    /// Как часто перед вызовом сверять отпечаток (версия Codex могла обновиться).
    static let recheckInterval: TimeInterval = 24 * 3600
    static let runTimeout: TimeInterval = 60
    static let versionTimeout: TimeInterval = 15
    static let providerName = "tapless-verify"

    /// Прошлая проверка: в `stateFile`.
    struct Stored: Codable, Equatable {
        var fingerprint: String
        var version: String
        /// Пусто — проверка пройдена.
        var problems: [String]
        /// В запрос попал `AGENTS.md`: блокировка при любом `verify`.
        var agentsLeak: Bool
        var checkedAt: Date
    }

    /// Что нашёл разбор тела запроса.
    struct Findings: Equatable {
        var problems: [String]
        var agentsLeak: Bool
    }

    /// Чего ждём в запросе.
    struct Expected {
        var systemPrompt: String
        var input: String
        var model: String
        /// `model_reasoning_effort` из аргументов harness; nil — не задан.
        var reasoningEffort: String?
        var marker: String
    }

    private let preparer: CodexPreparer
    private let settings: LLMConfig
    private let stateFile: URL?
    private var stored: [String: Stored]?
    private var reports: [String: CodexCheckReport] = [:]
    /// Когда и при каком `CodexHome.generation` сверялся отпечаток.
    private var lastLook: [String: (date: Date, generation: Int)] = [:]
    private var running: [String: Task<CodexCheckReport, Never>] = [:]
    private var handler: (@Sendable (CodexCheckReport) -> Void)?

    init(preparer: CodexPreparer, settings: LLMConfig, stateFile: URL?) {
        self.preparer = preparer
        self.settings = settings
        self.stateFile = stateFile
    }

    public func check(_ targets: [CodexTarget], force: Bool) async -> [CodexCheckReport] {
        var result: [CodexCheckReport] = []
        for target in targets {
            result.append(await run(target, force: force))
        }
        return result
    }

    public func setReportHandler(_ handler: @escaping @Sendable (CodexCheckReport) -> Void) {
        self.handler = handler
    }

    /// Перед вызовом Codex: раз в сутки и после пересборки папки сверяет отпечаток — при `verify = "block"`
    /// с ожиданием, иначе в фоне. Возвращает причину отказа, если вызовы harness заблокированы.
    func beforeCall(_ target: CodexTarget, generation: Int) async -> String? {
        guard stateFile != nil else { return nil }
        let key = target.key
        let stale = lastLook[key].map {
            $0.generation != generation || Date().timeIntervalSince($0.date) > Self.recheckInterval
        } ?? true
        if stale {
            lastLook[key] = (Date(), generation)
            if target.harness.verify == .block {
                handler?(await run(target, force: false))
            } else {
                Task { await self.runInBackground(target) }
            }
        }
        guard let report = reports[key], report.blocking else { return nil }
        return report.text + ". Подробности — в логе; после исправления: меню TapLess → «Проверить Codex снова»"
    }

    private func runInBackground(_ target: CodexTarget) async {
        let report = await run(target, force: false)
        handler?(report)
    }

    /// Одна проверка на harness и модель: параллельные запросы ждут ту же.
    private func run(_ target: CodexTarget, force: Bool) async -> CodexCheckReport {
        let key = target.key
        if let task = running[key] { return await task.value }
        let task = Task { await self.perform(target, force: force) }
        running[key] = task
        let report = await task.value
        running[key] = nil
        reports[key] = report
        return report
    }

    private func perform(_ target: CodexTarget, force: Bool) async -> CodexCheckReport {
        let name = "Codex «\(target.harnessName)», модель \(target.model)"
        func unavailable(_ reason: String, version: String = "") -> CodexCheckReport {
            Log.warning("\(name): проверка изоляции не выполнена — \(reason)", .llm)
            return CodexCheckReport(target: target, version: version, status: .unavailable(reason),
                                    blocking: false, isNew: true, checkedAt: Date())
        }

        let directory: URL
        do {
            directory = try await preparer.prepare(harness: target.harness)
        } catch {
            return unavailable(error.localizedDescription)
        }
        lastLook[target.key] = (Date(), preparer.home.generation)

        let version: String
        do {
            version = try await codexVersion(target.harness, home: directory)
        } catch {
            return unavailable("версия Codex не получена: \(error.localizedDescription)")
        }
        let fingerprint = Self.fingerprint(version: version, home: directory, target: target, settings: settings)
        if !force, let previous = loadStored()[target.key], previous.fingerprint == fingerprint {
            Log.debug("\(name): проверка изоляции не нужна — ничего не изменилось с \(previous.checkedAt)", .llm)
            return report(target, previous, isNew: false)
        }

        Log.info("\(name): проверка изоляции (\(version))\(force ? ", по запросу" : "")", .llm)
        let started = Date()
        let findings: Findings
        do {
            findings = try await Self.verify(target, home: directory, settings: settings)
        } catch {
            return unavailable(error.localizedDescription, version: version)
        }
        let entry = Stored(fingerprint: fingerprint, version: version, problems: findings.problems,
                           agentsLeak: findings.agentsLeak, checkedAt: Date())
        save(entry, key: target.key)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if findings.problems.isEmpty {
            Log.info("\(name): изоляция проверена за \(seconds) с — в запросе только промпт и текст TapLess", .llm)
        } else {
            Log.warning("\(name): в запросе лишнее (\(seconds) с): " + findings.problems.joined(separator: "; ")
                        + (findings.agentsLeak ? ". AGENTS.md попал в запрос — вызовы заблокированы" : ""), .llm)
        }
        return report(target, entry, isNew: true)
    }

    private func report(_ target: CodexTarget, _ entry: Stored, isNew: Bool) -> CodexCheckReport {
        let blocking = !entry.problems.isEmpty && (entry.agentsLeak || target.harness.verify == .block)
        return CodexCheckReport(target: target, version: entry.version,
                                status: entry.problems.isEmpty ? .passed : .problems(entry.problems),
                                blocking: blocking, isNew: isNew, checkedAt: entry.checkedAt)
    }

    // MARK: - Состояние

    private func loadStored() -> [String: Stored] {
        if let stored { return stored }
        var loaded: [String: Stored] = [:]
        if let stateFile, let data = try? Data(contentsOf: stateFile) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([String: Stored].self, from: data)) ?? [:]
        }
        stored = loaded
        return loaded
    }

    private func save(_ entry: Stored, key: String) {
        var all = loadStored()
        all[key] = entry
        stored = all
        guard let stateFile else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(all).write(to: stateFile, options: .atomic)
        } catch {
            Log.warning("Codex: итог проверки не сохранён в \(stateFile.path): \(error.localizedDescription)", .llm)
        }
    }

    // MARK: - Отпечаток

    /// `executable --version`: последняя непустая строка (обёртка может печатать что-то до неё).
    private func codexVersion(_ harness: HarnessConfig, home: URL) async throws -> String {
        let spec = ProcessSpec(
            shell: settings.shell,
            loginShell: settings.loginShell,
            script: ProcessLLMRepository.launchScript,
            arguments: [CodexPreparer.executable(harness), "--version"],
            input: "",
            environment: CodexPreparer.environment(settings: settings, harness: harness, home: home),
            workdir: home,
            timeout: Self.versionTimeout,
            label: "codex --version"
        )
        let output = try await ProcessJob().run(spec)
        return output.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// SHA-256 всего, от чего зависит запрос Codex. Значения переменных окружения в файл не попадают.
    static func fingerprint(version: String, home: URL, target: CodexTarget, settings: LLMConfig) -> String {
        var hash = SHA256()
        func add(_ text: String) {
            hash.update(data: Data(text.utf8))
            hash.update(data: Data([0]))
        }
        add(checkVersion)
        add(version)
        for file in ["config.toml", "model-catalog.json"] {
            add((try? Data(contentsOf: home.appendingPathComponent(file))).map { SHA256.hash(data: $0).description } ?? "-")
        }
        let harness = target.harness
        add(target.model)
        add(harness.executable)
        (harness.args + ["|"] + harness.textArgs).forEach(add)
        add(harness.input.rawValue)
        for (name, value) in settings.env.merging(harness.env, uniquingKeysWith: { _, new in new }).sorted(by: { $0.key < $1.key }) {
            add(name + "=" + value)
        }
        add(settings.shell)
        add(settings.loginShell ? "login" : "-")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Проверка

    /// Запускает Codex против `LoopbackCapture` во временной папке и разбирает запрос.
    /// Бросает ошибку, если проверка не дошла до запроса.
    static func verify(_ target: CodexTarget, home: URL, settings: LLMConfig) async throws -> Findings {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tapless-codex-verify-\(UUID().uuidString)",
                                                                isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let verifyHome = root.appendingPathComponent("home", isDirectory: true)
        let workdir = root.appendingPathComponent("workdir", isDirectory: true)
        let runDirectory = root.appendingPathComponent("run", isDirectory: true)
        for directory in [verifyHome, workdir, runDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let token = UUID().uuidString.prefix(8)
        let marker = "TAPLESS-AGENTS-MARKER-\(token)"
        try "# Проверка TapLess\n\(marker)\n".write(to: workdir.appendingPathComponent("AGENTS.md"),
                                                  atomically: true, encoding: .utf8)

        let capture = try LoopbackCapture()
        let port = try await capture.start()
        defer { capture.stop() }

        let catalog = home.appendingPathComponent("model-catalog.json")
        let config = CodexHome.makeConfigTable(userConfig: nil, sourcePath: "",
                                               catalogPath: fm.fileExists(atPath: catalog.path) ? catalog.path : nil)
        config["model_provider"] = providerName
        config["model_providers"] = TOMLTable([providerName: TOMLTable([
            "name": "TapLess verify",
            "base_url": "http://127.0.0.1:\(port)/v1",
            "wire_api": "responses",
            "env_key": "TAPLESS_VERIFY_KEY",
        ])])
        try CodexHome.render(config).write(to: verifyHome.appendingPathComponent("config.toml"),
                                           atomically: true, encoding: .utf8)

        var harness = target.harness
        harness.env["CODEX_HOME"] = verifyHome.path
        harness.env["TAPLESS_VERIFY_KEY"] = "tapless-verify"
        var llm = settings
        llm.workdir = workdir.path
        llm.timeoutSeconds = runTimeout
        let expected = Expected(systemPrompt: "Проверка TapLess: системный промпт \(token).",
                                input: "Проверка TapLess: текст \(token).",
                                model: target.model,
                                reasoningEffort: reasoningEffort(in: harness.args + harness.textArgs),
                                marker: marker)
        let request = LLMRequest(variantKey: 0, variantName: "проверка Codex, ответ 400 ожидаем",
                                 harnessName: target.harnessName, harness: harness, model: target.model,
                                 systemPrompt: expected.systemPrompt, input: expected.input)
        var runError: Error?
        do {
            _ = try await ProcessLLMRepository(settings: llm, runDirectory: runDirectory, defaultWorkdir: workdir)
                .complete(request)
        } catch {
            runError = error
        }

        let posts = capture.requests.filter { $0.method == "POST" }
        guard let sent = posts.last(where: { $0.path.hasSuffix("/responses") }) ?? posts.last else {
            throw LLMError.badOutput("Codex не отправил запрос"
                                     + (runError.map { ": \($0.localizedDescription)" } ?? ""))
        }
        if let encoding = sent.headers["content-encoding"], encoding != "identity" {
            throw LLMError.badOutput("тело запроса сжато (\(encoding))")
        }
        return try analyze(body: sent.body, expected: expected)
    }

    /// `model_reasoning_effort` из `-c model_reasoning_effort="…"` в аргументах.
    static func reasoningEffort(in arguments: [String]) -> String? {
        let prefix = "model_reasoning_effort="
        guard let argument = arguments.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(argument.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// Разбирает тело запроса Responses API. Всё, кроме промпта и текста проверки, — проблема.
    static func analyze(body: Data, expected: Expected) throws -> Findings {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LLMError.badOutput("тело запроса — не JSON-объект (\(body.count) байт)")
        }
        var problems: [String] = []
        var promptFound = false
        var inputFound = false

        if let tools = json["tools"] as? [[String: Any]], !tools.isEmpty {
            problems.append("инструменты: " + toolNames(tools).joined(separator: ", "))
        }
        if let instructions = json["instructions"] as? String, !instructions.isEmpty {
            if instructions == expected.systemPrompt {
                promptFound = true
            } else {
                problems.append("встроенные инструкции Codex (\(instructions.count) симв.)")
            }
        }
        for item in json["input"] as? [[String: Any]] ?? [] {
            let type = item["type"] as? String ?? "message"
            switch type {
            case "additional_tools":
                let tools = item["tools"] as? [[String: Any]] ?? []
                if !tools.isEmpty {
                    problems.append("дополнительные инструменты: " + toolNames(tools).joined(separator: ", "))
                }
            case "message":
                let role = item["role"] as? String ?? "?"
                let text = messageText(item["content"])
                if (role == "developer" || role == "system") && text == expected.systemPrompt {
                    promptFound = true
                } else if role == "user" && text.trimmingCharacters(in: .whitespacesAndNewlines) == expected.input {
                    inputFound = true
                } else {
                    problems.append("лишнее сообщение \(role): «\(excerpt(text))»")
                }
            default:
                problems.append("лишний элемент \(type)")
            }
        }
        if !promptFound { problems.append("нет системного промпта TapLess") }
        if !inputFound { problems.append("нет текста TapLess") }

        if !expected.model.isEmpty, let model = json["model"] as? String, model != expected.model {
            problems.append("модель «\(model)» вместо «\(expected.model)»")
        }
        if let effort = expected.reasoningEffort,
           let actual = (json["reasoning"] as? [String: Any])?["effort"] as? String, actual != effort {
            problems.append("reasoning effort «\(actual)» вместо «\(effort)»")
        }

        let agentsLeak = String(decoding: body, as: UTF8.self).contains(expected.marker)
        if agentsLeak { problems.insert("AGENTS.md из рабочей папки", at: 0) }
        return Findings(problems: problems, agentsLeak: agentsLeak)
    }

    /// Имена инструментов; у пространства имён — `имя.инструмент`.
    private static func toolNames(_ tools: [[String: Any]]) -> [String] {
        tools.flatMap { tool -> [String] in
            let name = tool["name"] as? String ?? tool["type"] as? String ?? "?"
            guard let nested = tool["tools"] as? [[String: Any]] else { return [name] }
            return nested.isEmpty ? [name] : toolNames(nested).map { "\(name).\($0)" }
        }
    }

    private static func messageText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Начало текста для лога и меню: первая непустая строка, до 60 символов.
    private static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}
