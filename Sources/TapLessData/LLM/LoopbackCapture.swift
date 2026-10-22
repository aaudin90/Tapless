import Foundation
import Network

/// HTTP-сервер на `127.0.0.1` для проверки Codex: записывает запросы и на все отвечает ошибкой,
/// чтобы Codex сразу завершился. До настоящего провайдера запрос не доходит.
final class LoopbackCapture: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Имена — в нижнем регистре.
        var headers: [String: String]
        var body: Data
    }

    /// Больше запрос не бывает: каталог инструментов и промпт — сотни КБ.
    private static let maxRequestSize = 64 << 20

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.aaudin90.tapless.codex-verify")
    private let lock = NSLock()
    private var captured: [Request] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Запросы, которые уже пришли.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// Запускает сервер. Возвращает порт.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    once.run { continuation.resume(returning: port) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.lock()
                self.captured.append(request)
                self.lock.unlock()
                self.respond(connection, status: request.method == "POST" ? 400 : 404)
            } else if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int) {
        let body = Data(#"{"error":{"message":"TapLess: проверка Codex","type":"invalid_request_error"}}"#.utf8)
        let head = "HTTP/1.1 \(status) \(status == 400 ? "Bad Request" : "Not Found")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Разбирает HTTP-запрос. nil — запрос пришёл не целиком.
    static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = buffer[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(Data(rest)) else { return nil }
            body = decoded
        } else {
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: body)
    }

    /// Тело `Transfer-Encoding: chunked`. nil — пришло не целиком.
    private static func dechunk(_ data: Data) -> Data? {
        var body = Data()
        var position = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: position..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[position..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 { return body }
            let chunkStart = lineEnd.upperBound
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            body.append(data[chunkStart..<chunkEnd])
            position = data.index(chunkEnd, offsetBy: 2)
        }
    }
}

/// Продолжение возобновляется один раз: состояние слушателя может смениться несколько раз.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
