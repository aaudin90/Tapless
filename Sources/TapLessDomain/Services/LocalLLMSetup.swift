import Foundation

/// Модель на сервере Ollama, которая нужна вариантам.
public struct OllamaTarget: Sendable, Hashable {
    /// Адрес сервера, например `http://127.0.0.1:11434`.
    public let url: String
    public let model: String
    /// `parallel` harness: сколько запросов TapLess шлёт одновременно. 0 — без ограничения.
    public var parallel: Int

    public init(url: String, model: String, parallel: Int = 0) {
        self.url = url
        self.model = model
        self.parallel = parallel
    }

    /// `parallel` двух harness на один сервер: 0 (без ограничения) важнее любого числа.
    public static func combinedParallel(_ a: Int, _ b: Int) -> Int {
        a == 0 || b == 0 ? 0 : max(a, b)
    }
}

/// Состояние подготовки локальной LLM (Ollama).
public enum LocalLLMStatus: Sendable, Equatable {
    /// Ни один включённый вариант не использует Ollama.
    case notUsed
    case checking
    /// Ollama установлена, но не отвечала: приложение Ollama запускается.
    case starting
    /// Ollama не найдена на этом Mac.
    case notInstalled
    /// Сервер не отвечает и запустить его не удалось (или он не на этом Mac).
    case notRunning(url: String)
    /// Модель скачивается; `fraction` — доля от 0 до 1, nil — пока неизвестна.
    case downloading(model: String, fraction: Double?)
    case ready
    case failed(String)

    /// Подготовка ещё идёт.
    public var isBusy: Bool {
        switch self {
        case .checking, .starting, .downloading: return true
        default: return false
        }
    }

    /// Текст для меню и панели.
    public var text: String {
        switch self {
        case .notUsed: return "не используется"
        case .checking: return "проверка…"
        case .starting: return "запускаю Ollama…"
        case .notInstalled: return "не установлена"
        case .notRunning(let url): return "сервер не отвечает (\(url))"
        case .downloading(let model, let fraction):
            guard let fraction else { return "скачиваю \(model)…" }
            return "скачиваю \(model): \(Int((fraction * 100).rounded(.down)))%"
        case .ready: return "готова"
        case .failed(let message): return "ошибка — \(message)"
        }
    }
}

/// Подготовка локальной LLM: проверить сервер, при необходимости запустить его и скачать модели.
public protocol LocalLLMSetup: Sendable {
    /// `status` получает промежуточные состояния; возвращается итоговое.
    func prepare(_ targets: [OllamaTarget], status: @escaping @Sendable (LocalLLMStatus) -> Void) async -> LocalLLMStatus
}
