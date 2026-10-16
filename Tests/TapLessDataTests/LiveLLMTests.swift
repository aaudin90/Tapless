import Foundation
import Testing
import TapLessData
import TapLessDomain

/// Живая проверка harness из конфига пользователя: настоящий вызов LLM, без GUI.
/// Запуск: `TAPLESS_LIVE_LLM=1 ./scripts/test.sh --filter LiveLLM`.
/// Конфиг — `~/.config/tapless.toml` или `TAPLESS_CONFIG`; лог — `TAPLESS_LIVE_LOG`, если задан.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAPLESS_LIVE_LLM"] == "1"), .serialized)
struct LiveLLMTests {
    private static func makeUseCase(_ edit: (inout AppConfig) -> Void = { _ in }) throws -> FormatTextUseCase {
        let paths = AppPaths.make()
        paths.createDirectories()
        if let log = ProcessInfo.processInfo.environment["TAPLESS_LIVE_LOG"] {
            AppLog.install(fileURL: URL(fileURLWithPath: log), subsystem: "io.github.aaudin90.tapless.tests")
        }
        var config = try FileConfigRepository(fileURL: paths.configFile).load().config
        Log.minimumLevel = config.log.logLevel
        edit(&config)
        let llm = RoutingLLMRepository(
            process: ProcessLLMRepository(settings: config.llm, runDirectory: paths.run, defaultWorkdir: paths.llmWorkdir),
            ollama: OllamaLLMRepository(settings: config.llm)
        )
        return FormatTextUseCase(llm: llm, config: config)
    }

    @Test func firstVariantAsText() async throws {
        let useCase = try Self.makeUseCase()
        let output = try await useCase.execute(text: "ну вот короче проверка связи раз два три", variantKey: useCase.firstVariantKey)
        #expect(!output.isEmpty)
    }

    @Test func firstVariantWithSchema() async throws {
        let useCase = try Self.makeUseCase { $0.variants[0].schema = "text" }
        let output = try await useCase.execute(text: "ну вот короче проверка связи раз два три", variantKey: useCase.firstVariantKey)
        #expect(!output.isEmpty)
        #expect(!output.hasPrefix("{"))
    }

    /// Все варианты сразу, как в панели: проверка очереди `parallel` на живом harness.
    @Test func allVariantsInParallel() async throws {
        let useCase = try Self.makeUseCase()
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for key in useCase.variantKeys {
                group.addTask { try await useCase.execute(text: "ну вот короче проверка связи раз два три", variantKey: key) }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(outputs.count == useCase.variantKeys.count)
        #expect(outputs.allSatisfy { !$0.isEmpty })
    }
}
