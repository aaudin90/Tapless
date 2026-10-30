import Foundation

/// Результат `SpeechGain.apply`.
public struct SpeechGainResult: Sendable {
    /// Запись после фильтра высоких частот, усиления и лимитера.
    public let samples: [Float]
    /// Применённый коэффициент (≥ 1).
    public let gain: Float
    /// Громкость речи (перцентиль RMS окон) до усиления, после фильтра.
    public let loudnessBefore: Float
    /// То же после усиления и лимитера.
    public let loudnessAfter: Float
    /// Доля отсчётов, которые лимитер сжал (0…1).
    public let limitedFraction: Double
    /// Максимальный RMS среди окон длиной ~85 мс: тот же смысл, что `AudioClip.peakLevel`.
    public let peakLevel: Float
    /// 99,9-й перцентиль |x| после фильтра, до усиления.
    public let peakBefore: Float
    /// Коэффициент урезан потолком по пикам (`SpeechGain.peakCeiling`): громкость речи просила больше.
    public let cappedByPeak: Bool
}

/// Нормирование громкости тихой записи (сырой многоканальный вход на звонке, тихий вывод VPIO).
/// Чистый Swift без Accelerate: так функции проверяются тестами в Domain. Всё линейно по длине записи,
/// сортируется только массив RMS окон (запись 300 с — 15 000 окон).
///
/// Порядок: фильтр высоких частот (убирает гул и постоянную составляющую, которые на тихом входе
/// после усиления становятся громче речи) → громкость речи (перцентиль RMS окон 20 мс, а не пик:
/// одиночный выброс не «душит» усиление) → коэффициент до цели −20 dBFS, но так, чтобы 99,9-й перцентиль |x|
/// не поднялся выше `peakCeiling` → мягкий лимитер. Нечисловые отсчёты (NaN, ±∞) обнуляются до фильтра.
public enum SpeechGain {
    /// Цель громкости речи: RMS 0.1 (−20 dBFS).
    public static let targetRMS: Float = 0.1
    /// Выше этого уровня лимитер плавно сжимает сигнал; ниже — сигнал не меняется.
    public static let limiterThreshold: Float = 0.5
    /// Частота среза фильтра высоких частот, Гц.
    public static let highPassCutoff: Double = 90
    /// Окно RMS, секунды.
    public static let windowSeconds: Double = 0.02
    /// Какой перцентиль RMS окон считается громкостью речи.
    public static let loudnessPercentile: Double = 0.95
    /// Потолок для 99,9-го перцентиля |x| после усиления (до лимитера). На записи с редкой речью 95-й перцентиль
    /// RMS окон попадает на шум и коэффициент доходит до ×100: речь тогда уходит в лимитер. Перцентиль 99,9 видит
    /// и редкую речь (её хватает на 0,1 % отсчётов, это ~16 отсчётов в секунду), а одиночный щелчок его не двигает.
    /// 0.9: лимитер начинается с 0.5, и пик на 0.9 он сжимает только до ~0.83, то есть мягко и не на всём сигнале.
    public static let peakCeiling: Float = 0.9
    /// Какой перцентиль |x| сравнивается с `peakCeiling`.
    public static let peakPercentile: Double = 0.999
    /// Громкость ниже этого — тишина: усиливать нечего.
    public static let silenceRMS: Float = 1e-6

