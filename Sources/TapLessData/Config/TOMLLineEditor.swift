import Foundation

/// Точечная правка TOML-файла пользователя по строкам: меняет или добавляет один ключ
/// простой таблицы `[table]`, не трогая комментарии, порядок и форматирование остального.
/// Полного разбора TOML здесь нет — итог проверяет вызывающий (`FileConfigRepository.setValue`).
enum TOMLLineEditor {
    /// Строка как базовый литерал TOML: `"` и `\` экранируются, управляющие символы — тоже.
    static func stringLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Ставит `key = value` в таблице `table`. `value` — готовый литерал TOML.
    /// Ключ есть — меняется только значение, комментарий в конце строки остаётся.
    /// Ключа нет — строка добавляется сразу после заголовка `[table]`. Таблицы нет — она дописывается в конец.
    /// Концы строк (`\n` или `\r\n`) сохраняются; новые строки получают тот конец, что в файле.
    static func setValue(_ value: String, forKey key: String, inTable table: String, in text: String) -> String {
        let crlf = text.contains("\r\n")
        let newline = crlf ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        let header = try! NSRegularExpression(
            pattern: "^\\s*\\[\\s*\(NSRegularExpression.escapedPattern(for: table))\\s*\\]\\s*(#.*)?$")
        let anyHeader = try! NSRegularExpression(pattern: "^\\s*\\[")
        let keyLine = try! NSRegularExpression(
            pattern: "^(\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^#]*?)(\\s*(#.*)?)$")

        /// Строка без конечного `\r` (его `.` и `$` в регулярных выражениях не берут).
        func body(_ line: String) -> String {
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        func matches(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            let line = body(line)
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }

        guard let start = lines.firstIndex(where: { matches(header, $0) != nil }) else {
            while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
            let tail = [newline, "[\(table)]" + newline, "\(key) = \(value)" + newline, ""]
            return (lines.isEmpty ? Array(tail.dropFirst()) : lines + tail).joined(separator: "\n")
        }
        let end = lines[(start + 1)...].firstIndex { matches(anyHeader, $0) != nil } ?? lines.count
        for index in (start + 1)..<end {
            let line = body(lines[index])
            guard let match = matches(keyLine, line),
                  let prefix = Range(match.range(at: 1), in: line),
                  let suffix = Range(match.range(at: 3), in: line) else { continue }
            lines[index] = String(line[prefix]) + value + String(line[suffix]) + (lines[index].hasSuffix("\r") ? "\r" : "")
            return lines.joined(separator: "\n")
        }
        lines.insert("\(key) = \(value)" + newline, at: start + 1)
        return lines.joined(separator: "\n")
    }
}
