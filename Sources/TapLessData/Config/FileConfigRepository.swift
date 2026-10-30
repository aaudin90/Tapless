import Foundation
import TapLessDomain
import TOMLKit

enum ConfigError: LocalizedError {
    case syntax(String)
    case schema(String)
    case io(String)
    case unsupportedValue(String)

    var errorDescription: String? {
        switch self {
        case .syntax(let s): return "Ошибка синтаксиса TOML: \(s)"
        case .schema(let s): return "Ошибка в значениях конфига: \(s)"
        case .io(let s): return "Не удалось прочитать конфиг: \(s)"
        case .unsupportedValue(let s):
            return "Неподдерживаемое значение в TOML: шестнадцатеричные (0x…), восьмеричные (0o…) и двоичные (0b…) числа, а также nan, inf и -inf не поддерживаются — используйте десятичные числа. Подробности: \(s)"
        }
    }
}

/// Конфиг = встроенные значения по умолчанию (config.default.toml → DefaultConfig)
/// + пользовательский TOML-файл поверх них. Файл хранит только переопределения;
/// приложение его не перезаписывает, только создаёт шаблон при первом запуске. Исключение —
/// одна строка `paste.auto_select`, `general.microphone` или `general.voice_processing` из меню
/// (`setInteger` / `setString`). Запись идёт в цель симлинка, если файл — ссылка.
public struct FileConfigRepository: ConfigRepository {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func defaults() -> AppConfig {
        do {
            return try Self.decode(Self.defaultTable())
        } catch {
            fatalError("Встроенный config.default.toml не разбирается: \(error.localizedDescription)")
        }
    }

    public func load() throws -> LoadedConfig {
        let defaults = Self.defaultTable()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let config = try Self.decode(defaults)
            return LoadedConfig(config: config, warnings: config.validationWarnings)
        }

        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ConfigError.io(error.localizedDescription)
        }
        let user = try Self.table(fromTOML: text)
        // [[variants]] — старый формат; [variants] с ключами без номера — частая опечатка.
        if user["variants"] is [Any]
            || (user["variants"] as? [String: Any])?.values.contains(where: { !($0 is [String: Any]) }) == true {
            throw ConfigError.schema("варианты задаются таблицами с номером: [variants.1], [variants.2]…, а не [[variants]]")
        }

        let warnings = ConfigMerge.unknownKeys(in: user, defaults: defaults)
            .map { "Неизвестный ключ «\($0)» — не используется. Проверьте имя и заголовок секции." }
        let config = try Self.decode(ConfigMerge.merge(defaults, overlay: user))
        return LoadedConfig(config: config, warnings: warnings + config.validationWarnings)
    }

    @discardableResult
    public func saveTemplateIfMissing() throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return false }
        let target = writeTarget
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = (fileURL.path as NSString).abbreviatingWithTildeInPath
        let template = ConfigTemplate.make(defaultsTOML: DefaultConfig.toml, filePath: path)
        try template.write(to: target, atomically: true, encoding: .utf8)
        return true
    }

    public func setInteger(_ value: Int, forKey key: String, inTable table: String) throws {
        try setValue(String(value), forKey: key, inTable: table, description: "\(table).\(key) = \(value)") {
            $0 as? Int == value
        }
    }

    public func setString(_ value: String, forKey key: String, inTable table: String) throws {
        try setValue(TOMLLineEditor.stringLiteral(value), forKey: key, inTable: table,
                     description: "\(table).\(key) = \"\(value)\"") {
            $0 as? String == value
        }
    }

    /// Ставит `key = literal` в файле пользователя; `isExpected` проверяет значение в разобранном итоге.
    private func setValue(_ literal: String, forKey key: String, inTable table: String, description: String,
                          isExpected: (Any?) -> Bool) throws {
        try saveTemplateIfMissing()
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ConfigError.io(error.localizedDescription)
        }
        let updated = TOMLLineEditor.setValue(literal, forKey: key, inTable: table, in: text)
        // Правка строк не понимает всего TOML (например, inline-таблицы): проверяем итог разбором.
        let parsed = try Self.table(fromTOML: updated)
        guard isExpected((parsed[table] as? [String: Any])?[key]) else {
            throw ConfigError.schema("не удалось записать \(description): поправьте файл вручную")
        }
        try write(updated)
    }

    /// Файл, в который идёт запись: цель симлинка, а не сам симлинк. Атомарная запись по пути
    /// симлинка заменила бы его обычным файлом и сломала dotfiles (stow, chezmoi).
    private var writeTarget: URL {
        fileURL.resolvingSymlinksInPath()
    }

    /// Атомарно записывает файл пользователя: временный файл создаётся рядом с целью симлинка,
    /// права прежнего файла сохраняются.
    private func write(_ text: String) throws {
        let target = writeTarget
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
        } catch {
            throw ConfigError.io(error.localizedDescription)
        }
    }

    // MARK: - Разбор

    private static func defaultTable() -> [String: Any] {
        do {
            return try table(fromTOML: DefaultConfig.toml)
        } catch {
            fatalError("Встроенный config.default.toml не разбирается: \(error.localizedDescription)")
        }
    }

    /// TOML → словарь через JSON (TOMLKit умеет конвертировать таблицу в JSON).
    static func table(fromTOML text: String) throws -> [String: Any] {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            throw ConfigError.syntax(String(describing: error))
        }
        let json = table.convert(to: .json)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            // TOMLKit отдаёт 0x10, 0o7, 0b101, nan и inf как есть — это невалидный JSON.
            throw ConfigError.unsupportedValue(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ConfigError.syntax("не удалось разобрать таблицу верхнего уровня")
        }
        return dictionary
    }

    static func decode(_ table: [String: Any]) throws -> AppConfig {
        do {
            let data = try JSONSerialization.data(withJSONObject: table)
            return try JSONDecoder().decode(ConfigDTO.self, from: data).domain()
        } catch let error as ConfigError {
            throw error
        } catch let error as DecodingError {
            throw ConfigError.schema(describe(error))
        } catch {
            throw ConfigError.schema(error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map { key -> String in
                if let i = key.intValue { return "[\(i)]" }
                return key.stringValue
            }.joined(separator: ".")
            return p.isEmpty ? "(корень)" : p
        }
        switch error {
        case .typeMismatch(let type, let ctx):
            return "\(path(ctx)): неверный тип, ожидается \(type)"
        case .valueNotFound(let type, let ctx):
            return "\(path(ctx)): нет значения типа \(type)"
        case .keyNotFound(let key, let ctx):
            return "\(path(ctx)): нет ключа \(key.stringValue)"
        case .dataCorrupted(let ctx):
            return "\(path(ctx)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
