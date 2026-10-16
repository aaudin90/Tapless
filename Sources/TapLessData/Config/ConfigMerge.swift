import Foundation

/// Слияние конфигов на уровне TOML-таблиц (после перевода в JSON-словари).
enum ConfigMerge {
    /// Таблицы со свободными ключами: их ключи не сверяются со значениями по умолчанию.
    static let freeFormTables: Set<String> = ["llm.env", "dictionary.terms"]

    /// Таблицы со свободными именами записей: `[variants.<номер>]`, `[harness.<имя>]`, `[schemas.<имя>]`.
    /// Ключи внутри записи сверяются со списком допустимых.
    private static let namedTables: [String: (keys: Set<String>, freeForm: Set<String>)] = [
        "variants": (ConfigDTO.variantKeys, []),
        "harness": (ConfigDTO.harnessKeys, ["env", "options"]),
        "schemas": (ConfigDTO.schemaKeys, []),
    ]

    /// Накладывает `overlay` на `base`: таблицы сливаются по ключам рекурсивно,
    /// остальные значения (строки, числа, массивы) из `overlay` заменяют значения `base` целиком.
    static func merge(_ base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let baseTable = base[key] as? [String: Any], let overlayTable = value as? [String: Any] {
                result[key] = merge(baseTable, overlay: overlayTable)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Ключи из `user`, которых нет в значениях по умолчанию. Обычно это опечатка
    /// или ключ без заголовка своей секции. Пути вида `general.hotkey`, `variants.2.nmae`,
    /// `harness.claude.exectable`.
    static func unknownKeys(in user: [String: Any], defaults: [String: Any], path: String = "") -> [String] {
        var found: [String] = []
        for key in user.keys.sorted() {
            let full = path.isEmpty ? key : "\(path).\(key)"
            if freeFormTables.contains(full) { continue }

            if let named = namedTables[full], let entries = user[key] as? [String: Any] {
                for name in entries.keys.sorted() {
                    guard let entry = entries[name] as? [String: Any] else { continue }
                    for entryKey in entry.keys.sorted()
                    where !named.keys.contains(entryKey) && !named.freeForm.contains(entryKey) {
                        found.append("\(full).\(name).\(entryKey)")
                    }
                }
                continue
            }

            guard let defaultValue = defaults[key] else {
                found.append(full)
                continue
            }
            if let userTable = user[key] as? [String: Any], let defaultTable = defaultValue as? [String: Any] {
                found += unknownKeys(in: userTable, defaults: defaultTable, path: full)
            }
        }
        return found
    }
}
