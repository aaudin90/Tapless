import Foundation

/// Harness Codex и модель, которые нужны вариантам: их проверяет `CodexIsolationChecker`.
public struct CodexTarget: Sendable, Equatable {
    /// Имя из `[harness.<имя>]`.
    public let harnessName: String
    public let harness: HarnessConfig
    public let model: String

    public init(harnessName: String, harness: HarnessConfig, model: String) {
        self.harnessName = harnessName
        self.harness = harness
        self.model = model
    }

    /// Ключ для состояния проверок: harness и модель.
    public var key: String { "\(harnessName)|\(model)" }
}

/// Итог проверки изоляции Codex.
public enum CodexCheckStatus: Sendable, Equatable {
    /// В запросе только промпт и текст TapLess, инструментов нет.
    case passed
    /// Проверка не прошла до конца: Codex не запустился, не отправил запрос и т. п. Codex работает как обычно.
    case unavailable(String)
    /// В запросе есть лишнее: инструменты, чужие инструкции, не та модель.
    case problems([String])
}

/// Проверка одного harness Codex с одной моделью.
public struct CodexCheckReport: Sendable, Equatable {
    public let target: CodexTarget
    /// Вывод `codex --version`; пусто, если версия не получена.
    public let version: String
    public let status: CodexCheckStatus
    /// Вызовы harness запрещены: `verify = "block"` или в запрос попал `AGENTS.md`.
    public let blocking: Bool
    /// Проверка прошла сейчас: изменились версия Codex, каталог моделей, конфиг или аргументы
    /// (или проверку запросили вручную). Иначе итог взят из прошлой проверки.
    public let isNew: Bool
    public let checkedAt: Date

    public init(target: CodexTarget, version: String, status: CodexCheckStatus, blocking: Bool,
                isNew: Bool, checkedAt: Date) {
        self.target = target
        self.version = version
        self.status = status
        self.blocking = blocking
        self.isNew = isNew
        self.checkedAt = checkedAt
    }

    /// Текст для меню и панели.
    public var text: String {
        let name = "Codex «\(target.harnessName)»"
        switch status {
        case .passed:
            return "\(name): изоляция проверена" + (version.isEmpty ? "" : " (\(version))")
        case .unavailable:
            return "\(name): проверка не выполнена — см. лог"
        case .problems(let problems):
            return "\(name): в запросе лишнее — \(problems.first ?? "см. лог")"
                + (problems.count > 1 ? " и ещё \(problems.count - 1)" : "")
                + (blocking ? ". Вызовы заблокированы" : "")
        }
    }
}

/// Проверка изоляции Codex: отправляет Codex пробный запрос на локальный сервер TapLess и смотрит,
/// что попало в запрос, кроме промпта и текста TapLess.
public protocol CodexIsolationChecker: Sendable {
    /// Без `force` полная проверка идёт, только если с прошлой изменились версия Codex, каталог моделей,
    /// конфиг или аргументы harness; иначе возвращается прошлый итог.
    func check(_ targets: [CodexTarget], force: Bool) async -> [CodexCheckReport]
    /// Получатель итогов фоновых проверок: перед вызовом Codex раз в сутки и после пересборки каталога.
    func setReportHandler(_ handler: @escaping @Sendable (CodexCheckReport) -> Void) async
}
