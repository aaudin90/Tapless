import Foundation

// MARK: - Настройки приложения
//
// Читаются один раз при запуске (см. ConfigRepository): чтобы применить изменения,
// приложение перезапускают. Значения по умолчанию живут в config.default.toml,
// а не здесь, — эти структуры только описывают форму данных.

public struct GeneralConfig: Sendable, Equatable {
    public var hotkey: String
    /// Клавиша «Показать последний результат». Пустая строка — клавиша выключена.
    public var showLastHotkey: String
    public var mode: String
    public var sounds: Bool
    public var minRecordingMs: Int
    public var tailMs: Int
    public var maxRecordingSeconds: Int

    public init(hotkey: String, showLastHotkey: String, mode: String, sounds: Bool,
                minRecordingMs: Int, tailMs: Int, maxRecordingSeconds: Int) {
        self.hotkey = hotkey
        self.showLastHotkey = showLastHotkey
        self.mode = mode
        self.sounds = sounds
        self.minRecordingMs = minRecordingMs
        self.tailMs = tailMs
        self.maxRecordingSeconds = maxRecordingSeconds
    }

    public var isHoldMode: Bool { mode.lowercased() == "hold" }
}

public struct PasteConfig: Sendable, Equatable {
    public var autoPaste: Bool
    public var restoreClipboard: Bool
    public var pasteDelayMs: Int
    public var restoreDelayMs: Int
    /// Автовставка: клавиша строки панели, которая вставляется сама, когда готова.
    /// Остальные варианты не запускаются. 0 — выключено, выбор цифрой.
    public var autoSelect: Int

    public init(autoPaste: Bool, restoreClipboard: Bool, pasteDelayMs: Int, restoreDelayMs: Int,
                autoSelect: Int = 0) {
        self.autoPaste = autoPaste
        self.restoreClipboard = restoreClipboard
        self.pasteDelayMs = pasteDelayMs
        self.restoreDelayMs = restoreDelayMs
        self.autoSelect = autoSelect
    }
}

public struct UIConfig: Sendable, Equatable {
    public var position: String
    public var width: Int
    public var maxLines: Int
    public var showRaw: Bool

    public init(position: String, width: Int, maxLines: Int, showRaw: Bool) {
        self.position = position
        self.width = width
        self.maxLines = maxLines
        self.showRaw = showRaw
    }
}

public struct STTConfig: Sendable, Equatable {
    public var model: String
    public var modelPath: String
    public var modelRepo: String
    public var language: String
    /// Статичная подсказка для Whisper. Словарь в Whisper не идёт.
    public var initialPrompt: String
    public var silenceThreshold: Double
    public var dropPhrases: [String]

    public init(model: String, modelPath: String, modelRepo: String, language: String,
                initialPrompt: String,
                silenceThreshold: Double, dropPhrases: [String]) {
        self.model = model
        self.modelPath = modelPath
        self.modelRepo = modelRepo
        self.language = language
        self.initialPrompt = initialPrompt
        self.silenceThreshold = silenceThreshold
        self.dropPhrases = dropPhrases
    }

    /// Короткое имя модели для меню.
    public var modelDisplayName: String {
        modelPath.isEmpty ? model : (modelPath as NSString).lastPathComponent
    }

    /// nil — автоопределение языка.
    public var languageCode: String? {
        let l = language.trimmingCharacters(in: .whitespaces).lowercased()
        return (l.isEmpty || l == "auto") ? nil : l
    }
}

public struct LLMConfig: Sendable, Equatable {
    /// Имя harness по умолчанию — ключ в `[harness.<имя>]`.
    public var harness: String
    public var model: String
    public var timeoutSeconds: Double
    public var shell: String
    public var loginShell: Bool
    public var extraPath: [String]
    public var workdir: String
    public var inputTemplate: String
    public var stripCodeFences: Bool
    public var basePrompt: String
    /// Дописывается в конец системного промпта при правке строки панели (после промпта варианта).
    public var revisePrompt: String
    /// Входной текст при правке: `{text}` — расшифровка, `{previous}` — прежний результат,
    /// `{feedback}` — замечания автора.
    public var reviseTemplate: String
    /// Задача для чистки надиктованных замечаний при правке строки (после base_prompt). Пусто — без чистки.
    public var feedbackPrompt: String
    public var env: [String: String]

    public init(harness: String, model: String, timeoutSeconds: Double, shell: String, loginShell: Bool,
                extraPath: [String], workdir: String, inputTemplate: String, stripCodeFences: Bool,
                basePrompt: String, revisePrompt: String, reviseTemplate: String, feedbackPrompt: String, env: [String: String]) {
        self.harness = harness
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.shell = shell
        self.loginShell = loginShell
        self.extraPath = extraPath
        self.workdir = workdir
        self.inputTemplate = inputTemplate
        self.stripCodeFences = stripCodeFences
        self.basePrompt = basePrompt
        self.revisePrompt = revisePrompt
        self.reviseTemplate = reviseTemplate
        self.feedbackPrompt = feedbackPrompt
        self.env = env
    }
}

