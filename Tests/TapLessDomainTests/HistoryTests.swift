import Foundation
import Testing
import TapLessData
@testable import TapLessDomain

private actor FakeHistory: HistoryRepository {
    private(set) var events: [(event: HistoryEvent, session: UUID)] = []
    private(set) var pruneCalls: [(retentionDays: Int, maxBytes: Int64)] = []

    func record(_ event: HistoryEvent, session: UUID, at date: Date) async {
        events.append((event, session))
    }

    func prune(now: Date, retentionDays: Int, maxBytes: Int64) async -> HistoryPruneResult {
        pruneCalls.append((retentionDays, maxBytes))
        return HistoryPruneResult(removedSessions: 0, removedPrompts: 0, freedBytes: 0)
    }

    /// Ждёт, пока накопится `count` событий (запись декоратора идёт в отдельном Task).
    func waitForEvents(_ count: Int) async -> [(event: HistoryEvent, session: UUID)] {
        for _ in 0..<500 where events.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return events
    }
}

private struct StubLLM: LLMRepository {
    let result: Result<String, Error>
    func complete(_ request: LLMRequest) async throws -> String { try result.get() }
}

private struct BoomError: LocalizedError {
    var errorDescription: String? { "бум" }
}

private func historyConfig(enabled: Bool = true, saveAudio: Bool = true) -> HistoryConfig {
    HistoryConfig(enabled: enabled, dir: "", saveAudio: saveAudio, retentionDays: 30, maxSizeMB: 2)
}

private func request(purpose: LLMPurpose = .variant) -> LLMRequest {
    LLMRequest(variantKey: 2, variantName: "v", harnessName: "h",
               harness: HarnessConfig(executable: "x", args: []), model: "m",
               systemPrompt: "sys", input: "in", purpose: purpose)
}

private func calls(_ events: [(event: HistoryEvent, session: UUID)]) -> [LLMCallRecord] {
    events.compactMap { if case .llmCall(let c) = $0.event { return c } else { return nil } }
}

@Suite struct DictationHistoryUseCaseTests {
    private let clip = AudioClip(samples: [0, 0.5], peakLevel: 0.5)

    @Test func disabledWritesNothing() async {
        let repo = FakeHistory()
        let useCase = DictationHistoryUseCase(repository: repo, config: historyConfig(enabled: false))
        await useCase.record(.transcript(text: "t", seconds: 1, model: "m"), session: UUID())
        #expect(await repo.events.isEmpty)
    }

    @Test func withoutSaveAudioDropsClipKeepsDuration() async {
        let repo = FakeHistory()
        let useCase = DictationHistoryUseCase(repository: repo, config: historyConfig(saveAudio: false))
        let id = UUID()
        await useCase.record(.recording(clip: clip, duration: 3, targetApp: "App"), session: id)
        await useCase.record(.feedbackRecording(clip: clip, duration: 2, key: 4), session: id)
        let events = await repo.events
        #expect(events.count == 2)
        if case .recording(let c, let d, let app) = events[0].event {
            #expect(c == nil && d == 3 && app == "App")
        } else { Issue.record("ожидалось recording") }
        if case .feedbackRecording(let c, let d, let key) = events[1].event {
            #expect(c == nil && d == 2 && key == 4)
        } else { Issue.record("ожидалось feedbackRecording") }
    }

    @Test func withSaveAudioKeepsClip() async {
        let repo = FakeHistory()
        let useCase = DictationHistoryUseCase(repository: repo, config: historyConfig())
        await useCase.record(.recording(clip: clip, duration: 1, targetApp: nil), session: UUID())
        if case .recording(let c, _, _) = await repo.events[0].event {
            #expect(c != nil)
        } else { Issue.record("ожидалось recording") }
    }

