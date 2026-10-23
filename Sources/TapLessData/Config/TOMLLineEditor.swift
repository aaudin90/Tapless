import Foundation

/// Точечная правка TOML-файла пользователя по строкам: меняет или добавляет один ключ
/// простой таблицы `[table]`, не трогая комментарии, порядок и форматирование остального.
/// Полного разбора TOML здесь нет — итог проверяет вызывающий (`FileConfigRepository.setInteger`).
enum TOMLLineEditor {
    /// Ставит `key = value` в таблице `table`. `value` — готовый литерал TOML.
    /// Ключ есть — меняется только значение, комментарий в конце строки остаётся.
    /// Ключа нет — строка добавляется сразу после заголовка `[table]`. Таблицы нет — она дописывается в конец.
    static func setValue(_ value: String, forKey key: String, inTable table: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let header = try! NSRegularExpression(
            pattern: "^\\s*\\[\\s*\(NSRegularExpression.escapedPattern(for: table))\\s*\\]\\s*(#.*)?$")
        let anyHeader = try! NSRegularExpression(pattern: "^\\s*\\[")
        let keyLine = try! NSRegularExpression(
            pattern: "^(\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*)([^#]*?)(\\s*(#.*)?)$")

        func matches(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }

        guard let start = lines.firstIndex(where: { matches(header, $0) != nil }) else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            let tail = ["", "[\(table)]", "\(key) = \(value)", ""]
            return (lines.isEmpty ? Array(tail.dropFirst()) : lines + tail).joined(separator: "\n")
        }
        let end = lines[(start + 1)...].firstIndex { matches(anyHeader, $0) != nil } ?? lines.count
        for index in (start + 1)..<end {
            let line = lines[index]
            guard let match = matches(keyLine, line),
                  let prefix = Range(match.range(at: 1), in: line),
                  let suffix = Range(match.range(at: 3), in: line) else { continue }
            lines[index] = String(line[prefix]) + value + String(line[suffix])
            return lines.joined(separator: "\n")
        }
        lines.insert("\(key) = \(value)", at: start + 1)
        return lines.joined(separator: "\n")
    }
}
