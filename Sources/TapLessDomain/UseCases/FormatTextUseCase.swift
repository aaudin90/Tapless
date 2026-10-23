import Foundation

public enum FormatTextError: LocalizedError, Equatable {
    case unknownVariant(Int)
    case unknownHarness(String)
    case unknownSchema(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .unknownVariant(let key): return "Нет варианта с клавишей \(key)"
        case .unknownHarness(let name): return "Нет секции [harness.\(name)] в конфиге"
        case .unknownSchema(let name): return "Нет секции [schemas.\(name)] в конфиге"
        case .emptyOutput: return "Пустой ответ"
        }
    }
}

/// Сценарий «текст → вариант оформления»: собирает системный промпт
/// (base_prompt + словарь + задача варианта), выбирает harness и схему,
/// отправляет текст в LLM и чистит ответ.
public struct FormatTextUseCase: Sendable {
    /// Включённые варианты; клавиша варианта — `firstVariantKey` + его индекс.
    public let variants: [VariantConfig]
    /// Клавиша первого варианта: 2, если клавиша 1 занята сырым текстом, иначе 1.
    public let firstVariantKey: Int

    /// Ключ запроса чистки замечаний: `prompt-0.txt`, `TAPLESS_VARIANT=0` — не пересекается с клавишами строк.
    public static let feedbackKey = 0

    private let llm: LLMRepository
    private let config: AppConfig
    private let settings: LLMConfig
    private let harnesses: [String: HarnessConfig]
    private let schemas: [String: SchemaConfig]
    private let dictionaryBlock: String
    private let rawTextKey: Int?

    public init(llm: LLMRepository, config: AppConfig) {
        self.llm = llm
        self.config = config
        self.settings = config.llm
        self.harnesses = config.harnesses
        self.schemas = config.schemas
        self.variants = config.activeVariants
        self.firstVariantKey = config.firstVariantKey
        self.dictionaryBlock = TextTools.dictionaryBlock(config.dictionary)
        self.rawTextKey = config.rawTextKey
    }

    /// Клавиши включённых вариантов по порядку.
    public var variantKeys: [Int] {
        config.variantKeys
    }

    /// Клавиши вариантов, которые запускаются на диктовку: при автовставке `autoSelectKey`
    /// только её вариант, остальные не тратят токены и время.
    public func runKeys(autoSelectKey: Int?) -> [Int] {
        config.runVariantKeys(autoSelectKey: autoSelectKey)
    }

    /// Вариант с клавишей `key`; nil — такой клавиши нет.
    public func variant(forKey key: Int) -> VariantConfig? {
        let index = key - firstVariantKey
        return variants.indices.contains(index) ? variants[index] : nil
    }

    /// Имя harness, которым запускается вариант с клавишей `key`.
    public func harnessName(forVariantKey key: Int) -> String? {
        variant(forKey: key).map { config.harnessName(for: $0) }
    }

    /// Тип harness варианта с клавишей `key`; nil — нет варианта или harness.
    public func harnessKind(forVariantKey key: Int) -> HarnessKind? {
        harnessName(forVariantKey: key).flatMap { harnesses[$0]?.kind }
    }

    /// Клавиши запускаемых вариантов, которые идут через Ollama: их промпт имеет смысл прогревать.
    public func warmUpKeys(autoSelectKey: Int?) -> [Int] {
        runKeys(autoSelectKey: autoSelectKey).filter { harnessKind(forVariantKey: $0) == .ollama }
    }

    /// Оформляет текст вариантом с клавишей `key` (`firstVariantKey`…9).
    public func execute(text: String, variantKey key: Int) async throws -> String {
        let request = try makeRequest(text: text, variantKey: key)
        let output = try await llm.complete(request)
        let cleaned = TextTools.cleanLLMOutput(output, stripFences: settings.stripCodeFences)
        guard !cleaned.isEmpty else { throw FormatTextError.emptyOutput }
        return cleaned
    }

    /// Прогревает кэш промпта Ollama для варианта с клавишей `key`: тот же системный промпт
    /// и пустой `input_template`, ответ — один токен (`num_predict = 1`). Следующая диктовка
    /// берёт общий префикс из кэша сервера и не разбирает промпт со словарём заново.
    /// Варианты не через Ollama не трогает: CLI-запуск ничего не кэширует, а стоит денег.
    public func warmUp(variantKey key: Int) async throws {
        var request = try makeRequest(text: "", variantKey: key)
        guard request.harness.kind == .ollama else { return }
        var harness = request.harness
        harness.options["num_predict"] = 1
        // Без схемы: один токен ответа её всё равно не пройдёт.
        request = LLMRequest(variantKey: request.variantKey, variantName: request.variantName + " (прогрев)",
                             harnessName: request.harnessName, harness: harness, model: request.model,
                             systemPrompt: request.systemPrompt, input: request.input,
                             purpose: .warmUp)
        _ = try await llm.complete(request)
    }

    /// Можно ли править строку с клавишей `key`: вариант или сырой текст (`rawTextKey`).
    public func canRevise(key: Int) -> Bool {
        variant(forKey: key) != nil || key == rawTextKey
    }

