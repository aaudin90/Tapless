import Foundation
import Testing
import TapLessData
@testable import TapLessDomain

private func defaultConfig() -> AppConfig {
    FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
}

@Suite struct FillTests {
    @Test func substitutesKnownKeys() {
        #expect(TextTools.fill("{a} и {b}", ["a": "1", "b": "2"]) == "1 и 2")
    }

    @Test func unknownPlaceholderStays() {
        #expect(TextTools.fill("{a} {zzz}", ["a": "1"]) == "1 {zzz}")
    }

    @Test func substitutedValueIsNotRescanned() {
        for _ in 0..<20 {
            #expect(TextTools.fill("{a} {b}", ["a": "{b}", "b": "X"]) == "{b} X")
        }
    }
}

@Suite struct CleanTranscriptTests {
    @Test func removesServiceTokens() {
        #expect(TextTools.cleanTranscript("<|ru|> привет <|endoftext|>", dropPhrases: []) == "привет")
    }

    @Test func dropPhraseDoesNotCutWords() {
        let out = TextTools.cleanTranscript("Корректорский и Корректор тут", dropPhrases: ["Корректор"])
        #expect(out == "Корректорский и тут")
    }

    @Test func unicodeEllipsisMatchesDropPhrase() {
        let out = TextTools.cleanTranscript("Привет. Продолжение следует…", dropPhrases: ["Продолжение следует..."])
        #expect(out == "Привет.")
    }

    @Test func dropPhraseWithFlexibleSpaces() {
        let out = TextTools.cleanTranscript("ок продолжение   СЛЕДУЕТ... дальше", dropPhrases: ["Продолжение следует..."])
        #expect(out == "ок дальше")
    }

    @Test func punctuationOnlyIsEmpty() {
        #expect(TextTools.cleanTranscript(" ... ", dropPhrases: []) == "")
    }
}

@Suite struct CleanLLMOutputTests {
    @Test func stripsSingleFence() {
        #expect(TextTools.cleanLLMOutput("```\nтекст\n```\n", stripFences: true) == "текст")
    }

    @Test func stripsFenceWithLanguage() {
        #expect(TextTools.cleanLLMOutput("```text\nстрока 1\nстрока 2\n```", stripFences: true) == "строка 1\nстрока 2")
    }

    @Test func keepsMultipleBlocks() {
        let s = "```\nfoo\n```\n\nтекст\n```\nbar\n```"
        #expect(TextTools.cleanLLMOutput(s, stripFences: true) == s)
    }

    @Test func keepsSingleLineFence() {
        #expect(TextTools.cleanLLMOutput("```foo```", stripFences: true) == "```foo```")
    }

    @Test func disabledStripKeepsFences() {
        #expect(TextTools.cleanLLMOutput("```\nтекст\n```", stripFences: false) == "```\nтекст\n```")
    }

    @Test func removesTranscriptTags() {
        #expect(TextTools.cleanLLMOutput("<transcript>привет</transcript>", stripFences: true) == "привет")
    }
}

@Suite struct DictionaryTextTests {
    @Test func emptyDictionaryBlock() {
        let d = DictionaryConfig(terms: [:], notes: "  ")
        #expect(TextTools.dictionaryBlock(d) == "(словарь пуст)")
    }

    @Test func termsAreSortedTrimmedAndDeduplicated() {
        let d = DictionaryConfig(
            terms: ["kubernetes ": ["кубер", " Кубер", "", "кубернетес"], "Docker": [], " ": ["пусто"]],
            notes: " Автор — Go-разработчик. "
        )
        let block = TextTools.dictionaryBlock(d)
        #expect(block.contains("\n- Docker\n- kubernetes ← кубер, кубернетес\n\nПояснения: Автор — Go-разработчик."))
        #expect(!block.contains("пусто"))
    }

    @Test func defaultsGoToPrompt() {
        let block = TextTools.dictionaryBlock(defaultConfig().dictionary)
        #expect(block.contains("- Claude Code ← клод код, клауд код, cloud code"))
    }
}
