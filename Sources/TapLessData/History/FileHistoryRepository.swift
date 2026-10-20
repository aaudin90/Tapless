import CryptoKit
import Foundation
import TapLessDomain

/// История диктовок в файлах: `<root>/history/<день>/<время>_<id>/` и `<root>/prompts/<id>.txt`.
/// Ошибки ввода-вывода в лог (`Log.warning`), наружу не бросаются; текст диктовки в лог не пишется.
public actor FileHistoryRepository: HistoryRepository {
    private let historyDir: URL
    private let promptsDir: URL
    private let fm = FileManager.default

    private struct Session {
        let folder: URL
        var doc: SessionDoc
    }

    private var sessions: [UUID: Session] = [:]
    private var order: [UUID] = []
    private var evicted: Set<UUID> = []
    private static let keptSessions = 20

    public init(root: URL) {
        historyDir = root.appendingPathComponent("history", isDirectory: true)
        promptsDir = root.appendingPathComponent("prompts", isDirectory: true)
    }

    // MARK: - Запись

    public func record(_ event: HistoryEvent, session id: UUID, at date: Date) async {
        guard var session = sessionState(id, at: date) else { return }
        do {
            try apply(event, to: &session, at: date)
        } catch {
            Log.warning("История: не удалось записать событие: \(error.localizedDescription)", .history)
        }
        sessions[id] = session
        writeDoc(session)
    }

    private func sessionState(_ id: UUID, at date: Date) -> Session? {
        if let existing = sessions[id] { return existing }
        if evicted.contains(id) {
            Log.debug("История: сессия \(id.uuidString.prefix(8)) вытеснена из памяти, событие пропущено", .history)
            return nil
        }
        let folder = historyDir
            .appendingPathComponent(Self.dayFormatter.string(from: date), isDirectory: true)
            .appendingPathComponent(Self.timeFormatter.string(from: date) + "_" + id.uuidString.lowercased().prefix(8),
                                    isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.warning("История: не удалось создать папку \(folder.path): \(error.localizedDescription)", .history)
            return nil
        }
        order.append(id)
        while order.count > Self.keptSessions {
            let old = order.removeFirst()
            sessions[old] = nil
            evicted.insert(old)
        }
        return Session(folder: folder, doc: SessionDoc(id: id.uuidString.lowercased(), startedAt: date))
    }

    private func apply(_ event: HistoryEvent, to session: inout Session, at date: Date) throws {
        let folder = session.folder
        switch event {
        case .recording(let clip, let duration, let targetApp):
            session.doc.targetApp = targetApp
            var file: String?
            if let clip {
                try WAVEncoder.encode(clip).write(to: folder.appendingPathComponent("audio.wav"))
                file = "audio.wav"
            }
            session.doc.audio = SessionDoc.Audio(file: file, seconds: duration)

        case .transcript(let text, let seconds, let model):
            try Data(text.utf8).write(to: folder.appendingPathComponent("transcript.txt"))
            session.doc.stt = SessionDoc.STT(model: model, seconds: seconds, text: text)

        case .feedbackRecording(let clip, let duration, let key):
            let index = session.doc.feedback.count + 1
            var file: String?
            if let clip {
                file = "feedback-\(index).wav"
                try WAVEncoder.encode(clip).write(to: folder.appendingPathComponent(file!))
            }
            session.doc.feedback.append(SessionDoc.Feedback(index: index, key: key, file: file,
                                                            seconds: duration, sttSeconds: 0, text: ""))

        case .feedbackTranscript(let text, let seconds, _, let key):
            var position = session.doc.feedback.lastIndex { $0.key == key && !$0.transcribed }
            if position == nil {
                let index = session.doc.feedback.count + 1
                session.doc.feedback.append(SessionDoc.Feedback(index: index, key: key, file: nil,
                                                                seconds: 0, sttSeconds: 0, text: ""))
                position = session.doc.feedback.count - 1
            }
            let at = position!
            session.doc.feedback[at].sttSeconds = seconds
            session.doc.feedback[at].text = text
            session.doc.feedback[at].transcribed = true
            try Data(text.utf8).write(to: folder.appendingPathComponent("feedback-\(session.doc.feedback[at].index).txt"))

        case .llmCall(let call):
            let index = session.doc.llm.count + 1
            let request = call.request
            let promptId = try storePrompt(request.systemPrompt)
            let name = String(format: "%02d", index) + "-\(request.purpose.rawValue)\(request.variantKey)-"
                + Self.safeName(request.model) + "-\(promptId).txt"
            let llmDir = folder.appendingPathComponent("llm", isDirectory: true)
            try fm.createDirectory(at: llmDir, withIntermediateDirectories: true)
            let body: String
            if call.cancelled {
                body = "ОТМЕНЕНО"
            } else if let error = call.error {
                body = "ОШИБКА: \(error)"
            } else {
                body = call.output ?? ""
            }
            try Data(body.utf8).write(to: llmDir.appendingPathComponent(name))
            session.doc.llm.append(SessionDoc.LLM(
                index: index, purpose: request.purpose.rawValue, key: request.variantKey,
                name: request.variantName, harness: request.harnessName, model: request.model,
                promptId: promptId, schema: request.schema?.name, input: request.input,
                output: call.output, error: call.error, cancelled: call.cancelled,
                startedAt: call.startedAt, seconds: call.seconds, file: "llm/" + name))

        case .delivered(let key, let text, let copyOnly):
            session.doc.deliveries.append(SessionDoc.Delivery(at: date, key: key, copyOnly: copyOnly, text: text))
        }
    }

    /// Сохраняет системный промпт один раз; повторно только освежает дату изменения.
    private func storePrompt(_ prompt: String) throws -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        let id = "p" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        let url = promptsDir.appendingPathComponent(id + ".txt")
        if fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            try Data(prompt.utf8).write(to: url)
        }
        return id
    }

    private func writeDoc(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Местное время со смещением (2026-10-20T16:49:06+03:00), как в именах папок, а не UTC.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            try encoder.encode(session.doc).write(to: session.folder.appendingPathComponent("session.json"))
        } catch {
            Log.warning("История: не удалось записать session.json: \(error.localizedDescription)", .history)
        }
    }

    // MARK: - Чистка

    public func prune(now: Date, retentionDays: Int, maxBytes: Int64) async -> HistoryPruneResult {
        var removedSessions = 0
        var removedPrompts = 0
        var freed: Int64 = 0

        var list = sessionFolders()
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            var kept: [SessionFolder] = []
            for item in list {
                if item.date < cutoff {
                    freed += remove(item.url)
                    removedSessions += 1
                } else {
                    kept.append(item)
                }
            }
            list = kept
        }
        if maxBytes > 0 {
            var sizes = list.map { size(of: $0.url) }
            var total = sizes.reduce(0, +)
            var index = 0
            while total > maxBytes, index < list.count - 1 {
                freed += remove(list[index].url)
                total -= sizes[index]
                sizes[index] = 0
                removedSessions += 1
                index += 1
            }
        }
        removeEmptyDays()

        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            let files = (try? fm.contentsOfDirectory(at: promptsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    freed += remove(file)
                    removedPrompts += 1
                }
            }
        }
        return HistoryPruneResult(removedSessions: removedSessions, removedPrompts: removedPrompts, freedBytes: freed)
    }

    private struct SessionFolder {
        let url: URL
        let sortKey: String
        let date: Date
    }

    /// Сессии по возрастанию (день, время). Дата — из имён папок, иначе дата изменения.
    private func sessionFolders() -> [SessionFolder] {
        var result: [SessionFolder] = []
        let days = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        for day in days {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: day.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dayName = day.lastPathComponent
            let dayDate = Self.dayFormatter.date(from: dayName)
            let items = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let name = item.lastPathComponent
                var date: Date?
                if dayDate != nil, let time = Self.timeFormatter.date(from: String(name.prefix(8))) {
                    let cal = Calendar.current
                    let t = cal.dateComponents([.hour, .minute, .second], from: time)
                    date = cal.date(byAdding: t, to: dayDate!)
                }
                let resolved = date ?? dayDate
                    ?? (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date()
                result.append(SessionFolder(url: item, sortKey: dayName + "/" + name, date: resolved))
            }
        }
        return result.sorted { $0.sortKey < $1.sortKey }
    }

    private func removeEmptyDays() {
        let days = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        for day in days {
            let items = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            if items.isEmpty { try? fm.removeItem(at: day) }
        }
    }

    private func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isRegularFile == true {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let v = try? file.resourceValues(forKeys: keys)
            guard v?.isRegularFile == true else { continue }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Удаляет файл или папку, возвращает освобождённые байты (0 при ошибке).
    private func remove(_ url: URL) -> Int64 {
        let bytes = size(of: url)
        do {
            try fm.removeItem(at: url)
            return bytes
        } catch {
            Log.warning("История: не удалось удалить \(url.lastPathComponent): \(error.localizedDescription)", .history)
            return 0
        }
    }

    // MARK: - Вспомогательное

    private static func safeName(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = text.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return mapped.isEmpty ? "model" : mapped
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let timeFormatter = formatter("HH-mm-ss")
}

/// Содержимое `session.json`. Ключи в файле — snake_case (кодировщик).
private struct SessionDoc: Codable {
    struct Audio: Codable {
        var file: String?
        var seconds: Double
    }
    struct STT: Codable {
        var model: String
        var seconds: Double
        var text: String
    }
    struct Feedback: Codable {
        var index: Int
        var key: Int
        var file: String?
        var seconds: Double
        var sttSeconds: Double
        var text: String
        /// Служебный признак: расшифровка получена. В файл не пишется.
        var transcribed = false

        enum CodingKeys: String, CodingKey { case index, key, file, seconds, sttSeconds, text }
    }
    struct LLM: Codable {
        var index: Int
        var purpose: String
        var key: Int
        var name: String
        var harness: String
        var model: String
        var promptId: String
        var schema: String?
        var input: String
        var output: String?
        var error: String?
        var cancelled: Bool
        var startedAt: Date
        var seconds: Double
        var file: String
    }
    struct Delivery: Codable {
        var at: Date
        var key: Int
        var copyOnly: Bool
        var text: String
    }

    var id: String
    var startedAt: Date
    var targetApp: String?
    var audio: Audio?
    var stt: STT?
    var feedback: [Feedback] = []
    var llm: [LLM] = []
    var deliveries: [Delivery] = []
}
