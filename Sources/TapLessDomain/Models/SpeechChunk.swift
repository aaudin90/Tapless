import Foundation

/// Кусок записи между паузами (VAD) и его расшифровка, как её вернула модель, без чистки.
public struct SpeechChunk: Sendable, Equatable {
    /// 16 кГц mono семплы куска: по ним кусок можно распознать заново.
    public let samples: [Float]
    public let text: String

    public init(samples: [Float], text: String) {
        self.samples = samples
        self.text = text
    }
}
