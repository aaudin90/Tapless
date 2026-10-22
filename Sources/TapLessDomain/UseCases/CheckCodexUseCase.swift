import Foundation

/// Сценарий «проверить изоляцию Codex»: для harness `type = "codex"`, которые нужны вариантам
/// или `llm.harness`, проверяет, что в запрос Codex не попадают инструменты и чужие инструкции.
public struct CheckCodexUseCase: Sendable {
    /// Что проверять. Пусто — Codex не используется, проверки нет.
    public let targets: [CodexTarget]
    private let checker: CodexIsolationChecker

    public init(checker: CodexIsolationChecker, config: AppConfig) {
        self.checker = checker
        self.targets = config.codexTargets
    }

    public var isUsed: Bool { !targets.isEmpty }

    /// `force` — проверить заново, даже если ничего не изменилось (пункт меню).
    public func execute(force: Bool) async -> [CodexCheckReport] {
        guard isUsed else { return [] }
        return await checker.check(targets, force: force)
    }

    /// Итоги фоновых проверок, которые запускает сам Codex-harness.
    public func onBackgroundReport(_ handler: @escaping @Sendable (CodexCheckReport) -> Void) async {
        await checker.setReportHandler(handler)
    }
}