/// Как подать текст в harness.
public enum HarnessInput: String, Sendable, Equatable, CaseIterable {
    /// Текст — в stdin.
    case stdin
    /// Текст — аргументом: плейсхолдер `{input}` в `args`. stdin пустой.
    case arg
}

/// Как читать ответ harness без схемы.
public enum HarnessOutput: String, Sendable, Equatable, CaseIterable {
    /// stdout целиком — готовый текст.
    case text
    /// stdout — JSON (объект, массив событий или JSON Lines); текст — по пути `outputPath`.
    case json
}

/// Как harness обращается к LLM.
public enum HarnessKind: String, Sendable, Equatable, CaseIterable {
    /// Запуск CLI-программы: `executable` + `args`.
    case process
    /// HTTP-запрос к серверу Ollama (`/api/chat`) по адресу `url`, без CLI.
    case ollama
    /// Codex CLI: запуск как у `process`, но с отдельной папкой `CODEX_HOME`, без `AGENTS.md`,
    /// MCP-серверов и прочих настроек пользователя.
    case codex
}

/// Что делать, если проверка изоляции Codex (`[harness.<имя>] verify`) нашла лишнее в запросе.
public enum CodexVerifyMode: String, Sendable, Equatable, CaseIterable {
    /// Предупредить в меню и панели, Codex работает дальше.
    case warn
    /// Не вызывать этот harness, пока проверка не пройдёт.
    case block
}

/// Способ обращения к LLM. Секция `[harness.<имя>]`.
///
/// `type = "process"` — CLI-программа (Claude Code, OpenCode, llm, свой скрипт).
/// Плейсхолдеры в аргументах: `{model}`, `{prompt_file}`, `{system_prompt}`, `{input}`,
/// `{schema}`, `{schema_file}`. Каждый аргумент передаётся программе как есть, без shell-разбора.
///
/// `type = "codex"` — как `process`, но Codex получает отдельную папку `CODEX_HOME`.
///
/// `type = "ollama"` — прямой запрос к Ollama: `url`, `think`, `keep_alive`, `options`.
/// Ключи CLI (`executable`, `args`, `input`, `output`…) не используются.
public struct HarnessConfig: Sendable, Equatable {
    public var kind: HarnessKind
    /// Модель по умолчанию для этого harness: важнее `llm.model`, но `model` варианта важнее её.
    /// Пусто — `llm.model`.
    public var model: String
    /// Имя программы в PATH, полный путь или функция/алиас shell (например, из `~/.zshenv`).
    public var executable: String
    /// Аргументы для всех запусков.
    public var args: [String]
    /// Добавляются после `args`, если у варианта нет схемы.
    public var textArgs: [String]
    /// Добавляются после `args`, если у варианта есть схема (`schema`).
    public var schemaArgs: [String]
    public var input: HarnessInput
    public var output: HarnessOutput
    /// Путь к тексту в JSON-ответе для `output = json`: ключи через точку, индексы массивов — числа.
    public var outputPath: String
    /// Путь к объекту по схеме в JSON-ответе, если у варианта есть схема. Пусто — весь ответ.
    public var schemaOutputPath: String
    /// Переменные окружения поверх `[llm.env]`.
    public var env: [String: String]
    /// Сколько запросов этого harness идёт одновременно; остальные ждут очереди. 0 — без ограничения.
    /// Для Ollama ещё и `OLLAMA_NUM_PARALLEL`, если TapLess сам запускает Ollama.app.
    public var parallel: Int
    /// Codex: что делать, если проверка изоляции нашла лишнее. Утечка `AGENTS.md` блокирует вызовы всегда.
    public var verify: CodexVerifyMode

    /// Ollama: адрес сервера, например `http://127.0.0.1:11434`.
    public var url: String
    /// Ollama: параметр `think`. Пусто — не передаётся; `"true"` / `"false"` — флаг;
    /// другое значение (`"low"`, `"medium"`, `"high"`) — уровень для моделей, которые его понимают.
    public var think: String
    /// Ollama: сколько держать модель в памяти после запроса (`"30m"`, `"-1"` — всегда). Пусто — как в Ollama.
    public var keepAlive: String
    /// Ollama: параметры модели (`temperature`, `num_ctx`, `top_p`…).
    public var options: [String: Double]

