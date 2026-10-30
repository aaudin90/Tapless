import Foundation
import TapLessDomain

// Форма конфига в TOML (snake_case) → доменные модели.
// Разбирается уже слитый конфиг (значения по умолчанию + файл пользователя),
// поэтому обязательны все ключи, кроме ключей вариантов, harness и схем:
// у новых [variants.<номер>], [harness.<имя>] и [schemas.<имя>] значений по умолчанию нет.

struct ConfigDTO: Decodable {
    let general: General
    let paste: Paste
    let ui: UI
    let stt: STT
    let llm: LLM
    let harness: [String: Harness]
    let schemas: [String: Schema]
    let log: LogSection
    let dictionary: DictionarySection
    let history: HistorySection
    /// Варианты по номерам: `[variants.1]`, `[variants.2]`… Номер задаёт порядок.
    let variants: [String: Variant]

    struct General: Decodable {
        let hotkey: String
        let showLastHotkey: String
        let mode: String
        let sounds: Bool
        let minRecordingMs: Int
        let tailMs: Int
        let maxRecordingSeconds: Int
        let checkUpdates: Bool
        let microphone: String
        let voiceProcessing: String

        enum CodingKeys: String, CodingKey {
            case hotkey, mode, sounds, microphone
            case voiceProcessing = "voice_processing"
            case showLastHotkey = "show_last_hotkey"
            case minRecordingMs = "min_recording_ms"
            case tailMs = "tail_ms"
            case maxRecordingSeconds = "max_recording_seconds"
            case checkUpdates = "check_updates"
        }
    }

    struct Paste: Decodable {
        let autoPaste: Bool
        let restoreClipboard: Bool
        let pasteDelayMs: Int
        let restoreDelayMs: Int
        let autoSelect: Int

        enum CodingKeys: String, CodingKey {
            case autoPaste = "auto_paste"
            case restoreClipboard = "restore_clipboard"
            case pasteDelayMs = "paste_delay_ms"
            case restoreDelayMs = "restore_delay_ms"
            case autoSelect = "auto_select"
        }
    }

    struct UI: Decodable {
        let position: String
        let width: Int
        let maxLines: Int
        let showRaw: Bool

        enum CodingKeys: String, CodingKey {
            case position, width
            case maxLines = "max_lines"
            case showRaw = "show_raw"
        }
    }

    struct STT: Decodable {
        let model: String
        let modelPath: String
        let modelRepo: String
        let language: String
        let initialPrompt: String
        let silenceThreshold: Double
        let dropPhrases: [String]

        enum CodingKeys: String, CodingKey {
            case model, language
            case modelPath = "model_path"
            case modelRepo = "model_repo"
            case initialPrompt = "initial_prompt"
            case silenceThreshold = "silence_threshold"
            case dropPhrases = "drop_phrases"
        }
    }

    struct LLM: Decodable {
        let harness: String
        let model: String
        let timeoutSeconds: Double
        let shell: String
        let loginShell: Bool
        let extraPath: [String]
        let workdir: String
        let inputTemplate: String
        let stripCodeFences: Bool
        let basePrompt: String
        let revisePrompt: String
        let reviseTemplate: String
        let feedbackPrompt: String
        let env: [String: String]

        enum CodingKeys: String, CodingKey {
            case harness, model, shell, workdir, env
            case timeoutSeconds = "timeout_seconds"
            case loginShell = "login_shell"
            case extraPath = "extra_path"
            case inputTemplate = "input_template"
            case stripCodeFences = "strip_code_fences"
            case basePrompt = "base_prompt"
            case revisePrompt = "revise_prompt"
            case reviseTemplate = "revise_template"
            case feedbackPrompt = "feedback_prompt"
        }
    }

