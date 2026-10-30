import Accelerate
import AVFoundation
import CoreAudio
import TapLessDomain

enum RecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case unstableInput

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Микрофон недоступен (нет устройства ввода или нет разрешения)"
        case .converterUnavailable: return "Не удалось настроить преобразование звука в 16 кГц"
        case .unstableInput: return "Устройство ввода меняется слишком часто"
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

    /// Движок живёт только во время записи: объект с созданным `inputNode` держит устройство ввода
    /// открытым, и Bluetooth-гарнитура остаётся в профиле HFP (глухой звук у всех программ).
    private var engine: AVAudioEngine?
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
    /// В записи был вход звонка: сырые капсюли встроенного микрофона (встроенное устройство, не меньше 3 каналов),
    /// пока звонилка держит голосовую обработку. Такой сигнал в 50–80 раз тише обычного, поэтому в `stop` он усиливается.
    /// Другие многоканальные входы (USB-стерео, BlackHole) только усредняются, без усиления.
    private var mixedInput = false
    /// Тап принимает отсчёты. Сбрасывается в `stop`, как только записанное забирается: пока движок
    /// освобождается в фоне, поздний буфер уже не попадёт в запись.
    private var accepting = false
    /// Последовательная очередь, на которой в фоне освобождается остановленный движок (`stop`).
    /// Следующий `startEngine` ждёт её (`sync`): устройство ввода должно освободиться до нового запуска.
    private let releaseQueue = DispatchQueue(label: "io.github.aaudin90.tapless.audio-release")
    private(set) var isRecording = false
    /// Микрофон, выбранный на старте записи. Смена настройки посреди записи действует со следующей:
    /// перезапуск движка (смена устройств системы) использует прежнее значение.
    private var microphone: MicrophoneSetting = .auto
    /// Голосовая обработка Apple, выбранная на старте записи; как и `microphone`, действует всю запись.
    private var voiceProcessing: VoiceProcessingMode = .off
    /// Последний запущенный движок работал с VPIO. Тогда `stop` не усиливает вход ×100: уровень делает AGC.
    private var voiceProcessedInput = false
    /// В текущей попытке запуска дошли до включения VPIO (нужно, чтобы отличить сбой VPIO от других сбоев). Только главный поток.
    private var voiceProcessingAttempted = false
    /// Устройство и формат, с которыми запущен движок. Нужны, чтобы отличить настоящую смену входа
    /// от пустого уведомления. Читаются с потока уведомлений, поэтому под `lock`.
    private var activeInput: (device: AudioDeviceID?, sampleRate: Double, channels: AVAudioChannelCount, voiceProcessing: Bool)?
    /// Моменты перезапусков движка за последние секунды: защита от бесконечного цикла перезапусков.
    private var restartTimes: [Date] = []
    private static let maxRestarts = 5
    private static let restartWindow: TimeInterval = 10

    /// Усиление входа звонка: громкость речи поднимается до цели `SpeechGain.targetRMS`, но не больше чем в `mixedMaxGain` раз.
    private static let mixedMaxGain: Float = 100
    /// Пиковый RMS входа звонка до усиления, ниже которого запись считается мёртвой (нули) и не усиливается.
    /// Речь от тишины по уровню на таком входе не отличить: на звонке речь давала 0.0006–0.0015, молчание — 0.0004.
    /// Поэтому порог ловит только мёртвый вход, а тишину отсеивает Whisper (пустой текст).
    private static let mixedSilenceRMS: Float = 0.0002
    /// С VPIO запись нормируется по громкости речи, только если её пиковый RMS ниже этого порога (AGC не справился), и не больше чем в `voiceMaxGain` раз.
    private static let voiceQuietRMS: Float = 0.005
    private static let voiceMaxGain: Float = 10

    /// Как сводить многоканальный вход в mono.
    private enum MixMode {
        /// Среднее каналов: сырые капсюли встроенного микрофона на звонке.
        case average
        /// Первый канал: после VPIO обработанный сигнал лежит в нём.
        case firstChannel
    }

    /// Сбой голосовой обработки: запуск повторяется без неё.
    private struct VoiceProcessingFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private final class Flag: @unchecked Sendable { var value = false }

    /// VPIO не запустилась в этом процессе. Каждая попытка блокирует главный поток до ~2,4 с (включение, связь,
    /// старт движка), поэтому после первого сбоя запись сразу идёт без неё. Сбрасывается перезапуском TapLess
    /// или сменой пункта «Голосовая обработка на звонке» в меню.
    private final class FailureState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failed }
            set { lock.lock(); failed = newValue; lock.unlock() }
        }
    }
    private static let voiceProcessingFailure = FailureState()

    /// Забыть прежний сбой VPIO: следующая запись на звонке попробует её снова.
    static func resetVoiceProcessingFailure() {
        voiceProcessingFailure.value = false
    }

    func start(microphone: MicrophoneSetting, voiceProcessing: VoiceProcessingMode) throws {
        if isRecording { _ = stop() }
        // До сброса состояния: tap движка прошлой записи, который ещё освобождается в фоне,
        // иначе успел бы дописать буфер в новую запись.
        releaseQueue.sync {}
        lock.lock()
        self.microphone = microphone
        self.voiceProcessing = voiceProcessing
        voiceProcessedInput = false
        accepting = true
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(AudioClip.sampleRate) * 60)
        peak = 0
        channelRMS = []
        channelMax = []
        rawBuffers = 0
        zeroBuffers = 0
        mixedInput = false
        restartTimes.removeAll()
        lock.unlock()

        try startEngine()
        isRecording = true
    }

    /// Перезапускает движок на текущем устройстве ввода, сохраняя уже записанное.
    func restart() throws {
        guard isRecording else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < Self.restartWindow }
        guard restartTimes.count < Self.maxRestarts else {
            Log.error("Движок перезапускался \(restartTimes.count) раз за \(Int(Self.restartWindow)) с — запись остановлена, чтобы не зациклиться", .audio)
            stopEngine()
            isRecording = false
            throw RecorderError.unstableInput
        }
        restartTimes.append(now)
        stopEngine()
        do {
            try startEngine()
        } catch {
            isRecording = false
            throw error
        }
    }

    /// Останавливает запись и отдаёт всё записанное. Движок освобождается в фоне, уже после того,
    /// как отсчёты забраны: с VPIO это ~0,47 с, которые иначе держали бы главный поток.
    func stop() -> AudioClip {
        let released: AVAudioEngine? = isRecording ? detachEngine() : nil
        isRecording = false
        let clip = takeClip()
        if let released { releaseInBackground(released) }
        return clip
    }

    private func takeClip() -> AudioClip {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        Log.debug("Запись остановлена: \(samples.count) отсчётов", .audio)
        let channels = channelRMS.indices.map {
            String(format: "к%d RMS %.4f / макс %.4f", $0 + 1, channelRMS[$0], channelMax[$0])
        }
        let rawLevels = "Вход до конвертера: \(channels.joined(separator: ", ")); нулевых буферов \(zeroBuffers) из \(rawBuffers)"
        // С VPIO уровни всех каналов нужны в обычном логе: по ним подбирается, какой канал брать.
        if voiceProcessedInput { Log.info(rawLevels, .audio) } else { Log.debug(rawLevels, .audio) }
        let level: Float
        // Уровень для проверки тишины. С VPIO — до нормирования: усиленный шум иначе проходит порог.
        // Вход звонка (×100) и обычная запись проверяются по итоговому уровню.
        var silenceLevel: Float?
        if voiceProcessedInput {
            silenceLevel = peak
            level = normalizeVoiceProcessed()
        } else {
            level = mixedInput ? amplifyMixed() : peak
        }
        let result = AudioClip(samples: samples, peakLevel: level, silenceLevel: silenceLevel)
        samples.removeAll()
        return result
    }

    /// Нормирует громкость записи с входа звонка (или тихой записи с VPIO) и возвращает пиковый RMS после
    /// обработки: фильтр высоких частот → усиление по громкости речи (95-й перцентиль RMS окон 20 мс, цель −20 dBFS,
    /// не больше `maxGain` и не выше потолка по 99,9-му перцентилю |x|) → мягкий лимитер (`SpeechGain`). Мёртвую запись (пиковый RMS ниже `mixedSilenceRMS`)
    /// не трогает: её отклонит проверка на тишину. Вызывается под `lock`.
    private func amplifyMixed(maxGain: Float = AudioRecorder.mixedMaxGain, label: String = "Вход звонка") -> Float {
        guard !samples.isEmpty else { return peak }
        guard peak >= Self.mixedSilenceRMS else {
            Log.info(String(format: "%@: без усиления, пиковый RMS %.4f ниже %.4f", label, peak, Self.mixedSilenceRMS), .audio)
            return peak
        }
        let result = SpeechGain.apply(to: samples, sampleRate: AudioClip.sampleRate, maxGain: maxGain)
        samples = result.samples
        Log.info(String(format: "%@: усиление ×%.1f (предел ×%.0f%@), громкость речи (p95 RMS 20 мс) %.4f → %.4f, "
                        + "p99,9 |x| %.4f, в лимитере %.2f%% отсчётов, пиковый RMS %.4f → %.4f",
                        label, result.gain, maxGain, result.cappedByPeak ? ", урезано потолком по пикам" : "",
                        result.loudnessBefore, result.loudnessAfter, result.peakBefore,
                        result.limitedFraction * 100, peak, result.peakLevel), .audio)
        return result.peakLevel
    }

    /// Запись с VPIO: уровень делает AGC, поэтому ×100 не применяется. Если запись всё же тише
    /// `voiceQuietRMS`, она нормируется по громкости речи, но не больше чем в `voiceMaxGain` раз. Вызывается под `lock`.
    private func normalizeVoiceProcessed() -> Float {
        guard peak < Self.voiceQuietRMS else {
            Log.info(String(format: "Голосовая обработка: без усиления, пиковый RMS %.4f", peak), .audio)
            return peak
        }
        return amplifyMixed(maxGain: Self.voiceMaxGain, label: "Голосовая обработка (тихая запись)")
    }

    // MARK: - Движок

    private func startEngine() throws {
        // Движок прошлой записи освобождается в фоне (`stop`): ждём, пока он отпустит устройство.
        releaseQueue.sync {}
        lock.lock()
        let wantedVoiceProcessing = voiceProcessing
        lock.unlock()
        if wantedVoiceProcessing == .call {
            if Self.voiceProcessingFailure.value {
                Log.debug("Голосовая обработка пропущена: в этом запуске TapLess она уже не стартовала", .audio)
            } else {
                // Сбой после попытки включить VPIO не фатален: запомнить его и писать старым путём
                // (усреднение каналов и усиление). Движок освобождается ровно один раз (`releaseEngine` снимает и observer).
                voiceProcessingAttempted = false
                let engine = AVAudioEngine()
                self.engine = engine
                do {
                    try configureAndStart(engine, voiceProcessing: .call)
                    return
                } catch {
                    releaseEngine()
                    guard voiceProcessingAttempted else { throw error }
                    Self.voiceProcessingFailure.value = true
                    Log.warning("Голосовая обработка не запустилась: \(Self.describeError(error)) — до перезапуска TapLess "
                                + "(или смены пункта меню «Голосовая обработка на звонке») запись идёт без неё", .audio)
                }
            }
        }
        // Новый движок на каждый запуск: после смены микрофона (AirPods и т. п.)
        // старый может отдавать устаревший формат входа.
        voiceProcessingAttempted = false
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            try configureAndStart(engine, voiceProcessing: .off)
        } catch {
            releaseEngine()
            throw error
        }
    }

    /// Ошибка с кодом: у AVAudioEngine это OSStatus (например, -10875 `kAudioUnitErr_FailedInitialization`).
    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private func configureAndStart(_ engine: AVAudioEngine, voiceProcessing: VoiceProcessingMode) throws {
        // Обращение к inputNode создаёт модуль ввода. Привязку к устройству делаем сразу после него,
        // до чтения формата, installTap и prepare: пока движок не инициализирован, устройство не открыто.
        let input = engine.inputNode
        lock.lock()
        let setting = microphone
        lock.unlock()
        let selectionNote = Self.bindInputDevice(input, setting: setting)
        var inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.error("Нет устройства ввода: формат входа \(inputFormat.sampleRate) Гц, \(inputFormat.channelCount) кан.", .audio)
            throw RecorderError.noInputDevice
        }
        Log.debug(Self.describeInput(input, format: inputFormat), .audio)

        // Признак звонка: встроенный микрофон и не меньше 3 каналов. Транспорт берётся у реального устройства
        // (не у агрегата, который AVAudioEngine собирает сам). Другие многоканальные входы — USB-стерео,
        // звуковые карты, BlackHole — отдают обычный сигнал: им не нужны ни VPIO, ни усиление ×100.
        let inputDevice = input.audioUnit.flatMap {
            Self.resolvedInput(of: $0, expected: nil)?.device
        } ?? Self.expectedInput(for: setting)
        let builtIn = inputDevice.map { Self.isBuiltIn($0) } ?? false
        let channelCount = Int(inputFormat.channelCount)
        let callInput = VoiceProcessingMode.isCallInput(inputChannels: channelCount, isBuiltIn: builtIn)
        if channelCount > 1 {
            Log.debug("Многоканальный вход: \(channelCount) кан., встроенное устройство: \(builtIn ? "да" : "нет") — "
                      + (callInput ? "вход звонка" : "обычный многоканальный вход, без VPIO и усиления"), .audio)
        }

        var voiceProcessed = false
        if voiceProcessing.shouldEnable(inputChannels: channelCount, isBuiltIn: builtIn) {
            voiceProcessingAttempted = true
            let before = Self.describeFormat(inputFormat)
            inputFormat = try enableVoiceProcessing(engine, input, setting: setting)
            voiceProcessed = true
            Log.info("Голосовая обработка включена: формат входа до — \(before), после — \(Self.describeFormat(inputFormat))", .audio)
        }

        // Реальный вход: модуль может смотреть на агрегат, который AVAudioEngine собирает сам,
        // а с VPIO — на устройство вывода.
        let resolved = input.audioUnit.flatMap {
            Self.resolvedInput(of: $0, expected: voiceProcessed ? Self.expectedInput(for: setting) : nil)
        }
        let device = resolved?.device
        let deviceName = device.flatMap { Self.deviceName($0) } ?? "неизвестно"
        if let aggregate = resolved?.aggregate {
            Log.debug("Вход идёт через агрегат \(aggregate) «\(Self.deviceName(aggregate) ?? "?")», реальное устройство «\(deviceName)»", .audio)
        }
        // С VPIO модуль указывает на устройство вывода: вход тогда не проверен, а взят из настройки (`expectedInput`).
        let assumedInput = resolved?.outputDevice != nil
        if let output = resolved?.outputDevice {
            Log.debug("Модуль VPIO указывает на устройство вывода «\(Self.deviceName(output) ?? "?")», вход предполагается — «\(deviceName)»", .audio)
        }
        // Многоканальный вход (раскладка DiscreteInOrder) AVAudioConverter сводит в mono нулями,
        // поэтому каналы сводятся до конвертера, а он только меняет частоту.
        let mixFormat: AVAudioFormat? = inputFormat.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
            : nil
        let mixMode: MixMode = voiceProcessed ? .firstChannel : .average
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: AudioClip.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              inputFormat.channelCount == 1 || mixFormat != nil,
              let converter = AVAudioConverter(from: mixFormat ?? inputFormat, to: targetFormat) else {
            Log.error("Не удалось создать конвертер \(inputFormat.sampleRate) Гц → \(AudioClip.sampleRate) Гц", .audio)
            throw RecorderError.converterUnavailable
        }
        // Индикатору — уровень с усилением, которое сырой вход звонка почти всегда получит в `stop`.
        // С VPIO усиление ×100 не применяется, поэтому и индикатор показывает фактический уровень.
        let levelGain: Float = callInput && !voiceProcessed ? Self.mixedMaxGain : 1

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, mixFormat: mixFormat, mixMode: mixMode, levelGain: levelGain,
                          converter: converter, targetFormat: targetFormat)
        }

        // Наблюдатель ставится до старта: уведомление, пришедшее во время запуска, иначе потерялось бы.
        // Обработка уходит на главную очередь: движок освобождается там же (или в фоне после отсчётов),
        // и из чужого потока его трогать нельзя. Движок захвачен слабо.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            DispatchQueue.main.async { self?.engineConfigurationChanged(engine) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.error("Не удалось запустить аудиодвижок: \(Self.describeError(error)); \(Self.describeGraph(engine, input: input))", .audio)
            throw error
        }
        lock.lock()
        if callInput { mixedInput = true }
        voiceProcessedInput = voiceProcessed
        // Формат движка — тот, с которым он запущен (после VPIO — уже изменённый): с ним сверяются уведомления.
        activeInput = (device, inputFormat.sampleRate, inputFormat.channelCount, voiceProcessed)
        lock.unlock()
        let deviceLabel = assumedInput ? "предполагаемое устройство ввода (expectedInput, не проверено)" : "устройство"
        Log.info("Аудиодвижок запущен: \(deviceLabel) «\(deviceName)»\(selectionNote.map { " (\($0))" } ?? "")\(voiceProcessed ? ", голосовая обработка" : ""), вход \(Int(inputFormat.sampleRate)) Гц, \(inputFormat.channelCount) кан. → \(Int(targetFormat.sampleRate)) Гц mono Float32", .audio)
    }

    /// Включает VPIO на модуле ввода до `installTap` и `prepare` и возвращает формат входа после включения.
    ///
    /// Из SDK (AVAudioIONode.h, `setVoiceProcessingEnabled`): VPIO включается на обоих IO-узлах сразу и только при
    /// остановленном движке; формат выхода входного узла и формат входа выходного узла должны совпадать.
    /// Формат входа выходного узла задаёт связь с ним (AVAudioEngine.h, `mainMixerNode`): пока связь микшер → выход
    /// не задана явно, движок сам подгоняет её под формат устройства вывода (на звонке 44,1 кГц при входе 48 кГц —
    /// отсюда ошибка -10875 при старте). Поэтому после включения VPIO связь делается явно, точно в формате выхода
    /// входного узла (на звонке проверено: этого достаточно). После связи формат выхода входного узла перечитывается:
    /// он идёт в `installTap` и должен совпасть с форматом связи по частоте и числу каналов, иначе это сбой VPIO.
    /// Микшер глушится (`outputVolume = 0`): звук на выход не идёт, VPIO нужен только для записи.
    private func enableVoiceProcessing(_ engine: AVAudioEngine, _ input: AVAudioInputNode,
                                       setting: MicrophoneSetting) throws -> AVAudioFormat {
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw VoiceProcessingFailure(reason: "setVoiceProcessingEnabled: \(Self.describeError(error))")
        }
        // Включение VPIO пересоздаёт модуль ввода: привязка к устройству могла сброситься, возвращаем её.
        // Предупреждения не пишем: с VPIO модуль указывает на устройство вывода, и сверка не сойдётся и при удаче.
        _ = Self.bindInputDevice(input, setting: setting, logWarnings: false)
        // AGC остаётся включённым: он заменяет усиление ×100.
        input.isVoiceProcessingAGCEnabled = true
        // Меньше приглушать собеседника звонка.
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceProcessingFailure(reason: "после включения формат входа \(format.sampleRate) Гц, \(format.channelCount) кан.")
        }
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 0
        Log.info("Голосовая обработка, до связи микшер → выход: \(Self.describeGraph(engine, input: input)); формат связи — \(Self.describeFormat(format))", .audio)
        engine.connect(mixer, to: engine.outputNode, format: format)
        Log.info("Голосовая обработка, после связи: \(Self.describeGraph(engine, input: input))", .audio)
        let actual = input.outputFormat(forBus: 0)
        guard actual.sampleRate > 0, actual.channelCount > 0,
              actual.sampleRate == format.sampleRate, actual.channelCount == format.channelCount else {
            throw VoiceProcessingFailure(reason: "после связи формат входа \(Self.describeFormat(actual)), "
                                         + "а связь сделана в \(Self.describeFormat(format))")
        }
        return actual
    }

    /// Все форматы графа для лога: вход (выход входного узла), выходной узел (вход и выход) и микшер.
    private static func describeGraph(_ engine: AVAudioEngine, input: AVAudioInputNode) -> String {
        let head = "inputNode: вход \(describeFormat(input.inputFormat(forBus: 0))), выход \(describeFormat(input.outputFormat(forBus: 0)))"
        // Без VPIO выходной узел и микшер не трогаем: обращение к ним создаёт узлы и связи, которых в обычной записи нет.
        guard input.isVoiceProcessingEnabled else { return head }
        let output = engine.outputNode
        let mixer = engine.mainMixerNode
        return head + "; "
            + "outputNode: вход \(describeFormat(output.inputFormat(forBus: 0))), выход \(describeFormat(output.outputFormat(forBus: 0))); "
            + "микшер: выход \(describeFormat(mixer.outputFormat(forBus: 0)))"
    }

    private static func describeFormat(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Гц, \(format.channelCount) кан."
    }

    /// Уведомление движка о смене конфигурации. Вызывается на главной очереди. Если движок продолжает работать
    /// на том же устройстве с тем же форматом (например, привязанный к выбранному микрофону движок получил
    /// уведомление о смене устройства по умолчанию), перезапускать нечего — иначе привязка и перезапуск зациклились бы.
    /// Движок здесь только читается: освобождать его внутри обработчика уведомления SDK не разрешает,
    /// перезапуск идёт позже, через `onConfigurationChange` → `restart`.
    private func engineConfigurationChanged(_ engine: AVAudioEngine?) {
        // Движок уже освобождён или заменён (уведомление догнало `stop` / `restart`): сообщать не о чем.
        guard let engine, engine === self.engine else { return }
        Log.info("Уведомление AVAudioEngineConfigurationChange", .audio)
        lock.lock()
        let active = activeInput
        let setting = microphone
        lock.unlock()
        if engine.isRunning, let active, let unit = engine.inputNode.audioUnit,
           engine.inputNode.isVoiceProcessingEnabled == active.voiceProcessing,
           Self.resolvedInput(of: unit, expected: active.voiceProcessing ? Self.expectedInput(for: setting) : nil)?.device == active.device,
           (Self.choice(for: setting).deviceID ?? Self.defaultInputDevice()) == active.device {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate == active.sampleRate, format.channelCount == active.channels {
                Log.info("Аудиодвижок работает на прежнем устройстве и формате — перезапуск не нужен", .audio)
                return
            }
        }
        onConfigurationChange?()
    }

    /// Останавливает движок и отпускает устройство: снимает tap, `stop`, выключает VPIO, `reset`, обнуляет поле.
    /// Безопасно вызывать повторно и без запущенного движка. Синхронно: перезапуск движка ждёт освобождения устройства.
    private func stopEngine() {
        releaseEngine()
        Log.debug("Аудиодвижок остановлен", .audio)
    }

    /// Отцепляет движок от рекордера: снимает наблюдателя и забывает движок. Только главный поток.
    /// Само освобождение — `release`, синхронно (`releaseEngine`) или в фоне (`releaseInBackground`).
    private func detachEngine() -> AVAudioEngine? {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        lock.lock()
        activeInput = nil
        lock.unlock()
        let detached = engine
        engine = nil
        return detached
    }

    private func releaseEngine() {
        if let engine = detachEngine() { Self.release(engine) }
    }

    /// Освобождает остановленную запись на `releaseQueue`; следующий `startEngine` дождётся её.
    private func releaseInBackground(_ engine: AVAudioEngine) {
        releaseQueue.async {
            Self.release(engine)
            Log.debug("Аудиодвижок остановлен (в фоне)", .audio)
        }
    }

    private static func release(_ engine: AVAudioEngine) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        // VPIO держит и вход, и выход; выключается только при остановленном движке и освобождает оба узла.
        if input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(false)
            } catch {
                Log.warning("Не удалось выключить голосовую обработку: \(error.localizedDescription)", .audio)
            }
        }
        engine.reset()
    }

    private func process(_ buffer: AVAudioPCMBuffer, mixFormat: AVAudioFormat?, mixMode: MixMode, levelGain: Float,
                         converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        measureRaw(buffer)
        let source: AVAudioPCMBuffer
        if let mixFormat {
            guard let mixed = Self.downmix(buffer, to: mixFormat, mode: mixMode) else { return }
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
        guard accepting else {
            lock.unlock()
            return
        }
        samples.append(contentsOf: chunk)
        if rms > peak { peak = rms }
        lock.unlock()

        onLevel?(rms * levelGain)
    }

    /// Сводит каналы буфера в один, с той же частотой: усредняет или берёт первый.
    private static func downmix(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, mode: MixMode) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData?[0] else { return nil }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = vDSP_Stride(interleaved ? channels : 1)
        vDSP_vclr(out, 1, frames)
        for channel in 0..<(mode == .average ? channels : 1) {
            let base = interleaved ? data[0] + channel : data[channel]
            vDSP_vadd(out, 1, base, stride, out, 1, frames)
        }
        var scale = mode == .average ? 1 / Float(channels) : 1
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
        guard let unit = input.audioUnit, let resolved = resolvedInput(of: unit, expected: nil) else {
            return head + "; устройство CoreAudio неизвестно"
        }
        let device = resolved.device
        let aggregate = resolved.aggregate.map { " (через агрегат \($0) «\(deviceName($0) ?? "?")»)" } ?? ""
        let name = (deviceName(device) ?? "?") + aggregate
        let channels = inputChannels(device).map(String.init) ?? "?"
        let transport = uint32Property(device, kAudioDevicePropertyTransportType).map(fourCC) ?? "?"
        let busy = uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 ? "да" : "нет" } ?? "?"
        let muted = uint32Property(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
            .map { $0 != 0 ? "да" : "нет" } ?? "нет свойства"
        return head + "; устройство CoreAudio \(device) «\(name)», транспорт \(transport), каналов входа \(channels), "
            + "уже используется: \(busy), mute входа: \(muted)"
    }

    static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr && device != 0 ? device : nil
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func inputChannels(_ device: AudioDeviceID) -> Int? {
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

    static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
