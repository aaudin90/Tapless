import Foundation
import Testing
@testable import TapLessDomain

private func makeConfig(harnesses: [String: HarnessConfig], llmHarness: String = "cli",
                        llmModel: String = "llm-model", variants: [VariantConfig]) -> AppConfig {
    AppConfig(
        general: GeneralConfig(hotkey: "option+quote", showLastHotkey: "option+semicolon", mode: "toggle", sounds: false,
                               minRecordingMs: 300, tailMs: 0, maxRecordingSeconds: 60),
        paste: PasteConfig(autoPaste: true, restoreClipboard: true, pasteDelayMs: 0, restoreDelayMs: 0),
        ui: UIConfig(position: "top", width: 400, maxLines: 5, showRaw: true),
        stt: STTConfig(model: "m", modelPath: "", modelRepo: "", language: "ru",
                       initialPrompt: "", silenceThreshold: 0, dropPhrases: []),
        llm: LLMConfig(harness: llmHarness, model: llmModel, timeoutSeconds: 30, shell: "/bin/zsh",
                       loginShell: true, extraPath: [], workdir: "", inputTemplate: "{text}",
                       stripCodeFences: false, basePrompt: "", env: [:]),
        harnesses: harnesses,
        schemas: [:],
        log: LogConfig(level: "info", includeText: false),
        dictionary: DictionaryConfig(terms: [:], notes: ""),
        variants: variants)
}

@Suite struct HarnessResolutionTests {
    private let cli = HarnessConfig(executable: "tool", args: [], model: "cli-model")
    private let bare = HarnessConfig(executable: "bare", args: [])

    @Test func variantModelWinsOverHarnessAndLLM() {
        let variant = VariantConfig(name: "v", prompt: "p", model: "variant-model")
        let config = makeConfig(harnesses: ["cli": cli], variants: [variant])
        #expect(config.model(for: variant) == "variant-model")
    }

    @Test func harnessModelWinsOverLLM() {
        let variant = VariantConfig(name: "v", prompt: "p")
        let config = makeConfig(harnesses: ["cli": cli], variants: [variant])
        #expect(config.model(for: variant) == "cli-model")
    }

    @Test func llmModelIsFallback() {
        let variant = VariantConfig(name: "v", prompt: "p")
        let config = makeConfig(harnesses: ["cli": bare], llmHarness: "cli", variants: [variant])
        #expect(config.model(for: variant) == "llm-model")
    }

    @Test func variantHarnessModelUsed() {
        let variant = VariantConfig(name: "v", prompt: "p", harness: "oll")
        let config = makeConfig(harnesses: ["cli": cli, "oll": .ollama(url: "http://x", model: "gemma")],
                                variants: [variant])
        #expect(config.model(for: variant) == "gemma")
    }

    @Test func unknownHarnessFallsBackToLLMModel() {
        let variant = VariantConfig(name: "v", prompt: "p", harness: "nope")
        let config = makeConfig(harnesses: ["cli": cli], variants: [variant])
        #expect(config.model(for: variant) == "llm-model")
    }

    @Test func harnessNameFallsBackToLLMHarness() {
        let own = VariantConfig(name: "a", prompt: "p", harness: "oll")
        let plain = VariantConfig(name: "b", prompt: "p")
        let config = makeConfig(harnesses: ["cli": cli, "oll": .ollama(url: "http://x")], variants: [own, plain])
        #expect(config.harnessName(for: own) == "oll")
        #expect(config.harnessName(for: plain) == "cli")
    }

    @Test func ollamaTargetAndFactory() {
        let harness = HarnessConfig.ollama(url: "http://x", model: "m", think: "false", keepAlive: "1h",
                                           options: ["temperature": 0.5])
        #expect(harness.kind == .ollama)
        #expect(harness.target == "Ollama http://x")
        #expect(harness.executable.isEmpty)
        #expect(cli.target == "tool")
    }

    @Test func emptyOllamaURLWarns() {
        let config = makeConfig(harnesses: ["cli": cli, "oll": .ollama(url: "  ")],
                                variants: [VariantConfig(name: "v", prompt: "p")])
        #expect(config.validationWarnings == ["harness.oll.url пустой — запросы к Ollama завершатся ошибкой."])
    }

