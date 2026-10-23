import Foundation

/// Сценарий «проверить и поставить обновление»: сравнивает текущую версию с последним релизом
/// и передаёт установку `AppUpdater`.
public struct CheckUpdateUseCase: Sendable {
    /// Как часто проверять в фоне.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// Задержка первой проверки после запуска: не мешать загрузке модели и первой диктовке.
    public static let firstCheckDelay: TimeInterval = 30

    /// Версия запущенного приложения; nil — не из `.app` (нет `CFBundleShortVersionString`).
    public let currentVersion: AppVersion?
    /// `general.check_updates`: проверять ли в фоне. Пункт меню работает всегда.
    public let checksAutomatically: Bool
    private let updater: AppUpdater

    public init(updater: AppUpdater, currentVersion: String?, config: AppConfig) {
        self.updater = updater
        self.currentVersion = currentVersion.flatMap(AppVersion.init)
        self.checksAutomatically = config.general.checkUpdates
    }

    /// Обновление возможно: версия приложения известна.
    public var isAvailable: Bool { currentVersion != nil }

    /// Релиз новее текущей версии; nil — обновления нет.
    public func check() async throws -> AppRelease? {
        guard let currentVersion, let release = try await updater.latestRelease() else { return nil }
        return release.version > currentVersion ? release : nil
    }

    public func prepare(_ release: AppRelease, replacing current: URL) async throws -> URL {
        try await updater.prepare(release, replacing: current)
    }

    public func scheduleInstall(staged: URL, replacing current: URL, afterExitOf pid: Int32) throws {
        try updater.scheduleInstall(staged: staged, replacing: current, afterExitOf: pid)
    }
}
