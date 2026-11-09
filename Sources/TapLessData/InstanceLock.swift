import Foundation

/// Результат попытки занять замок единственного экземпляра.
public enum InstanceLockResult {
    /// Замок занят этим процессом. Держите объект до выхода из программы.
    case acquired(InstanceLock)
    /// Замком владеет другой процесс (и не отпустил за время ожидания).
    case alreadyRunning
    /// Замок открыть не удалось (нет папки, нет прав и т. п.): это не повод отказываться от запуска.
    case unavailable(String)
}

/// Замок единственного экземпляра: `flock(LOCK_EX)` на файле. Ядро снимает замок само, когда процесс
/// завершается (в том числе падает), поэтому «залипшего» замка не бывает.
///
/// Дескриптор открыт с `O_CLOEXEC`: TapLess запускает дочерние процессы через `posix_spawn`, а `ollama serve`
/// переживает TapLess. Унаследованный дескриптор держал бы замок, пока жив потомок.
public final class InstanceLock: @unchecked Sendable {
    private var descriptor: Int32

    /// Дескриптор файла замка (-1 после `release`). Нужен тестам.
    var fileDescriptor: Int32 { descriptor }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Занимает замок на файле `url`. Если замок занят, опрашивает его каждые `pollInterval` секунд до `timeout`:
    /// после `build_app.sh --install` и обновления новый процесс стартует сразу после смерти старого.
    public static func acquire(at url: URL, timeout: TimeInterval = 3, pollInterval: TimeInterval = 0.1) -> InstanceLockResult {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return .unavailable("open: \(String(cString: strerror(errno)))")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return .acquired(InstanceLock(descriptor: descriptor))
            }
            let code = errno
            guard code == EWOULDBLOCK else {
                close(descriptor)
                return .unavailable("flock: \(String(cString: strerror(code)))")
            }
            guard Date() < deadline else {
                close(descriptor)
                return .alreadyRunning
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Отпускает замок. После этого другой процесс (или другой дескриптор) может его занять.
    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
