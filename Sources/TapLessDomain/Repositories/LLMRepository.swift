import Foundation

/// Внешняя LLM: получает запрос, возвращает сырой ответ модели.
public protocol LLMRepository: Sendable {
    /// Отмена задачи (`Task.cancel()`) прерывает запрос и бросает `CancellationError`.
    func complete(_ request: LLMRequest) async throws -> String
}
