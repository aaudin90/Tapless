import Foundation
import Testing
import TapLessDomain
@testable import TapLessData

private func makeRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapless-history-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func llmRequest(prompt: String = "системный промпт", model: String = "gemma4:e4b-it-q4_K_M") -> LLMRequest {
    LLMRequest(variantKey: 2, variantName: "Вариант", harnessName: "ollama",
               harness: .ollama(url: "http://x"), model: model, systemPrompt: prompt, input: "вход")
}

private func contents(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
}

private func makeSessionFolder(_ root: URL, day: String, name: String, bytes: Int = 10) throws {
    let dir = root.appendingPathComponent("history/\(day)/\(name)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent("audio.wav"))
}

@Suite struct FileHistoryRepositoryTests {
    @Test func recordsSessionFiles() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        let id = UUID()
        let date = Date()
        let clip = AudioClip(samples: [0, 1, -1, 2, 0.5], peakLevel: 1)

        await repo.record(.recording(clip: clip, duration: 0.5, targetApp: "Notes"), session: id, at: date)
        await repo.record(.transcript(text: "привет", seconds: 1.5, model: "whisper"), session: id, at: date)
        let call = LLMCallRecord(request: llmRequest(), output: "ответ", error: nil, cancelled: false,
                                 startedAt: date, seconds: 0.7)
        await repo.record(.llmCall(call), session: id, at: date)
        await repo.record(.delivered(key: 2, text: "ответ", copyOnly: false), session: id, at: date)

        let history = root.appendingPathComponent("history")
        let days = contents(history)
        #expect(days.count == 1)
        let sessions = contents(history.appendingPathComponent(days[0]))
        #expect(sessions.count == 1)
        #expect(sessions[0].hasSuffix("_" + id.uuidString.lowercased().prefix(8)))
        let folder = history.appendingPathComponent(days[0]).appendingPathComponent(sessions[0])
        #expect(contents(folder) == ["audio.wav", "llm", "session.json", "transcript.txt"])

        let wav = try Data(contentsOf: folder.appendingPathComponent("audio.wav"))
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
        #expect(uint32(wav, 24) == 16000)
        #expect(uint32(wav, 40) == 2 * 5)
        #expect(wav.count == 44 + 10)

        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8) == "привет")

        let promptFiles = contents(root.appendingPathComponent("prompts"))
        #expect(promptFiles.count == 1)
        let promptId = promptFiles[0].replacingOccurrences(of: ".txt", with: "")
        #expect(promptId.hasPrefix("p") && promptId.count == 9)
        let llmFiles = contents(folder.appendingPathComponent("llm"))
        #expect(llmFiles == ["01-variant2-gemma4-e4b-it-q4_K_M-\(promptId).txt"])
        #expect(try String(contentsOf: folder.appendingPathComponent("llm/" + llmFiles[0]), encoding: .utf8) == "ответ")

        let json = try String(contentsOf: folder.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(json.contains("\"target_app\" : \"Notes\""))
        #expect(json.contains("\"prompt_id\" : \"\(promptId)\""))
        #expect(json.contains("\"copy_only\" : false"))
        // Время — местное, со смещением пояса, как в именах папок.
        let local = ISO8601DateFormatter()
        local.timeZone = .current
        #expect(json.contains("\"started_at\" : \"\(local.string(from: date))\""))
    }

    @Test func recordsErrorAndFeedback() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        let id = UUID()
        let date = Date()
        await repo.record(.feedbackRecording(clip: nil, duration: 1, key: 3), session: id, at: date)
        await repo.record(.feedbackTranscript(text: "замечание", seconds: 0.4, model: "w", key: 3), session: id, at: date)
        let call = LLMCallRecord(request: llmRequest(), output: nil, error: "сбой", cancelled: false,
                                 startedAt: date, seconds: 1)
        await repo.record(.llmCall(call), session: id, at: date)

        let history = root.appendingPathComponent("history")
        let day = history.appendingPathComponent(contents(history)[0])
        let folder = day.appendingPathComponent(contents(day)[0])
        #expect(contents(folder) == ["feedback-1.txt", "llm", "session.json"])
        let llmFile = contents(folder.appendingPathComponent("llm"))[0]
        #expect(try String(contentsOf: folder.appendingPathComponent("llm/" + llmFile), encoding: .utf8) == "ОШИБКА: сбой")
    }

    @Test func repeatedPromptKeepsFileAndRefreshesDate() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        let id = UUID()
        let call = LLMCallRecord(request: llmRequest(), output: "a", error: nil, cancelled: false,
                                 startedAt: Date(), seconds: 1)
        await repo.record(.llmCall(call), session: id, at: Date())
        let prompts = root.appendingPathComponent("prompts")
        let file = prompts.appendingPathComponent(contents(prompts)[0])
        let old = Date(timeIntervalSinceNow: -86_400 * 5)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        await repo.record(.llmCall(call), session: id, at: Date())
        #expect(contents(prompts).count == 1)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        #expect(modified.timeIntervalSince(old) > 86_400)
    }

    @Test func pruneByAge() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        try makeSessionFolder(root, day: "2020-01-01", name: "10-00-00_aaaaaaaa")
        let today = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        try makeSessionFolder(root, day: f.string(from: today), name: "00-00-00_bbbbbbbb")

        let result = await repo.prune(now: today, retentionDays: 30, maxBytes: 0)
        #expect(result.removedSessions == 1)
        #expect(result.freedBytes > 0)
        let history = root.appendingPathComponent("history")
        #expect(contents(history) == [f.string(from: today)])
    }

    @Test func pruneBySizeKeepsNewest() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        try makeSessionFolder(root, day: "2026-10-18", name: "10-00-00_aaaaaaaa", bytes: 100_000)
        try makeSessionFolder(root, day: "2026-10-19", name: "10-00-00_bbbbbbbb", bytes: 100_000)
        try makeSessionFolder(root, day: "2026-10-20", name: "10-00-00_cccccccc", bytes: 100_000)

        let result = await repo.prune(now: Date(), retentionDays: 0, maxBytes: 1)
        #expect(result.removedSessions == 2)
        let history = root.appendingPathComponent("history")
        #expect(contents(history) == ["2026-10-20"])
        #expect(contents(history.appendingPathComponent("2026-10-20")) == ["10-00-00_cccccccc"])
    }

    @Test func pruneRemovesOldPrompts() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileHistoryRepository(root: root)
        let prompts = root.appendingPathComponent("prompts")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        let oldFile = prompts.appendingPathComponent("pold00000.txt")
        let freshFile = prompts.appendingPathComponent("pnew00000.txt")
        try Data("a".utf8).write(to: oldFile)
        try Data("b".utf8).write(to: freshFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 60)],
                                              ofItemAtPath: oldFile.path)

        let result = await repo.prune(now: Date(), retentionDays: 30, maxBytes: 0)
        #expect(result.removedPrompts == 1)
        #expect(contents(prompts) == ["pnew00000.txt"])

        let kept = await repo.prune(now: Date(), retentionDays: 0, maxBytes: 0)
        #expect(kept.removedPrompts == 0)
    }

    @Test func historyRootDefaultsToCache() {
        #expect(AppPaths.historyRoot(custom: "").path.hasSuffix("/.cache/tapless"))
        #expect(AppPaths.historyRoot(custom: "~/x").path.hasSuffix("/x"))
        #expect(!AppPaths.historyRoot(custom: "~/x").path.contains("~"))
    }
}
