import Foundation

/// Записанный звук в формате, который ждёт Whisper: 16 кГц mono Float32.
public struct AudioClip: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    /// Максимальный RMS среди буферов записи (после усиления, если оно было).
    public let peakLevel: Float
    /// Уровень, по которому запись проверяется на тишину (`stt.silence_threshold`). По умолчанию равен `peakLevel`.
    /// Запись с VPIO усиливается, если она тихая, и усиленный шум прошёл бы порог, поэтому для неё здесь
    /// стоит уровень до усиления. Сырой вход звонка (3 канала, ×100) уровень до усиления не передаёт:
    /// он в 100–200 раз ниже нормы и порог отсеял бы всю речь.
    public let silenceLevel: Float

    public init(samples: [Float], peakLevel: Float, silenceLevel: Float? = nil) {
        self.samples = samples
        self.peakLevel = peakLevel
        self.silenceLevel = silenceLevel ?? peakLevel
    }

    public var duration: Double { Double(samples.count) / Self.sampleRate }
}
