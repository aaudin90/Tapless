import Foundation

/// Сессия (одна диктовка), к которой относятся вызовы LLM в текущей задаче.
public enum HistoryContext {
    @TaskLocal public static var session: UUID?
}

/// Один вызов LLM для истории.
public struct LLMCallRecord: Sendable, Equatable {
    public let request: LLMRequest
    /// Ответ LLM до `cleanLLMOutput`; nil — ошибка.
    public let output: String?
    /// `localizedDescription` ошибки.
    public let error: String?
    public let cancelled: Bool
    public let startedAt: Date
    public let seconds: Double

    public init(request: LLMRequest, output: String?, error: String?, cancelled: Bool,
                startedAt: Date, seconds: Double) {
        self.request = request
        self.output = output
        self.error = error
        self.cancelled = cancelled
        self.startedAt = startedAt
        self.seconds = seconds
    }
}

public enum HistoryEvent: Sendable {
    /// Запись диктовки принята в распознавание. clip == nil — аудио не сохраняется (save_audio = false).
    case recording(clip: AudioClip?, duration: Double, targetApp: String?)
    case transcript(text: String, seconds: Double, model: String)
    /// Надиктованное замечание к строке `key` (режим правки).
    case feedbackRecording(clip: AudioClip?, duration: Double, key: Int)
    case feedbackTranscript(text: String, seconds: Double, model: String, key: Int)
    case llmCall(LLMCallRecord)
    /// Пользователь выбрал строку: вставка или копирование.
    case delivered(key: Int, text: String, copyOnly: Bool)
}

public struct HistoryPruneResult: Sendable, Equatable {
    public let removedSessions: Int
    public let removedPrompts: Int
    public let freedBytes: Int64

    public init(removedSessions: Int, removedPrompts: Int, freedBytes: Int64) {
        self.removedSessions = removedSessions
        self.removedPrompts = removedPrompts
        self.freedBytes = freedBytes
    }
}

public protocol HistoryRepository: Sendable {
    func record(_ event: HistoryEvent, session: UUID, at date: Date) async
    /// retentionDays 0 — без срока; maxBytes 0 — без предела.
    func prune(now: Date, retentionDays: Int, maxBytes: Int64) async -> HistoryPruneResult
}
