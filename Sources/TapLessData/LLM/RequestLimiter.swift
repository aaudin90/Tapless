import Foundation
import TapLessDomain

/// Очередь запросов к harness: одновременно идёт не больше `limit` запросов
/// с одним ключом (имя harness), остальные ждут по порядку поступления.
/// Отменённый запрос уходит из очереди с `CancellationError`.
actor RequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var running: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]

    /// Ждёт свободный слот. true — запрос стоял в очереди.
    @discardableResult
    func acquire(_ key: String, limit: Int) async throws -> Bool {
        try Task.checkCancellation()
        if running[key, default: 0] < limit {
            running[key, default: 0] += 1
            return false
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Отмена могла прийти до постановки в очередь: onCancel тогда никого не нашёл.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(key, id: id) }
        }
        return true
    }

    /// Освобождает слот: его сразу получает первый в очереди.
    func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.continuation.resume()
        } else {
            running[key] = max(0, running[key, default: 0] - 1)
        }
    }

    /// Сколько запросов ждёт и сколько идёт — для тестов.
    func counts(_ key: String) -> (running: Int, waiting: Int) {
        (running[key, default: 0], waiters[key]?.count ?? 0)
    }

    private func cancel(_ key: String, id: UUID) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
