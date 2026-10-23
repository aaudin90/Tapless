import Foundation
import Testing
import TapLessData
@testable import TapLessDomain

/// Встроенные значения по умолчанию — готовый полный AppConfig для тестов.
/// TapLessData здесь только как источник фикстуры: сценарии от него не зависят.
private func defaultConfig() -> AppConfig {
    FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
}

private actor RecordingLLM: LLMRepository {
    private let reply: String
    private(set) var requests: [LLMRequest] = []

    init(reply: String) { self.reply = reply }

    func complete(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        return reply
    }
}

private final class StubRecognizer: SpeechRecognizer, @unchecked Sendable {
    let reply: String
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }

    init(reply: String) { self.reply = reply }
    func prepare(status: @escaping @Sendable (String) -> Void) async throws {}
    func unload() async {}
    func transcribe(_ samples: [Float], prompt: String) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return reply
    }
}

private actor RecordingSetup: LocalLLMSetup {
    private(set) var calls: [[OllamaTarget]] = []

    func prepare(_ targets: [OllamaTarget], status: @escaping @Sendable (LocalLLMStatus) -> Void) async -> LocalLLMStatus {
        calls.append(targets)
        status(.checking)
        return .ready
    }
}

@Suite struct PrepareLocalLLMUseCaseTests {
    @Test func defaultsUseOllama() async {
        let config = defaultConfig()
        let setup = RecordingSetup()
        let useCase = PrepareLocalLLMUseCase(setup: setup, config: config)
        let model = config.harnesses["ollama"]?.model ?? ""
        #expect(!model.isEmpty)
        #expect(useCase.targets == [OllamaTarget(url: "http://127.0.0.1:11434", model: model, parallel: 3)])
        #expect(await useCase.execute(status: { _ in }) == .ready)
        #expect(await setup.calls == [useCase.targets])
    }

    @Test func notUsedWithoutOllamaVariants() async {
        var config = defaultConfig()
        config.llm.harness = "claude"
        let setup = RecordingSetup()
        let useCase = PrepareLocalLLMUseCase(setup: setup, config: config)
        #expect(!useCase.isUsed)
        #expect(await useCase.execute(status: { _ in }) == .notUsed)
        #expect(await setup.calls.isEmpty)
    }
}

@Suite struct FormatTextUseCaseTests {
    @Test func buildsRequestFromConfig() async throws {
        var config = defaultConfig()
        config.variants[1].model = "sonnet"
        let llm = RecordingLLM(reply: "```\nГотово.\n```\n")
        let useCase = FormatTextUseCase(llm: llm, config: config)

        let result = try await useCase.execute(text: "привет", variantKey: 3)
        #expect(result == "Готово.")

        let request = try #require(await llm.requests.first)
        #expect(request.variantKey == 3)
        #expect(request.variantName == config.variants[1].name)
        #expect(request.model == "sonnet")
        #expect(request.harnessName == "ollama")
        #expect(request.harness == config.harnesses["ollama"])
        #expect(request.schema == nil)
        #expect(request.input.contains("<transcript>\nпривет\n</transcript>"))
        #expect(request.systemPrompt.hasSuffix(config.variants[1].prompt))
        #expect(request.systemPrompt.contains("Claude Code"))
        #expect(!request.systemPrompt.contains("{dictionary}"))
    }

    @Test func variantHarnessAndSchema() async throws {
        var config = defaultConfig()
        config.harnesses["fast"] = HarnessConfig(executable: "fast", args: ["{model}"])
        config.variants[0].harness = "fast"
        config.variants[0].schema = "text"
        let llm = RecordingLLM(reply: "ok")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.harnessName(forVariantKey: 1) == nil)
        #expect(useCase.harnessName(forVariantKey: 2) == "fast")
        #expect(useCase.harnessName(forVariantKey: 3) == "ollama")
        #expect(useCase.harnessKind(forVariantKey: 2) == .process)
        #expect(useCase.harnessKind(forVariantKey: 3) == .ollama)
        #expect(useCase.harnessKind(forVariantKey: 9) == nil)

