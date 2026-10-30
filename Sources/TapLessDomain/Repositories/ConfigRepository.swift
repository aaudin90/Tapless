import Foundation

/// Конфиг, прочитанный при запуске, и замечания к пользовательскому файлу (неизвестные ключи и т. п.).
public struct LoadedConfig: Sendable {
    public let config: AppConfig
    public let warnings: [String]

    public init(config: AppConfig, warnings: [String]) {
        self.config = config
        self.warnings = warnings
    }
}

/// Хранилище настроек: встроенные значения по умолчанию + пользовательский файл поверх них.
public protocol ConfigRepository: Sendable {
    /// Пользовательский файл с переопределениями.
    var fileURL: URL { get }

    /// Только встроенные значения по умолчанию.
    func defaults() -> AppConfig

    /// Значения по умолчанию, поверх которых наложен пользовательский файл:
    /// значение из файла важнее. Файла нет — возвращаются значения по умолчанию.
    func load() throws -> LoadedConfig

    /// Записывает файл-шаблон, если файла ещё нет. Возвращает true, если записал.
    @discardableResult
    func saveTemplateIfMissing() throws -> Bool

    /// Записывает в файл одно целое значение `[table] key = value` (настройка из меню:
    /// сейчас `paste.auto_select`). Если файл — симлинк, пишется его цель.
    /// Остальной файл, комментарии и порядок строк не меняются. Не вышло — файл не тронут.
    func setInteger(_ value: Int, forKey key: String, inTable table: String) throws

    /// То же для строки `[table] key = "value"` (настройки из меню: сейчас `general.microphone`
    /// и `general.voice_processing`).
    func setString(_ value: String, forKey key: String, inTable table: String) throws
}