    @Test func pruneRunsEvenWhenDisabled() async {
        let repo = FakeHistory()
        let useCase = DictationHistoryUseCase(repository: repo, config: historyConfig(enabled: false))
        _ = await useCase.prune()
        let calls = await repo.pruneCalls
        #expect(calls.count == 1)
        #expect(calls[0].retentionDays == 30)
        #expect(calls[0].maxBytes == 2 * 1_048_576)
    }
}

@Suite struct HistoryLLMRepositoryTests {
    private func make(_ result: Result<String, Error>, config: HistoryConfig = historyConfig())
        -> (HistoryLLMRepository, FakeHistory) {
        let repo = FakeHistory()
        let history = DictationHistoryUseCase(repository: repo, config: config)
        return (HistoryLLMRepository(base: StubLLM(result: result), history: history), repo)
    }

    @Test func recordsCallWithSession() async throws {
        let (decorator, repo) = make(.success("ответ"))
        let id = UUID()
        let output = try await HistoryContext.$session.withValue(id) {
            try await decorator.complete(request())
        }
        #expect(output == "ответ")
        let events = await repo.waitForEvents(1)
        #expect(events.count == 1)
        #expect(events[0].session == id)
        let record = try #require(calls(events).first)
        #expect(record.output == "ответ" && record.error == nil && !record.cancelled)
        #expect(record.request == request())
    }

    @Test func skipsWithoutSession() async throws {
        let (decorator, repo) = make(.success("ответ"))
        _ = try await decorator.complete(request())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await repo.events.isEmpty)
    }

    @Test func skipsWarmUp() async throws {
        let (decorator, repo) = make(.success("ответ"))
        _ = try await HistoryContext.$session.withValue(UUID()) {
            try await decorator.complete(request(purpose: .warmUp))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await repo.events.isEmpty)
    }

    @Test func recordsAndRethrowsError() async throws {
        let (decorator, repo) = make(.failure(BoomError()))
        await #expect(throws: BoomError.self) {
            try await HistoryContext.$session.withValue(UUID()) {
                try await decorator.complete(request())
            }
        }
        let record = try #require(calls(await repo.waitForEvents(1)).first)
        #expect(record.output == nil && record.error == "бум" && !record.cancelled)
    }

    @Test func recordsCancellation() async throws {
        let (decorator, repo) = make(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await HistoryContext.$session.withValue(UUID()) {
                try await decorator.complete(request())
            }
        }
        let record = try #require(calls(await repo.waitForEvents(1)).first)
        #expect(record.cancelled && record.output == nil)
    }

    @Test func disabledHistoryWritesNothing() async throws {
        let (decorator, repo) = make(.success("x"), config: historyConfig(enabled: false))
        _ = try await HistoryContext.$session.withValue(UUID()) {
            try await decorator.complete(request())
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await repo.events.isEmpty)
    }
}

@Suite struct FormatTextPurposeTests {
    private actor Capture: LLMRepository {
        private(set) var requests: [LLMRequest] = []
        func complete(_ request: LLMRequest) async throws -> String {
            requests.append(request)
            return "ok"
        }
    }

    @Test func purposesAreSet() async throws {
        var config = FileConfigRepository(fileURL: URL(fileURLWithPath: "/nonexistent")).defaults()
        config.llm.feedbackPrompt = "чисти"
        let capture = Capture()
        let useCase = FormatTextUseCase(llm: capture, config: config)
        let key = try #require(useCase.variantKeys.first)
        _ = try await useCase.execute(text: "т", variantKey: key)
        _ = try await useCase.revise(transcript: "т", previous: "п", feedback: "ф", key: key)
        _ = try await useCase.cleanFeedback("з", key: key)
        try await useCase.warmUp(variantKey: key)
        let purposes = await capture.requests.map(\.purpose)
        #expect(purposes.prefix(3) == [.variant, .revision, .feedback])
        if useCase.harnessKind(forVariantKey: key) == .ollama {
            #expect(purposes.last == .warmUp)
        }
    }
}