    @Test func ollamaHarnessHasNoCLIWarnings() {
        var ollama = HarnessConfig.ollama(url: "http://127.0.0.1:11434")
        ollama.input = .arg
        ollama.output = .json
        var config = makeConfig(harnesses: ["oll": ollama], llmHarness: "oll",
                                variants: [VariantConfig(name: "v", prompt: "p", schema: "text")])
        config.schemas["text"] = SchemaConfig(json: "{}")
        #expect(config.validationWarnings.isEmpty)
    }

    @Test func cliHarnessStillGetsCLIWarnings() {
        var harness = HarnessConfig(executable: "tool", args: [])
        harness.input = .arg
        var config = makeConfig(harnesses: ["cli": harness],
                                variants: [VariantConfig(name: "v", prompt: "p", schema: "text")])
        config.schemas["text"] = SchemaConfig(json: "{}")
        let warnings = config.validationWarnings
        #expect(warnings.contains { $0.contains("schema_args") })
        #expect(warnings.contains { $0.contains("{input}") })
    }

    @Test func ollamaTargetsAreUniqueAndOnlyForOllama() {
        let harnesses: [String: HarnessConfig] = [
            "cli": cli,
            "oll": .ollama(url: " http://127.0.0.1:11434 ", model: "gemma", parallel: 2),
            "oll4": .ollama(url: "http://127.0.0.1:11434", model: "gemma", parallel: 4),
            "unlimited": .ollama(url: "http://127.0.0.1:11434", model: "gemma:big"),
            "remote": .ollama(url: "http://box:11434", model: "qwen"),
            "blank": .ollama(url: "  ", model: "x"),
        ]
        let variants = [
            VariantConfig(name: "a", prompt: "p", harness: "oll"),
            VariantConfig(name: "b", prompt: "p", harness: "oll"),
            VariantConfig(name: "c", prompt: "p", model: "gemma:big", harness: "oll"),
            VariantConfig(name: "d", prompt: "p"),
            VariantConfig(name: "e", prompt: "p", harness: "remote"),
            VariantConfig(name: "f", prompt: "p", harness: "blank"),
            VariantConfig(name: "g", prompt: "p", harness: "remote", enabled: false),
            VariantConfig(name: "h", prompt: "p", harness: "nope"),
            VariantConfig(name: "i", prompt: "p", harness: "oll4"),
            VariantConfig(name: "j", prompt: "p", harness: "unlimited"),
        ]
        var config = makeConfig(harnesses: harnesses, variants: variants)
        config.ui.showRaw = false  // 9 включённых вариантов: все получают клавиши
        #expect(config.ollamaTargets == [
            OllamaTarget(url: "http://127.0.0.1:11434", model: "gemma", parallel: 4),
            OllamaTarget(url: "http://127.0.0.1:11434", model: "gemma:big"),
            OllamaTarget(url: "http://box:11434", model: "qwen"),
        ])
    }

    @Test func localLLMStatusText() {
        #expect(LocalLLMStatus.downloading(model: "m", fraction: 0.456).text == "скачиваю m: 45%")
        #expect(LocalLLMStatus.downloading(model: "m", fraction: nil).text == "скачиваю m…")
        #expect(LocalLLMStatus.downloading(model: "m", fraction: nil).isBusy)
        #expect(!LocalLLMStatus.notInstalled.isBusy)
    }

    @Test func showLastHotkeySameAsHotkeyWarns() {
        var config = makeConfig(harnesses: ["cli": cli], variants: [VariantConfig(name: "v", prompt: "p")])
        config.general.showLastHotkey = " Quote + option "
        #expect(config.validationWarnings.contains { $0.contains("show_last_hotkey") })
        config.general.showLastHotkey = ""
        #expect(!config.validationWarnings.contains { $0.contains("show_last_hotkey") })
        config.general.showLastHotkey = "option+semicolon"
        #expect(!config.validationWarnings.contains { $0.contains("show_last_hotkey") })
    }
}
