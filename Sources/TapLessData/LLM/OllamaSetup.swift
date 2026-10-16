import Foundation
import TapLessDomain

/// Чем запустить сервер Ollama: приложением или CLI (`ollama serve`).
enum OllamaLauncher: Equatable, Sendable {
    case app(URL)
    case cli(URL)
}

/// Где на этом Mac стоит Ollama и как её запустить. В тестах подменяется.
struct OllamaInstallation: Sendable {
    /// Ollama.app, если установлена; иначе CLI `ollama` (например, из Homebrew); иначе nil.
    var launcher: @Sendable () -> OllamaLauncher?
    /// Запускает сервер в фоне с переменными окружения. Для `ollama serve` возвращает процесс:
    /// по нему видно, что сервер сразу упал (порт занят и т. п.), и не нужно ждать таймаут.
    var launch: @Sendable (OllamaLauncher, [String: String]) throws -> OllamaServerProcess?

    static let system = OllamaInstallation(
        launcher: {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if let app = ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app"]
                .first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return .app(URL(fileURLWithPath: app))
            }
            return ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { .cli(URL(fileURLWithPath: $0)) }
        },
        launch: { launcher, env in
            switch launcher {
            case .app(let app):
                try launchApp(app, env)
                return nil
            case .cli(let cli):
                return try OllamaServe.start(cli, env)
            }
        }
    )

    /// `open -g --env … -a Ollama.app`: приложение наследует переменные и передаёт их серверу.
    /// Если Ollama.app уже запущена, `open` её только активирует, и переменные не применяются.
    private static func launchApp(_ app: URL, _ env: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g"] + env.keys.sorted().flatMap { ["--env", "\($0)=\(env[$0]!)"] } + ["-a", app.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OllamaSetupError.launch("open завершился с кодом \(process.terminationStatus)")
        }
    }
}

/// Процесс `ollama serve`, запущенный TapLess: знает, завершился ли он.
final class OllamaServerProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var exit: String?

    init(pid: pid_t) { self.pid = pid }

    /// nil — процесс жив; иначе «код N» или «сигнал N».
    var exitDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return exit
    }

    /// `status` — как из `waitpid`.
    func finished(status: Int32) {
        let signal = status & 0x7f
        let text = signal == 0 ? "код \((status >> 8) & 0xff)" : "сигнал \(signal)"
        lock.lock(); exit = text; lock.unlock()
    }
}

/// Запуск `ollama serve` без Ollama.app. Сервер живёт в своей сессии (`setsid`):
/// он переживает выход и перезапуск TapLess, как сервер из Ollama.app.
enum OllamaServe {
    /// Вывод сервера; при > 5 МБ прежний файл переименовывается в `ollama.log.1`.
    /// Ротация — только при запуске: живой сервер пишет в открытый файл, пока не завершится.
    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TapLess/ollama.log")
    }

    /// Окружение сервера: только базовые переменные и `OLLAMA_*` из окружения TapLess
    /// плюс `overrides`. Прокси и ключи не передаются: если TapLess запущен из терминала,
    /// он унаследовал окружение shell, а сервер качает модели напрямую.
    /// Свои настройки памяти пользователя (`OLLAMA_FLASH_ATTENTION`, `OLLAMA_KV_CACHE_TYPE`) важнее наших.
    static func serverEnvironment(_ inherited: [String: String], _ overrides: [String: String]) -> [String: String] {
        let keep: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        var env = inherited.filter { keep.contains($0.key) || $0.key.hasPrefix("OLLAMA_") }
        for (key, value) in overrides where env[key] == nil || !OllamaSetup.userTunableKeys.contains(key) {
            env[key] = value
        }
        return env
    }

    static func start(_ cli: URL, _ env: [String: String], logFile log: URL = logFile,
                      inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> OllamaServerProcess {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? NSNumber, size.intValue > 5_000_000 {
            let old = log.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: log, to: old)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, NSTemporaryDirectory())

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let environment = serverEnvironment(inherited, env)
        let argv = [cli.path, "serve"].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, cli.path, &fileActions, &attributes, argv, envp)
        guard result == 0 else {
            throw OllamaSetupError.launch("\(cli.path) serve: \(String(cString: strerror(result)))")
        }
        Log.info("Ollama: запущен \(cli.path) serve, pid \(pid), вывод — \(log.path)", .llm)
        let process = OllamaServerProcess(pid: pid)
        // Забираем код выхода, чтобы не оставить зомби, если сервер завершится раньше TapLess.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            process.finished(status: status)
            Log.warning("Ollama: \(cli.path) serve (pid \(pid)) завершился, \(process.exitDescription ?? "")", .llm)
        }
        return process
    }
}

