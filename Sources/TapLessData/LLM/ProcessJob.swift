import Foundation
import TapLessDomain

// MARK: - Запуск процесса

/// Запуск `shell [-l] -c script arguments…`. В `script` аргументы доступны как `$0`, `$1`…
struct ProcessSpec: Sendable {
    var shell: String
    var loginShell: Bool
    var script: String
    var arguments: [String] = []
    var input: String
    var environment: [String: String]
    var workdir: URL
    var timeout: TimeInterval
    var label: String
}

/// Один запуск команды. `cancel()` можно вызвать из любого потока.
///
/// Команда стартует через `posix_spawn` в отдельной группе процессов: таймаут и отмена
/// останавливают всю группу (SIGTERM, через 2 с — SIGKILL), поэтому потомки shell не остаются сиротами.
final class ProcessJob: @unchecked Sendable {
    /// Сколько ждём SIGTERM, прежде чем послать SIGKILL всей группе.
    private static let killGrace: TimeInterval = 2
    /// Сколько ждём EOF пайпов после выхода лидера группы.
    private static let drainGrace: TimeInterval = 1

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var timedOut = false
    /// Лидер реапнут и очистка закончена: сигналы группе слать нельзя (pgid мог быть переиспользован).
    private var finished = false

    /// Накопитель вывода одного пайпа. `finish()` выходит из группы ровно один раз.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var done = false
        private let group: DispatchGroup

        init(group: DispatchGroup) {
            self.group = group
            group.enter()
        }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        func finish() {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { group.leave() }
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let started = pid > 0
        lock.unlock()
        if started { stopGroup() }
    }

    /// SIGTERM всей группе, через `killGrace` — SIGKILL, если очистка ещё не закончена.
    private func stopGroup() {
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            signalGroup(SIGKILL)
        }
    }

    private func signalGroup(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, !finished else { return }
        _ = kill(-pid, signal)
    }

    /// Отменённый запуск бросает `CancellationError`.
    func run(_ spec: ProcessSpec) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: { try self.runBlocking(spec) }))
            }
        }
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }

    /// Запускает процесс лидером новой группы. Возвращает pid или код ошибки `posix_spawn`.
    private static func spawn(_ spec: ProcessSpec, stdin: Int32, stdout: Int32, stderr: Int32) -> (pid: pid_t, error: Int32) {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdin, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderr, 2)
        let chdirResult = posix_spawn_file_actions_addchdir_np(&fileActions, spec.workdir.path)
        if chdirResult != 0 { return (0, chdirResult) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = [spec.shell] + (spec.loginShell ? ["-l"] : []) + ["-c", spec.script] + spec.arguments
        let envp = spec.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, spec.shell, &fileActions, &attributes, argvPointers, envPointers)
            }
        }
        return (pid, result)
    }

    private func runBlocking(_ spec: ProcessSpec) throws -> String {
        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let writer = stdinPipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)

        let started = Date()
        let spawned = Self.spawn(
            spec,
            stdin: stdinPipe.fileHandleForReading.fileDescriptor,
            stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderr: stderrPipe.fileHandleForWriting.fileDescriptor
        )
        // Концы ребёнка в родителе не нужны: иначе не будет EOF.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if spawned.error != 0 {
            try? writer.close()
            let reason = "\(spec.shell): \(String(cString: strerror(spawned.error)))"
            Log.error("[\(spec.label)] не запустился: \(reason), рабочая папка \(spec.workdir.path)", .llm)
            throw LLMError.launch(reason)
        }
        let childPid = spawned.pid
        Log.debug("[\(spec.label)] pid \(childPid), вход \(spec.input.utf8.count) байт, таймаут \(Int(spec.timeout)) с", .llm)

        lock.lock()
        pid = childPid
        let cancelledEarly = cancelled
        lock.unlock()
        if cancelledEarly { stopGroup() }

        let timer = DispatchWorkItem { [self] in
            lock.lock()
            let alive = !finished
            if alive { timedOut = true }
            lock.unlock()
            if alive { stopGroup() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + spec.timeout, execute: timer)

        // stdin пишем отдельно, чтобы не зависнуть, если процесс не читает вход. Ошибки (EPIPE) не важны.
        let inputData = Data(spec.input.utf8)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: inputData)
            try? writer.close()
        }

        // stdout и stderr читаем без блокировки потока: EOF приходит пустым availableData.
        let group = DispatchGroup()
        let outCollector = Collector(group: group)
        let errCollector = Collector(group: group)
        let outReader = stdoutPipe.fileHandleForReading
        let errReader = stderrPipe.fileHandleForReading
        for (reader, collector) in [(outReader, outCollector), (errReader, errCollector)] {
            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collector.finish()
                } else {
                    collector.append(data)
                }
            }
        }

        var status: Int32 = 0
        while waitpid(childPid, &status, 0) == -1 {
            if errno != EINTR { status = 0; break }
        }

        // Лидер вышел: даём пайпам дочитаться, потом добиваем остатки группы.
        _ = group.wait(timeout: .now() + Self.drainGrace)
        lock.lock()
        _ = kill(-childPid, SIGKILL)
        finished = true
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        lock.unlock()
        timer.cancel()
        outReader.readabilityHandler = nil
        errReader.readabilityHandler = nil
        try? outReader.close()
        try? errReader.close()

        let elapsed = Date().timeIntervalSince(started)
        let stdout = String(decoding: outCollector.snapshot(), as: UTF8.self)
        let stderr = String(decoding: errCollector.snapshot(), as: UTF8.self)

        let summary = String(format: "[%@] процесс завершён за %.2f с, stdout %ld байт, stderr %ld байт",
                             spec.label, elapsed, stdout.utf8.count, stderr.utf8.count)
        if wasCancelled {
            Log.info("[\(spec.label)] отменён через \(String(format: "%.1f", elapsed)) с", .llm)
            throw CancellationError()
        }
        if wasTimedOut {
            Log.error("[\(spec.label)] нет ответа за \(Int(spec.timeout)) с, остановлен. stderr: \(ShellTools.lastLines(stderr, maxChars: 800))", .llm)
            throw LLMError.timeout(spec.timeout)
        }

        let signal = status & 0x7f
        if signal != 0 {
            let details = ShellTools.lastLines(stderr.isEmpty ? stdout : stderr, maxChars: 300)
            Log.error("\(summary); убит сигналом \(signal): \(ShellTools.lastLines(stderr + "\n" + stdout, maxChars: 800))", .llm)
            throw LLMError.killed(signal, details)
        }
        let code = (status >> 8) & 0xff
        guard code == 0 else {
            // claude -p пишет ошибки (например, нет логина) в stdout — показываем и то, и другое.
            let details = ShellTools.lastLines(stderr.isEmpty ? stdout : stderr, maxChars: 300)
            Log.error("\(summary); код \(code): \(ShellTools.lastLines(stderr + "\n" + stdout, maxChars: 800))", .llm)
            throw LLMError.failed(code, details)
        }
        Log.debug("\(summary), код 0", .llm)
        // Codex повторяет в stderr вход и ответ, поэтому stderr удачного запуска — только с include_text.
        if !stderr.isEmpty && Log.includeText {
            Log.debug("[\(spec.label)] stderr: \(ShellTools.lastLines(stderr, maxChars: 800))", .llm)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Log.error("[\(spec.label)] пустой stdout. stderr: \(ShellTools.lastLines(stderr, maxChars: 800))", .llm)
            throw LLMError.emptyOutput(ShellTools.lastLines(stderr, maxChars: 200))
        }
        return stdout
    }
}
