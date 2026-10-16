import Foundation
import TapLessDomain

/// Выбирает реализацию по типу harness варианта: CLI-программа или Ollama.
/// Если у harness задан `parallel`, лишние запросы ждут в очереди (`RequestLimiter`).
/// Очередь Ollama — общая на сервер (url): несколько harness делят его слоты.
public struct RoutingLLMRepository: LLMRepository {
    private let process: LLMRepository
    private let ollama: LLMRepository
    private let limiter = RequestLimiter()

    public init(process: LLMRepository, ollama: LLMRepository) {
        self.process = process
        self.ollama = ollama
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let limit = request.harness.parallel
        guard limit > 0 else { return try await route(request) }

        let key = Self.queueKey(request)
        let label = "\(request.variantKey) \(request.variantName)"
        let started = Date()
        if try await limiter.acquire(key, limit: limit) {
            Log.info(String(format: "[%@] ждал в очереди %@ (parallel = %ld) %.2f с",
                            label, key, limit, Date().timeIntervalSince(started)), .llm)
        }
        do {
            let result = try await route(request)
            await limiter.release(key)
            return result
        } catch {
            await limiter.release(key)
            throw error
        }
    }

    /// Ключ очереди: сервер для Ollama, имя harness для CLI.
    static func queueKey(_ request: LLMRequest) -> String {
        switch request.harness.kind {
        case .ollama: return "Ollama " + request.harness.url.trimmingCharacters(in: .whitespaces)
        case .process: return "harness " + request.harnessName
        }
    }

    private func route(_ request: LLMRequest) async throws -> String {
        switch request.harness.kind {
        case .process: return try await process.complete(request)
        case .ollama: return try await ollama.complete(request)
        }
    }
}
