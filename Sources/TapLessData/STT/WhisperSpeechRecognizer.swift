import Foundation
import TapLessDomain
import WhisperKit

enum WhisperError: LocalizedError {
    case notLoaded
    case modelFolderMissing(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Модель Whisper ещё не загружена"
        case .modelFolderMissing(let p): return "В папке нет модели WhisperKit: \(p)"
        }
    }
}

/// Отдаёт каждую следующую отметку в 10% один раз; колбэк прогресса приходит из разных потоков.
private final class ProgressMilestone: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func advance(to percent: Int) -> Int? {
        let step = percent / 10 * 10
        lock.lock()
        defer { lock.unlock() }
        guard step > last else { return nil }
        last = step
        return step
    }
}

/// STT на WhisperKit (CoreML, Neural Engine). Модель грузится один раз и живёт в памяти.
public actor WhisperSpeechRecognizer: SpeechRecognizer {
    /// Предел подсказки: остальные ~170 токенов окна остаются под текст.
    static let maxPromptTokens = 48

    private let settings: STTConfig
    private let modelsDirectory: URL
    private var whisper: WhisperKit?
    private var loadingTask: Task<Void, Error>?

    public init(settings: STTConfig, modelsDirectory: URL) {
        self.settings = settings
        self.modelsDirectory = modelsDirectory
    }

    public func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if whisper != nil {
            Log.debug("Модель уже загружена", .stt)
            return
        }
        // Загрузка уже идёт — ждём её, а не запускаем вторую.
        if let task = loadingTask {
            Log.debug("Загрузка модели уже идёт, жду её", .stt)
            try await task.value
            // Пока ждали, мог пройти unload() — не сообщаем об успехе без модели.
            guard whisper != nil else { throw WhisperError.notLoaded }
            return
        }
        let task = Task { try await self.performLoad(status: status) }
        loadingTask = task
        defer { loadingTask = nil }
        try await task.value
        guard whisper != nil else { throw WhisperError.notLoaded }
    }

    public func unload() async {
        if let task = loadingTask { _ = try? await task.value }
        // Сначала обнуляем: на await актор реентерабелен, параллельный prepare не должен видеть выгружаемую модель.
        Log.info("Выгружаю модель Whisper", .stt)
        let old = whisper
        whisper = nil
        await old?.unloadModels()
    }

    public func transcribe(_ samples: [Float], prompt: String) async throws -> String {
        guard let whisper else { throw WhisperError.notLoaded }

        var promptTokens: [Int]?
        if !prompt.isEmpty, let tokenizer = whisper.tokenizer {
            let special = tokenizer.specialTokens.specialTokenBegin
            let ids = tokenizer.encode(text: " " + prompt).filter { $0 < special }
            // На окно до 30 с у WhisperKit 224 токена, и подсказка отнимает их у текста:
            // подсказка на 111 токенов обрывала русскую речь уже на 15-й секунде.
            if ids.count > Self.maxPromptTokens {
                Log.warning("Подсказка Whisper длиннее \(Self.maxPromptTokens) токенов (\(ids.count)), начало отброшено. Сократите stt.initial_prompt", .stt)
            }
            if !ids.isEmpty { promptTokens = Array(ids.suffix(Self.maxPromptTokens)) }
        }

        let language = settings.languageCode
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )

        Log.debug("Параметры распознавания: язык \(language ?? "авто"), подсказка \(promptTokens?.count ?? 0) токенов (\(prompt.count) симв.), \(samples.count) отсчётов", .stt)
        let started = Date()
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        Log.info(String(format: "Распознано %.1f с аудио за %.2f с, %ld симв.",
                        Double(samples.count) / AudioClip.sampleRate,
                        Date().timeIntervalSince(started),
                        text.count), .stt)
        return text
    }

    // MARK: - Загрузка

    private func performLoad(status: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let loadStarted = Date()
        Log.info("Подготовка модели Whisper: model=\(settings.model), model_path=\(settings.modelPath.isEmpty ? "—" : settings.modelPath), язык=\(settings.language)", .stt)

        let folder: URL
        if !settings.modelPath.isEmpty {
            folder = URL(fileURLWithPath: ShellTools.expandTilde(settings.modelPath), isDirectory: true)
            guard Self.isModelFolder(folder) else {
                Log.error("В model_path нет модели WhisperKit: \(folder.path)", .stt)
                throw WhisperError.modelFolderMissing(folder.path)
            }
        } else if let local = Self.findLocalModel(named: settings.model, in: modelsDirectory) {
            folder = local
            Log.info("Локальная модель найдена: \(local.path)", .stt)
        } else {
            status("Скачиваю модель \(settings.model)…")
            Log.info("Локальной модели нет, скачиваю \(settings.model) из \(settings.modelRepo)", .stt)
            let milestone = ProgressMilestone()
            let downloadStarted = Date()
            folder = try await WhisperKit.download(
                variant: settings.model,
                downloadBase: modelsDirectory,
                from: settings.modelRepo,
                progressCallback: { progress in
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    status("Скачиваю модель: \(percent)%")
                    if let reached = milestone.advance(to: percent) {
                        Log.info("Скачивание модели: \(reached)%", .stt)
                    }
                }
            )
            Log.info(String(format: "Модель скачана за %.1f с: %@", Date().timeIntervalSince(downloadStarted), folder.path), .stt)
        }

        status("Загружаю модель в Neural Engine… (первый раз — до нескольких минут)")
        Log.info("Загружаю модель в CoreML из \(folder.path)", .stt)
        let started = Date()

        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: modelsDirectory,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        if settings.modelPath.isEmpty {
            // Метка «скачано полностью»: прерванная загрузка не будет принята за готовую модель.
            FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path,
                                           contents: Data())
        }
        whisper = kit
        Log.info(String(format: "Модель загружена за %.1f с (всего с подготовкой %.1f с)",
                        Date().timeIntervalSince(started), Date().timeIntervalSince(loadStarted)), .stt)
        status("")
    }

    // MARK: Поиск уже скачанной модели (чтобы запуск работал без сети)

    static let completeMarker = ".tapless-complete"

    static func isModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: url.appendingPathComponent("\(name).mlpackage").path)
        }
        return has("AudioEncoder") && has("TextDecoder") && has("MelSpectrogram")
    }

    static func findLocalModel(named name: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let last = url.lastPathComponent
            if last.hasSuffix(".mlmodelc") || last.hasSuffix(".mlpackage") || enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if last == name || last.hasSuffix(name), isModelFolder(url),
               fm.fileExists(atPath: url.appendingPathComponent(completeMarker).path) {
                candidates.append(url)
            }
        }

        // Точное совпадение → "openai_whisper-<name>" → любое с "openai" → первое.
        return candidates.first { $0.lastPathComponent == name }
            ?? candidates.first { $0.lastPathComponent == "openai_whisper-\(name)" }
            ?? candidates.first { $0.lastPathComponent.contains("openai") }
            ?? candidates.first
    }
}
