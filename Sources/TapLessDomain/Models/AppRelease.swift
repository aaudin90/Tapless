import Foundation

/// Версия приложения: числа через точку (`0.8.0`), тег может начинаться с `v` (`v0.8.0`).
/// Недостающие числа считаются нулями: `0.8` == `0.8.0`.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// nil — не версия: пусто, буквы, суффиксы вроде `-beta`.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// Опубликованный релиз приложения.
public struct AppRelease: Sendable, Equatable {
    public let version: AppVersion
    /// Тег релиза как есть, например `v0.8.0`.
    public let tag: String
    /// Описание релиза (Markdown).
    public let notes: String
    /// Страница релиза для браузера.
    public let pageURL: URL
    /// Архив с `.app`.
    public let archiveURL: URL
    /// Файл SHA-256 архива; nil — у релиза его нет, и обновить из приложения нельзя.
    public let checksumURL: URL?

    public init(version: AppVersion, tag: String, notes: String, pageURL: URL, archiveURL: URL, checksumURL: URL?) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.pageURL = pageURL
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
    }
}