        _ = try await useCase.execute(text: "a", variantKey: 2)
        let request = try #require(await llm.requests.first)
        #expect(request.harnessName == "fast")
        #expect(request.harness.executable == "fast")
        #expect(request.schema == LLMSchema(name: "text", config: config.schemas["text"]!))
    }

    @Test func unknownHarnessOrSchemaIsError() async {
        var config = defaultConfig()
        config.variants[0].harness = "nope"
        config.variants[1].schema = "missing"
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config)
        await #expect(throws: FormatTextError.unknownHarness("nope")) {
            try await useCase.execute(text: "a", variantKey: 2)
        }
        await #expect(throws: FormatTextError.unknownSchema("missing")) {
            try await useCase.execute(text: "a", variantKey: 3)
        }
    }

    @Test func skipsDisabledVariants() async throws {
        var config = defaultConfig()
        config.variants[0].enabled = false
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config)
        #expect(useCase.variants.count == config.variants.count - 1)
        #expect(useCase.variants.first?.name == config.variants[1].name)
        await #expect(throws: FormatTextError.unknownVariant(9)) {
            try await useCase.execute(text: "a", variantKey: 9)
        }
    }

    @Test func disabledVariantInTheMiddleShiftsKeys() {
        var config = defaultConfig()
        config.variants = (1...4).map { VariantConfig(name: "v\($0)", prompt: "p\($0)") }
        config.variants[1].enabled = false
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config)
        #expect(useCase.variantKeys == [2, 3, 4])
        #expect([2, 3, 4].map { useCase.variant(forKey: $0)?.name } == ["v1", "v3", "v4"])
    }

    @Test func rawTextTakesKeyOneAndVariantsFollow() async throws {
        let config = defaultConfig()
        let llm = RecordingLLM(reply: "x")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(config.rawTextKey == 1)
        #expect(useCase.firstVariantKey == 2)
        #expect(useCase.variantKeys == [2, 3])
        #expect(useCase.variant(forKey: 2)?.name == config.variants[0].name)
        await #expect(throws: FormatTextError.unknownVariant(1)) {
            try await useCase.execute(text: "a", variantKey: 1)
        }
    }

    @Test func withoutRawTextVariantsStartAtOne() {
        var config = defaultConfig()
        config.ui.showRaw = false
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config)
        #expect(config.rawTextKey == nil)
        #expect(useCase.variantKeys == [1, 2])
        #expect(useCase.variant(forKey: 1)?.name == config.variants[0].name)
    }

    @Test func activeVariantsFitKeysUpToNine() async {
        var config = defaultConfig()
        config.variants = (1...12).map { VariantConfig(name: "v\($0)", prompt: "p\($0)") }
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config)
        #expect(useCase.variants.count == 8)
        #expect(useCase.variantKeys.last == 9)
        await #expect(throws: FormatTextError.unknownVariant(10)) {
            try await useCase.execute(text: "a", variantKey: 10)
        }

        config.ui.showRaw = false
        #expect(FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: config).variants.count == 9)
    }

    @Test func emptyReplyIsError() async {
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: " <transcript></transcript> "), config: defaultConfig())
        await #expect(throws: FormatTextError.emptyOutput) {
            try await useCase.execute(text: "a", variantKey: 2)
        }
    }

    @Test func reviseVariantBuildsPromptAndInput() async throws {
        var config = defaultConfig()
        config.variants[0].schema = "text"
        let llm = RecordingLLM(reply: "```\nПравка.\n```")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.canRevise(key: 2))

        let result = try await useCase.revise(transcript: "сырой", previous: "старый", feedback: "короче", key: 2)
        #expect(result == "Правка.")

        let request = try #require(await llm.requests.first)
        #expect(request.variantKey == 2)
        #expect(request.variantName == config.variants[0].name + " (правка)")
        #expect(request.systemPrompt.contains(config.variants[0].prompt))
        #expect(request.systemPrompt.hasSuffix(config.llm.revisePrompt))
        #expect(request.systemPrompt.contains("Это правка"))
        #expect(request.input.contains("<transcript>\nсырой\n</transcript>"))
        #expect(request.input.contains("<previous>\nстарый\n</previous>"))
        #expect(request.input.contains("<feedback>\nкороче\n</feedback>"))
        #expect(request.schema == LLMSchema(name: "text", config: config.schemas["text"]!))
    }

    @Test func reviseRawTextUsesLLMHarnessWithoutVariantPrompt() async throws {
        var config = defaultConfig()
        config.variants[0].harness = "fast"
        config.harnesses["fast"] = HarnessConfig(executable: "fast", args: [])
        let llm = RecordingLLM(reply: "ok")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.canRevise(key: 1))
        #expect(useCase.harnessKind(forRevisionKey: 1) == config.harnesses[config.llm.harness]?.kind)
        #expect(useCase.harnessKind(forRevisionKey: 2) == .process)
        #expect(useCase.harnessKind(forRevisionKey: 9) == nil)

        _ = try await useCase.revise(transcript: "a", previous: "a", feedback: "f", key: 1)
        let request = try #require(await llm.requests.first)
        #expect(request.variantKey == 1)
        #expect(request.variantName == "Как распознано (правка)")
        #expect(request.harnessName == config.llm.harness)
        #expect(request.schema == nil)
        #expect(!request.systemPrompt.contains(config.variants[0].prompt))
        #expect(request.systemPrompt.hasSuffix(config.llm.revisePrompt))
    }

    @Test func cleanFeedbackBuildsRequest() async throws {
        var config = defaultConfig()
        config.llm.inputTemplate = "<f>{text}</f>"
        let llm = RecordingLLM(reply: "```\nИсправлено.\n```")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.cleansFeedback)
        #expect(useCase.feedbackHarnessKind == config.harnesses[config.llm.harness]?.kind)

        let result = try await useCase.cleanFeedback("сделай покороче")
        #expect(result == "Исправлено.")

        let request = try #require(await llm.requests.first)
        #expect(request.variantKey == FormatTextUseCase.feedbackKey)
        #expect(request.variantKey == 0)
        #expect(request.variantName == "Замечание")
        #expect(request.harnessName == config.llm.harness)
        #expect(request.schema == nil)
        #expect(request.input == "<f>сделай покороче</f>")
        #expect(request.systemPrompt.contains("Claude Code"))
        #expect(!request.systemPrompt.contains("{dictionary}"))
        #expect(request.systemPrompt.hasSuffix("\n" + config.llm.feedbackPrompt))
    }

    @Test func emptyFeedbackPromptSkipsLLM() async throws {
        var config = defaultConfig()
        config.llm.feedbackPrompt = " \n "
        let llm = RecordingLLM(reply: "не должно вызываться")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(!useCase.cleansFeedback)
        let result = try await useCase.cleanFeedback("как есть")
        #expect(result == "как есть")
        #expect(await llm.requests.isEmpty)
    }

    @Test func emptyFeedbackReplyIsError() async {
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "  "), config: defaultConfig())
        await #expect(throws: FormatTextError.emptyOutput) {
            try await useCase.cleanFeedback("a")
        }
    }

    @Test func reviseUnknownKeyIsError() async {
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: "x"), config: defaultConfig())
        #expect(!useCase.canRevise(key: 9))
        await #expect(throws: FormatTextError.unknownVariant(9)) {
            try await useCase.revise(transcript: "a", previous: "b", feedback: "c", key: 9)
        }
    }

    @Test func reviseDoesNotReexpandPlaceholdersInUserText() async throws {
        let llm = RecordingLLM(reply: "ok")
        let useCase = FormatTextUseCase(llm: llm, config: defaultConfig())
        _ = try await useCase.revise(transcript: "{feedback}", previous: "{text}", feedback: "{previous}", key: 2)
        let input = try #require(await llm.requests.first).input
        #expect(input.contains("<transcript>\n{feedback}\n</transcript>"))
        #expect(input.contains("<previous>\n{text}\n</previous>"))
        #expect(input.contains("<feedback>\n{previous}\n</feedback>"))
    }

    @Test func reviseTemplateWithoutFeedbackWarns() {
        var config = defaultConfig()
        #expect(!config.validationWarnings.contains { $0.contains("revise_template") })
        config.llm.reviseTemplate = "{text} {previous}"
        #expect(config.validationWarnings.contains { $0.contains("revise_template") && $0.contains("{feedback}") })
    }

    @Test func warmUpSendsSamePromptWithOneToken() async throws {
        var config = defaultConfig()
        config.variants[0].schema = "text"
        let llm = RecordingLLM(reply: "")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.warmUpKeys(autoSelectKey: nil) == [2, 3])

        try await useCase.warmUp(variantKey: 2)
        _ = try? await useCase.execute(text: "привет", variantKey: 2)
        let requests = await llm.requests
        let warm = try #require(requests.first)
        let real = try #require(requests.last)
        #expect(warm.systemPrompt == real.systemPrompt)
        #expect(warm.model == real.model)
        #expect(warm.input == "<transcript>\n\n</transcript>")
        #expect(real.input.hasPrefix("<transcript>\n"))
        #expect(warm.schema == nil)
        #expect(warm.harness.options["num_predict"] == 1)
        #expect(real.harness.options["num_predict"] == nil)
        #expect(warm.harness.options["num_ctx"] == real.harness.options["num_ctx"])
    }

    @Test func warmUpSkipsProcessHarness() async throws {
        var config = defaultConfig()
        config.harnesses["fast"] = HarnessConfig(executable: "fast", args: [])
        config.variants[0].harness = "fast"
        let llm = RecordingLLM(reply: "")
        let useCase = FormatTextUseCase(llm: llm, config: config)
        #expect(useCase.warmUpKeys(autoSelectKey: nil) == [3])

        try await useCase.warmUp(variantKey: 2)
        #expect(await llm.requests.isEmpty)
    }

    @Test func autoSelectRunsAndWarmsOnlyItsVariant() {
        let useCase = FormatTextUseCase(llm: RecordingLLM(reply: ""), config: defaultConfig())
        #expect(useCase.variantKeys == [2, 3])
        #expect(useCase.runKeys(autoSelectKey: nil) == [2, 3])
        #expect(useCase.runKeys(autoSelectKey: 3) == [3])
        #expect(useCase.warmUpKeys(autoSelectKey: 3) == [3])
        #expect(useCase.warmUpKeys(autoSelectKey: nil) == [2, 3])

        // Автовставка сырого текста: ИИ не нужен ни одному варианту.
        #expect(useCase.runKeys(autoSelectKey: 1).isEmpty)
        #expect(useCase.warmUpKeys(autoSelectKey: 1).isEmpty)
    }
}