    struct Harness: Decodable {
        let type: String?
        let model: String?
        let executable: String?
        let args: [String]?
        let textArgs: [String]?
        let schemaArgs: [String]?
        let input: String?
        let output: String?
        let outputPath: String?
        let schemaOutputPath: String?
        let env: [String: String]?
        let url: String?
        let think: Think?
        let keepAlive: String?
        let options: [String: Double]?
        let parallel: Int?
        let verify: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case type, model, executable, args, input, output, env, url, think, options, parallel, verify
            case textArgs = "text_args"
            case schemaArgs = "schema_args"
            case outputPath = "output_path"
            case schemaOutputPath = "schema_output_path"
            case keepAlive = "keep_alive"
        }

        /// `think` в TOML — флаг (`false`) или уровень строкой (`"low"`).
        struct Think: Decodable {
            let value: String

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    value = flag ? "true" : "false"
                } else {
                    value = try container.decode(String.self)
                }
            }
        }
    }

    struct Schema: Decodable {
        let json: String?
        let file: String?
        let resultPath: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case json, file
            case resultPath = "result_path"
        }
    }

    struct LogSection: Decodable {
        let level: String
        let includeText: Bool

        enum CodingKeys: String, CodingKey {
            case level
            case includeText = "include_text"
        }
    }

    struct HistorySection: Decodable {
        let enabled: Bool
        let dir: String
        let saveAudio: Bool
        let retentionDays: Int
        let maxSizeMb: Int

        enum CodingKeys: String, CodingKey {
            case enabled, dir
            case saveAudio = "save_audio"
            case retentionDays = "retention_days"
            case maxSizeMb = "max_size_mb"
        }
    }

    struct DictionarySection: Decodable {
        let terms: [String: [String]]
        let notes: String

        enum CodingKeys: String, CodingKey {
            case terms, notes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notes = try c.decode(String.self, forKey: .notes)
            // Прежний формат — массив терминов без вариантов распознавания.
            if let list = try? c.decode([String].self, forKey: .terms) {
                terms = Dictionary(list.map { ($0, []) }, uniquingKeysWith: { first, _ in first })
            } else {
                terms = try c.decode([String: [String]].self, forKey: .terms)
            }
        }
    }

    struct Variant: Decodable {
        let name: String?
        let prompt: String?
        let model: String?
        let harness: String?
        let schema: String?
        let enabled: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, prompt, model, harness, schema, enabled
        }
    }

    /// Ключи, которые допустимы у варианта ([variants.<номер>]).
    static let variantKeys = Set(Variant.CodingKeys.allCases.map(\.rawValue))
    /// Ключи секции [harness.<имя>].
    static let harnessKeys = Set(Harness.CodingKeys.allCases.map(\.rawValue))
    /// Ключи секции [schemas.<имя>].
    static let schemaKeys = Set(Schema.CodingKeys.allCases.map(\.rawValue))

    func domain() throws -> AppConfig {
        try AppConfig(
            general: GeneralConfig(
                hotkey: general.hotkey,
                showLastHotkey: general.showLastHotkey,
                mode: general.mode,
                sounds: general.sounds,
                minRecordingMs: general.minRecordingMs,
                tailMs: general.tailMs,
                maxRecordingSeconds: general.maxRecordingSeconds,
                checkUpdates: general.checkUpdates,
                microphone: general.microphone,
                voiceProcessing: general.voiceProcessing
            ),
            paste: PasteConfig(
                autoPaste: paste.autoPaste,
                restoreClipboard: paste.restoreClipboard,
                pasteDelayMs: paste.pasteDelayMs,
                restoreDelayMs: paste.restoreDelayMs,
                autoSelect: paste.autoSelect
            ),
            ui: UIConfig(
                position: ui.position,
                width: ui.width,
                maxLines: ui.maxLines,
                showRaw: ui.showRaw
            ),
            stt: STTConfig(
                model: stt.model,
                modelPath: stt.modelPath,
                modelRepo: stt.modelRepo,
                language: stt.language,
                initialPrompt: stt.initialPrompt,
                silenceThreshold: stt.silenceThreshold,
                dropPhrases: stt.dropPhrases
            ),
            llm: LLMConfig(
                harness: llm.harness,
                model: llm.model,
                timeoutSeconds: llm.timeoutSeconds,
                shell: llm.shell,
                loginShell: llm.loginShell,
                extraPath: llm.extraPath,
                workdir: llm.workdir,
                inputTemplate: llm.inputTemplate,
                stripCodeFences: llm.stripCodeFences,
                basePrompt: llm.basePrompt,
                revisePrompt: llm.revisePrompt,
                reviseTemplate: llm.reviseTemplate,
                feedbackPrompt: llm.feedbackPrompt,
                env: llm.env
            ),
            harnesses: harness.reduce(into: [:]) { result, item in
                result[item.key] = try item.value.domain(name: item.key)
            },
            schemas: schemas.mapValues {
                SchemaConfig(json: $0.json ?? "", file: $0.file ?? "", resultPath: $0.resultPath ?? "")
            },
            log: LogConfig(level: log.level, includeText: log.includeText),
            dictionary: DictionaryConfig(terms: dictionary.terms, notes: dictionary.notes),
            history: HistoryConfig(
                enabled: history.enabled,
                dir: history.dir,
                saveAudio: history.saveAudio,
                retentionDays: history.retentionDays,
                maxSizeMB: history.maxSizeMb
            ),
            variants: try orderedVariants().map { number, v in
                guard let prompt = v.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError.schema("variants.\(number): не задан prompt")
                }
                return VariantConfig(
                    name: v.name ?? "Вариант \(number)",
                    prompt: prompt,
                    model: v.model,
                    harness: v.harness,
                    schema: v.schema,
                    enabled: v.enabled ?? true
                )
            }
        )
    }

    /// Варианты по возрастанию номера. Номер — целое число от 1 без нулей впереди и знака:
    /// слияние с дефолтами идёт по строке ключа, и `01` не совпал бы с `1`.
    private func orderedVariants() throws -> [(Int, Variant)] {
        try variants.map { key, variant in
            guard let number = Int(key), number >= 1, String(number) == key else {
                throw ConfigError.schema("variants.\(key): номер варианта должен быть целым числом от 1 без нулей впереди, например [variants.3]")
            }
            return (number, variant)
        }
        .sorted { $0.0 < $1.0 }
    }
}

