import Accelerate
import AVFoundation
import TapLessDomain

enum RecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Микрофон недоступен (нет устройства ввода или нет разрешения)"
        case .converterUnavailable: return "Не удалось настроить преобразование звука в 16 кГц"
        }
    }
}

/// Пишет микрофон и сразу конвертирует в 16 кГц mono Float32 — формат, который ждёт Whisper.
/// `start`, `restart` и `stop` вызываются с главного потока.
final class AudioRecorder: @unchecked Sendable {
    /// Уровень сигнала (RMS буфера), вызывается с аудиопотока.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Сменилось устройство ввода или его формат (подключили AirPods и т. п.). Движок при этом
    /// останавливается сам; чтобы продолжить запись, вызовите `restart()`. Вызывается с любого потока.
    var onConfigurationChange: (@Sendable () -> Void)?

    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    private(set) var isRecording = false

    private final class Flag: @unchecked Sendable { var value = false }

    func start() throws {
        if isRecording { _ = stop() }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(AudioClip.sampleRate) * 60)
        peak = 0
        lock.unlock()

        try startEngine()
        isRecording = true
    }

    /// Перезапускает движок на текущем устройстве ввода, сохраняя уже записанное.
    func restart() throws {
        guard isRecording else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            isRecording = false
            throw error
        }
    }

    /// Останавливает запись и отдаёт всё записанное.
    func stop() -> AudioClip {
        if isRecording {
            stopEngine()
            isRecording = false
        }
        lock.lock()
        defer { lock.unlock() }
        Log.debug("Запись остановлена: \(samples.count) отсчётов", .audio)
        let result = AudioClip(samples: samples, peakLevel: peak)
        samples.removeAll()
        return result
    }

    // MARK: - Движок

    private func startEngine() throws {
        // Новый движок на каждый запуск: после смены микрофона (AirPods и т. п.)
        // старый может отдавать устаревший формат входа.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.error("Нет устройства ввода: формат входа \(inputFormat.sampleRate) Гц, \(inputFormat.channelCount) кан.", .audio)
            throw RecorderError.noInputDevice
        }
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "неизвестно"
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: AudioClip.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.error("Не удалось создать конвертер \(inputFormat.sampleRate) Гц → \(AudioClip.sampleRate) Гц", .audio)
            throw RecorderError.converterUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.error("Не удалось запустить аудиодвижок: \(error.localizedDescription)", .audio)
            throw error
        }
        Log.info("Аудиодвижок запущен: устройство «\(deviceName)», вход \(Int(inputFormat.sampleRate)) Гц, \(inputFormat.channelCount) кан. → \(Int(targetFormat.sampleRate)) Гц mono Float32", .audio)

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Log.info("Уведомление AVAudioEngineConfigurationChange", .audio)
            self?.onConfigurationChange?()
        }
    }

    private func stopEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.debug("Аудиодвижок остановлен", .audio)
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let consumed = Flag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))

        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        lock.lock()
        samples.append(contentsOf: chunk)
        if rms > peak { peak = rms }
        lock.unlock()

        onLevel?(rms)
    }
}
