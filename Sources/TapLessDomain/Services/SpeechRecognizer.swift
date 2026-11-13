import Foundation

/// STT-модель: превращает звук в текст. Настройки модели передаются реализации при создании.
public protocol SpeechRecognizer: Sendable {
    /// Скачивает (если нужно) и загружает модель. Повторный вызов после загрузки — мгновенный.
    /// `status` получает текст для пользователя: прогресс скачивания, этап загрузки.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws

    /// Выгружает модель: следующий `prepare` загрузит её заново.
    func unload() async

    /// Режет 16 кГц mono запись на куски по паузам (не длиннее окна модели) и распознаёт каждый.
    /// Куски — в порядке записи; текст куска может быть пустым. `prompt` — подсказка с терминами,
    /// может быть пустой.
    func transcribeChunks(_ samples: [Float], prompt: String) async throws -> [SpeechChunk]

    /// Распознаёт один кусок из `transcribeChunks` целиком, без нарезки.
    func transcribe(_ samples: [Float], prompt: String) async throws -> String
}
