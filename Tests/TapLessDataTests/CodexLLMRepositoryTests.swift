import Foundation
import Testing
import TOMLKit
@testable import TapLessData
import TapLessDomain

/// Запоминает запросы и отвечает их `CODEX_HOME`.
private actor RecordingLLM: LLMRepository {
    private(set) var requests: [LLMRequest] = []

    func complete(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        return request.harness.env["CODEX_HOME"] ?? ""
    }
}

@Suite final class CodexLLMRepositoryTests {
    private var directories: [URL] = []

    deinit {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir
    }

    /// `CODEX_HOME` пользователя с конфигом и, если `auth`, с `auth.json`.
    private func makeSource(config: String?, auth: Bool = true) throws -> URL {
        let source = try makeTempDir().appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if let config {
            try config.write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        if auth {
            try #"{"tokens":{}}"#.write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        }
        try "# личные инструкции".write(to: source.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        return source
    }

    private static let userConfig = """
    model = "gpt-big"
    model_provider = "proxy"
    notify = ["/bin/echo"]

    [model_providers.proxy]
    name = "Прокси"
    base_url = "https://proxy.example/v1"
    wire_api = "responses"
    http_headers = { "X-Token" = "secret" }

    [mcp_servers.gitlab]
    command = "gitlab-mcp"

    [features]
    goals = true
    """

    private func generatedConfig(_ home: URL) throws -> TOMLTable {
        try TOMLTable(string: String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8))
    }

    @Test func homeKeepsProviderAndAuthOnly() throws {
        let source = try makeSource(config: Self.userConfig)
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        let dir = try home.prepare(source: source)

        let config = try generatedConfig(dir)
        #expect(config["model_provider"]?.string == "proxy")
        #expect(config["model_providers"]?["proxy"]?["base_url"]?.string == "https://proxy.example/v1")
        #expect(config["model_providers"]?["proxy"]?["http_headers"]?["X-Token"]?.string == "secret")
        #expect(config["model"] == nil)
        #expect(config["notify"] == nil)
        #expect(config["mcp_servers"] == nil)
        #expect(config["features"]?["goals"]?.bool == false)
        #expect(config["features"]?["shell_tool"]?.bool == false)
        #expect(config["analytics"]?["enabled"]?.bool == false)
        #expect(config["web_search"]?.string == "disabled")

        let fm = FileManager.default
        let auth = dir.appendingPathComponent("auth.json")
        #expect(try fm.destinationOfSymbolicLink(atPath: auth.path) == source.appendingPathComponent("auth.json").path)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("AGENTS.md").path))
        let permissions = try fm.attributesOfItem(atPath: dir.appendingPathComponent("config.toml").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func homeFollowsSourceChanges() throws {
        let source = try makeSource(config: Self.userConfig)
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        let dir = try home.prepare(source: source)

        try "model_provider = \"other\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source.appendingPathComponent("auth.json"))
        _ = try home.prepare(source: source)

        #expect(try generatedConfig(dir)["model_provider"]?.string == "other")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("auth.json").path)) == nil)
    }

    @Test func brokenOrMissingUserConfigKeepsQuietSettings() throws {
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        for config in ["model_provider = ", nil] {
            let dir = try home.prepare(source: try makeSource(config: config, auth: false))
            let generated = try generatedConfig(dir)
            #expect(generated["model_provider"] == nil)
            #expect(generated["analytics"]?["enabled"]?.bool == false)
        }
    }

    private static let modelsCache = """
    {"fetched_at": "2026-10-22", "etag": "x", "models": [
      {"slug": "gpt-6-luna", "tool_mode": "code_mode_only", "multi_agent_version": "v2",
       "apply_patch_tool_type": "freeform", "web_search_tool_type": "text",
       "experimental_supported_tools": ["exec"], "supports_search_tool": true, "context_window": 1000}
    ]}
    """

    @Test func homeDisablesToolsAndBuildsCatalog() throws {
        let source = try makeSource(config: nil)
        try Self.modelsCache.write(to: source.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        let dir = try home.prepare(source: source)

        let config = try generatedConfig(dir)
        #expect(config["tools"]?["experimental_request_user_input"]?["enabled"]?.bool == false)
        #expect(config["include_permissions_instructions"]?.bool == false)
        #expect(config["include_environment_context"]?.bool == false)
        #expect(config["project_doc_max_bytes"]?.int == 0)
        #expect(config["skills"]?["include_instructions"]?.bool == false)
        #expect(config["tools"]?["update_plan"]?["enabled"]?.bool == false)
        #expect(config["features"]?["default_mode_request_user_input"]?.bool == false)
        let catalogPath = try #require(config["model_catalog_json"]?.string)
        #expect(catalogPath == dir.appendingPathComponent("model-catalog.json").path)

        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: catalogPath))) as? [String: Any]
        #expect(catalog?["etag"] == nil)
        let model = try #require((catalog?["models"] as? [[String: Any]])?.first)
        #expect(model["slug"] as? String == "gpt-6-luna")
        #expect(model["context_window"] as? Int == 1000)
        for key in CodexHome.removedModelKeys { #expect(model[key] == nil) }
        #expect((model["experimental_supported_tools"] as? [String])?.isEmpty == true)
        #expect(model["supports_search_tool"] as? Bool == false)
    }

    @Test func catalogFollowsNewestModelsCache() throws {
        let source = try makeSource(config: nil)
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        let dir = try home.prepare(source: source)
        #expect(try generatedConfig(dir)["model_catalog_json"] == nil)

        // Свой кэш Codex пишет в папку TapLess: он свежее кэша пользователя.
        let old = source.appendingPathComponent("models_cache.json")
        try Self.modelsCache.write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        try Self.modelsCache.replacingOccurrences(of: "gpt-6-luna", with: "gpt-7")
            .write(to: dir.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        _ = try home.prepare(source: source)

        let catalog = try String(contentsOf: dir.appendingPathComponent("model-catalog.json"), encoding: .utf8)
        #expect(catalog.contains("gpt-7"))
        #expect(try generatedConfig(dir)["model_catalog_json"] != nil)
    }

    @Test func bundledCatalogIsFallbackOnly() throws {
        let source = try makeSource(config: nil)
        let home = CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home"))
        #expect(home.needsBundledCatalog(source: source))
        #expect(throws: (any Error).self) { try home.saveBundledCatalog(Data("{}".utf8)) }

        try home.saveBundledCatalog(Data(Self.modelsCache.replacingOccurrences(of: "gpt-6-luna", with: "bundled-model").utf8))
        #expect(!home.needsBundledCatalog(source: source))
        let dir = try home.prepare(source: source)
        let catalog = dir.appendingPathComponent("model-catalog.json")
        #expect(try String(contentsOf: catalog, encoding: .utf8).contains("bundled-model"))

        // Кэш моделей важнее встроенного каталога, даже если он старше.
        let cache = source.appendingPathComponent("models_cache.json")
        try Self.modelsCache.write(to: cache, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: cache.path)
        _ = try home.prepare(source: source)
        let rebuilt = try String(contentsOf: catalog, encoding: .utf8)
        #expect(rebuilt.contains("gpt-6-luna") && !rebuilt.contains("bundled-model"))
    }

    @Test func repositoryLoadsBundledCatalogOnceWithoutCache() async throws {
        let dir = try makeTempDir()
        let source = try makeSource(config: nil)
        let fakeCatalog = dir.appendingPathComponent("catalog.json")
        try Self.modelsCache.write(to: fakeCatalog, atomically: true, encoding: .utf8)
        let calls = dir.appendingPathComponent("calls.txt")
        let script = dir.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        echo "$CODEX_HOME $*" >> '\(calls.path)'
        sleep 0.2
        cat '\(fakeCatalog.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var settings = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults().llm
        settings.loginShell = false
        let homeDir = dir.appendingPathComponent("codex-home")
        let codex = CodexLLMRepository(process: RecordingLLM(), settings: settings, homeDirectory: homeDir)
        let harness = HarnessConfig(executable: script.path, args: [], env: ["CODEX_HOME": source.path], kind: .codex)
        try await withThrowingTaskGroup(of: String.self) { group in
            for key in 1...3 {
                group.addTask {
                    try await codex.complete(LLMRequest(variantKey: key, variantName: "v", harnessName: "codex",
                                                        harness: harness, model: "m", systemPrompt: "s", input: "i"))
                }
            }
            for try await _ in group {}
        }

        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["\(homeDir.path) debug models --bundled"])
        #expect(try generatedConfig(homeDir)["model_catalog_json"] != nil)
        #expect(try String(contentsOf: homeDir.appendingPathComponent("model-catalog.json"), encoding: .utf8).contains("gpt-6-luna"))
    }

    @Test func brokenModelsCacheSkipsCatalog() throws {
        let source = try makeSource(config: nil)
        try "{}".write(to: source.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        let dir = try CodexHome(directory: try makeTempDir().appendingPathComponent("codex-home")).prepare(source: source)
        let config = try generatedConfig(dir)
        #expect(config["model_catalog_json"] == nil)
        #expect(config["tools"]?["experimental_request_user_input"]?["enabled"]?.bool == false)
    }

    @Test func sourceHomePrefersHarnessThenLLMThenEnvironment() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(CodexLLMRepository.sourceHome(harnessEnv: ["CODEX_HOME": "/h"], llmEnv: ["CODEX_HOME": "/l"],
                                              environment: ["CODEX_HOME": "/e"]).path == "/h")
        #expect(CodexLLMRepository.sourceHome(harnessEnv: ["CODEX_HOME": " "], llmEnv: ["CODEX_HOME": "/l"],
                                              environment: ["CODEX_HOME": "/e"]).path == "/l")
        #expect(CodexLLMRepository.sourceHome(harnessEnv: [:], llmEnv: [:], environment: ["CODEX_HOME": "/e"]).path == "/e")
        #expect(CodexLLMRepository.sourceHome(harnessEnv: [:], llmEnv: [:], environment: ["CODEX_HOME": "~/c"]).path
                == home.appendingPathComponent("c").path)
        #expect(CodexLLMRepository.sourceHome(harnessEnv: [:], llmEnv: [:], environment: [:]).path
                == home.appendingPathComponent(".codex").path)
    }

    @Test func requestGetsIsolatedHomeAndKeepsTheRest() async throws {
        let source = try makeSource(config: Self.userConfig)
        let homeDir = try makeTempDir().appendingPathComponent("codex-home")
        let inner = RecordingLLM()
        let settings = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults().llm
        let codex = CodexLLMRepository(process: inner, settings: settings, homeDirectory: homeDir)
        let harness = HarnessConfig(executable: "codex", args: ["exec"], env: ["CODEX_HOME": source.path, "A": "1"],
                                    kind: .codex)
        let request = LLMRequest(variantKey: 2, variantName: "v", harnessName: "codex", harness: harness,
                                 model: "m", systemPrompt: "s", input: "i", purpose: .revision)

        #expect(try await codex.complete(request) == homeDir.path)
        let sent = try #require(await inner.requests.first)
        #expect(sent.harness.env["A"] == "1")
        #expect(sent.harness.args == ["exec"])
        #expect(sent.purpose == .revision)
        #expect(sent.systemPrompt == "s")
        #expect(FileManager.default.fileExists(atPath: homeDir.appendingPathComponent("config.toml").path))
    }

    @Test func routingSendsCodexKindToCodexRepository() async throws {
        let process = RecordingLLM()
        let codex = RecordingLLM()
        let routing = RoutingLLMRepository(process: process, ollama: process, codex: codex)
        let harness = HarnessConfig(executable: "codex", args: [], kind: .codex, parallel: 1)
        _ = try await routing.complete(LLMRequest(variantKey: 1, variantName: "v", harnessName: "codex",
                                                  harness: harness, model: "m", systemPrompt: "s", input: "i"))
        #expect(await codex.requests.count == 1)
        #expect(await process.requests.isEmpty)
        #expect(RoutingLLMRepository.queueKey(LLMRequest(variantKey: 1, variantName: "v", harnessName: "codex",
                                                         harness: harness, model: "m", systemPrompt: "s",
                                                         input: "i")) == "harness codex")
    }
}
