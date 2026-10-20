import Foundation

/// Схема структурированного ответа, выбранная вариантом.
public struct LLMSchema: Sendable, Equatable {
    /// Имя из `[schemas.<имя>]` — для логов и имени файла.
    public let name: String
    public let config: SchemaConfig

    public init(name: String, config: SchemaConfig) {
        self.name = name
        self.config = config
    }
}

/// Назначение запроса к LLM — для истории и логов.
public enum LLMPurpose: String, Sendable, Equatable { case variant, revision, feedback, warmUp }

/// Один запрос на оформление текста внешней LLM-программой (один вариант).
public struct LLMRequest: Sendable, Equatable {
    /// Клавиша варианта: 1…9.
    public let variantKey: Int
    public let variantName: String
    /// Имя harness из `[harness.<имя>]` — для логов.
    public let harnessName: String
    public let harness: HarnessConfig
    public let model: String
    public let systemPrompt: String
    /// Текст для LLM: `input_template` с подставленной расшифровкой.
    public let input: String
    public let schema: LLMSchema?
    public let purpose: LLMPurpose

    public init(variantKey: Int, variantName: String, harnessName: String, harness: HarnessConfig,
                model: String, systemPrompt: String, input: String, schema: LLMSchema? = nil,
                purpose: LLMPurpose = .variant) {
        self.variantKey = variantKey
        self.variantName = variantName
        self.harnessName = harnessName
        self.harness = harness
        self.model = model
        self.systemPrompt = systemPrompt
        self.input = input
        self.schema = schema
        self.purpose = purpose
    }
}
