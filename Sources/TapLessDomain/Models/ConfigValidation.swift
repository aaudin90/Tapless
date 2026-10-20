import Foundation

extension AppConfig {
    /// Смысловые предупреждения: значения, которые формально валидны,
    /// но приложение ведёт себя не так, как мог ожидать пользователь.
    /// Тексты описывают фактическое поведение.
    public var validationWarnings: [String] {
        var warnings: [String] = []

        // Режим: hold распознаётся по `mode.lowercased() == "hold"`, всё остальное — toggle.
        let mode = general.mode.lowercased()
        if mode != "toggle" && mode != "hold" {
            warnings.append("general.mode = \"\(general.mode)\": ожидается \"toggle\" или \"hold\" — используется \"toggle\".")
        }

        // Одинаковые сочетания: вторая клавиша не зарегистрируется. Сравнение без учёта
        // порядка, регистра и пробелов; синонимы (alt / option) не распознаются.
        func keyParts(_ s: String) -> Set<String> {
            Set(s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if !general.showLastHotkey.trimmingCharacters(in: .whitespaces).isEmpty,
           keyParts(general.showLastHotkey) == keyParts(general.hotkey) {
            warnings.append("general.show_last_hotkey совпадает с general.hotkey (\"\(general.hotkey)\") — клавиша «Показать последний результат» не будет работать.")
        }

        // Позиция панели: "center" (без учёта регистра), всё остальное — сверху.
        let position = ui.position.lowercased()
        if position != "top" && position != "center" {
            warnings.append("ui.position = \"\(ui.position)\": ожидается \"top\" или \"center\" — панель показывается сверху (\"top\").")
        }

        let enabledCount = variants.filter(\.enabled).count
        if enabledCount > maxVariants {
            warnings.append("Включено \(enabledCount) вариантов, используются первые \(maxVariants) (клавиши \(firstVariantKey)–9).")
        } else if enabledCount == 0 {
            if let rawTextKey {
                warnings.append("Нет ни одного включённого варианта (секции [variants.<номер>]) — будет доступен только сырой текст (клавиша \(rawTextKey)).")
            } else {
                warnings.append("Нет ни одного включённого варианта (секции [variants.<номер>]), а ui.show_raw = false — выбирать будет нечего.")
            }
        }

        if LogLevel(name: log.level) == nil {
            warnings.append("log.level = \"\(log.level)\": ожидается \"debug\", \"info\", \"warning\" или \"error\" — используется \"debug\".")
        }

        if history.retentionDays < 0 {
            warnings.append("history.retention_days = \(history.retentionDays): ожидается 0 (без срока) или больше — срок не применяется.")
        }
        if history.maxSizeMB < 0 {
            warnings.append("history.max_size_mb = \(history.maxSizeMB): ожидается 0 (без предела) или больше — предел не применяется.")
        }

        for placeholder in ["{previous}", "{feedback}"] where !llm.reviseTemplate.contains(placeholder) {
            warnings.append("llm.revise_template без \(placeholder): правка строки панели потеряет \(placeholder == "{feedback}" ? "замечания автора" : "прежний результат").")
        }

        warnings += harnessWarnings
        return warnings
    }

    private var harnessWarnings: [String] {
        var warnings: [String] = []
        let knownHarnesses = harnesses.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")

        if harnesses[llm.harness] == nil {
            warnings.append("llm.harness = \"\(llm.harness)\": нет секции [harness.\(llm.harness)] (есть: \(knownHarnesses)) — варианты без своего harness завершатся ошибкой.")
        }
        for variant in variants where variant.enabled {
            let label = "Вариант «\(variant.name)»"
            if let name = variant.harness, harnesses[name] == nil {
                warnings.append("\(label): harness = \"\(name)\" — нет секции [harness.\(name)] (есть: \(knownHarnesses)).")
            }
            if let name = variant.schema, schemas[name] == nil {
                warnings.append("\(label): schema = \"\(name)\" — нет секции [schemas.\(name)].")
            }
            if variant.schema != nil, let harness = harnesses[harnessName(for: variant)],
               harness.kind == .process, harness.schemaArgs.isEmpty {
                warnings.append("\(label): у harness \"\(harnessName(for: variant))\" пустой schema_args — схема в программу не передаётся.")
            }
        }

        for name in harnesses.keys.sorted() {
            guard let harness = harnesses[name] else { continue }
            if harness.kind == .ollama {
                if harness.url.trimmingCharacters(in: .whitespaces).isEmpty {
                    warnings.append("harness.\(name).url пустой — запросы к Ollama завершатся ошибкой.")
                }
                continue
            }
            if harness.executable.trimmingCharacters(in: .whitespaces).isEmpty {
                warnings.append("harness.\(name).executable пустой — запуск завершится ошибкой.")
            }
            let allArgs = harness.args + harness.textArgs + harness.schemaArgs
            if harness.input == .arg && !allArgs.contains(where: { $0.contains("{input}") }) {
                warnings.append("harness.\(name): input = \"arg\", но в аргументах нет {input} — текст до программы не дойдёт.")
            }
            if harness.output == .json && harness.outputPath.isEmpty {
                warnings.append("harness.\(name): output = \"json\" без output_path — вставляется весь JSON-ответ.")
            }
        }

        for name in schemas.keys.sorted() {
            guard let schema = schemas[name] else { continue }
            if schema.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && schema.file.trimmingCharacters(in: .whitespaces).isEmpty {
                warnings.append("schemas.\(name): не заданы ни json, ни file.")
            }
        }
        return warnings
    }
}
