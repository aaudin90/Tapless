import Foundation
import TOMLKit
import TapLessDomain

/// Отдельная папка `CODEX_HOME` для harness `type = "codex"`.
///
/// Из своей папки (`~/.codex`) Codex берёт глобальный `AGENTS.md`, а из `config.toml` — MCP-серверы,
/// навыки, память, хуки, `notify` и модель. Флага, чтобы не читать `AGENTS.md`, у `codex exec` нет:
/// `--ignore-user-config` пропускает только `config.toml`. Поэтому TapLess запускает Codex со своей папкой:
/// - `auth.json` — символическая ссылка на вход пользователя: обновлённый токен Codex пишет в оригинал;
/// - `config.toml` — только ключи провайдера и входа из конфига пользователя (`inheritedKeys`)
///   плюс выключенные телеметрия и инструменты (`quietSettings`);
/// - `model-catalog.json` — каталог моделей без инструментов (`removedModelKeys`, `disabledModelValues`).
///   Источник — самый свежий `models_cache.json` (своей папки или пользователя), а если кэша нет —
///   встроенный каталог Codex (`bundledCatalogName`, его пишет `CodexLLMRepository`).
///   С `model_catalog_json` Codex свой кэш больше не обновляет: свежий каталог приходит из `~/.codex`.
///
/// Часть инструментов задаёт не конфиг, а профиль модели: у `gpt-6-luna` `tool_mode = "code_mode_only"`
/// и `multi_agent_version` включают `exec`, `wait` и `collaboration.*` при любых `[features]`.
/// Поэтому TapLess подменяет каталог (`model_catalog_json`) копией без этих ключей: список инструментов пуст.
/// Что в запрос не попало лишнего, проверяет `CodexIsolationVerifier`.
///
/// Без телеметрии `codex exec` выходит сразу после ответа; с ней ждёт отправку метрик до 10 с.
final class CodexHome: @unchecked Sendable {
    /// Ключи `config.toml` пользователя, которые переносятся: без них не работает свой провайдер
    /// (прокси, заголовки) или вход.
    static let inheritedKeys = [
        "model_provider",
        "model_providers",
        "openai_base_url",
        "chatgpt_base_url",
        "forced_login_method",
        "forced_chatgpt_workspace_id",
        "cli_auth_credentials_store",
    ]

    /// Инструменты и фоновые функции Codex, которые TapLess выключает: модели нужно только ответить текстом.
    /// Незнакомое имя Codex пропускает с предупреждением в stderr.
    static let disabledFeatures = [
        "apps", "plugins", "remote_plugin", "goals", "multi_agent", "image_generation", "shell_tool",
        "view_image", "hooks", "skill_search", "skill_mcp_dependency_install", "browser_use",
        "browser_use_external", "in_app_browser", "computer_use", "tool_suggest", "sleep_tool",
        "shell_snapshot", "default_mode_request_user_input", "send_async_message", "send_message_to_user_async",
        "skill_env_var_dependency_prompt",
    ]

    /// Ключи профиля модели, которые удаляются из каталога: они включают инструменты в обход `[features]`.
    static let removedModelKeys = ["tool_mode", "multi_agent_version", "apply_patch_tool_type", "web_search_tool_type"]
    /// Ключи профиля модели, которые выключаются: инструменты и инструкции к ним.
    static let disabledModelValues: [String: Any] = [
        "experimental_supported_tools": [String](),
        "supports_search_tool": false,
        "include_apps_usage_instructions": false,
        "include_plugin_usage_instructions": false,
        "include_skills_usage_instructions": false,
    ]

    /// Встроенный каталог Codex (`codex debug models --bundled`): запасной источник, если кэша моделей нет.
    static let bundledCatalogName = "bundled-models.json"

    let directory: URL
    private let lock = NSLock()
    private var prepared: Snapshot?
    private var rebuilds = 0

    /// Что было на входе прошлой подготовки: если ничего не изменилось, папка не пересобирается.
    private struct Snapshot: Equatable {
        var source: String
        var config: Data?
        var hasAuth: Bool
        var modelsCache: ModelsCache?
    }

    /// Файл, из которого собран каталог.
    private struct ModelsCache: Equatable {
        var url: URL
        var modified: Date
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// Готовит папку по `source` — `CODEX_HOME` пользователя. Возвращает путь для `CODEX_HOME`.
    func prepare(source: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let sourceConfig = source.appendingPathComponent("config.toml")
        let sourceAuth = source.appendingPathComponent("auth.json")
        let snapshot = Snapshot(source: source.path,
                                config: try? Data(contentsOf: sourceConfig),
                                hasAuth: fm.fileExists(atPath: sourceAuth.path),
                                modelsCache: newestModelsCache(source: source) ?? bundledCatalog())
        if snapshot == prepared, fm.fileExists(atPath: directory.path) { return directory }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try linkAuth(sourceAuth, exists: snapshot.hasAuth)
            let catalog = writeCatalog(from: snapshot.modelsCache?.url)
            let config = Self.makeConfig(userConfig: snapshot.config.map { String(decoding: $0, as: UTF8.self) },
                                         sourcePath: sourceConfig.path, catalogPath: catalog?.path)
            let file = directory.appendingPathComponent("config.toml")
            try config.write(to: file, atomically: true, encoding: .utf8)
            // В конфиге могут быть заголовки с токеном провайдера.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.error("Codex: не подготовить папку \(directory.path): \(error.localizedDescription)", .llm)
            throw LLMError.launch("папка Codex \(directory.path): \(error.localizedDescription)")
        }
        prepared = snapshot
        rebuilds += 1
        Log.info("Codex: папка \(directory.path) готова (вход и провайдер — из \(source.path)"
                 + (snapshot.hasAuth ? "" : ", auth.json нет") + ")", .llm)
        return directory
    }