enum OllamaSetupError: LocalizedError {
    case badURL(String)
    case launch(String)
    case http(Int, String)
    case pull(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let url): return "неверный url Ollama: «\(url)»"
        case .launch(let details): return "не удалось запустить Ollama: \(details)"
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .pull(let message): return message
        }
    }
}

/// Готовит Ollama к работе: проверяет сервер (`/api/version`), запускает Ollama.app
/// или `ollama serve`, если сервер молчит, и скачивает недостающие модели (`/api/pull`) с прогрессом.
///
/// Модели скачивает сам сервер Ollama, приложение только следит за прогрессом.
public struct OllamaSetup: LocalLLMSetup {
    private let session: URLSession
    private let installation: OllamaInstallation
    private let startTimeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(session: URLSession = .shared) {
        self.init(session: session, installation: .system, startTimeout: 30, pollInterval: 0.5)
    }

    init(session: URLSession, installation: OllamaInstallation, startTimeout: TimeInterval, pollInterval: TimeInterval) {
        self.session = session
        self.installation = installation
        self.startTimeout = startTimeout
        self.pollInterval = pollInterval
    }

    public func prepare(_ targets: [OllamaTarget],
                        status: @escaping @Sendable (LocalLLMStatus) -> Void) async -> LocalLLMStatus {
        guard !targets.isEmpty else { return .notUsed }
        status(.checking)
        var servers: [String] = []
        for target in targets where !servers.contains(target.url) { servers.append(target.url) }

        for server in servers {
            let models = targets.filter { $0.url == server }.map(\.model)
            guard let base = Self.baseURL(server) else {
                Log.error("Ollama: неверный url «\(server)»", .llm)
                return .failed(OllamaSetupError.badURL(server).localizedDescription)
            }
            if !(await isReachable(base)) {
                let limits = targets.filter { $0.url == server }.map(\.parallel)
                let parallel = limits.dropFirst().reduce(limits.first ?? 0, OllamaTarget.combinedParallel)
                if let result = await start(base, parallel: parallel, status: status) { return result }
            }
            do {
                let installed = try await installedModels(base)
                Log.info("Ollama \(base.absoluteString): моделей на сервере \(Set(installed).count), нужны: \(models.joined(separator: ", "))", .llm)
                for model in models where !Self.contains(installed, model) {
                    try await pull(model, base: base, status: status)
                }
            } catch is CancellationError {
                Log.info("Ollama: подготовка отменена", .llm)
                return .failed("подготовка отменена")
            } catch {
                Log.error("Ollama: \(error.localizedDescription)", .llm)
                return .failed(error.localizedDescription)
            }
        }
        Log.info("Ollama готова: \(targets.map(\.model).joined(separator: ", "))", .llm)
        return .ready
    }

    // MARK: - Сервер

