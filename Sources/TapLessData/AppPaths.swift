import Foundation

/// Где приложение хранит файлы на диске.
public struct AppPaths: Sendable {
    /// Пользовательские настройки (только переопределения значений по умолчанию).
    public let configFile: URL
    public let support: URL
    public let models: URL
    /// Временные файлы запусков: системные промпты вариантов.
    public let run: URL
    /// Пустая рабочая папка LLM-команды, чтобы claude не подхватил CLAUDE.md случайного проекта.
    public let llmWorkdir: URL
    public let logFile: URL

    public static func make() -> AppPaths {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let configFile: URL
        if let custom = ProcessInfo.processInfo.environment["TAPLESS_CONFIG"], !custom.isEmpty {
            configFile = URL(fileURLWithPath: ShellTools.expandTilde(custom))
        } else {
            configFile = home.appendingPathComponent(".config/tapless.toml")
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let support = appSupport.appendingPathComponent("TapLess", isDirectory: true)

        return AppPaths(
            configFile: configFile,
            support: support,
            models: support.appendingPathComponent("models", isDirectory: true),
            run: support.appendingPathComponent("run", isDirectory: true),
            llmWorkdir: support.appendingPathComponent("llm-workdir", isDirectory: true),
            logFile: home.appendingPathComponent("Library/Logs/TapLess/TapLess.log")
        )
    }

    /// Старые файлы лога прямо в `~/Library/Logs` (до переезда в папку `TapLess`).
    public var legacyLogFiles: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return [logs.appendingPathComponent("TapLess.log"), logs.appendingPathComponent("TapLess.log.1")]
    }

    /// Удаляет старые файлы лога. Возвращает удалённые.
    @discardableResult
    public func removeLegacyLogFiles() -> [URL] {
        let fm = FileManager.default
        return legacyLogFiles.filter { url in
            fm.fileExists(atPath: url.path) && (try? fm.removeItem(at: url)) != nil
        }
    }

    public func createDirectories() {
        let fm = FileManager.default
        for dir in [support, models, run, llmWorkdir,
                    configFile.deletingLastPathComponent(),
                    logFile.deletingLastPathComponent()] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
