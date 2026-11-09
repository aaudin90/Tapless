import Foundation
import Testing
@testable import TapLessData

@Suite final class InstanceLockTests {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("instance.lock") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func secondAcquireFailsWhileHeld() throws {
        guard case .acquired(let first) = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05) else {
            Issue.record("первый замок не занят")
            return
        }
        let second = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05)
        guard case .alreadyRunning = second else {
            Issue.record("второй замок должен быть отклонён: \(second)")
            return
        }
        first.release()
    }

    @Test func acquireSucceedsAfterRelease() throws {
        guard case .acquired(let first) = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05) else {
            Issue.record("первый замок не занят")
            return
        }
        first.release()
        guard case .acquired(let second) = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05) else {
            Issue.record("замок не занялся после release")
            return
        }
        second.release()
    }

    @Test func acquireWaitsForRelease() throws {
        guard case .acquired(let first) = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05) else {
            Issue.record("первый замок не занят")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { first.release() }
        guard case .acquired(let second) = InstanceLock.acquire(at: file, timeout: 3, pollInterval: 0.05) else {
            Issue.record("ожидание отпускания замка не сработало")
            return
        }
        second.release()
    }

    @Test func descriptorIsCloseOnExec() throws {
        guard case .acquired(let lock) = InstanceLock.acquire(at: file, timeout: 0.2, pollInterval: 0.05) else {
            Issue.record("замок не занят")
            return
        }
        let flags = fcntl(lock.fileDescriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
        lock.release()
    }

    @Test func missingDirectoryIsUnavailable() {
        let result = InstanceLock.acquire(at: directory.appendingPathComponent("нет/instance.lock"), timeout: 0.1)
        guard case .unavailable = result else {
            Issue.record("ожидалось .unavailable: \(result)")
            return
        }
    }
}
