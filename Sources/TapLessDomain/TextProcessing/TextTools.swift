import Foundation

/// Обработка текста: словарь, замены, чистка расшифровки и ответа модели.
public enum TextTools {
    /// Подстановка {key} → value за один проход: подставленный текст повторно не сканируется,
    /// плейсхолдеры с неизвестным ключом остаются как есть.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{([a-z_]+)\\}") else { return template }
        let ns = template as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            result += values[key] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Словарь

    /// Блок словаря для системного промпта ({dictionary}).
    static func dictionaryBlock(_ d: DictionaryConfig) -> String {
        var parts: [String] = []

        let terms = unique(d.terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !terms.isEmpty {
            parts.append("Пиши именно так: " + terms.joined(separator: ", "))
        }

        let pairs = d.replace
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.key < $1.key }
        if !pairs.isEmpty {
            let lines = pairs.map { "- «\($0.key)» → \($0.value)" }.joined(separator: "\n")
            parts.append("Частые ошибки распознавания → как правильно:\n" + lines)
        }

        let notes = d.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("Пояснения: " + notes)
        }

        return parts.isEmpty ? "(словарь пуст)" : parts.joined(separator: "\n\n")
    }

    /// Подсказка для Whisper: initial_prompt + правильные написания терминов
    /// (обрезаются по краям, дубликаты без учёта регистра убираются).
    static func whisperPrompt(stt: STTConfig, dictionary: DictionaryConfig) -> String {
        var pieces: [String] = []
        let initial = stt.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !initial.isEmpty { pieces.append(initial) }
        if stt.promptFromDictionary {
            let raw = dictionary.terms + dictionary.replace.values.sorted()
            let terms = unique(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            if !terms.isEmpty { pieces.append(terms.joined(separator: ", ") + ".") }
        }
        return pieces.joined(separator: " ")
    }

    /// Замены «как слышится» → «как писать»: без учёта регистра, только целые слова,
    /// пробелы и дефисы внутри фразы — любые. Один проход одним regex: результат одной замены
    /// другой не переписывается. Ключи упорядочены по длине (длинные первыми), затем по алфавиту —
    /// результат детерминирован. Если ключи различаются только регистром, побеждает первый.
    /// Значение вставляется буквально.
    static func applyReplacements(_ text: String, _ map: [String: String]) -> String {
        var patterns: [String] = []
        var values: [String] = []
        let keys = map.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        for key in keys {
            let words = key.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            patterns.append("(" + words.joined(separator: "[\\s\\-]+") + ")")
            values.append(map[key] ?? "")
        }
        guard !patterns.isEmpty else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + patterns.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let index = (1...patterns.count).first(where: { m.range(at: $0).location != NSNotFound }) else { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += values[index - 1]
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Чистка

    /// Убирает служебные токены, «галлюцинации» и лишние пробелы из ответа Whisper.
    /// Фразы из dropPhrases ищутся без учёта регистра и по границам слов (если фраза начинается
    /// или заканчивается буквой/цифрой); пробелы внутри фразы — любые, «...» совпадает и с «…».
    static func cleanTranscript(_ text: String, dropPhrases: [String]) -> String {
        var t = text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: " ", options: .regularExpression)
        for phrase in dropPhrases {
            guard let regex = dropRegex(for: phrase) else { continue }
            t = regex.stringByReplacingMatches(
                in: t, options: [], range: NSRange(location: 0, length: (t as NSString).length),
                withTemplate: " "
            )
        }
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Только знаки препинания — значит, ничего не сказано.
        if t.rangeOfCharacter(from: .alphanumerics) == nil { return "" }
        return t
    }

    private static func dropRegex(for phrase: String) -> NSRegularExpression? {
        let normalized = phrase.replacingOccurrences(of: "…", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = normalized.first, let last = normalized.last else { return nil }
        let words = normalized.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = words.joined(separator: "\\s+")
            .replacingOccurrences(of: "\\.\\.\\.", with: "(?:\\.\\.\\.|…)")
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        let pattern = (isWord(first) ? "(?<![\\p{L}\\p{N}])" : "")
            + body
            + (isWord(last) ? "(?![\\p{L}\\p{N}])" : "")
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Чистит ответ модели: обёртку ```…```, эхо тегов <transcript>, пробелы по краям.
    static func cleanLLMOutput(_ text: String, stripFences: Bool) -> String {
        var t = text.replacingOccurrences(of: "</?transcript>", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripFences { t = stripCodeFences(t) }
        return t
    }

    /// Снимает внешние ограды ```…```, только если это один блок: первая строка начинается с ```,
    /// последняя равна ```, внутри строк с ``` нет. Ответ из нескольких блоков не трогает.
    static func stripCodeFences(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = t.components(separatedBy: "\n")
        guard lines.count >= 3,
              lines[0].hasPrefix("```"),
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
              !lines[1..<(lines.count - 1)].contains(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
              }) else { return t }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where !item.isEmpty && !seen.contains(item.lowercased()) {
            seen.insert(item.lowercased())
            out.append(item)
        }
        return out
    }
}