    public init(executable: String, args: [String], textArgs: [String] = [], schemaArgs: [String] = [],
                input: HarnessInput = .stdin, output: HarnessOutput = .text, outputPath: String = "",
                schemaOutputPath: String = "", env: [String: String] = [:],
                kind: HarnessKind = .process, model: String = "", url: String = "", think: String = "",
                keepAlive: String = "", options: [String: Double] = [:], parallel: Int = 0,
                verify: CodexVerifyMode = .warn) {
        self.kind = kind
        self.model = model
        self.executable = executable
        self.args = args
        self.textArgs = textArgs
        self.schemaArgs = schemaArgs
        self.input = input
        self.output = output
        self.outputPath = outputPath
        self.schemaOutputPath = schemaOutputPath
        self.env = env
        self.url = url
        self.think = think
        self.keepAlive = keepAlive
        self.options = options
        self.parallel = parallel
        self.verify = verify
    }

    /// Harness для Ollama.
    public static func ollama(url: String, model: String = "", think: String = "", keepAlive: String = "",
                              options: [String: Double] = [:], parallel: Int = 0) -> HarnessConfig {
        HarnessConfig(executable: "", args: [], kind: .ollama, model: model, url: url, think: think,
                      keepAlive: keepAlive, options: options, parallel: parallel)
    }

    /// Для лога и меню: программа или адрес сервера.
    public var target: String {
        switch kind {
        case .process, .codex: return executable
        case .ollama: return "Ollama \(url)"
        }
    }
}

/// JSON Schema для структурированного ответа. Секция `[schemas.<имя>]`.
public struct SchemaConfig: Sendable, Equatable {
    /// Схема текстом. Если задан `file`, берётся файл.
    public var json: String
    /// Путь к файлу со схемой (`~` раскрывается).
    public var file: String
    /// Какое поле ответа вставлять: путь через точку. Пусто — весь JSON.
    public var resultPath: String

    public init(json: String = "", file: String = "", resultPath: String = "") {
        self.json = json
        self.file = file
        self.resultPath = resultPath
    }
}

public struct LogConfig: Sendable, Equatable {
    /// "debug", "info", "warning" или "error".
    public var level: String
    /// Писать ли в лог сам текст диктовки и ответов. false — только длину.
    public var includeText: Bool

    public init(level: String, includeText: Bool) {
        self.level = level
        self.includeText = includeText
    }

    /// Уровень из конфига; неизвестное имя — `.debug`.
    public var logLevel: LogLevel { LogLevel(name: level) ?? .debug }
}

/// История диктовок на диске. Секция `[history]`.
public struct HistoryConfig: Sendable, Equatable {
    public var enabled: Bool
    /// Папка истории. Пусто — `~/.cache/tapless`.
    public var dir: String
    public var saveAudio: Bool
    /// 0 — без срока.
    public var retentionDays: Int
    /// 0 — без предела.
    public var maxSizeMB: Int

    public init(enabled: Bool, dir: String, saveAudio: Bool, retentionDays: Int, maxSizeMB: Int) {
        self.enabled = enabled
        self.dir = dir
        self.saveAudio = saveAudio
        self.retentionDays = retentionDays
        self.maxSizeMB = maxSizeMB
    }
}

/// Словарь для модели: термин → как он может прийти из распознавания, плюс свободные пояснения.
public struct DictionaryConfig: Sendable, Equatable {
    public var terms: [String: [String]]
    public var notes: String

    public init(terms: [String: [String]], notes: String) {
        self.terms = terms
        self.notes = notes
    }
}

public struct VariantConfig: Sendable, Equatable {
    public var name: String
    public var prompt: String
    public var model: String?
    /// Свой harness вместо `llm.harness`.
    public var harness: String?
    /// Имя схемы из `[schemas.<имя>]`: ответ запрашивается структурированным.
    public var schema: String?
    public var enabled: Bool

    public init(name: String, prompt: String, model: String? = nil, harness: String? = nil,
                schema: String? = nil, enabled: Bool = true) {
        self.name = name
        self.prompt = prompt
        self.model = model
        self.harness = harness
        self.schema = schema
        self.enabled = enabled
    }
}

public struct AppConfig: Sendable, Equatable {
    public var general: GeneralConfig
    public var paste: PasteConfig
    public var ui: UIConfig
    public var stt: STTConfig
    public var llm: LLMConfig
    public var harnesses: [String: HarnessConfig]
    public var schemas: [String: SchemaConfig]
    public var log: LogConfig
    public var dictionary: DictionaryConfig
    public var history: HistoryConfig
    public var variants: [VariantConfig]