    /// Сколько раз папка пересобиралась за время работы: после пересборки проверка изоляции идёт заново.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return rebuilds
    }

    /// Нужен ли встроенный каталог: нет ни кэша моделей, ни сохранённого встроенного каталога.
    func needsBundledCatalog(source: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return newestModelsCache(source: source) == nil && bundledCatalog() == nil
    }

    /// Сохраняет вывод `codex debug models --bundled`. Битый каталог не сохраняется.
    func saveBundledCatalog(_ data: Data) throws {
        _ = try Self.makeCatalog(modelsCache: data)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent(Self.bundledCatalogName), options: .atomic)
    }

    /// Свежий `models_cache.json`: своей папки или папки пользователя.
    private func newestModelsCache(source: URL) -> ModelsCache? {
        [directory, source]
            .compactMap { Self.stamp($0.appendingPathComponent("models_cache.json")) }
            .max { $0.modified < $1.modified }
    }

    private func bundledCatalog() -> ModelsCache? {
        Self.stamp(directory.appendingPathComponent(Self.bundledCatalogName))
    }

    private static func stamp(_ url: URL) -> ModelsCache? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return modified.map { ModelsCache(url: url, modified: $0) }
    }

    /// Пишет `model-catalog.json` без инструментов. Без источника или с битым источником каталога нет:
    /// тогда Codex берёт профиль модели с сервера, и инструменты профиля остаются.
    private func writeCatalog(from cache: URL?) -> URL? {
        guard let cache else {
            Log.warning("Codex: нет ни models_cache.json, ни встроенного каталога — каталог без инструментов не собран", .llm)
            return nil
        }
        do {
            let data = try Self.makeCatalog(modelsCache: Data(contentsOf: cache))
            let file = directory.appendingPathComponent("model-catalog.json")
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            Log.warning("Codex: каталог из \(cache.path) не собран: \(error.localizedDescription)", .llm)
            return nil
        }
    }

    /// Каталог для `model_catalog_json`: модели из `models_cache.json` или встроенного каталога
    /// без ключей, включающих инструменты.
    static func makeCatalog(modelsCache: Data) throws -> Data {
        guard let cache = try JSONSerialization.jsonObject(with: modelsCache) as? [String: Any],
              let models = cache["models"] as? [[String: Any]], !models.isEmpty else {
            throw LLMError.badOutput("в каталоге моделей нет списка models")
        }
        let cleaned = models.map { model -> [String: Any] in
            var model = model
            for key in removedModelKeys { model.removeValue(forKey: key) }
            model.merge(disabledModelValues) { _, new in new }
            return model
        }
        return try JSONSerialization.data(withJSONObject: ["models": cleaned], options: [.sortedKeys])
    }

    /// `auth.json` — ссылка на файл пользователя. Если у пользователя файла нет, ссылки тоже нет:
    /// тогда Codex берёт ключ из `CODEX_API_KEY` / `OPENAI_API_KEY`.
    private func linkAuth(_ sourceAuth: URL, exists: Bool) throws {
        let fm = FileManager.default
        let link = directory.appendingPathComponent("auth.json")
        let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
        if exists && current == sourceAuth.path { return }
        // fileExists идёт по ссылке, поэтому битую ссылку видно только через current.
        if current != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        if exists {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: sourceAuth.path)
        }
    }

    /// `config.toml` для Codex: перенесённые ключи пользователя и `quietSettings`.
    /// Если конфиг пользователя не разбирается, переносить нечего: в лог — предупреждение.
    static func makeConfig(userConfig: String?, sourcePath: String, catalogPath: String? = nil) -> String {
        render(makeConfigTable(userConfig: userConfig, sourcePath: sourcePath, catalogPath: catalogPath))
    }

    static func render(_ table: TOMLTable) -> String {
        "# Создано TapLess для harness type = \"codex\". Файл пересоздаётся, правки не сохранятся.\n"
            + table.convert() + "\n"
    }

    static func makeConfigTable(userConfig: String?, sourcePath: String, catalogPath: String? = nil) -> TOMLTable {
        let table = TOMLTable()
        if let userConfig {
            do {
                let user = try TOMLTable(string: userConfig)
                for key in inheritedKeys {
                    if let value = user[key] { table[key] = value }
                }
            } catch {
                Log.warning("Codex: \(sourcePath) не разбирается, провайдер и вход — по умолчанию: \(error.localizedDescription)", .llm)
            }
        }
        table["check_for_update_on_startup"] = false
        table["web_search"] = "disabled"
        table["analytics"] = TOMLTable(["enabled": false])
        table["feedback"] = TOMLTable(["enabled": false])
        table["otel"] = TOMLTable(["metrics_exporter": "none"])
        let features = TOMLTable()
        for name in disabledFeatures { features[name] = false }
        table["features"] = features
        // Инструкции о песочнице, окружении, приложениях и режимах — лишние ~4000 токенов на каждый вызов.
        table["include_permissions_instructions"] = false
        table["include_environment_context"] = false
        table["include_apps_instructions"] = false
        table["include_collaboration_mode_instructions"] = false
        // AGENTS.md из рабочей папки и выше не читается: рабочая папка пустая, но так надёжнее.
        table["project_doc_max_bytes"] = 0
        // Список навыков (~2000 символов) Codex добавляет к промпту даже без инструментов.
        table["skills"] = TOMLTable(["include_instructions": false])
        // request_user_input и update_plan не зависят от профиля модели: выключаются только здесь.
        table["tools"] = TOMLTable([
            "experimental_request_user_input": TOMLTable(["enabled": false]),
            "update_plan": TOMLTable(["enabled": false]),
        ])
        if let catalogPath { table["model_catalog_json"] = catalogPath }
        return table
    }
}
