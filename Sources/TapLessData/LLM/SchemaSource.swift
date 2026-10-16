import Foundation
import TapLessDomain

/// Текст JSON Schema варианта: из файла (`file`, важнее) или из `json`.
enum SchemaSource {
    struct Loaded {
        var text: String
        /// Файл со схемой, если она задана файлом.
        var file: URL?
        /// Разобранная схема — JSON-объект.
        var object: [String: Any]
    }

    static func load(_ schema: LLMSchema) throws -> Loaded {
        let config = schema.config
        let text: String
        var file: URL?
        if !config.file.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: ShellTools.expandTilde(config.file))
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                Log.error("Схема «\(schema.name)»: не прочитать \(url.path): \(error.localizedDescription)", .llm)
                throw LLMError.schemaFile("не прочитать \(url.path): \(error.localizedDescription)")
            }
            file = url
        } else {
            text = config.json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            Log.error("Схема «\(schema.name)»: не JSON-объект", .llm)
            throw LLMError.schemaFile("«\(schema.name)» — не JSON-объект")
        }
        return Loaded(text: text, file: file, object: object)
    }
}
