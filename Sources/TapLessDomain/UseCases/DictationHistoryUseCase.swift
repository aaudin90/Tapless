import Foundation

/// Сценарий «сохранить диктовку в историю»: применяет настройки `[history]`
/// к событиям и передаёт их репозиторию.
public struct DictationHistoryUseCase: Sendable {
    private let repository: HistoryRepository
    private let config: HistoryConfig

    public init(repository: HistoryRepository, config: HistoryConfig) {
        self.repository = repository
        self.config = config
    }

    public var isEnabled: Bool { config.enabled }

    /// Ничего не делает при `enabled = false`; при `save_audio = false` убирает `clip` из событий
    /// (длительность остаётся).
    public func record(_ event: HistoryEvent, session: UUID, at date: Date = Date()) async {
        guard config.enabled else { return }
        await repository.record(stripped(event), session: session, at: date)
    }

    /// Чистит всегда, даже при `enabled = false`: иначе после выключения старое лежало бы вечно.
    public func prune(now: Date = Date()) async -> HistoryPruneResult {
        let maxBytes = Int64(max(config.maxSizeMB, 0)) * 1_048_576
        return await repository.prune(now: now, retentionDays: max(config.retentionDays, 0), maxBytes: maxBytes)
    }

    private func stripped(_ event: HistoryEvent) -> HistoryEvent {
        guard !config.saveAudio else { return event }
        switch event {
        case .recording(_, let duration, let targetApp):
            return .recording(clip: nil, duration: duration, targetApp: targetApp)
        case .feedbackRecording(_, let duration, let key):
            return .feedbackRecording(clip: nil, duration: duration, key: key)
        default:
            return event
        }
    }
}

/// Декоратор `LLMRepository`: передаёт запрос дальше и пишет вызов в историю.
/// Пишет только если задан `HistoryContext.session` и `purpose != .warmUp`.
/// Запись идёт в отдельном `Task` и не задерживает ответ.
public struct HistoryLLMRepository: LLMRepository {
    private let base: LLMRepository
    private let history: DictationHistoryUseCase

    public init(base: LLMRepository, history: DictationHistoryUseCase) {
        self.base = base
        self.history = history
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let session = HistoryContext.session
        guard let session, history.isEnabled, request.purpose != .warmUp else {
            return try await base.complete(request)
        }
        let startedAt = Date()
        let clock = ContinuousClock()
        let begin = clock.now
        func seconds() -> Double {
            let d = begin.duration(to: clock.now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        do {
            let output = try await base.complete(request)
            write(LLMCallRecord(request: request, output: output, error: nil, cancelled: false,
                                startedAt: startedAt, seconds: seconds()), session: session)
            return output
        } catch {
            let cancelled = error is CancellationError
            write(LLMCallRecord(request: request, output: nil,
                                error: cancelled ? nil : error.localizedDescription, cancelled: cancelled,
                                startedAt: startedAt, seconds: seconds()), session: session)
            throw error
        }
    }

    private func write(_ record: LLMCallRecord, session: UUID) {
        let history = history
        Task.detached {
            await history.record(.llmCall(record), session: session, at: record.startedAt)
        }
    }
}
