import Foundation

/// Шаблон пользовательского файла настроек: пояснение + закомментированная копия
/// значений по умолчанию. Пока ничего не раскомментировано, файл ничего не меняет.
enum ConfigTemplate {
    static func make(defaultsTOML: String, filePath: String) -> String {
        let header = """
        # ──────────────────────────────────────────────────────────────────────
        #  TapLess — ваши настройки.  Путь: \(filePath)
        #
        #  Пишите сюда только то, что хотите поменять: значение из этого файла
        #  важнее встроенного значения по умолчанию, остальное берётся из дефолтов.
        #  Ниже закомментирована полная копия значений по умолчанию. Чтобы поменять
        #  параметр, раскомментируйте его ВМЕСТЕ с заголовком секции ([general],
        #  [llm] и т. д.) и поменяйте значение.
        #
        #  Таблицы ([general], [llm.env], [variants.2], [dictionary.replace] …)
        #  сливаются по ключам: в [variants.2] достаточно указать новый prompt,
        #  а [variants.3] добавит третий вариант. Массивы заменяются целиком:
        #  если задать terms, термины по умолчанию не используются.
        #
        #  Изменения применяются после перезапуска: меню TapLess → «Перезапустить».
        # ──────────────────────────────────────────────────────────────────────

        """

        var lines = defaultsTOML.components(separatedBy: "\n")
        // Шапку файла значений по умолчанию не повторяем: она про другой файл.
        while let first = lines.first, first.hasPrefix("#") { lines.removeFirst() }

        let body = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return line }
            return "# " + line
        }
        return header + body.joined(separator: "\n")
    }
}