    public init(general: GeneralConfig, paste: PasteConfig, ui: UIConfig, stt: STTConfig,
                llm: LLMConfig, harnesses: [String: HarnessConfig], schemas: [String: SchemaConfig],
                log: LogConfig, dictionary: DictionaryConfig, history: HistoryConfig, variants: [VariantConfig]) {
        self.general = general
        self.paste = paste
        self.ui = ui
        self.stt = stt
        self.llm = llm
        self.harnesses = harnesses
        self.schemas = schemas
        self.log = log
        self.dictionary = dictionary
        self.history = history
        self.variants = variants
    }

    /// Клавиша сырого текста («Как распознано»): 1, если `ui.show_raw`; иначе nil.
    public var rawTextKey: Int? {
        ui.showRaw ? 1 : nil
    }

    /// Клавиша первого варианта: 2, если клавиша 1 занята сырым текстом, иначе 1.
    public var firstVariantKey: Int {
        ui.showRaw ? 2 : 1
    }

    /// Сколько вариантов помещается на клавиши до 9.
    public var maxVariants: Int {
        10 - firstVariantKey
    }

    /// Включённые варианты, не больше `maxVariants` (клавиши `firstVariantKey`…9).
    public var activeVariants: [VariantConfig] {
        Array(variants.filter(\.enabled).prefix(maxVariants))
    }

    /// Клавиши включённых вариантов по порядку.
    public var variantKeys: [Int] {
        activeVariants.indices.map { firstVariantKey + $0 }
    }

    /// Клавиши строк панели: сырой текст (если есть) и включённые варианты.
    public var panelKeys: [Int] {
        (rawTextKey.map { [$0] } ?? []) + variantKeys
    }

    /// Клавиша автовставки из `paste.auto_select`; nil — выключено или такой строки нет.
    public var autoSelectKey: Int? {
        validAutoSelectKey(paste.autoSelect)
    }

    /// `value`, если это клавиша строки панели (сырой текст или включённый вариант); иначе nil.
    /// 0 — автовставка выключена.
    public func validAutoSelectKey(_ value: Int) -> Int? {
        value != 0 && panelKeys.contains(value) ? value : nil
    }

    /// Клавиши вариантов, которые запускаются на диктовку: все включённые; при автовставке
    /// `autoSelectKey` — только её вариант, при автовставке сырого текста — ни одного.
    /// Автовставку меняют из меню на ходу, поэтому клавиша — параметр, а не `paste.auto_select`.
    public func runVariantKeys(autoSelectKey: Int?) -> [Int] {
        guard let key = autoSelectKey else { return variantKeys }
        return variantKeys.contains(key) ? [key] : []
    }

    /// Harness варианта: свой или `llm.harness`.
    public func harnessName(for variant: VariantConfig) -> String {
        variant.harness ?? llm.harness
    }

    /// Модель варианта: `model` варианта → `model` его harness → `llm.model`.
    public func model(for variant: VariantConfig) -> String {
        if let model = variant.model { return model }
        if let harnessModel = harnesses[harnessName(for: variant)]?.model, !harnessModel.isEmpty {
            return harnessModel
        }
        return llm.model
    }

    /// Серверы Ollama и модели, которые нужны включённым вариантам, без повторов, в порядке вариантов.
    /// Автовставку не учитывает: её меняют на ходу, а подготовка идёт при запуске.
    public var ollamaTargets: [OllamaTarget] {
        var targets: [OllamaTarget] = []
        for variant in activeVariants {
            guard let harness = harnesses[harnessName(for: variant)], harness.kind == .ollama else { continue }
            let url = harness.url.trimmingCharacters(in: .whitespaces)
            let model = model(for: variant).trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty, !model.isEmpty else { continue }
            if let index = targets.firstIndex(where: { $0.url == url && $0.model == model }) {
                targets[index].parallel = OllamaTarget.combinedParallel(targets[index].parallel, harness.parallel)
            } else {
                targets.append(OllamaTarget(url: url, model: model, parallel: harness.parallel))
            }
        }
        return targets
    }

    /// Harness Codex и модели, которые нужны включённым вариантам и `llm.harness`
    /// (правка сырого текста и чистка замечаний к нему), без повторов.
    public var codexTargets: [CodexTarget] {
        var uses = activeVariants.map { (harnessName(for: $0), model(for: $0)) }
        let defaultModel = harnesses[llm.harness].map { $0.model.isEmpty ? llm.model : $0.model } ?? llm.model
        uses.append((llm.harness, defaultModel))
        var targets: [CodexTarget] = []
        for (name, model) in uses {
            guard let harness = harnesses[name], harness.kind == .codex else { continue }
            let model = model.trimmingCharacters(in: .whitespaces)
            guard !targets.contains(where: { $0.harnessName == name && $0.model == model }) else { continue }
            targets.append(CodexTarget(harnessName: name, harness: harness, model: model))
        }
        return targets
    }
}
