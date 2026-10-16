import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import TapLessDomain

/// Зависимости контроллера. Собираются в main.swift.
struct AppDependencies {
    /// Настройки на всё время работы: чтобы применить изменения, приложение перезапускают.
    let config: AppConfig
    /// Ошибка чтения пользовательского файла. Тогда `config` — значения по умолчанию.
    let configError: String?
    let configWarnings: [String]
    let configRepository: ConfigRepository
    let transcribe: TranscribeSpeechUseCase
    let format: FormatTextUseCase
    let prepareLocalLLM: PrepareLocalLLMUseCase
    let modelsDirectory: URL
    let logFile: URL
}

/// Presentation: состояние приложения, меню-бар, горячие клавиши и окно вариантов.
/// Распознавание и оформление текста отдаёт сценариям из TapLessDomain.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle, recording, transcribing, results, message
    }

    private let config: AppConfig
    private let configError: String?
    private let configWarnings: [String]
    private let configRepository: ConfigRepository
    private let transcribe: TranscribeSpeechUseCase
    private let format: FormatTextUseCase
    private let prepareLocalLLM: PrepareLocalLLMUseCase
    private let modelsDirectory: URL
    private let logFile: URL

    private let model = PopupModel()
    private lazy var popup = PopupController(model: model)
    private let recorder = AudioRecorder()

    private var statusItem: NSStatusItem?
    private var hotkeyError: String?
    /// Клавиша «Показать последний результат»: значок для меню и ошибка регистрации.
    private var showLastHotkeyDisplay = ""
    private var showLastHotkeyError: String?
    private var sessionKeyIDs: [UInt32] = []

    private var state: State = .idle
    private var session = UUID()
    private var targetApp: NSRunningApplication?
    private var jobs: [Task<Void, Never>] = []
    private var pendingCopyOnly = false
    private var hasResults = false

    private var autoStopTask: Task<Void, Never>?
    private var messageHideTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    /// Распознавание текущей записи. Живёт, пока Whisper занят, даже если сессию уже отменили.
    private var transcribeTask: Task<Void, Never>?
    private var transcribeSession: UUID?
    private var audioRestartPending = false
    private var recordingStartedAt: Date?

    private var modelReady = false
    private var modelStatus = "ещё не загружена"
    private var modelLoadError: String?

    /// Подготовка Ollama: проверка сервера, запуск, скачивание моделей.
    private var localLLMStatus: LocalLLMStatus = .notUsed
    private var localLLMTask: Task<Void, Never>?

    init(_ deps: AppDependencies) {
        config = deps.config
        configError = deps.configError
        configWarnings = deps.configWarnings
        configRepository = deps.configRepository
        transcribe = deps.transcribe
        format = deps.format
        prepareLocalLLM = deps.prepareLocalLLM
        modelsDirectory = deps.modelsDirectory
        logFile = deps.logFile
        super.init()
    }

    /// Короткая метка сессии для строк лога: по ней прослеживается одна диктовка.
    private func tag(_ sid: UUID) -> String {
        "[\(sid.uuidString.prefix(8))]"
    }

    // MARK: - Запуск

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Приложение запущено (applicationDidFinishLaunching)", .app)
        let createdConfig = saveConfigTemplateIfMissing()
        setupStatusItem()
        applyUIConfig()

        popup.onSelect = { [weak self] key in self?.select(key, copyOnly: false) }
        popup.onClose = { [weak self] in self?.closePopup(reason: "крестик") }
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            Task { @MainActor in
                if self.state == .recording { self.model.pushLevel(level) }
            }
        }
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.audioConfigurationChanged() }
        }

        registerMainHotKey()
        registerShowLastHotKey()
        observeAppSwitches()
        requestPermissionsIfNeeded()
        loadModel()
        startLocalLLMSetup(reason: "запуск приложения")

        if let configError {
            showAlert(title: "Ошибка в конфиге TapLess",
                      text: "\(configError)\n\nИспользуются настройки по умолчанию. Исправьте файл и перезапустите TapLess.")
        } else if !configWarnings.isEmpty {
            showAlert(title: "Замечания к конфигу TapLess",
                      text: configWarnings.joined(separator: "\n") + "\n\nПосле правки перезапустите TapLess.")
        } else if createdConfig {
            showMessage("Создан файл настроек \(configPathDisplay). Модель Whisper скачивается — прогресс в меню TapLess.",
                        seconds: 8)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelJobs()
        localLLMTask?.cancel()
        _ = recorder.stop()
        Log.info("TapLess завершён", .app)
    }

    // MARK: - Конфиг

    private var configPathDisplay: String {
        (configRepository.fileURL.path as NSString).abbreviatingWithTildeInPath
    }

    @discardableResult
    private func saveConfigTemplateIfMissing() -> Bool {
        do {
            return try configRepository.saveTemplateIfMissing()
        } catch {
            Log.error("Не удалось создать файл настроек \(configRepository.fileURL.path): \(error.localizedDescription)", .config)
            return false
        }
    }

    private func applyUIConfig() {
        model.rawKey = config.rawTextKey
        model.maxLines = max(1, config.ui.maxLines)
        model.width = CGFloat(max(420, min(1200, config.ui.width)))
        popup.position = config.ui.position
    }

    // MARK: - Горячие клавиши

    private func registerMainHotKey() {
        do {
            let spec = try HotKeyParser.parse(config.general.hotkey)
            model.hotkeyDisplay = spec.display
            let id = HotKeyCenter.shared.register(
                spec,
                onPress: { [weak self] in self?.hotKeyDown() },
                onRelease: { [weak self] in self?.hotKeyUp() }
            )
            hotkeyError = id == nil ? "Сочетание \(spec.display) занято другой программой" : nil
            if id != nil {
                Log.info("Главная клавиша \(spec.display) зарегистрирована (\(config.general.hotkey), режим \(config.general.mode))", .hotkey)
            }
        } catch {
            hotkeyError = "Горячая клавиша: \(error.localizedDescription)"
        }
        if let hotkeyError { Log.error(hotkeyError, .hotkey) }
    }

    private func registerShowLastHotKey() {
        let raw = config.general.showLastHotkey
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            Log.info("Клавиша «Показать последний результат» выключена (show_last_hotkey пуст)", .hotkey)
            return
        }
        do {
            let spec = try HotKeyParser.parse(raw)
            let id = HotKeyCenter.shared.register(spec, onPress: { [weak self] in self?.showLastHotKeyDown() })
            if id == nil {
                showLastHotkeyError = "Сочетание \(spec.display) для «Показать последний результат» занято"
            } else {
                showLastHotkeyDisplay = spec.display
                Log.info("Клавиша «Показать последний результат» \(spec.display) зарегистрирована (\(raw))", .hotkey)
            }
        } catch {
            showLastHotkeyError = "Клавиша «Показать последний результат»: \(error.localizedDescription)"
        }
        if let showLastHotkeyError { Log.error(showLastHotkeyError, .hotkey) }
    }

    /// Показывает последний результат; если окно с результатами уже открыто — закрывает его.
    private func showLastHotKeyDown() {
        switch state {
        case .results:
            closePopup(reason: "клавиша \(showLastHotkeyDisplay)")
        case .recording, .transcribing:
            Log.debug("Клавиша показа результата нажата во время записи или распознавания — игнорирую", .hotkey)
        case .idle, .message:
            if hasResults {
                showLastResult()
            } else {
                showMessage("Последнего результата пока нет.", seconds: 2)
            }
        }
    }

    /// Пользователь ушёл в другое приложение, не выбрав вариант, — закрываем окно,
    /// иначе цифры так и остались бы перехвачены глобально.
    private func observeAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.state == .results || self.state == .message else { return }
                if pid == ProcessInfo.processInfo.processIdentifier { return }
                if let target = self.targetApp?.processIdentifier, pid == target { return }
                self.closePopup(reason: "переключение на \(app?.bundleIdentifier ?? "другое приложение")")
            }
        }
    }

    private func hotKeyDown() {
        switch state {
        case .idle, .results, .message:
            startRecording(trigger: "горячая клавиша")
        case .recording:
            stopRecording(trigger: "горячая клавиша")
        case .transcribing:
            Log.debug("Клавиша записи нажата во время распознавания — игнорирую", .hotkey)
        }
    }

    private func hotKeyUp() {
        if config.general.isHoldMode, state == .recording {
            stopRecording(trigger: "отпускание клавиши (hold)")
        }
    }

    /// Esc + цифры (и ⇧+цифры), пока окно открыто.
    private func registerSessionKeys(withSelection: Bool) {
        unregisterSessionKeys()
        let center = HotKeyCenter.shared

        if let id = center.register(keyCode: UInt32(kVK_Escape), modifiers: 0,
                                    onPress: { [weak self] in self?.closePopup(reason: "Esc") }) {
            sessionKeyIDs.append(id)
        }
        guard withSelection else { return }

        let keys = (model.rawKey.map { [$0] } ?? []) + format.variantKeys
        let shift = UInt32(shiftKey)
        for key in keys {
            for code in [HotKeyParser.digitKeyCodes[key], HotKeyParser.keypadKeyCodes[key]] {
                if let id = center.register(keyCode: UInt32(code), modifiers: 0,
                                            onPress: { [weak self] in self?.select(key, copyOnly: false) }) {
                    sessionKeyIDs.append(id)
                }
                if let id = center.register(keyCode: UInt32(code), modifiers: shift,
                                            onPress: { [weak self] in self?.select(key, copyOnly: true) }) {
                    sessionKeyIDs.append(id)
                }
            }
        }
    }

    private func unregisterSessionKeys() {
        if !sessionKeyIDs.isEmpty { Log.debug("Снимаю сессионные клавиши: \(sessionKeyIDs.count)", .hotkey) }
        HotKeyCenter.shared.unregister(sessionKeyIDs)
        sessionKeyIDs.removeAll()
    }

    // MARK: - Запись

    private func startRecording(trigger: String) {
        messageHideTask?.cancel()
        let front = NSWorkspace.shared.frontmostApplication
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("Старт записи: источник=\(trigger), фокус=\(front?.localizedName ?? "—") (\(front?.bundleIdentifier ?? "—")), микрофон=\(authStatusName(micStatus))", .audio)

        // Прежнюю сессию не трогаем, пока запись не началась: если старт не удастся,
        // её варианты доработают и останутся в «Показать последний результат».
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            Log.warning("Микрофон: разрешение ещё не выдано, запрашиваю", .audio)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            showMessage("Разрешите TapLess доступ к микрофону и нажмите \(model.hotkeyDisplay) ещё раз.", seconds: 6)
            return
        default:
            Log.error("Микрофон: нет доступа (\(authStatusName(micStatus)))", .audio)
            showMessage("Нет доступа к микрофону: Системные настройки → Конфиденциальность и безопасность → Микрофон → TapLess.",
                        seconds: 8)
            return
        }

        do {
            try recorder.start()
        } catch {
            Log.error("Не удалось начать запись: \(error)", .audio)
            showMessage("Не удалось начать запись: \(error.localizedDescription)", seconds: 6)
            return
        }

        cancelJobs()
        transcribeTask?.cancel()
        unregisterSessionKeys()
        session = UUID()
        recordingStartedAt = Date()
        model.pendingKey = nil
        targetApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
        model.targetName = targetApp?.localizedName ?? ""
        model.targetIcon = targetApp?.icon
        Log.info("\(tag(session)) Запись идёт, цель вставки: \(targetApp?.localizedName ?? "—") (\(targetApp?.bundleIdentifier ?? "—")), лимит \(max(5, config.general.maxRecordingSeconds)) с", .audio)

        state = .recording
        hasResults = false
        model.resetForRecording()
        if !modelReady { model.note = "Whisper: \(modelStatusText)" }
        registerSessionKeys(withSelection: false)
        popup.show()
        playSound("Tink")
        updateStatusIcon()

        let limit = max(5, config.general.maxRecordingSeconds)
        let sid = session
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.session == sid, self.state == .recording else { return }
            self.stopRecording(trigger: "автостоп по лимиту")
        }
    }

    private func stopRecording(trigger: String) {
        guard state == .recording else { return }
        let recorded = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Log.info(String(format: "%@ Стоп записи: источник=%@, записано %.2f с, хвост %ld мс", tag(session), trigger, recorded, max(0, config.general.tailMs)), .audio)
        autoStopTask?.cancel()
        state = .transcribing
        model.phase = .transcribing
        // Строки вариантов показываем сразу — можно заранее нажать цифру.
        model.variants = initialVariantStates()
        registerSessionKeys(withSelection: true)
        playSound("Pop")
        updateStatusIcon()

        let sid = session
        let tail = max(0, config.general.tailMs)
        transcribeSession = sid
        transcribeTask = Task { [weak self] in
            // Дописываем хвост, чтобы не обрезать последнее слово.
            try? await Task.sleep(nanoseconds: UInt64(tail) * 1_000_000)
            guard let self else { return }
            if self.session == sid {
                await self.finishRecording(sid)
            }
            if self.transcribeSession == sid {
                self.transcribeTask = nil
                self.transcribeSession = nil
            }
        }
    }

    /// Сменилось устройство ввода: движок остановился сам. Перезапускаем его на новом
    /// устройстве, уже записанное сохраняется. Не вышло — распознаём то, что успели записать.
    private func audioConfigurationChanged() {
        guard state == .recording, !audioRestartPending else { return }
        audioRestartPending = true
        let sid = session
        Log.info("\(tag(sid)) Изменилась конфигурация аудио, перезапуск через 300 мс", .audio)
        Task { [weak self] in
            // Уведомления приходят пачкой (например, AirPods переключают профиль) — ждём, пока утихнут.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.audioRestartPending = false
            guard self.session == sid, self.state == .recording else { return }
            do {
                try self.recorder.restart()
                Log.info("\(self.tag(sid)) Устройство ввода сменилось — запись продолжена", .audio)
            } catch {
                Log.error("\(self.tag(sid)) Устройство ввода сменилось, запись не продолжить: \(error.localizedDescription)", .audio)
                self.stopRecording(trigger: "ошибка устройства")
            }
        }
    }

    private func finishRecording(_ sid: UUID) async {
        let clip = recorder.stop()
        let t = tag(sid)
        Log.info(String(format: "%@ Запись завершена: %.2f с, %ld отсчётов, пик RMS %.4f", t, clip.duration, clip.samples.count, clip.peakLevel), .audio)

        switch transcribe.rejection(for: clip) {
        case .tooShort(let seconds):
            Log.info(String(format: "%@ Отклонено: слишком короткая запись (%.2f с)", t, seconds), .audio)
            closePopup(reason: "слишком короткая запись")
            return
        case .silence:
            Log.info(String(format: "%@ Отклонено: тишина (пик %.4f, порог %.4f)", t, clip.peakLevel, config.stt.silenceThreshold), .audio)
            showMessage("Тишина — ничего не записано. Проверьте микрофон или порог stt.silence_threshold.", seconds: 4)
            return
        case nil:
            break
        }

        do {
            if !modelReady { model.note = "Whisper: \(modelStatusText)" }
            try await ensureModelLoaded()
            guard session == sid else { return }
            model.note = nil

            Log.info("\(t) Распознавание началось", .stt)
            let sttStarted = Date()
            let text = try await transcribe.execute(clip)
            guard session == sid else {
                Log.info("\(t) Распознавание завершено, но сессия сменилась — результат отброшен", .stt)
                return
            }
            Log.info(String(format: "%@ Распознавание завершено за %.2f с: %@", t, Date().timeIntervalSince(sttStarted), Log.text(text)), .stt)
            guard !text.isEmpty else {
                Log.info("\(t) Ничего не распознано", .stt)
                showMessage("Ничего не распознано.", seconds: 3)
                return
            }
            startVariants(for: text, session: sid)
        } catch {
            guard session == sid, !(error is CancellationError) else {
                Log.info("\(t) Распознавание отменено", .stt)
                return
            }
            Log.error("\(t) Распознавание: \(error)", .stt)
            showMessage("Ошибка распознавания: \(error.localizedDescription)", seconds: 8)
        }
    }

    // MARK: - LLM-варианты

    private func initialVariantStates() -> [VariantState] {
        zip(format.variantKeys, format.variants).map {
            VariantState(id: $0.0, name: $0.1.name, status: .running, seconds: nil)
        }
    }

    private func startVariants(for text: String, session sid: UUID) {
        Log.info("\(tag(sid)) Запуск вариантов: \(format.variants.count)", .llm)
        for (key, variant) in zip(format.variantKeys, format.variants) {
            let harness = format.harnessName(forVariantKey: key) ?? "—"
            Log.info("\(tag(sid)) Вариант \(key) «\(variant.name)»: harness=\(harness)", .llm)
        }
        state = .results
        hasResults = true
        model.rawText = text
        model.phase = .results
        model.variants = initialVariantStates()
        if localLLMStatus != .notUsed && localLLMStatus != .ready {
            model.note = "Ollama: \(localLLMStatus.text)"
        }
        updateStatusIcon()

        for key in format.variantKeys {
            runVariant(key: key, text: text, session: sid)
        }

        // Если клавишу сырого текста нажали ещё во время распознавания — вставляем сразу.
        if let rawKey = model.rawKey, model.pendingKey == rawKey {
            Log.info("\(tag(sid)) Отложенный выбор \(rawKey) (сырой текст) исполняется", .ui)
            select(rawKey, copyOnly: pendingCopyOnly)
        }
    }

    private func runVariant(key: Int, text: String, session sid: UUID) {
        let format = self.format
        let started = Date()
        Log.debug("\(tag(sid)) Вариант \(key): запуск", .llm)
        let job = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await format.execute(text: text, variantKey: key))
            } catch {
                result = .failure(error)
            }
            guard let self, self.session == sid else { return }
            self.finishVariant(key: key, result: result, seconds: Date().timeIntervalSince(started), session: sid)
        }
        jobs.append(job)
    }

    private func finishVariant(key: Int, result: Result<String, Error>, seconds: Double, session sid: UUID) {
        switch result {
        case .success(let text):
            Log.info(String(format: "%@ Вариант %ld готов за %.2f с: %@", tag(sid), key, seconds, Log.text(text)), .llm)
            setVariant(key, status: .done(text), seconds: seconds)
        case .failure(let error):
            if error is CancellationError { return }
            Log.error(String(format: "%@ Вариант %ld не удался за %.2f с: %@", tag(sid), key, seconds, error.localizedDescription), .llm)
            setVariant(key, status: .failed(error.localizedDescription), seconds: seconds)
            // Ollama могли закрыть или удалить модель — проверяем и чиним в фоне.
            if format.harnessKind(forVariantKey: key) == .ollama {
                startLocalLLMSetup(reason: "вариант \(key) не удался")
            }
        }

        // Цифру нажали заранее — вставляем, как только вариант готов.
        guard model.pendingKey == key,
              let variant = model.variants.first(where: { $0.id == key }) else { return }
        switch variant.status {
        case .done:
            Log.info("\(tag(sid)) Отложенный выбор \(key) исполняется", .ui)
            select(key, copyOnly: pendingCopyOnly)
        case .failed:
            Log.info("\(tag(sid)) Отложенный выбор \(key) сброшен: вариант не удался", .ui)
            model.pendingKey = nil
            NSSound.beep()
        case .running:
            break
        }
    }

    private func setVariant(_ key: Int, status: VariantState.Status, seconds: Double?) {
        guard let index = model.variants.firstIndex(where: { $0.id == key }) else { return }
        model.variants[index].status = status
        model.variants[index].seconds = seconds
    }

    private func cancelJobs() {
        jobs.forEach { $0.cancel() }
        jobs.removeAll()
    }

    // MARK: - Выбор и вставка

    private func select(_ key: Int, copyOnly: Bool) {
        guard state == .results || state == .transcribing else { return }
        Log.info("\(tag(session)) Выбор: ключ=\(key), copyOnly=\(copyOnly)", .ui)

        var text: String?
        if key == model.rawKey {
            text = model.rawText.isEmpty ? nil : model.rawText
        } else {
            guard let variant = model.variants.first(where: { $0.id == key }) else {
                Log.warning("\(tag(session)) Выбор \(key): такого варианта нет", .ui)
                NSSound.beep()
                return
            }
            switch variant.status {
            case .done(let t): text = t
            case .running: text = nil
            case .failed:
                Log.info("\(tag(session)) Выбор \(key): вариант не удался — игнорирую", .ui)
                NSSound.beep()
                return
            }
        }

        guard let text else {
            // Ещё не готово — запоминаем выбор и вставим по готовности.
            Log.info("\(tag(session)) Вариант \(key) ещё не готов — выбор отложен (pendingKey)", .ui)
            model.pendingKey = key
            pendingCopyOnly = copyOnly
            return
        }
        deliver(text, copyOnly: copyOnly)
    }

    private func deliver(_ text: String, copyOnly: Bool) {
        let t = tag(session)
        Log.info("\(t) Доставка: \(Log.text(text)), copyOnly=\(copyOnly)", .paste)
        model.pendingKey = nil
        unregisterSessionKeys()
        popup.hide()
        state = .idle
        updateStatusIcon()

        let target = targetApp
        let pasteConfig = config.paste
        Task { [weak self] in
            let outcome = await Paster.deliver(text, to: target, config: pasteConfig, copyOnly: copyOnly)
            guard let self else { return }
            Log.info("\(t) Итог доставки: \(outcome), цель \(target?.bundleIdentifier ?? "—")", .paste)
            switch outcome {
            case .pasted:
                break
            case .copied:
                self.showMessage("Скопировано в буфер обмена.", seconds: 1.5)
            case .copiedNeedsAccessibility:
                self.showMessage("Скопировано. Для автовставки разрешите TapLess «Универсальный доступ» и вставьте ⌘V.",
                                 seconds: 6)
                Paster.requestAccessibility()
            }
        }
    }

    // MARK: - Окно

    private func showMessage(_ text: String, seconds: Double = 3) {
        Log.info("\(tag(session)) Сообщение (\(seconds) с): \(text)", .ui)
        if state == .recording {
            Log.info("\(tag(session)) Запись остановлена из-за сообщения", .audio)
            autoStopTask?.cancel()
            _ = recorder.stop()
        }
        unregisterSessionKeys()
        state = .message
        model.pendingKey = nil
        model.phase = .message(text)
        registerSessionKeys(withSelection: false)
        popup.show()
        updateStatusIcon()

        messageHideTask?.cancel()
        messageHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.state == .message else { return }
            self.closePopup(reason: "таймаут сообщения")
        }
    }

    /// Esc / крестик. Во время записи и распознавания — отмена; результаты остаются в «Показать последний».
    private func closePopup(reason: String = "крестик") {
        Log.info("\(tag(session)) Закрытие панели: причина=\(reason), состояние=\(state)", .ui)
        switch state {
        case .recording:
            autoStopTask?.cancel()
            _ = recorder.stop()
            session = UUID()
            playSound("Funk")
        case .transcribing:
            _ = recorder.stop()   // хвост tail_ms ещё мог писать
            session = UUID()
            transcribeTask?.cancel()
            cancelJobs()
        case .idle, .results, .message:
            break
        }
        messageHideTask?.cancel()
        model.pendingKey = nil
        unregisterSessionKeys()
        popup.hide()
        state = .idle
        updateStatusIcon()
    }

    private func showLastResult() {
        guard hasResults, state != .recording, state != .transcribing else { return }
        Log.info("\(tag(session)) Показ последнего результата", .ui)
        messageHideTask?.cancel()
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp = front
        }
        model.targetName = targetApp?.localizedName ?? ""
        model.targetIcon = targetApp?.icon
        state = .results
        model.pendingKey = nil
        model.phase = .results
        registerSessionKeys(withSelection: true)
        popup.show()
        updateStatusIcon()
    }

    // MARK: - Модель Whisper

    private var modelStatusText: String {
        if modelReady { return "готова (\(config.stt.modelDisplayName))" }
        if let modelLoadError { return "ошибка — \(modelLoadError)" }
        return modelStatus
    }

    private func loadModel(forceReload: Bool = false) {
        Log.info("Загрузка модели Whisper (forceReload=\(forceReload))", .stt)
        modelReady = false
        modelLoadError = nil
        modelStatus = "загрузка…"
        updateStatusIcon()
        modelLoadTask?.cancel()
        modelLoadTask = Task { [weak self] in
            try? await self?.ensureModelLoaded(forceReload: forceReload)
        }
    }

    private func ensureModelLoaded(forceReload: Bool = false) async throws {
        let status: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.setModelStatus(text) }
        }
        let started = Date()
        do {
            if forceReload {
                try await transcribe.reloadModel(status: status)
            } else {
                try await transcribe.prepareModel(status: status)
            }
            modelReady = true
            modelLoadError = nil
            modelStatus = "готова"
            Log.info(String(format: "Модель Whisper готова (ожидание %.1f с)", Date().timeIntervalSince(started)), .stt)
            updateStatusIcon()
        } catch {
            modelReady = false
            modelLoadError = error.localizedDescription
            Log.error(String(format: "Модель Whisper не загрузилась за %.1f с: %@", Date().timeIntervalSince(started), error.localizedDescription), .stt)
            updateStatusIcon()
            throw error
        }
    }

    private func setModelStatus(_ text: String) {
        guard !text.isEmpty, !modelReady else { return }
        if text != modelStatus { Log.debug("Статус модели: \(text)", .stt) }
        modelStatus = text
        if state == .recording || state == .transcribing {
            model.note = "Whisper: \(text)"
        }
        updateStatusIcon()
    }

    // MARK: - Ollama

    /// Проверяет Ollama, запускает её и докачивает модели. Повторный вызов во время проверки ничего не делает.
    private func startLocalLLMSetup(reason: String) {
        guard prepareLocalLLM.isUsed else { return }
        guard localLLMTask == nil else { return }
        Log.info("Подготовка Ollama (\(reason))", .llm)
        localLLMStatus = .checking
        let prepare = prepareLocalLLM
        localLLMTask = Task { [weak self] in
            let status: @Sendable (LocalLLMStatus) -> Void = { status in
                Task { @MainActor in self?.setLocalLLMStatus(status) }
            }
            let result = await prepare.execute(status: status)
            guard let self else { return }
            self.localLLMTask = nil
            self.localLLMStatus = result
            Log.info("Ollama: \(result.text)", .llm)
            self.updateLocalLLMNote()
        }
    }

    private func setLocalLLMStatus(_ status: LocalLLMStatus) {
        // Промежуточные статусы могут прийти после итогового — их пропускаем.
        guard localLLMTask != nil else { return }
        localLLMStatus = status
        updateLocalLLMNote()
    }

    /// Строка о состоянии Ollama внизу панели, пока она открыта с вариантами.
    private func updateLocalLLMNote() {
        guard state == .results else { return }
        if localLLMStatus == .ready {
            if model.note?.hasPrefix("Ollama:") == true { model.note = nil }
        } else {
            model.note = "Ollama: \(localLLMStatus.text)"
        }
    }

    private var localLLMStatusText: String {
        guard localLLMStatus == .ready else { return localLLMStatus.text }
        let models = Array(Set(prepareLocalLLM.targets.map(\.model))).sorted()
        return "готова (\(models.joined(separator: ", ")))"
    }

    // MARK: - Разрешения

    private func authStatusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "разрешён"
        case .notDetermined: return "не запрашивался"
        case .denied: return "запрещён"
        case .restricted: return "ограничен"
        @unknown default: return "неизвестно"
        }
    }

    private func requestPermissionsIfNeeded() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("Разрешения: микрофон=\(authStatusName(mic)), универсальный доступ=\(Paster.isTrusted ? "есть" : "нет")", .app)
        if mic == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("Микрофон: \(granted ? "разрешён" : "запрещён")", .app)
            }
        }
        if config.paste.autoPaste && !Paster.isTrusted {
            Log.warning("Автовставка включена, но нет «Универсального доступа» — запрашиваю", .app)
            Paster.requestAccessibility()
        }
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var tint: NSColor?
        switch state {
        case .recording:
            symbol = "mic.fill"
            tint = .systemRed
        case .transcribing:
            symbol = "ellipsis.circle"
        default:
            if modelReady {
                symbol = "waveform"
            } else if modelLoadError != nil {
                symbol = "exclamationmark.triangle"
            } else {
                symbol = "arrow.down.circle"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TapLess")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = "TapLess — Whisper: \(modelStatusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            menu.addItem(item)
        }

        info("TapLess · \(model.hotkeyDisplay.isEmpty ? "клавиша не задана" : model.hotkeyDisplay)")
        info("Whisper: \(modelStatusText)")
        if prepareLocalLLM.isUsed {
            info("Ollama: \(localLLMStatusText)")
            switch localLLMStatus {
            case .notInstalled:
                action("⚠︎ Установить Ollama…", #selector(installOllamaAction))
                action("Проверить Ollama снова", #selector(recheckOllamaAction))
            case .notRunning, .failed:
                action("Проверить Ollama снова", #selector(recheckOllamaAction))
            default:
                break
            }
        }
        if configError != nil { info("⚠︎ Ошибка в конфиге — исправьте файл и перезапустите") }
        if !configWarnings.isEmpty { info("⚠︎ В конфиге есть замечания — см. лог") }
        if let hotkeyError { info("⚠︎ \(hotkeyError)") }
        if let showLastHotkeyError { info("⚠︎ \(showLastHotkeyError)") }
        if config.paste.autoPaste && !Paster.isTrusted {
            action("⚠︎ Разрешить автовставку (Универсальный доступ)…", #selector(grantAccessibilityAction))
        }
        menu.addItem(.separator())

        action(state == .recording ? "Остановить запись" : "Начать запись", #selector(toggleRecordingAction),
               enabled: state != .transcribing)
        action(showLastHotkeyDisplay.isEmpty ? "Показать последний результат" : "Показать последний результат (\(showLastHotkeyDisplay))",
               #selector(showLastResultAction),
               enabled: hasResults && state != .recording && state != .transcribing)
        menu.addItem(.separator())

        action("Открыть конфиг…", #selector(openConfigAction))
        action("Перезапустить (применить конфиг)", #selector(restartAction))
        action("Перезагрузить модель", #selector(reloadModelAction), enabled: canReloadModel)
        action("Папка с моделями", #selector(openModelsFolderAction))
        action("Открыть лог", #selector(openLogAction))
        menu.addItem(.separator())

        action("Запускать при входе", #selector(toggleLoginItemAction),
               checked: SMAppService.mainApp.status == .enabled)
        action("Выйти", #selector(quitAction))
    }

    @objc private func toggleRecordingAction() {
        Log.info("Меню: \(state == .recording ? "Остановить запись" : "Начать запись")", .app)
        if state == .recording { stopRecording(trigger: "меню") } else { startRecording(trigger: "меню") }
    }

    @objc private func showLastResultAction() {
        Log.info("Меню: Показать последний результат", .app)
        showLastResult()
    }

    @objc private func openConfigAction() {
        Log.info("Меню: Открыть конфиг", .app)
        saveConfigTemplateIfMissing()
        let url = configRepository.fileURL
        if !NSWorkspace.shared.open(url) {
            // У .toml может не быть приложения по умолчанию — открываем текстовым редактором.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-t", url.path]
            try? process.run()
        }
    }

    /// Конфиг читается только при запуске, поэтому изменения применяются перезапуском.
    @objc private func restartAction() {
        Log.info("Меню: Перезапустить", .app)
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            Log.warning("Перезапуск недоступен: запуск не из .app (\(bundleURL.path))", .app)
            showAlert(title: "Перезапуск недоступен",
                      text: "TapLess запущен не из .app. Перезапустите процесс вручную.",
                      offerConfig: false)
            return
        }
        // Ждём, пока текущий процесс завершится, иначе open просто активирует его.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
            bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
        } catch {
            Log.error("Не удалось перезапустить: \(error.localizedDescription)", .app)
            showAlert(title: "Не удалось перезапустить TapLess", text: error.localizedDescription, offerConfig: false)
            return
        }
        Log.info("Перезапуск: завершаю процесс, новый запустит /bin/sh", .app)
        NSApp.terminate(nil)
    }

    /// Модель нельзя выгружать, пока она загружается или Whisper ещё распознаёт
    /// (в том числе отменённую по Esc запись).
    private var canReloadModel: Bool {
        state != .transcribing && transcribeTask == nil && (modelReady || modelLoadError != nil)
    }

    @objc private func reloadModelAction() {
        Log.info("Меню: Перезагрузить модель (доступно: \(canReloadModel))", .app)
        guard canReloadModel else { return }
        loadModel(forceReload: true)
    }

    @objc private func openModelsFolderAction() {
        Log.info("Меню: Папка с моделями", .app)
        NSWorkspace.shared.open(modelsDirectory)
    }

    @objc private func openLogAction() {
        Log.info("Меню: Открыть лог (\(logFile.path))", .app)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        NSWorkspace.shared.open(logFile)
    }

    @objc private func installOllamaAction() {
        Log.info("Меню: Установить Ollama", .app)
        if let url = URL(string: "https://ollama.com/download/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckOllamaAction() {
        Log.info("Меню: Проверить Ollama снова", .app)
        startLocalLLMSetup(reason: "меню")
    }

    @objc private func grantAccessibilityAction() {
        Log.info("Меню: Разрешить автовставку", .app)
        Paster.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItemAction() {
        let enabled = SMAppService.mainApp.status == .enabled
        Log.info("Меню: Запускать при входе — \(enabled ? "выключаю" : "включаю")", .app)
        do {
            if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            Log.info("Автозапуск при входе: статус \(SMAppService.mainApp.status.rawValue)", .app)
        } catch {
            Log.error("Не удалось изменить автозапуск: \(error.localizedDescription)", .app)
            showAlert(title: "Не удалось изменить автозапуск", text: error.localizedDescription, offerConfig: false)
        }
    }

    @objc private func quitAction() {
        Log.info("Меню: Выйти", .app)
        NSApp.terminate(nil)
    }

    // MARK: - Мелочи

    private func playSound(_ name: String) {
        guard config.general.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func showAlert(title: String, text: String, offerConfig: Bool = true) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        if offerConfig {
            alert.addButton(withTitle: "Открыть конфиг")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { openConfigAction() }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
