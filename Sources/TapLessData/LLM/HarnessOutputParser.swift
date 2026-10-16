import Foundation
import TapLessDomain

/// Достаёт текст ответа из stdout harness.
///
/// JSON-ответ может быть объектом, массивом событий (`claude -p --output-format json`
/// в подробном режиме) или JSON Lines (по объекту на строку). Путь — ключи через точку,
/// индексы массивов — числами. Если на пути встречается массив, а компонент пути не число,
/// ищется последний элемент массива, в котором путь есть.
enum HarnessOutputParser {
    /// - Parameters:
    ///   - path: где в ответе лежит результат. Пусто — весь ответ.
    ///   - resultPath: путь внутри результата (поле объекта по схеме). Пусто — весь результат.
    static func extract(from stdout: String, format: HarnessOutput, path: String, resultPath: String) throws -> String {
        if format == .text { return stdout }

        guard let root = parse(stdout) else {
            throw LLMError.badOutput("ожидался JSON")
        }
        guard var value = lookup(root, components(path)) else {
            throw LLMError.badOutput("в JSON нет «\(path)»")
        }
        if !resultPath.isEmpty {
            // Некоторые программы отдают объект по схеме строкой с JSON.
            if let string = value as? String, let nested = parse(string) { value = nested }
            guard let nested = lookup(value, components(resultPath)) else {
                throw LLMError.badOutput("в ответе нет поля «\(resultPath)»")
            }
            value = nested
        }
        return render(value)
    }

    /// JSON целиком или JSON Lines (массив из разобранных строк).
    static func parse(_ text: String) -> Any? {
        let data = Data(text.utf8)
        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return value
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let values = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        return values.isEmpty || values.count < lines.count ? nil : values
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    static func lookup(_ value: Any, _ path: [String]) -> Any? {
        guard let key = path.first else { return value is NSNull ? nil : value }
        let rest = Array(path.dropFirst())
        if let object = value as? [String: Any] {
            return object[key].flatMap { lookup($0, rest) }
        }
        if let array = value as? [Any] {
            if let index = Int(key) {
                let resolved = index < 0 ? array.count + index : index
                guard array.indices.contains(resolved) else { return nil }
                return lookup(array[resolved], rest)
            }
            for element in array.reversed() {
                if let found = lookup(element, path) { return found }
            }
        }
        return nil
    }

    /// Строка — как есть, остальное — JSON с отступами.
    static func render(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
