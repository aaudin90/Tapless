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

    private let llm: LLMRepository
    private let config: AppConfig
    private let settings: LLMConfig
    private let harnesses: [String: HarnessConfig]
    private let schemas: [String: SchemaConfig]
    private let dictionaryBlock: String

    public init(llm: LLMRepository, config: AppConfig) {
        self.llm = llm
        self.config = config
        self.settings = config.llm
        self.harnesses = config.harnesses
        self.schemas = config.schemas
        self.variants = config.activeVariants
        self.firstVariantKey = config.firstVariantKey
        self.dictionaryBlock = TextTools.dictionaryBlock(config.dictionary)
    }

    /// Клавиши включённых вариантов по порядку.
    public var variantKeys: [Int] {
        variants.indices.map { firstVariantKey + $0 }
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

    /// Оформляет текст вариантом с клавишей `key` (`firstVariantKey`…9).
    public func execute(text: String, variantKey key: Int) async throws -> String {
        guard let variant = variant(forKey: key) else { throw FormatTextError.unknownVariant(key) }

        let harnessName = config.harnessName(for: variant)
        guard let harness = harnesses[harnessName] else { throw FormatTextError.unknownHarness(harnessName) }

        var schema: LLMSchema?
        if let schemaName = variant.schema {
            guard let config = schemas[schemaName] else { throw FormatTextError.unknownSchema(schemaName) }
            schema = LLMSchema(name: schemaName, config: config)
        }

        let basePrompt = TextTools.fill(settings.basePrompt, ["dictionary": dictionaryBlock])
        let request = LLMRequest(
            variantKey: key,
            variantName: variant.name,
            harnessName: harnessName,
            harness: harness,
            model: config.model(for: variant),
            systemPrompt: basePrompt + "\n" + variant.prompt,
            input: TextTools.fill(settings.inputTemplate, ["text": text]),
            schema: schema
        )

        let output = try await llm.complete(request)
        let cleaned = TextTools.cleanLLMOutput(output, stripFences: settings.stripCodeFences)
        guard !cleaned.isEmpty else { throw FormatTextError.emptyOutput }
        return cleaned
    }
}
