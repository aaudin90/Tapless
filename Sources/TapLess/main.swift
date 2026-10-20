import AppKit
import TapLessData
import TapLessDomain

// Точка входа и сборка зависимостей (composition root): единственное место,
// где Presentation встречается с реализациями из TapLessData.

// Запись в закрытый пайп (например, команда LLM упала раньше, чем прочитала stdin)
// не должна убивать приложение.
signal(SIGPIPE, SIG_IGN)

/// Заголовок лога: версия, сборка, система, пути.
func logStartupBanner(_ paths: AppPaths) {
    let info = Bundle.main.infoDictionary
    let version: String
    if let short = info?["CFBundleShortVersionString"] as? String {
        version = "\(short) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    } else {
        version = "dev"
    }
    #if DEBUG
    let build = "DEBUG"
    #else
    let build = "RELEASE"
    #endif
    #if arch(arm64)
    let arch = "arm64"
    #elseif arch(x86_64)
    let arch = "x86_64"
    #else
    let arch = "unknown"
    #endif
    let configExists = FileManager.default.fileExists(atPath: paths.configFile.path)
    Log.info("TapLess \(version), сборка \(build)", .app)
    Log.info("Система: \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch), pid \(ProcessInfo.processInfo.processIdentifier)", .app)
    Log.info("Bundle: \(Bundle.main.bundlePath)", .app)
    Log.info("Конфиг: \(paths.configFile.path) (\(configExists ? "есть" : "нет, будет создан шаблон"))", .config)
    Log.info("Лог: \(paths.logFile.path)", .app)
}

/// Итоговые настройки после слияния дефолтов и файла пользователя.
func logConfigSummary(_ config: AppConfig) {
    let g = config.general
    Log.info("Конфиг: hotkey=\(g.hotkey), show_last_hotkey=\(g.showLastHotkey.isEmpty ? "—" : g.showLastHotkey), mode=\(g.mode), sounds=\(g.sounds)", .config)
    let s = config.stt
    Log.info("Конфиг: stt model=\(s.model), model_path=\(s.modelPath.isEmpty ? "—" : s.modelPath), language=\(s.language)", .config)
    let l = config.llm
    Log.info("Конфиг: llm harness=\(l.harness), model=\(l.model), timeout=\(l.timeoutSeconds) с, shell=\(l.shell), login_shell=\(l.loginShell), workdir=\(l.workdir.isEmpty ? "по умолчанию" : l.workdir)", .config)
    for name in config.harnesses.keys.sorted() {
        guard let harness = config.harnesses[name] else { continue }
        Log.info("Конфиг: harness \(name) → \(harness.target)" + (harness.model.isEmpty ? "" : ", model=\(harness.model)"), .config)
        switch harness.kind {
        case .process:
            Log.debug("Конфиг: harness \(name): аргументов \(harness.args.count), text_args \(harness.textArgs.count), schema_args \(harness.schemaArgs.count)", .config)
        case .ollama:
            Log.debug("Конфиг: harness \(name): think=\(harness.think.isEmpty ? "—" : harness.think), keep_alive=\(harness.keepAlive.isEmpty ? "—" : harness.keepAlive), options=\(harness.options.count)", .config)
        }
    }
    if let rawKey = config.rawTextKey {
        Log.info("Конфиг: клавиша \(rawKey) — сырой текст «Как распознано»", .config)
    }
    for (index, variant) in config.activeVariants.enumerated() {
        Log.info("Конфиг: вариант \(config.firstVariantKey + index) «\(variant.name)» model=\(config.model(for: variant)), harness=\(config.harnessName(for: variant)), schema=\(variant.schema ?? "—")", .config)
    }
    Log.info("Конфиг: paste auto_paste=\(config.paste.autoPaste), restore_clipboard=\(config.paste.restoreClipboard)", .config)
    Log.info("Конфиг: log level=\(config.log.level), include_text=\(config.log.includeText)", .config)
}

MainActor.assumeIsolated {
    let paths = AppPaths.make()
    paths.createDirectories()
    AppLog.install(fileURL: paths.logFile, subsystem: Bundle.main.bundleIdentifier ?? "io.github.aaudin90.tapless")
    Log.minimumLevel = .debug
    logStartupBanner(paths)
    let removedLegacy = paths.removeLegacyLogFiles()
    if !removedLegacy.isEmpty {
        Log.info("Удалены старые файлы лога: \(removedLegacy.map(\.path).joined(separator: ", "))", .app)
    }

    // Конфиг читается один раз: чтобы применить изменения, приложение перезапускают.
    let configRepository = FileConfigRepository(fileURL: paths.configFile)
    var config: AppConfig
    var configError: String?
    var configWarnings: [String] = []
    do {
        let loaded = try configRepository.load()
        config = loaded.config
        configWarnings = loaded.warnings
    } catch {
        config = configRepository.defaults()
        configError = error.localizedDescription
        Log.error("Конфиг: \(error.localizedDescription)", .config)
    }
    configWarnings.forEach { Log.warning("Конфиг: \($0)", .config) }
    Log.minimumLevel = config.log.logLevel
    Log.includeText = config.log.includeText
    logConfigSummary(config)

    let historyRoot = AppPaths.historyRoot(custom: config.history.dir)
    let history = DictationHistoryUseCase(repository: FileHistoryRepository(root: historyRoot),
                                          config: config.history)
    Log.info("История: \(history.isEnabled ? "включена" : "выключена"), \(historyRoot.path), "
             + "срок \(config.history.retentionDays) дн., предел \(config.history.maxSizeMB) МБ, "
             + "аудио \(config.history.saveAudio ? "да" : "нет")", .config)

    let recognizer = WhisperSpeechRecognizer(settings: config.stt, modelsDirectory: paths.models)
    // Каждый вызов LLM в контексте диктовки (HistoryContext.session) попадает в историю.
    let llm = HistoryLLMRepository(
        base: RoutingLLMRepository(
            process: ProcessLLMRepository(settings: config.llm,
                                          runDirectory: paths.run,
                                          defaultWorkdir: paths.llmWorkdir),
            ollama: OllamaLLMRepository(settings: config.llm)
        ),
        history: history
    )

    let controller = AppController(AppDependencies(
        config: config,
        configError: configError,
        configWarnings: configWarnings,
        configRepository: configRepository,
        transcribe: TranscribeSpeechUseCase(recognizer: recognizer, config: config),
        format: FormatTextUseCase(llm: llm, config: config),
        prepareLocalLLM: PrepareLocalLLMUseCase(setup: OllamaSetup(), config: config),
        history: history,
        historyDirectory: historyRoot,
        modelsDirectory: paths.models,
        logFile: paths.logFile
    ))

    let app = NSApplication.shared
    app.delegate = controller
    app.setActivationPolicy(.accessory)   // без иконки в Dock, только меню-бар
    withExtendedLifetime(controller) {
        app.run()
    }
}
