import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    /// Имя уровня в конфиге (`[log] level`) и в строке лога.
    public var name: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    /// Уровень по имени из конфига, без учёта регистра. Неизвестное имя — nil.
    public init?(name: String) {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let level = Self.allCases.first(where: { $0.name == key }) else { return nil }
        self = level
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Подсистема, к которой относится запись. В Console.app это категория `os_log`.
public enum LogCategory: String, Sendable, CaseIterable {
    case app, config, hotkey, audio, stt, llm, paste, ui, history
}

/// Фасад лога. Куда писать, решает слой Data: он подключает приёмник при запуске
/// (`Log.setSink`). Без приёмника записи отбрасываются.
///
/// Сообщение — `@autoclosure`: строка не собирается, если уровень ниже `minimumLevel`.
public enum Log {
    public typealias Sink = @Sendable (LogLevel, LogCategory, String) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: Sink?
    nonisolated(unsafe) private static var level: LogLevel = .debug
    nonisolated(unsafe) private static var textAllowed = false

    public static func setSink(_ newSink: Sink?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    /// Записи ниже этого уровня отбрасываются.
    public static var minimumLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return level }
        set { lock.lock(); level = newValue; lock.unlock() }
    }

    /// Писать ли в лог сам текст диктовки и ответов LLM (`[log] include_text`).
    public static var includeText: Bool {
        get { lock.lock(); defer { lock.unlock() }; return textAllowed }
        set { lock.lock(); textAllowed = newValue; lock.unlock() }
    }

    /// Пользовательский текст для лога: сам текст в кавычках, если `includeText`,
    /// иначе только длина — чтобы надиктованное не оседало в логах.
    public static func text(_ value: String) -> String {
        includeText ? "«\(value)»" : "‹\(value.count) симв.›"
    }

    public static func debug(_ message: @autoclosure () -> String, _ category: LogCategory = .app) {
        write(.debug, category, message)
    }

    public static func info(_ message: @autoclosure () -> String, _ category: LogCategory = .app) {
        write(.info, category, message)
    }

    public static func warning(_ message: @autoclosure () -> String, _ category: LogCategory = .app) {
        write(.warning, category, message)
    }

    public static func error(_ message: @autoclosure () -> String, _ category: LogCategory = .app) {
        write(.error, category, message)
    }

    private static func write(_ messageLevel: LogLevel, _ category: LogCategory, _ message: () -> String) {
        lock.lock()
        let current = sink
        let enabled = messageLevel >= level
        lock.unlock()
        guard enabled, let current else { return }
        current(messageLevel, category, message())
    }
}
