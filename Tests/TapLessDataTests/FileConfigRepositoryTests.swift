import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

@Suite final class FileConfigRepositoryTests {
    /// Временные папки теста; удаляются в `deinit` (swift-testing создаёт экземпляр на каждый тест).
    private var directories: [URL] = []

    deinit {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRepository(_ toml: String?) throws -> FileConfigRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        let file = dir.appendingPathComponent("tapless.toml")
        if let toml {
            try toml.write(to: file, atomically: true, encoding: .utf8)
        }
        return FileConfigRepository(fileURL: file)
    }

    @Test func defaultsParse() {
        let config = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
        #expect(config.general.hotkey == "option+quote")
        #expect(config.general.showLastHotkey == "option+semicolon")
        #expect(config.general.mode == "toggle")
        #expect(config.llm.model == "haiku")
        #expect(config.llm.harness == "ollama")
        #expect(config.harnesses["ollama"]?.kind == .ollama)
        #expect(config.harnesses["ollama"]?.model == "gemma4:e4b-it-q4_K_M")
        #expect(config.harnesses["claude"]?.executable == "claude")
        #expect(config.harnesses["claude"]?.args.contains("{prompt_file}") == true)
        #expect(config.harnesses["claude"]?.schemaOutputPath == "structured_output")
        #expect(config.harnesses["claude"]?.args.contains("--safe-mode") == true)
        #expect(config.harnesses["codex"]?.kind == .codex)
        #expect(config.harnesses["codex"]?.executable == "codex")
        #expect(config.harnesses["codex"]?.model == "gpt-6-luna")
        #expect(config.harnesses["codex"]?.args.contains(#"model_instructions_file="{prompt_file}""#) == true)
        #expect(config.harnesses["codex"]?.schemaArgs == ["--output-schema", "{schema_file}"])
        #expect(config.schemas["text"]?.resultPath == "text")
        #expect(config.log.logLevel == .debug)
        #expect(!config.log.includeText)
        #expect(config.activeVariants.map(\.name) == ["Как сказал", "Деловое сообщение"])
        #expect(config.paste.autoSelect == 0)
        #expect(config.autoSelectKey == nil)
        #expect(config.runVariantKeys(autoSelectKey: nil) == [2, 3])
        #expect(config.dictionary.terms["Claude Code"]?.contains("клауд код") == true)
    }