@Suite struct TranscribeSpeechUseCaseTests {
    @Test func rejectsShortAndSilentClips() {
        let useCase = TranscribeSpeechUseCase(recognizer: StubRecognizer(reply: ""), config: defaultConfig())
        let second = Int(AudioClip.sampleRate)

        let short = AudioClip(samples: Array(repeating: 0.1, count: second / 10), peakLevel: 0.1)
        #expect(useCase.rejection(for: short) == .tooShort(seconds: 0.1))

        let silent = AudioClip(samples: Array(repeating: 0, count: second), peakLevel: 0.001)
        #expect(useCase.rejection(for: silent) == .silence)

        let speech = AudioClip(samples: Array(repeating: 0.1, count: second), peakLevel: 0.1)
        #expect(useCase.rejection(for: speech) == nil)
    }

    @Test func rejectionBoundaries() {
        var config = defaultConfig()
        let second = Int(AudioClip.sampleRate)
        config.general.minRecordingMs = 500
        config.stt.silenceThreshold = 0.25
        let useCase = TranscribeSpeechUseCase(recognizer: StubRecognizer(reply: ""), config: config)

        let exactDuration = AudioClip(samples: Array(repeating: 0.1, count: second / 2), peakLevel: 0.5)
        #expect(useCase.rejection(for: exactDuration) == nil)

        let exactPeak = AudioClip(samples: Array(repeating: 0.1, count: second), peakLevel: 0.25)
        #expect(useCase.rejection(for: exactPeak) == nil)

        let shortAndQuiet = AudioClip(samples: Array(repeating: 0, count: second / 10), peakLevel: 0.0)
        #expect(useCase.rejection(for: shortAndQuiet) == .tooShort(seconds: 0.1))
    }

