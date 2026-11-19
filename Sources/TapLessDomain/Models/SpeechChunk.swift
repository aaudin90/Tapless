import Foundation

/// Кусок записи между паузами (VAD) и его расшифровка, как её вернула модель, без чистки.
public struct SpeechChunk: Sendable, Equatable {
    /// Хвост короче этого не проверяется: после речи почти всегда есть доли секунды тишины.
    static let tailMinSeconds = 0.5
    /// Хвост считается речью, если его пиковый RMS не ниже этой доли пикового RMS распознанной части.
    /// На 120 записях тишина в хвосте давала 5–58 %, пропущенная речь — 126 %.
    static let tailLevelRatio: Float = 0.75
    /// Окно RMS, ~85 мс при 16 кГц: тот же смысл, что у `AudioClip.peakLevel`.
    static let levelWindow = 1360

    /// 16 кГц mono семплы куска: по ним кусок можно распознать заново.
    public let samples: [Float]
    public let text: String
    /// Конец последнего сегмента расшифровки в секундах от начала куска. nil — модель его не сообщила.
    public let spokenEnd: Double?

    public init(samples: [Float], text: String, spokenEnd: Double? = nil) {
        self.samples = samples
        self.text = text
        self.spokenEnd = spokenEnd
    }

    /// Модель закончила расшифровку раньше конца куска, а в остатке звук не тише речи:
    /// скорее всего, последние слова пропущены. Тишину в хвосте распознавать нельзя —
    /// на ней Whisper выдумывает «Готово.», «Спасибо.», «Продолжение следует...».
    public var hasLoudUnspokenTail: Bool {
        guard let spokenEnd, spokenEnd > 0 else { return false }
        let cut = Int(spokenEnd * AudioClip.sampleRate)
        guard cut > 0, cut < samples.count,
              Double(samples.count - cut) / AudioClip.sampleRate >= Self.tailMinSeconds else { return false }
        let spoken = Self.peakLevel(samples[..<cut])
        return spoken > 0 && Self.peakLevel(samples[cut...]) >= spoken * Self.tailLevelRatio
    }

    /// Максимальный RMS среди окон `levelWindow`.
    static func peakLevel(_ samples: ArraySlice<Float>) -> Float {
        var peak: Float = 0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + levelWindow, samples.endIndex)
            let window = samples[start..<end]
            let energy = window.reduce(Float(0)) { $0 + $1 * $1 }
            peak = max(peak, (energy / Float(window.count)).squareRoot())
            start = end
        }
        return peak
    }
}
