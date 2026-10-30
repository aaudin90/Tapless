import Foundation

/// Почему запись не стоит распознавать.
public enum ClipRejection: Sendable, Equatable {
    /// Короче `general.min_recording_ms` — скорее всего, случайное нажатие.
    case tooShort(seconds: Double)
    /// Вся запись тише `stt.silence_threshold`: на тишине Whisper выдумывает фразы.
    case silence
}

/// Сценарий «звук → текст»: проверка записи, распознавание STT-моделью
/// со статичной подсказкой `stt.initial_prompt` и чистка расшифровки.
/// Ошибки распознавания здесь не исправляются: это делает модель в `FormatTextUseCase` по словарю.
public struct TranscribeSpeechUseCase: Sendable {
    private let recognizer: SpeechRecognizer
    private let general: GeneralConfig
    private let stt: STTConfig

    public init(recognizer: SpeechRecognizer, config: AppConfig) {
        self.recognizer = recognizer
        self.general = config.general
        self.stt = config.stt
    }

    /// Скачивает и загружает модель, если это ещё не сделано.
    public func prepareModel(status: @escaping @Sendable (String) -> Void) async throws {
        try await recognizer.prepare(status: status)
    }

    /// Выгружает модель и загружает её заново.
    public func reloadModel(status: @escaping @Sendable (String) -> Void) async throws {
        await recognizer.unload()
        try await recognizer.prepare(status: status)
    }

    /// nil — запись можно распознавать.
    public func rejection(for clip: AudioClip) -> ClipRejection? {
        if clip.duration * 1000 < Double(general.minRecordingMs) {
            return .tooShort(seconds: clip.duration)
        }
        if Double(clip.silenceLevel) < stt.silenceThreshold {
            return .silence
        }
        return nil
    }

    /// Распознаёт запись. Модель должна быть загружена (`prepareModel`).
    /// Пустая строка — ничего не сказано.
    public func execute(_ clip: AudioClip) async throws -> String {
        let prompt = stt.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try await recognizer.transcribe(clip.samples, prompt: prompt)
        return TextTools.cleanTranscript(raw, dropPhrases: stt.dropPhrases)
    }
}
