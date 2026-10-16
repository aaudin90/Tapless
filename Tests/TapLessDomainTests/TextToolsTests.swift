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

@Suite struct ApplyReplacementsTests {
    @Test func wholeWordsOnly() {
        #expect(TextTools.applyReplacements("клоды и клод", ["клод": "Claude"]) == "клоды и Claude")
    }

    @Test func caseInsensitive() {
        #expect(TextTools.applyReplacements("КЛОД", ["клод": "Claude"]) == "Claude")
    }

    @Test func phraseWithAnySeparators() {
        let map = ["клауд код": "Claude Code"]
        #expect(TextTools.applyReplacements("клауд код", map) == "Claude Code")
        #expect(TextTools.applyReplacements("клауд-код", map) == "Claude Code")
        #expect(TextTools.applyReplacements("клауд   \n код", map) == "Claude Code")
    }

    @Test func hyphenatedKeyMatchesSpace() {
        let map = ["кто-то": "someone"]
        #expect(TextTools.applyReplacements("кто то и кто-то", map) == "someone и someone")
    }

    @Test func noRepeatedReplacement() {
        let map = ["клауд код": "Claude Code", "claude": "X", "code": "CODE"]
        #expect(TextTools.applyReplacements("код клауд код", map) == "код Claude Code")
    }

    @Test func deterministicForEqualLength() {
        #expect(TextTools.applyReplacements("a b", ["a": "b", "b": "c"]) == "b c")
    }

    @Test func specialCharactersAreLiteral() {
        let map = ["c++": "$1\\n", "a.b": "$0"]
        #expect(TextTools.applyReplacements("c++ и a.b и axb", map) == "$1\\n и $0 и axb")
    }

    @Test func emptyKeysAndMapAreSkipped() {
        #expect(TextTools.applyReplacements("текст", ["": "x", " - ": "y"]) == "текст")
        #expect(TextTools.applyReplacements("текст", [:]) == "текст")
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
        let d = DictionaryConfig(terms: [], replace: [:], applyLocally: true, notes: "")
        #expect(TextTools.dictionaryBlock(d) == "(словарь пуст)")
    }

    @Test func whisperPromptTrimsAndDeduplicates() {
        var config = defaultConfig()
        config.stt.initialPrompt = ""
        config.stt.promptFromDictionary = true
        config.dictionary.terms = [" Kubernetes", "Kubernetes ", "swift"]
        config.dictionary.replace = ["кубер": "kubernetes\n", "": "  "]
        let prompt = TextTools.whisperPrompt(stt: config.stt, dictionary: config.dictionary)
        #expect(prompt == "Kubernetes, swift.")
    }

    @Test func whisperPromptWithoutDictionary() {
        var config = defaultConfig()
        config.stt.initialPrompt = " Привет. "
        config.stt.promptFromDictionary = false
        config.dictionary.terms = ["Kubernetes"]
        #expect(TextTools.whisperPrompt(stt: config.stt, dictionary: config.dictionary) == "Привет.")
    }
}
