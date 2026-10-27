import Accelerate
import AVFoundation
import CoreAudio
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
    // Диагностика входа до конвертера: максимум RMS и модуля по каждому каналу,
    // число буферов и полностью нулевых буферов.
    private var channelRMS: [Float] = []
    private var channelMax: [Float] = []
    private var rawBuffers = 0
    private var zeroBuffers = 0
    /// В записи был многоканальный вход: сырые капсюли встроенного микрофона, пока звонилка
    /// держит голосовую обработку. Такой сигнал в 50–80 раз тише обычного, поэтому в `stop` он усиливается.
    private var mixedInput = false
    private(set) var isRecording = false

    /// Усиление многоканального входа: пик записи поднимается до `mixedTargetPeak`, но не больше чем в `mixedMaxGain` раз.
    private static let mixedTargetPeak: Float = 0.3
    private static let mixedMaxGain: Float = 100
    /// Пиковый RMS многоканального входа до усиления, ниже которого запись считается мёртвой (нули) и не усиливается.
    /// Речь от тишины по уровню на таком входе не отличить: на звонке речь давала 0.0006–0.0015, молчание — 0.0004.
    /// Поэтому порог ловит только мёртвый вход, а тишину отсеивает Whisper (пустой текст).
    private static let mixedSilenceRMS: Float = 0.0002

    private final class Flag: @unchecked Sendable { var value = false }

    func start() throws {
        if isRecording { _ = stop() }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(AudioClip.sampleRate) * 60)
        peak = 0
        channelRMS = []
        channelMax = []
        rawBuffers = 0
        zeroBuffers = 0
        mixedInput = false
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
        let channels = channelRMS.indices.map {
            String(format: "к%d RMS %.4f / макс %.4f", $0 + 1, channelRMS[$0], channelMax[$0])
        }
        Log.debug("Вход до конвертера: \(channels.joined(separator: ", ")); нулевых буферов \(zeroBuffers) из \(rawBuffers)", .audio)
        let level = mixedInput ? amplifyMixed() : peak
        let result = AudioClip(samples: samples, peakLevel: level)
        samples.removeAll()
        return result
    }

    /// Усиливает запись с многоканального входа по её пику и возвращает пиковый RMS после усиления.
    /// Тихую запись (пиковый RMS ниже `mixedSilenceRMS`) не трогает: её отклонит проверка на тишину.
    /// Вызывается под `lock`.
    private func amplifyMixed() -> Float {
        guard !samples.isEmpty else { return peak }
        var maxAbs: Float = 0
        vDSP_maxmgv(samples, 1, &maxAbs, vDSP_Length(samples.count))
        guard peak >= Self.mixedSilenceRMS, maxAbs > 0 else {
            Log.info(String(format: "Многоканальный вход: без усиления, пиковый RMS %.4f ниже %.4f", peak, Self.mixedSilenceRMS), .audio)
            return peak
        }
        var gain = max(1, min(Self.mixedMaxGain, Self.mixedTargetPeak / maxAbs))
        let count = vDSP_Length(samples.count)
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &gain, base, 1, count)
        }
        Log.info(String(format: "Многоканальный вход: усиление ×%.1f (пик %.4f → %.4f, пиковый RMS %.4f → %.4f)",
                        gain, maxAbs, maxAbs * gain, peak, peak * gain), .audio)
        return peak * gain
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
        Log.debug(Self.describeInput(input, format: inputFormat), .audio)
        // Многоканальный вход (раскладка DiscreteInOrder) AVAudioConverter сводит в mono нулями,
        // поэтому каналы усредняются до конвертера, а он только меняет частоту.
        let mixFormat: AVAudioFormat? = inputFormat.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
            : nil
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: AudioClip.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              inputFormat.channelCount == 1 || mixFormat != nil,
              let converter = AVAudioConverter(from: mixFormat ?? inputFormat, to: targetFormat) else {
            Log.error("Не удалось создать конвертер \(inputFormat.sampleRate) Гц → \(AudioClip.sampleRate) Гц", .audio)
            throw RecorderError.converterUnavailable
        }
        if mixFormat != nil { mixedInput = true }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, mixFormat: mixFormat, converter: converter, targetFormat: targetFormat)
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

    private func process(_ buffer: AVAudioPCMBuffer, mixFormat: AVAudioFormat?,
                         converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        measureRaw(buffer)
        let source: AVAudioPCMBuffer
        if let mixFormat {
            guard let mixed = Self.downmix(buffer, to: mixFormat) else { return }
            source = mixed
        } else {
            source = buffer
        }
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
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
            return source
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

        // Индикатору — уровень с усилением, которое многоканальный вход почти всегда получит в `stop`.
        onLevel?(mixFormat == nil ? rms : rms * Self.mixedMaxGain)
    }

    /// Усредняет каналы буфера в один, с той же частотой.
    private static func downmix(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData?[0] else { return nil }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = vDSP_Stride(interleaved ? channels : 1)
        vDSP_vclr(out, 1, frames)
        for channel in 0..<channels {
            let base = interleaved ? data[0] + channel : data[channel]
            vDSP_vadd(out, 1, base, stride, out, 1, frames)
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(out, 1, &scale, out, 1, frames)
        mono.frameLength = buffer.frameLength
        return mono
    }

    // MARK: - Диагностика входа

    /// Копит уровень каждого канала сырого буфера, до сведения в mono.
    private func measureRaw(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = vDSP_Stride(interleaved ? channels : 1)
        var rms = [Float](repeating: 0, count: channels)
        var maxAbs = [Float](repeating: 0, count: channels)
        for channel in 0..<channels {
            let base = interleaved ? data[0] + channel : data[channel]
            vDSP_rmsqv(base, stride, &rms[channel], frames)
            vDSP_maxmgv(base, stride, &maxAbs[channel], frames)
        }

        lock.lock()
        if channelRMS.count != channels {
            channelRMS = [Float](repeating: 0, count: channels)
            channelMax = [Float](repeating: 0, count: channels)
        }
        for channel in 0..<channels {
            channelRMS[channel] = max(channelRMS[channel], rms[channel])
            channelMax[channel] = max(channelMax[channel], maxAbs[channel])
        }
        rawBuffers += 1
        if maxAbs.allSatisfy({ $0 == 0 }) { zeroBuffers += 1 }
        lock.unlock()
    }

    /// Строка для лога: формат входа до конвертера и устройство CoreAudio, к которому привязан движок.
    private static func describeInput(_ input: AVAudioInputNode, format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        let layout = format.channelLayout.map { "0x" + String($0.layoutTag, radix: 16) } ?? "нет"
        let head = "Формат входа: \(format.channelCount) кан., "
            + (format.isInterleaved ? "interleaved" : "non-interleaved")
            + ", \(asbd.mBitsPerChannel) бит, флаги 0x\(String(asbd.mFormatFlags, radix: 16)), раскладка \(layout)"
        guard let unit = input.audioUnit, let device = currentDevice(of: unit) else {
            return head + "; устройство CoreAudio неизвестно"
        }
        let name = deviceName(device) ?? "?"
        let channels = inputChannels(device).map(String.init) ?? "?"
        let transport = uint32Property(device, kAudioDevicePropertyTransportType).map(fourCC) ?? "?"
        let busy = uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 ? "да" : "нет" } ?? "?"
        let muted = uint32Property(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
            .map { $0 != 0 ? "да" : "нет" } ?? "нет свойства"
        return head + "; устройство CoreAudio \(device) «\(name)», транспорт \(transport), каналов входа \(channels), "
            + "уже используется: \(busy), mute входа: \(muted)"
    }

    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr && device != 0 ? device : nil
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func inputChannels(_ device: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