    /// nil — сервер запустился; иначе итоговое состояние.
    private func start(_ base: URL, parallel: Int,
                       status: @escaping @Sendable (LocalLLMStatus) -> Void) async -> LocalLLMStatus? {
        let url = base.absoluteString
        guard Self.isLocal(base) else {
            Log.warning("Ollama \(url) не отвечает; сервер не на этом Mac — запустить его нельзя", .llm)
            return .notRunning(url: url)
        }
        guard let launcher = installation.launcher() else {
            Log.warning("Ollama не установлена: нет Ollama.app и CLI ollama", .llm)
            return .notInstalled
        }
        status(.starting)
        let env = Self.serverEnvironment(base, parallel: parallel)
        let what: String
        switch launcher {
        case .app(let app): what = app.path
        case .cli(let cli): what = "\(cli.path) serve"
        }
        Log.info("Ollama \(url) не отвечает, запускаю \(what) с "
                 + env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: " "), .llm)
        let process: OllamaServerProcess?
        do {
            process = try installation.launch(launcher, env)
        } catch {
            Log.error("Ollama: \(error.localizedDescription)", .llm)
            return .failed(error.localizedDescription)
        }
        let started = Date()
        while Date().timeIntervalSince(started) < startTimeout {
            if Task.isCancelled { return .failed("подготовка отменена") }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if let exit = process?.exitDescription {
                let message = "ollama serve завершился сразу (\(exit)), подробности — \(OllamaServe.logFile.path)"
                Log.error("Ollama: \(message)", .llm)
                return .failed(message)
            }
            if await isReachable(base) {
                Log.info(String(format: "Ollama запущена за %.1f с", Date().timeIntervalSince(started)), .llm)
                return nil
            }
        }
        Log.error("Ollama не ответила за \(Int(startTimeout)) с после запуска", .llm)
        return .notRunning(url: url)
    }

    private func isReachable(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/version"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Имена моделей на сервере (`/api/tags`).
    private func installedModels(_ base: URL) async throws -> [String] {
        let request = URLRequest(url: base.appendingPathComponent("api/tags"), timeoutInterval: 10)
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw OllamaSetupError.http(code, json?["error"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        let models = json?["models"] as? [[String: Any]] ?? []
        return models.flatMap { [$0["name"] as? String, $0["model"] as? String].compactMap { $0 } }
    }

    // MARK: - Скачивание модели

    private func pull(_ model: String, base: URL,
                      status: @escaping @Sendable (LocalLLMStatus) -> Void) async throws {
        Log.info("Ollama: модели \(model) нет, скачиваю", .llm)
        status(.downloading(model: model, fraction: nil))
        // timeoutInterval — пауза без данных, а не длительность всего скачивания.
        var request = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        var progress = PullProgress()
        var lastPercent = -1
        var lastLogged = -10
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let error = event["error"] as? String {
                throw code == 200 ? OllamaSetupError.pull(error) : OllamaSetupError.http(code, error)
            }
            if progress.apply(event) {
                Log.info(String(format: "Ollama: модель %@ скачана за %.0f с", model, Date().timeIntervalSince(started)), .llm)
                return
            }
            guard let fraction = progress.fraction else { continue }
            let percent = Int((fraction * 100).rounded(.down))
            if percent != lastPercent {
                lastPercent = percent
                status(.downloading(model: model, fraction: fraction))
            }
            if percent >= lastLogged + 10 {
                lastLogged = percent - percent % 10
                Log.info("Ollama: скачивание \(model): \(percent)%", .llm)
            }
        }
        guard code == 200 else { throw OllamaSetupError.http(code, "скачивание \(model) не удалось") }
        throw OllamaSetupError.pull("скачивание \(model) оборвалось")
    }

    // MARK: - Вспомогательное

    static func baseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Переменные сервера, которые пользователь может задать сам (они важнее наших).
    static let userTunableKeys: Set<String> = ["OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE"]

    /// Переменные для сервера, который запускает TapLess: адрес из `url`, `parallel` слотов
    /// (если > 0), flash attention и KV-кэш q8_0 — меньше памяти на контекст при той же скорости.
    static func serverEnvironment(_ base: URL, parallel: Int) -> [String: String] {
        var host = base.host ?? "127.0.0.1"
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        var env = [
            "OLLAMA_HOST": "\(host):\(base.port ?? 11434)",
            "OLLAMA_FLASH_ATTENTION": "1",
            "OLLAMA_KV_CACHE_TYPE": "q8_0",
        ]
        if parallel > 0 { env["OLLAMA_NUM_PARALLEL"] = String(parallel) }
        return env
    }

    static func isLocal(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// Есть ли модель среди установленных. Имя без тега Ollama хранит как `<имя>:latest`.
    static func contains(_ installed: [String], _ model: String) -> Bool {
        installed.contains(model) || (!model.contains(":") && installed.contains(model + ":latest"))
    }
}

/// Прогресс `/api/pull`: сумма скачанного по всем слоям (`digest`).
struct PullProgress {
    private var totals: [String: Double] = [:]
    private var completed: [String: Double] = [:]

    /// Учитывает событие; true — скачивание завершено (`status: success`).
    mutating func apply(_ event: [String: Any]) -> Bool {
        if event["status"] as? String == "success" { return true }
        if let digest = event["digest"] as? String, let total = (event["total"] as? NSNumber)?.doubleValue, total > 0 {
            totals[digest] = total
            completed[digest] = (event["completed"] as? NSNumber)?.doubleValue ?? completed[digest] ?? 0
        }
        return false
    }

    /// Доля от 0 до 1; nil — размер ещё неизвестен.
    var fraction: Double? {
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, completed.values.reduce(0, +) / total)
    }
}
