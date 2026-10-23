import Foundation

/// Источник релизов и установщик обновлений (реализация — GitHub Releases в TapLessData).
public protocol AppUpdater: Sendable {
    /// Последний опубликованный релиз (без черновиков и пре-релизов). nil — релизов нет.
    func latestRelease() async throws -> AppRelease?

    /// Скачивает архив релиза, сверяет SHA-256, распаковывает и проверяет, что новый `.app`
    /// подписан тем же сертификатом, что `current`. Возвращает путь к новому `.app`
    /// во временной папке рядом с `current`. Отмена задачи прерывает скачивание.
    func prepare(_ release: AppRelease, replacing current: URL) async throws -> URL

    /// Запускает фоновую замену: ждёт выхода процесса `pid`, ставит `staged` на место `current`
    /// и запускает новое приложение. После вызова приложение должно завершиться само.
    func scheduleInstall(staged: URL, replacing current: URL, afterExitOf pid: Int32) throws
}