    @Test func setIntegerReplacesValueAndKeepsComments() throws {
        let repository = try makeRepository("""
        # шапка
        [paste]
        restore_clipboard = false
        auto_select = 3   # из меню

        [ui]
        auto_select_note = 1
        """)
        try repository.setInteger(2, forKey: "auto_select", inTable: "paste")
        let text = try String(contentsOf: repository.fileURL, encoding: .utf8)
        #expect(text == """
        # шапка
        [paste]
        restore_clipboard = false
        auto_select = 2   # из меню

        [ui]
        auto_select_note = 1
        """)
    }

    @Test func setIntegerAddsKeyAndTable() throws {
        let withTable = try makeRepository("[paste] # вставка\nrestore_clipboard = false\n\n[ui]\nwidth = 700\n")
        try withTable.setInteger(2, forKey: "auto_select", inTable: "paste")
        #expect(try String(contentsOf: withTable.fileURL, encoding: .utf8)
                == "[paste] # вставка\nauto_select = 2\nrestore_clipboard = false\n\n[ui]\nwidth = 700\n")
        #expect(try withTable.load().config.autoSelectKey == 2)

        // Ключ в другой таблице и закомментированный ключ не трогаем: [paste] дописывается в конец.
        let withoutTable = try makeRepository("[ui]\nwidth = 700\n# [paste]\n# auto_select = 0\n\n")
        try withoutTable.setInteger(3, forKey: "auto_select", inTable: "paste")
        #expect(try String(contentsOf: withoutTable.fileURL, encoding: .utf8)
                == "[ui]\nwidth = 700\n# [paste]\n# auto_select = 0\n\n[paste]\nauto_select = 3\n")
        #expect(try withoutTable.load().config.paste.autoSelect == 3)
    }

    @Test func setIntegerCreatesTemplateWhenFileIsMissing() throws {
        let repository = try makeRepository(nil)
        try repository.setInteger(2, forKey: "auto_select", inTable: "paste")
        let loaded = try repository.load()
        #expect(loaded.config.autoSelectKey == 2)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func setIntegerLeavesFileWhenResultIsWrong() throws {
        let original = "paste = { auto_paste = true }\n"
        let repository = try makeRepository(original)
        #expect(throws: ConfigError.self) {
            try repository.setInteger(2, forKey: "auto_select", inTable: "paste")
        }
        #expect(try String(contentsOf: repository.fileURL, encoding: .utf8) == original)
    }

    @Test func missingFileGivesDefaults() throws {
        let repository = try makeRepository(nil)
        let loaded = try repository.load()
        #expect(loaded.config == repository.defaults())
        #expect(loaded.warnings.isEmpty)
    }

    @Test func fileOverridesDefaults() throws {
        let repository = try makeRepository("""
        [general]
        hotkey = "ctrl+shift+d"

        [llm]
        model = "sonnet"

        [llm.env]
        ANTHROPIC_API_KEY = "test"

        [dictionary.terms]
        "JSON" = ["джейсон"]
        """)
        let defaults = repository.defaults()
        let config = try repository.load().config

        #expect(config.general.hotkey == "ctrl+shift+d")
        #expect(config.llm.model == "sonnet")
        // Остальные ключи секций берутся из значений по умолчанию.
        #expect(config.general.mode == defaults.general.mode)
        #expect(config.llm.harness == defaults.llm.harness)
        #expect(config.llm.env["ANTHROPIC_API_KEY"] == "test")
        // Таблицы сливаются по ключам.
        #expect(config.dictionary.terms["JSON"] == ["джейсон"])
        #expect(config.dictionary.terms["Claude Code"] == defaults.dictionary.terms["Claude Code"])
        #expect(config.variants == defaults.variants)
    }

    @Test func arraysReplaceDefaults() throws {
        let repository = try makeRepository("""
        [stt]
        drop_phrases = ["Конец"]
        """)
        let config = try repository.load().config
        #expect(config.stt.dropPhrases == ["Конец"])
    }

    /// Прежний формат словаря: массив terms заменяет термины по умолчанию, без вариантов распознавания.
    @Test func legacyTermsArrayStillParses() throws {
        let repository = try makeRepository("""
        [dictionary]
        terms = ["Kotlin", "Go"]
        """)
        let loaded = try repository.load()
        #expect(loaded.config.dictionary.terms == ["Kotlin": [], "Go": []])
        #expect(loaded.warnings.isEmpty)
    }

    /// Удалённые ключи regex-замен и подсказки из словаря — предупреждения, не ошибка.
    @Test func removedDictionaryKeysWarn() throws {
        let repository = try makeRepository("""
        [stt]
        prompt_from_dictionary = true

        [dictionary]
        apply_locally = true

        [dictionary.replace]
        "кубер" = "Kubernetes"
        """)
        let warnings = try repository.load().warnings.joined(separator: "\n")
        #expect(warnings.contains("stt.prompt_from_dictionary"))
        #expect(warnings.contains("dictionary.apply_locally"))
        #expect(warnings.contains("dictionary.replace"))
    }

    @Test func variantKeysOverrideAndNewNumbersAdd() throws {
        let defaults = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
        let repository = try makeRepository("""
        [variants.2]
        prompt = "Мой промпт."

        [variants.10]
        prompt = "Десятый."

        [variants.3]
        prompt = "Переведи на английский."
        model = "sonnet"
        """)
        let loaded = try repository.load()
        let variants = loaded.config.variants
        #expect(loaded.warnings.isEmpty)
        #expect(variants.map(\.name) == ["Как сказал", "Деловое сообщение", "Вариант 3", "Вариант 10"])
        #expect(variants[0] == defaults.variants[0])
        #expect(variants[1].prompt == "Мой промпт.")
        #expect(variants[2].model == "sonnet")
        #expect(variants[2].enabled)
        #expect(variants[2].harness == nil)
    }

    @Test func variantCanBeDisabled() throws {
        let repository = try makeRepository("[variants.1]\nenabled = false")
        let config = try repository.load().config
        #expect(config.activeVariants.map(\.name) == ["Деловое сообщение"])
    }

    @Test func badVariantNumberIsError() throws {
        for toml in ["[variants.abc]\nprompt = \"p\"", "[variants.0]\nprompt = \"p\"",
                     "[variants.01]\nprompt = \"p\"", "[variants.\"+3\"]\nprompt = \"p\""] {
            let repository = try makeRepository(toml)
            #expect(throws: ConfigError.self) { try repository.load() }
        }
    }

    @Test func newVariantWithoutPromptIsError() throws {
        let repository = try makeRepository("[variants.3]\nname = \"Пусто\"")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error.localizedDescription.contains("variants.3: не задан prompt"))
        }
    }

    @Test func oldVariantsArrayIsError() throws {
        for toml in ["[[variants]]\nprompt = \"p\"", "[variants]\nprompt = \"p\""] {
            let repository = try makeRepository(toml)
            do {
                _ = try repository.load()
                Issue.record("ожидалась ошибка")
            } catch {
                #expect(error.localizedDescription.contains("[variants.1]"))
            }
        }
    }

    @Test func variantNumbersMayHaveGapsAndKeysFollowOrder() throws {
        let repository = try makeRepository("""
        [ui]
        show_raw = false

        [variants.7]
        prompt = "семь"

        [variants.2]
        enabled = false
        """)
        let config = try repository.load().config
        #expect(config.variants.map(\.name) == [config.variants[0].name, config.variants[1].name, "Вариант 7"])
        #expect(config.activeVariants.map(\.prompt).last == "семь")
        #expect(config.rawTextKey == nil)
        #expect(config.firstVariantKey == 1)
        #expect(config.activeVariants.count == 2)
    }

    @Test func unknownKeysProduceWarnings() throws {
        let repository = try makeRepository("""
        hotkey = "ctrl+d"

        [general]
        hotky = "ctrl+d"

        [llm.env]
        ANY_NAME = "ok"

        [variants.3]
        name = "A"
        prompt = "B"
        nmae = "C"
        """)
        let warnings = try repository.load().warnings
        #expect(warnings.count == 3)
        #expect(warnings.contains { $0.contains("«hotkey»") })
        #expect(warnings.contains { $0.contains("«general.hotky»") })
        #expect(warnings.contains { $0.contains("«variants.3.nmae»") })
    }

    @Test func syntaxErrorThrows() throws {
        let repository = try makeRepository("[general\nhotkey = ")
        #expect(throws: ConfigError.self) { try repository.load() }
    }

    @Test func wrongTypeThrowsWithPath() throws {
        let repository = try makeRepository("[ui]\nwidth = \"wide\"")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error.localizedDescription.contains("ui.width"))
        }
    }

    @Test func templateIsCreatedOnceAndChangesNothing() throws {
        let repository = try makeRepository(nil)
        #expect(try repository.saveTemplateIfMissing())
        #expect(try !repository.saveTemplateIfMissing())

        let text = try String(contentsOf: repository.fileURL, encoding: .utf8)
        #expect(text.contains("# hotkey = \"option+quote\""))
        let loaded = try repository.load()
        #expect(loaded.config == repository.defaults())
        #expect(loaded.warnings.isEmpty)
    }

    @Test func existingFileIsNotOverwritten() throws {
        let original = "[llm]\nmodel = \"opus\"\n"
        let repository = try makeRepository(original)
        #expect(try !repository.saveTemplateIfMissing())
        #expect(try String(contentsOf: repository.fileURL, encoding: .utf8) == original)
    }

    @Test func hexNumberGivesClearError() throws {
        let repository = try makeRepository("[ui]\nwidth = 0x280")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error is ConfigError)
            #expect(error.localizedDescription.contains("шестнадцатеричные"))
            #expect(error.localizedDescription.contains("десятичные"))
        }
    }

    @Test func nanGivesClearError() throws {
        let repository = try makeRepository("[llm]\ntimeout_seconds = nan")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error is ConfigError)
            #expect(error.localizedDescription.contains("nan"))
        }
    }

    @Test func defaultsHaveNoWarnings() {
        let repository = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent"))
        #expect(repository.defaults().validationWarnings.isEmpty)
    }

    @Test func unknownModeWarns() throws {
        let repository = try makeRepository("[general]\nmode = \"holdd\"")
        let warnings = try repository.load().warnings
        #expect(warnings == ["general.mode = \"holdd\": ожидается \"toggle\" или \"hold\" — используется \"toggle\"."])
    }

    @Test func modeIsCaseInsensitive() throws {
        let repository = try makeRepository("[general]\nmode = \"HOLD\"")
        #expect(try repository.load().warnings.isEmpty)
    }

    @Test func unknownPositionWarns() throws {
        let repository = try makeRepository("[ui]\nposition = \"bottom\"")
        let warnings = try repository.load().warnings
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("ui.position = \"bottom\""))
    }

    @Test func tooManyVariantsWarns() throws {
        let variants = (1...11).map { "[variants.\($0)]\nprompt = \"p\($0)\"" }.joined(separator: "\n")
        let repository = try makeRepository(variants)
        let warnings = try repository.load().warnings
        #expect(warnings == ["Включено 11 вариантов, используются первые 8 (клавиши 2–9)."])
    }

    @Test func noEnabledVariantsWarns() throws {
        let repository = try makeRepository("[variants.1]\nenabled = false\n\n[variants.2]\nenabled = false")
        let warnings = try repository.load().warnings
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("только сырой текст (клавиша 1)"))
    }

    @Test func noVariantsAndNoRawWarnsAboutNothingToChoose() throws {
        let repository = try makeRepository("[ui]\nshow_raw = false\n\n[variants.1]\nenabled = false\n\n[variants.2]\nenabled = false")
        let warnings = try repository.load().warnings
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("выбирать будет нечего"))
    }

    // MARK: - Harness и схемы

    @Test func harnessParallel() throws {
        let defaults = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
        #expect(defaults.harnesses["ollama"]?.parallel == 3)
        #expect(defaults.harnesses["claude"]?.parallel == 0)

        let config = try makeRepository("[harness.ollama]\nparallel = 2").load().config
        #expect(config.harnesses["ollama"]?.parallel == 2)
        #expect(config.ollamaTargets.first?.parallel == 2)

        let negative = try makeRepository("[harness.ollama]\nparallel = -1")
        do {
            _ = try negative.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error.localizedDescription.contains("harness.ollama.parallel = -1"))
        }
    }

    @Test func harnessKeyOverrideKeepsOtherKeys() throws {
        let repository = try makeRepository("""
        [harness.claude]
        executable = "claude-proxy"

        [harness.claude.env]
        HTTPS_PROXY = "http://proxy:8080"
        """)
        let defaults = repository.defaults().harnesses["claude"]
        let loaded = try repository.load()
        let claude = try #require(loaded.config.harnesses["claude"])
        #expect(claude.executable == "claude-proxy")
        #expect(claude.args == defaults?.args)
        #expect(claude.textArgs == defaults?.textArgs)
        #expect(claude.env["HTTPS_PROXY"] == "http://proxy:8080")
        #expect(claude.env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == defaults?.env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        #expect(loaded.warnings.isEmpty)
    }

    @Test func codexExecutableOverrideKeepsType() throws {
        let repository = try makeRepository("[harness.codex]\nexecutable = \"codex-proxy\"")
        let loaded = try repository.load()
        let codex = try #require(loaded.config.harnesses["codex"])
        #expect(codex.kind == .codex)
        #expect(codex.executable == "codex-proxy")
        #expect(codex.args == repository.defaults().harnesses["codex"]?.args)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func codexVerifyMode() throws {
        let repository = try makeRepository("[harness.codex]\nverify = \"block\"")
        #expect(try repository.load().config.harnesses["codex"]?.verify == .block)
        #expect(repository.defaults().harnesses["codex"]?.verify == .warn)
        do {
            _ = try makeRepository("[harness.codex]\nverify = \"never\"").load()
            Issue.record("ожидалась ошибка конфига")
        } catch {
            #expect(error.localizedDescription.contains("harness.codex.verify"))
        }
    }

    @Test func codexHarnessNeedsExecutable() throws {
        let repository = try makeRepository("[harness.my]\ntype = \"codex\"")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка конфига")
        } catch {
            #expect(error.localizedDescription.contains("harness.my: не задан executable"))
        }
    }

    @Test func newHarnessNeedsOnlyExecutable() throws {
        let repository = try makeRepository("""
        [llm]
        harness = "echo"

        [harness.echo]
        executable = "cat"
        """)
        let loaded = try repository.load()
        #expect(loaded.config.harnesses["echo"] == HarnessConfig(executable: "cat", args: []))
        #expect(loaded.config.harnesses["claude"] != nil)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func unknownHarnessAndSchemaKeysWarn() throws {
        let repository = try makeRepository("""
        [harness.claude]
        exectable = "x"

        [harness.my]
        executable = "my"
        argz = []

        [harness.my.env]
        ANY = "ok"

        [schemas.s]
        json = "{}"
        result = "text"
        """)
        let warnings = try repository.load().warnings
        #expect(warnings.contains { $0.contains("«harness.claude.exectable»") })
        #expect(warnings.contains { $0.contains("«harness.my.argz»") })
        #expect(warnings.contains { $0.contains("«schemas.s.result»") })
        #expect(!warnings.contains { $0.contains("ANY") })
    }

    @Test func badHarnessInputIsError() throws {
        let repository = try makeRepository("[harness.claude]\ninput = \"file\"")
        do {
            _ = try repository.load()
            Issue.record("ожидалась ошибка")
        } catch {
            #expect(error.localizedDescription.contains("harness.claude.input"))
            #expect(error.localizedDescription.contains("\"stdin\" или \"arg\""))
        }
    }

    @Test func variantHarnessAndSchemaAreParsedAndChecked() throws {
        let repository = try makeRepository("""
        [variants.1]
        name = "A"
        prompt = "a"
        harness = "opencode"
        schema = "text"

        [variants.2]
        name = "B"
        prompt = "b"
        harness = "nope"
        schema = "missing"
        """)
        let loaded = try repository.load()
        #expect(loaded.config.variants[0].harness == "opencode")
        #expect(loaded.config.variants[0].schema == "text")
        let warnings = loaded.warnings
        // opencode без schema_args: схема в программу не передаётся.
        #expect(warnings.contains { $0.contains("«A»") && $0.contains("schema_args") })
        #expect(warnings.contains { $0.contains("«B»") && $0.contains("[harness.nope]") })
        #expect(warnings.contains { $0.contains("«B»") && $0.contains("[schemas.missing]") })
    }

    @Test func unknownDefaultHarnessAndLogLevelWarn() throws {
        let repository = try makeRepository("[llm]\nharness = \"gemini\"\n\n[log]\nlevel = \"verbose\"")
        let warnings = try repository.load().warnings
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.contains("llm.harness = \"gemini\"") })
        #expect(warnings.contains { $0.contains("log.level = \"verbose\"") })
    }

    @Test func argInputWithoutPlaceholderWarns() throws {
        let repository = try makeRepository("[harness.x]\nexecutable = \"x\"\ninput = \"arg\"")
        let warnings = try repository.load().warnings
        #expect(warnings == ["harness.x: input = \"arg\", но в аргументах нет {input} — текст до программы не дойдёт."])
    }
}
