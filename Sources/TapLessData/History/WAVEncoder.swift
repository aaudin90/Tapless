import Foundation
import TapLessDomain

/// WAV: PCM 16 бит little-endian, 16 кГц, mono, 44-байтный заголовок.
enum WAVEncoder {
    static func encode(_ clip: AudioClip) -> Data {
        let sampleRate = UInt32(AudioClip.sampleRate)
        let dataSize = UInt32(clip.samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        for sample in clip.samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