    /// Фильтр высоких частот 2-го порядка (Баттерворт, Q = 1/√2, билинейное преобразование).
    public static func highPass(_ samples: [Float], sampleRate: Double, cutoff: Double = highPassCutoff) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0, cutoff > 0, cutoff < sampleRate / 2 else { return samples }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let cosW = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 + cosW) / 2 / a0
        let b1 = -(1 + cosW) / a0
        let b2 = b0
        let a1 = -2 * cosW / a0
        let a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var output = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                for i in 0..<input.count {
                    // NaN или ∞ навсегда испортили бы состояние фильтра: такой отсчёт считается тишиной.
                    let x0 = input[i].isFinite ? Double(input[i]) : 0
                    let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    x2 = x1; x1 = x0
                    y2 = y1; y1 = y0
                    out[i] = Float(y0)
                }
            }
        }
        return output
    }

    /// RMS каждого полного окна из `window` отсчётов. Запись короче окна даёт один RMS всей записи.
    public static func windowRMS(_ samples: [Float], window: Int) -> [Float] {
        guard !samples.isEmpty, window > 0 else { return [] }
        let size = min(window, samples.count)
        let count = samples.count / size
        var result = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { input in
            for w in 0..<count {
                var sum = 0.0
                let base = w * size
                for i in base..<(base + size) {
                    let v = Double(input[i])
                    sum += v * v
                }
                result[w] = Float((sum / Double(size)).squareRoot())
            }
        }
        return result
    }

    /// Перцентиль по рангу (`fraction` 0…1). Пустой массив даёт 0.
    public static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(1, max(0, fraction))).rounded())
        return sorted[index]
    }

    /// k-й по порядку элемент (0 — наименьший) без полной сортировки: выбор за O(n) в среднем.
    /// Трёхсторонний раздел, поэтому длинные серии одинаковых значений (тишина) не замедляют выбор.
    static func kthSmallest(_ values: [Float], _ k: Int) -> Float {
        guard !values.isEmpty else { return 0 }
        var a = values
        var lo = 0
        var hi = a.count - 1
        let target = min(max(k, 0), hi)
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let pivot = max(min(a[lo], a[mid]), min(max(a[lo], a[mid]), a[hi]))
            var lt = lo
            var i = lo
            var gt = hi
            while i <= gt {
                if a[i] < pivot {
                    a.swapAt(lt, i)
                    lt += 1
                    i += 1
                } else if a[i] > pivot {
                    a.swapAt(i, gt)
                    gt -= 1
                } else {
                    i += 1
                }
            }
            if target < lt {
                hi = lt - 1
            } else if target > gt {
                lo = gt + 1
            } else {
                return pivot
            }
        }
        return a[target]
    }

    /// Перцентиль по рангу от |x| (`fraction` 0…1): тот же ранг, что у `percentile`, но без сортировки.
    public static func magnitudePercentile(_ samples: [Float], _ fraction: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let magnitudes = samples.map { abs($0) }
        let index = Int((Double(magnitudes.count - 1) * min(1, max(0, fraction))).rounded())
        return kthSmallest(magnitudes, index)
    }

    /// Урезает коэффициент так, чтобы пик (`peak`, 99,9-й перцентиль |x|) после усиления не превысил `ceiling`.
    /// Результат не меньше 1: громче цели и громче потолка не ослабляем. Пика нет (тишина) — `gain` без изменений.
    public static func limitedByPeak(_ gain: Float, peak: Float, ceiling: Float = peakCeiling) -> Float {
        guard peak > 0 else { return gain }
        return max(1, min(gain, ceiling / peak))
    }

    /// Коэффициент усиления: цель / громкость, не меньше 1 (громче цели не ослабляем) и не больше `maxGain`.
    /// Тишина (громкость ниже `silenceRMS`) — 1.
    public static func gain(loudness: Float, target: Float = targetRMS, maxGain: Float) -> Float {
        guard loudness >= silenceRMS else { return 1 }
        return max(1, min(maxGain, target / loudness))
    }

    /// Мягкий лимитер: до `threshold` сигнал не меняется, выше — гладкое сжатие `T + (1 − T)·tanh((|x| − T)/(1 − T))`.
    /// Кривая непрерывна, производная в пороге равна 1, значения не больше 1: клиппинга нет.
    public static func softLimit(_ x: Float, threshold: Float = limiterThreshold) -> Float {
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let headroom = 1 - threshold
        let limited = threshold + headroom * tanhf((magnitude - threshold) / headroom)
        return x < 0 ? -limited : limited
    }

    /// Полный проход: фильтр → громкость → усиление → лимитер.
    public static func apply(to samples: [Float], sampleRate: Double, maxGain: Float) -> SpeechGainResult {
        let window = max(1, Int(sampleRate * windowSeconds))
        let filtered = highPass(samples, sampleRate: sampleRate)
        let before = percentile(windowRMS(filtered, window: window), loudnessPercentile)
        let wanted = gain(loudness: before, maxGain: maxGain)
        let peakBefore = magnitudePercentile(filtered, peakPercentile)
        let factor = limitedByPeak(wanted, peak: peakBefore)

        var output = filtered
        var limited = 0
        output.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<buffer.count {
                let y = buffer[i] * factor
                if abs(y) > limiterThreshold {
                    buffer[i] = softLimit(y)
                    limited += 1
                } else {
                    buffer[i] = y
                }
            }
        }
        let after = percentile(windowRMS(output, window: window), loudnessPercentile)
        let peak = windowRMS(output, window: max(1, Int(sampleRate * 0.085))).max() ?? 0
        return SpeechGainResult(samples: output, gain: factor, loudnessBefore: before, loudnessAfter: after,
                                limitedFraction: samples.isEmpty ? 0 : Double(limited) / Double(samples.count),
                                peakLevel: peak, peakBefore: peakBefore, cappedByPeak: factor < wanted)
    }
}
