import Foundation

/// Сценарий «подготовить Ollama»: для вариантов с `type = "ollama"` проверяет сервер,
/// запускает Ollama, если она установлена, и скачивает недостающие модели.
public struct PrepareLocalLLMUseCase: Sendable {
    /// Что нужно включённым вариантам. Пусто — Ollama не используется.
    public let targets: [OllamaTarget]
    private let setup: LocalLLMSetup

    public init(setup: LocalLLMSetup, config: AppConfig) {
        self.setup = setup
        self.targets = config.ollamaTargets
    }

    public var isUsed: Bool { !targets.isEmpty }

    public func execute(status: @escaping @Sendable (LocalLLMStatus) -> Void) async -> LocalLLMStatus {
        guard isUsed else { return .notUsed }
        return await setup.prepare(targets, status: status)
    }
}