    /// Тип harness строки `key` с учётом сырого текста (для сырого — `llm.harness`).
    public func harnessKind(forRevisionKey key: Int) -> HarnessKind? {
        if let kind = harnessKind(forVariantKey: key) { return kind }
        guard key == rawTextKey else { return nil }
        return harnesses[settings.harness]?.kind
    }

    /// Перегенерирует строку `key` по замечаниям автора. `transcript` — исходная расшифровка,
    /// `previous` — текущий текст строки, `feedback` — замечания.
    public func revise(transcript: String, previous: String, feedback: String, key: Int) async throws -> String {
        let request = try makeReviseRequest(transcript: transcript, previous: previous, feedback: feedback, key: key)
        let output = try await llm.complete(request)
        let cleaned = TextTools.cleanLLMOutput(output, stripFences: settings.stripCodeFences)
        guard !cleaned.isEmpty else { throw FormatTextError.emptyOutput }
        return cleaned
    }

    /// Чистить ли надиктованные замечания: `llm.feedback_prompt` не пуст.
    public var cleansFeedback: Bool {
        !settings.feedbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Чистит надиктованные замечания к строке `key`: ошибки распознавания, термины по словарю, пунктуация.
    /// Harness и модель — той же строки (`harnessKind(forRevisionKey:)`), но без промпта и схемы варианта;
    /// для сырого текста — `llm.harness`. Пустой `llm.feedback_prompt` — возвращает текст как есть, без LLM.
    public func cleanFeedback(_ text: String, key: Int) async throws -> String {
        guard cleansFeedback else { return text }
        var variant = variant(forKey: key)
        variant?.schema = nil
        let request = try buildRequest(
            key: Self.feedbackKey, variant: variant, nameSuffix: "", name: "Замечание",
            taskPrompt: settings.feedbackPrompt, revisePrompt: nil,
            input: TextTools.fill(settings.inputTemplate, ["text": text]), purpose: .feedback)
        let output = try await llm.complete(request)
        let cleaned = TextTools.cleanLLMOutput(output, stripFences: settings.stripCodeFences)
        guard !cleaned.isEmpty else { throw FormatTextError.emptyOutput }
        return cleaned
    }

    private func makeRequest(text: String, variantKey key: Int) throws -> LLMRequest {
        guard let variant = variant(forKey: key) else { throw FormatTextError.unknownVariant(key) }
        return try buildRequest(
            key: key, variant: variant, nameSuffix: "",
            taskPrompt: variant.prompt, revisePrompt: nil,
            input: TextTools.fill(settings.inputTemplate, ["text": text]), purpose: .variant)
    }

    private func makeReviseRequest(transcript: String, previous: String, feedback: String, key: Int) throws -> LLMRequest {
        let input = TextTools.fill(settings.reviseTemplate,
                                   ["text": transcript, "previous": previous, "feedback": feedback])
        if let variant = variant(forKey: key) {
            return try buildRequest(key: key, variant: variant, nameSuffix: " (правка)",
                                    taskPrompt: variant.prompt, revisePrompt: settings.revisePrompt, input: input, purpose: .revision)
        }
        guard key == rawTextKey else { throw FormatTextError.unknownVariant(key) }
        return try buildRequest(key: key, variant: nil, nameSuffix: " (правка)",
                                taskPrompt: nil, revisePrompt: settings.revisePrompt, input: input, purpose: .revision)
    }

    /// Общая сборка запроса. `variant == nil` — сырой текст: harness и модель из `llm`, без схемы.
    /// Промпт варианта сюда не берётся: его передают в `taskPrompt`.
    private func buildRequest(key: Int, variant: VariantConfig?, nameSuffix: String, name: String? = nil,
                              taskPrompt: String?, revisePrompt: String?, input: String,
                              purpose: LLMPurpose) throws -> LLMRequest {
        let harnessName = variant.map { config.harnessName(for: $0) } ?? settings.harness
        guard let harness = harnesses[harnessName] else { throw FormatTextError.unknownHarness(harnessName) }

        var schema: LLMSchema?
        if let schemaName = variant?.schema {
            guard let config = schemas[schemaName] else { throw FormatTextError.unknownSchema(schemaName) }
            schema = LLMSchema(name: schemaName, config: config)
        }

        var systemPrompt = TextTools.fill(settings.basePrompt, ["dictionary": dictionaryBlock])
        if let taskPrompt { systemPrompt += "\n" + taskPrompt }
        if let revisePrompt { systemPrompt += "\n\n" + revisePrompt }

        let model = variant.map { config.model(for: $0) } ?? (harness.model.isEmpty ? settings.model : harness.model)
        return LLMRequest(
            variantKey: key,
            variantName: (name ?? variant?.name ?? "Как распознано") + nameSuffix,
            harnessName: harnessName,
            harness: harness,
            model: model,
            systemPrompt: systemPrompt,
            input: input,
            schema: schema,
            purpose: purpose
        )
    }
}