extension ConfigDTO.Harness {
    func domain(name: String) throws -> HarnessConfig {
        func parse<T: RawRepresentable & CaseIterable>(_ value: String?, key: String, default fallback: T) throws -> T
        where T.RawValue == String {
            guard let value else { return fallback }
            if let parsed = T(rawValue: value.lowercased()) { return parsed }
            let allowed = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " или ")
            throw ConfigError.schema("harness.\(name).\(key) = \"\(value)\": ожидается \(allowed)")
        }
        let kind = try parse(type, key: "type", default: HarnessKind.process)
        if kind != .ollama && (executable ?? "").isEmpty {
            throw ConfigError.schema("harness.\(name): не задан executable (для Ollama укажите type = \"ollama\")")
        }
        return HarnessConfig(
            executable: executable ?? "",
            args: args ?? [],
            textArgs: textArgs ?? [],
            schemaArgs: schemaArgs ?? [],
            input: try parse(input, key: "input", default: HarnessInput.stdin),
            output: try parse(output, key: "output", default: HarnessOutput.text),
            outputPath: outputPath ?? "",
            schemaOutputPath: schemaOutputPath ?? "",
            env: env ?? [:],
            kind: kind,
            model: model ?? "",
            url: url ?? "",
            think: think?.value ?? "",
            keepAlive: keepAlive ?? "",
            options: options ?? [:],
            parallel: try parallelValue(name: name),
            verify: try parse(verify, key: "verify", default: CodexVerifyMode.warn)
        )
    }

    private func parallelValue(name: String) throws -> Int {
        guard let parallel else { return 0 }
        guard parallel >= 0 else {
            throw ConfigError.schema("harness.\(name).parallel = \(parallel): ожидается 0 (без ограничения) или больше")
        }
        return parallel
    }
}
