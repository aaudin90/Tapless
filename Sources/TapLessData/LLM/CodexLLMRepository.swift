import Foundation
import TapLessDomain

/// Codex CLI (`type = "codex"`): запуск как у CLI-harness, но с отдельной папкой `CODEX_HOME` (`CodexHome`),
/// чтобы Codex не подхватил `AGENTS.md`, MCP-серверы, навыки и прочие настройки пользователя.
///
/// Вход и провайдер берутся из `CODEX_HOME` пользователя: `[harness.<имя>.env]`, `[llm.env]`,
/// окружение TapLess или `~/.codex`.
///
/// Если кэша моделей нет ни у пользователя, ни в папке TapLess (Codex ещё ни разу не запускался),
/// каталог без инструментов собирается из встроенного: `executable debug models --bundled`,
/// один раз за запуск TapLess.
///
/// Перед вызовом `verifier` решает, не пора ли проверить изоляцию заново (раз в сутки и после
/// пересборки папки), и не пускает вызов, если проверка его заблокировала.
public struct CodexLLMRepository: LLMRepository {
    private let process: LLMRepository
    private let preparer: CodexPreparer
    /// Проверка изоляции с теми же `CODEX_HOME` и каталогом моделей, что у вызовов.
    public let verifier: CodexIsolationVerifier

    /// - Parameters:
    ///   - process: запуск CLI — обычно `ProcessLLMRepository`.
    ///   - homeDirectory: папка TapLess для `CODEX_HOME`.
    ///   - checkStateFile: где хранить итоги проверок изоляции. nil — итоги только в памяти,
    ///     и перед вызовами проверка сама не запускается (тесты).
    public init(process: LLMRepository, settings: LLMConfig, homeDirectory: URL, checkStateFile: URL? = nil) {
        self.process = process
        self.preparer = CodexPreparer(home: CodexHome(directory: homeDirectory), settings: settings)
        self.verifier = CodexIsolationVerifier(preparer: preparer, settings: settings, stateFile: checkStateFile)
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let directory = try await preparer.prepare(harness: request.harness)
        let target = CodexTarget(harnessName: request.harnessName, harness: request.harness, model: request.model)
        if let reason = await verifier.beforeCall(target, generation: preparer.home.generation) {
            throw LLMError.blocked(reason)
        }

        var harness = request.harness
        harness.env["CODEX_HOME"] = directory.path
        let isolated = LLMRequest(variantKey: request.variantKey, variantName: request.variantName,
                                  harnessName: request.harnessName, harness: harness, model: request.model,
                                  systemPrompt: request.systemPrompt, input: request.input,
                                  schema: request.schema, purpose: request.purpose)
        return try await process.complete(isolated)
    }

    /// `CODEX_HOME` пользователя: из `[harness.<имя>.env]`, затем `[llm.env]`, затем окружения; по умолчанию `~/.codex`.
    static func sourceHome(harnessEnv: [String: String], llmEnv: [String: String],
                           environment: [String: String]) -> URL {
        let custom = [harnessEnv["CODEX_HOME"], llmEnv["CODEX_HOME"], environment["CODEX_HOME"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let custom {
            return URL(fileURLWithPath: ShellTools.expandTilde(custom), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
}

/// Готовит папку `CODEX_HOME` TapLess: при необходимости встроенный каталог, затем `CodexHome.prepare`.
/// Общая для вызовов и проверки изоляции.
struct CodexPreparer: Sendable {
    /// Сколько ждём `codex debug models --bundled`.
    static let bundledTimeout: TimeInterval = 30

    let home: CodexHome
    let settings: LLMConfig
    private let bundled = OnceTask()

    init(home: CodexHome, settings: LLMConfig) {
        self.home = home
        self.settings = settings
    }

    /// Возвращает путь для `CODEX_HOME`.
    func prepare(harness: HarnessConfig) async throws -> URL {
        let source = CodexLLMRepository.sourceHome(harnessEnv: harness.env, llmEnv: settings.env,
                                                   environment: ProcessInfo.processInfo.environment)
        if home.needsBundledCatalog(source: source) {
            await bundled.run { [home, settings] in
                await Self.loadBundledCatalog(home: home, harness: harness, settings: settings)
            }
        }
        return try home.prepare(source: source)
    }

    /// Окружение для служебных запусков Codex (`--version`, `debug models`) с `CODEX_HOME` TapLess.
    static func environment(settings: LLMConfig, harness: HarnessConfig, home: URL) -> [String: String] {
        // CODEX_HOME из [harness.<имя>.env] — папка пользователя, а нужна своя.
        ProcessLLMRepository.environment(settings: settings, harness: harness)
            .merging(["CODEX_HOME": home.path]) { _, ours in ours }
    }

    static func executable(_ harness: HarnessConfig) -> String {
        harness.executable.hasPrefix("~") ? ShellTools.expandTilde(harness.executable) : harness.executable
    }

    /// Запускает `executable debug models --bundled` с `CODEX_HOME` TapLess и сохраняет каталог.
    /// Ошибка — только в лог: тогда каталога нет, а инструменты из профиля модели остаются.
    private static func loadBundledCatalog(home: CodexHome, harness: HarnessConfig, settings: LLMConfig) async {
        do {
            try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let spec = ProcessSpec(
                shell: settings.shell,
                loginShell: settings.loginShell,
                script: ProcessLLMRepository.launchScript,
                arguments: [executable(harness), "debug", "models", "--bundled"],
                input: "",
                environment: environment(settings: settings, harness: harness, home: home.directory),
                workdir: home.directory,
                timeout: bundledTimeout,
                label: "codex debug models"
            )
            let output = try await ProcessJob().run(spec)
            try home.saveBundledCatalog(Data(output.utf8))
            Log.info("Codex: кэша моделей нет, каталог собран из встроенного (\(output.utf8.count) байт)", .llm)
        } catch {
            Log.warning("Codex: встроенный каталог моделей не получен: \(error.localizedDescription)", .llm)
        }
    }
}

/// Задача, которая выполняется один раз; параллельные вызовы ждут её же.
private actor OnceTask {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if task == nil { task = Task { await operation() } }
        await task?.value
    }
}