    @Test func zeroMinRecordingAllowsEmptyClip() {
        var config = defaultConfig()
        config.general.minRecordingMs = 0
        config.stt.silenceThreshold = 0.25
        let useCase = TranscribeSpeechUseCase(recognizer: StubRecognizer(reply: ""), config: config)
        #expect(useCase.rejection(for: AudioClip(samples: [], peakLevel: 0.5)) == nil)
        #expect(useCase.rejection(for: AudioClip(samples: [], peakLevel: 0.0)) == .silence)
    }

    /// Текст после Whisper только чистится: термины словаря исправляет ИИ, не распознавание.
    @Test func cleansTranscriptWithoutReplacements() async throws {
        let raw = "<|ru|> Запусти клод   код и хайку. Продолжение следует..."
        let useCase = TranscribeSpeechUseCase(recognizer: StubRecognizer(reply: raw), config: defaultConfig())
        let clip = AudioClip(samples: [0.1], peakLevel: 0.1)
        #expect(try await useCase.execute(clip) == "Запусти клод код и хайку.")
    }

    /// В Whisper идёт только stt.initial_prompt, словарь — нет.
    @Test func whisperGetsOnlyInitialPrompt() async throws {
        var config = defaultConfig()
        config.stt.initialPrompt = " Ollama, Gemma. "
        config.dictionary.terms = ["Kubernetes": ["кубер"]]
        let recognizer = StubRecognizer(reply: "текст")
        _ = try await TranscribeSpeechUseCase(recognizer: recognizer, config: config).execute(AudioClip(samples: [0.1], peakLevel: 0.1))
        #expect(recognizer.prompts == ["Ollama, Gemma."])
    }

    @Test func punctuationOnlyIsEmpty() async throws {
        let useCase = TranscribeSpeechUseCase(recognizer: StubRecognizer(reply: " ... "), config: defaultConfig())
        #expect(try await useCase.execute(AudioClip(samples: [0.1], peakLevel: 0.1)) == "")
    }
}
