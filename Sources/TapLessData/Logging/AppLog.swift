import Foundation
import os
import TapLessDomain

/// Приёмник `Log`: каждая запись уходит в унифицированный лог macOS (`os.Logger`,
/// виден в Console.app) и в файл (~/Library/Logs/TapLess/TapLess.log).
/// Файл больше 5 МБ переносится в `<имя>.1` (старый `.1` заменяется) —
/// при подключении и во время работы.
public enum AppLog {
    /// Подключает приёмник. Большой файл уходит в `<имя>.1`, запись идёт в новый.
    public static func install(fileURL: URL, subsystem: String) {
        let writer = LogFileWriter(url: fileURL)
        writer.rotateIfNeeded()
        let loggers = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        })
        Log.setSink { level, category, message in
            if let logger = loggers[category] {
                switch level {
                case .debug: logger.debug("\(message, privacy: .public)")
                case .info: logger.info("\(message, privacy: .public)")
                case .warning: logger.notice("\(message, privacy: .public)")
                case .error: logger.error("\(message, privacy: .public)")
                }
            }
            writer.write(level, category, message)
        }
    }
}

final class LogFileWriter: @unchecked Sendable {
    static let defaultMaxBytes: UInt64 = 5_000_000

    private let url: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "tapless.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(url: URL, maxBytes: UInt64 = LogFileWriter.defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Строка файла: время, уровень (выровнен), `[категория]`, сообщение.
    static func format(date: String, level: LogLevel, category: LogCategory, message: String) -> String {
        let name = level.name.uppercased()
        let padded = name + String(repeating: " ", count: max(0, 7 - name.count))
        return "\(date) \(padded) [\(category.rawValue)] \(message)\n"
    }

    func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let date = Date()
        queue.async { [self] in
            let line = Self.format(date: formatter.string(from: date), level: level,
                                   category: category, message: message)
            #if DEBUG
            FileHandle.standardError.write(Data(line.utf8))
            #endif
            append(Data(line.utf8))
        }
    }

    /// Ждёт, пока все поставленные в очередь записи попадут в файл (для тестов).
    func flush() {
        queue.sync {}
    }

    /// Переносит файл больше лимита в `<имя>.1`. Вызывается до первой записи.
    func rotateIfNeeded() {
        queue.sync {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
               size > maxBytes {
                rotate()
            }
        }
    }

    private func append(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        let offset = (try? handle.seekToEnd()) ?? 0
        if offset > maxBytes {
            try? handle.close()
            rotate()
            try? data.write(to: url)
            return
        }
        try? handle.write(contentsOf: data)
        try? handle.close()
    }

    private func rotate() {
        let fm = FileManager.default
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}
