import Foundation

/// Записанный звук в формате, который ждёт Whisper: 16 кГц mono Float32.
public struct AudioClip: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    /// Максимальный RMS среди буферов записи.
    public let peakLevel: Float

    public init(samples: [Float], peakLevel: Float) {
        self.samples = samples
        self.peakLevel = peakLevel
    }

    public var duration: Double { Double(samples.count) / Self.sampleRate }
}
