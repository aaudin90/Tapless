import Foundation
import Testing
@testable import TapLessDomain

struct SpeechGainTests {
    private let rate = 16_000.0
    private let invSqrt2: Float = 0.70710678

    private func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(Double(amplitude) * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    @Test func loudnessIsSetBySineNotBySingleOutlier() {
        var samples = sine(1000, amplitude: 0.01, seconds: 10)
        samples[80_000] = 0.9
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        let sineRMS: Float = 0.01 * invSqrt2
        let expected = SpeechGain.targetRMS / sineRMS
        #expect(abs(result.gain - expected) / expected < 0.1)
        #expect(result.limitedFraction < 0.01)
    }

    @Test func gainBringsSpeechToTarget() {
        let samples = sine(1000, amplitude: 0.02, seconds: 5)
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        #expect(abs(result.loudnessAfter - SpeechGain.targetRMS) < 0.01)
        #expect(result.loudnessBefore < result.loudnessAfter)
    }

    @Test func gainIsCappedByMaxGain() {
        let samples = sine(1000, amplitude: 0.0005, seconds: 3)
        #expect(SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 10).gain == 10)
        #expect(SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100).gain > 10)
    }

    @Test func loudSignalIsNotAttenuated() {
        let samples = sine(1000, amplitude: 0.4, seconds: 2)
        #expect(SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100).gain == 1)
    }

    @Test func silenceIsNotAmplified() {
        let zeros = [Float](repeating: 0, count: 32_000)
        let result = SpeechGain.apply(to: zeros, sampleRate: rate, maxGain: 100)
        #expect(result.gain == 1)
        #expect(result.samples.allSatisfy { $0 == 0 })
        #expect(SpeechGain.gain(loudness: 0, maxGain: 100) == 1)
        let empty = SpeechGain.apply(to: [], sampleRate: rate, maxGain: 100)
        #expect(empty.gain == 1 && empty.samples.isEmpty)
    }

    @Test func highPassAttenuatesHumAndKeepsSpeechBand() {
        let hum = SpeechGain.highPass(sine(50, amplitude: 1, seconds: 2), sampleRate: rate)
        let humRatio = rms(hum[8_000...]) / invSqrt2
        #expect(humRatio < 0.35)
        let tone = SpeechGain.highPass(sine(1000, amplitude: 1, seconds: 2), sampleRate: rate)
        let toneRatio = rms(tone[8_000...]) / invSqrt2
        #expect(toneRatio > 0.97 && toneRatio < 1.03)
    }

    @Test func highPassRemovesDCOffset() {
        let shifted = [Float](repeating: 0.2, count: 32_000)
        let filtered = SpeechGain.highPass(shifted, sampleRate: rate)
        #expect(abs(filtered[31_000]) < 0.001)
    }

    @Test func limiterNeverClipsAndKeepsLowLevels() {
        for i in stride(from: -100.0, through: 100.0, by: 0.05) {
            let x = Float(i)
            let y = SpeechGain.softLimit(x)
            #expect(abs(y) <= 1.0)
            if abs(x) <= SpeechGain.limiterThreshold { #expect(y == x) }
        }
        #expect(abs(SpeechGain.softLimit(100)) <= 1)
        #expect(SpeechGain.softLimit(-100) < 0)
        let t = SpeechGain.limiterThreshold
        #expect(abs(SpeechGain.softLimit(t + 0.0001) - (t + 0.0001)) < 0.0001)
    }

    @Test func limiterIsMonotonic() {
        var previous: Float = 0
        for i in stride(from: 0.0, through: 20.0, by: 0.01) {
            let y = SpeechGain.softLimit(Float(i))
            #expect(y >= previous)
            previous = y
        }
    }

    @Test func appliedSignalStaysBelowOne() {
        var samples = sine(1000, amplitude: 0.005, seconds: 5)
        samples[40_000] = 0.9
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        #expect(result.samples.allSatisfy { abs($0) <= 1.0 })
        #expect(result.limitedFraction > 0)
    }

    /// Детерминированный шум: линейный конгруэнтный генератор, значения в [-amplitude, amplitude].
    private func noise(amplitude: Float, count: Int, seed: UInt32 = 12345) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    @Test func rareSpeechOnNoiseIsLimitedByPeakCeiling() {
        // 60 с шума (RMS ≈ 0.0012) и 1 с «речи» с амплитудой 0.05 посередине: речь занимает ~1,7 % записи,
        // 95-й перцентиль RMS окон приходится на шум и без потолка просил бы ×83.
        var samples = noise(amplitude: 0.002, count: 60 * 16_000)
        for i in 0..<16_000 {
            samples[30 * 16_000 + i] += 0.05 * Float(sin(2 * Double.pi * 300 * Double(i) / rate))
        }
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        let unlimited = SpeechGain.gain(loudness: result.loudnessBefore, maxGain: 100)
        #expect(unlimited > 60)
        #expect(result.cappedByPeak)
        #expect(result.gain < 25)
        #expect(result.gain > 1)
        // После усиления 99,9-й перцентиль |x| не выше потолка (с запасом на фильтр и округление перцентиля).
        let after = SpeechGain.magnitudePercentile(SpeechGain.highPass(samples, sampleRate: rate).map { $0 * result.gain },
                                                   SpeechGain.peakPercentile)
        #expect(after <= SpeechGain.peakCeiling * 1.001)
        #expect(result.samples.allSatisfy { abs($0) <= 1.0 })
    }

    @Test func singleClickDoesNotCapGain() {
        var samples = sine(1000, amplitude: 0.01, seconds: 10)
        samples[80_000] = 0.9
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        #expect(!result.cappedByPeak)
        // 99,9-й перцентиль остался на уровне синусоиды, а не на щелчке.
        #expect(result.peakBefore < 0.02)
        #expect(result.gain > 10)
    }

    @Test func peakCeilingNeverAttenuates() {
        #expect(SpeechGain.limitedByPeak(5, peak: 0.45) == 2)
        #expect(SpeechGain.limitedByPeak(1.5, peak: 0.45) == 1.5)
        #expect(SpeechGain.limitedByPeak(5, peak: 2) == 1)
        #expect(SpeechGain.limitedByPeak(5, peak: 0) == 5)
        #expect(SpeechGain.limitedByPeak(1, peak: 2) == 1)
    }

    @Test func nanAndInfinityDoNotPoisonFilterOrGain() {
        var samples = sine(1000, amplitude: 0.01, seconds: 5)
        samples[10_000] = .nan
        samples[10_001] = .infinity
        samples[20_000] = -.infinity
        let result = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        #expect(result.samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        #expect(result.gain.isFinite)
        let expected = SpeechGain.targetRMS / (0.01 * invSqrt2)
        #expect(abs(result.gain - expected) / expected < 0.1)
        // Фильтр после NaN продолжает работать: хвост записи не обнулён и не залип.
        #expect(rms(result.samples[60_000...]) > 0.05)
        let filtered = SpeechGain.highPass(samples, sampleRate: rate)
        #expect(filtered.allSatisfy { $0.isFinite })
    }

    @Test func magnitudePercentileMatchesSorting() {
        let values = noise(amplitude: 1, count: 5_001, seed: 7) + [Float](repeating: 0, count: 2_000)
        for fraction in [0.0, 0.1, 0.5, 0.95, 0.999, 1.0] {
            let expected = SpeechGain.percentile(values.map { abs($0) }, fraction)
            #expect(SpeechGain.magnitudePercentile(values, fraction) == expected)
        }
        #expect(SpeechGain.magnitudePercentile([], 0.999) == 0)
        #expect(SpeechGain.magnitudePercentile([-0.5], 0.999) == 0.5)
    }

    @Test func percentileAndWindows() {
        #expect(SpeechGain.percentile([], 0.95) == 0)
        #expect(SpeechGain.percentile([1, 2, 3, 4, 100], 0.5) == 3)
        #expect(SpeechGain.percentile([1, 2, 3, 4, 100], 1) == 100)
        #expect(SpeechGain.windowRMS([], window: 320).isEmpty)
        #expect(SpeechGain.windowRMS([0.5, 0.5, 0.5], window: 320) == [0.5])
        #expect(SpeechGain.windowRMS([1, 1, 0, 0, 1], window: 2) == [1, 0])
    }

    @Test func longRecordingIsProcessedInReasonableTime() {
        let samples = sine(1000, amplitude: 0.01, seconds: 300)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = SpeechGain.apply(to: samples, sampleRate: rate, maxGain: 100)
        }
        // В debug-сборке тестов (без оптимизаций) допуск щедрый; в release запись 300 с обрабатывается за десятки мс.
        #expect(elapsed < .seconds(15))
    }
}
