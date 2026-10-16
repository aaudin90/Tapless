import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

/// LLM, которая отвечает только после `open()`, и считает одновременные запросы.
private actor GatedLLM: LLMRepository {
    private var gate: [CheckedContinuation<Void, Never>] = []
    private(set) var started: [Int] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    func complete(_ request: LLMRequest) async throws -> String {
        started.append(request.variantKey)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        await withCheckedContinuation { gate.append($0) }
        inFlight -= 1
        try Task.checkCancellation()
        return "ok \(request.variantKey)"
    }

    /// Отпускает все ждущие запросы.
    func open() {
        gate.forEach { $0.resume() }
        gate.removeAll()
    }

    var waiting: Int { gate.count }
}

/// LLM, которая всегда падает: слот очереди должен освобождаться и при ошибке.
private struct FailingLLM: LLMRepository {
    func complete(_ request: LLMRequest) async throws -> String {
        throw LLMError.launch("тест")
    }
}

private func request(_ key: Int, harness: HarnessConfig) -> LLMRequest {
    LLMRequest(variantKey: key, variantName: "v\(key)", harnessName: "ollama", harness: harness,
               model: "m", systemPrompt: "s", input: "i")
}

/// Ждёт условие (до 2 с): запросы стартуют асинхронно.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@Suite struct RequestLimiterTests {
    @Test func limitsConcurrentRequestsPerHarness() async throws {
        let llm = GatedLLM()
        let routing = RoutingLLMRepository(process: llm, ollama: llm)
        let harness = HarnessConfig.ollama(url: "http://127.0.0.1:11434", parallel: 2)

        let tasks = (1...5).map { key in Task { try await routing.complete(request(key, harness: harness)) } }
        #expect(await eventually { await llm.waiting == 2 })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await llm.started.count == 2)

        while await llm.started.count < 5 {
            await llm.open()
            _ = await eventually { await llm.waiting > 0 }
        }
        await llm.open()
        var results: [String] = []
        for task in tasks { results.append(try await task.value) }
        #expect(results == (1...5).map { "ok \($0)" })
        #expect(await llm.maxInFlight == 2)
    }

    @Test func ollamaHarnessesShareServerQueue() {
        let a = LLMRequest(variantKey: 2, variantName: "a", harnessName: "fast", harness: .ollama(url: "http://h:1 "),
                           model: "m", systemPrompt: "s", input: "i")
        let b = LLMRequest(variantKey: 3, variantName: "b", harnessName: "slow", harness: .ollama(url: "http://h:1"),
                           model: "m", systemPrompt: "s", input: "i")
        let cli = LLMRequest(variantKey: 4, variantName: "c", harnessName: "claude", harness: HarnessConfig(executable: "c", args: []),
                             model: "m", systemPrompt: "s", input: "i")
        #expect(RoutingLLMRepository.queueKey(a) == RoutingLLMRepository.queueKey(b))
        #expect(RoutingLLMRepository.queueKey(cli) == "harness claude")
    }

    @Test func failedRequestReleasesSlot() async throws {
        let routing = RoutingLLMRepository(process: FailingLLM(), ollama: FailingLLM())
        let harness = HarnessConfig.ollama(url: "http://127.0.0.1:11434", parallel: 1)
        for key in 1...3 {
            await #expect(throws: LLMError.self) { try await routing.complete(request(key, harness: harness)) }
        }
    }

    @Test func zeroMeansNoLimit() async throws {
        let llm = GatedLLM()
        let routing = RoutingLLMRepository(process: llm, ollama: llm)
        let harness = HarnessConfig.ollama(url: "http://127.0.0.1:11434")

        let tasks = (1...4).map { key in Task { try await routing.complete(request(key, harness: harness)) } }
        #expect(await eventually { await llm.waiting == 4 })
        await llm.open()
        for task in tasks { _ = try await task.value }
        #expect(await llm.maxInFlight == 4)
    }

    @Test func cancelledWaiterLeavesQueue() async throws {
        let limiter = RequestLimiter()
        try await limiter.acquire("h", limit: 1)
        let waiter = Task { try await limiter.acquire("h", limit: 1) }
        #expect(await eventually { await limiter.counts("h").waiting == 1 })

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await eventually { await limiter.counts("h").waiting == 0 })

        await limiter.release("h")
        #expect(await limiter.counts("h").running == 0)
        #expect(try await limiter.acquire("h", limit: 1) == false)
    }

    @Test func releaseHandsSlotToNextWaiter() async throws {
        let limiter = RequestLimiter()
        try await limiter.acquire("h", limit: 1)
        let waiter = Task { try await limiter.acquire("h", limit: 1) }
        #expect(await eventually { await limiter.counts("h").waiting == 1 })
        await limiter.release("h")
        #expect(try await waiter.value == true)
        #expect(await limiter.counts("h").running == 1)
        #expect(await limiter.counts("h").waiting == 0)
    }
}
