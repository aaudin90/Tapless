import Foundation
import TapLessDomain

/// LLM через HTTP API локального сервера Ollama (`POST /api/chat`), без CLI.
///
/// Системный промпт и текст уходят сообщениями `system` и `user`, ответ — одним JSON
/// (`stream: false`). Схема варианта передаётся в `format`, Ollama сам ограничивает ответ ею.
public struct OllamaLLMRepository: LLMRepository {
    private let settings: LLMConfig
    private let session: URLSession

    /// - Parameter session: сессия для запросов; в тестах — с подменённым транспортом.
    public init(settings: LLMConfig, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let label = "\(request.variantKey) \(request.variantName)"
        let harness = request.harness
        let timeout = max(5, settings.timeoutSeconds)

        let base = harness.url.trimmingCharacters(in: .whitespaces)
        guard let endpoint = URL(string: base.hasSuffix("/") ? base + "api/chat" : base + "/api/chat"),
              endpoint.scheme != nil, endpoint.host != nil else {
            Log.error("[\(label)] неверный url Ollama: «\(harness.url)»", .llm)
            throw LLMError.launch("неверный url Ollama: «\(harness.url)»")
        }

        let schema = try request.schema.map { try SchemaSource.load($0) }
        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.input],
            ],
            "stream": false,
        ]
        if let think = Self.think(harness.think) { body["think"] = think }
        if let keepAlive = Self.keepAlive(harness.keepAlive) { body["keep_alive"] = keepAlive }
        if !harness.options.isEmpty { body["options"] = harness.options }
        if let schema { body["format"] = schema.object }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.info("[\(label)] harness «\(request.harnessName)»: Ollama \(endpoint.absoluteString), модель \(request.model)"
                 + (request.schema.map { ", схема «\($0.name)»" } ?? "")
                 + ", вход \(Log.text(request.input))", .llm)
        Log.debug("[\(label)] think=\(harness.think.isEmpty ? "—" : harness.think), "
                  + "keep_alive=\(harness.keepAlive.isEmpty ? "—" : harness.keepAlive), "
                  + "options=\(harness.options.isEmpty ? "—" : harness.options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")), "
                  + "системный промпт \(request.systemPrompt.count) симв., таймаут \(Int(timeout)) с", .llm)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                Log.debug("[\(label)] запрос к Ollama отменён", .llm)
                throw CancellationError()
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    Log.error("[\(label)] Ollama: нет ответа за \(Int(timeout)) с", .llm)
                    throw LLMError.timeout(timeout)
                case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                    Log.error("[\(label)] Ollama недоступен: \(urlError.localizedDescription)", .llm)
                    throw LLMError.serverUnavailable(base, urlError.localizedDescription)
                default:
                    break
                }
            }
            Log.error("[\(label)] Ollama: \(error.localizedDescription)", .llm)
            throw LLMError.launch(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(started)

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = json?["error"] as? String ?? String(decoding: data.prefix(500), as: UTF8.self)
            Log.error("[\(label)] Ollama: HTTP \(status) за \(String(format: "%.2f", elapsed)) с: \(message)", .llm)
            if status == 404, message.contains("not found") { throw LLMError.modelMissing(request.model) }
            throw LLMError.http(status, message)
        }
        guard let json, let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            Log.error("[\(label)] Ollama: в ответе нет message.content: \(String(decoding: data.prefix(500), as: UTF8.self))", .llm)
            throw LLMError.badOutput("в ответе Ollama нет message.content")
        }
        Log.debug("[\(label)] Ollama: \(Self.metrics(json, thinking: message["thinking"] as? String))", .llm)

        let result: String
        if let requestSchema = request.schema {
            do {
                result = try HarnessOutputParser.extract(from: content, format: .json, path: "",
                                                         resultPath: requestSchema.config.resultPath)
            } catch {
                Log.error("[\(label)] \(error.localizedDescription). content: \(ShellTools.lastLines(content, maxChars: 800))", .llm)
                throw error
            }
        } else {
            result = content
        }
        Log.info(String(format: "[%@] готово за %.1f с, %ld симв.", label, elapsed, result.count), .llm)
        return result
    }

    // MARK: - Параметры запроса

    /// `think`: пусто — не передавать; `true` / `false` — флаг; иначе уровень строкой.
    static func think(_ value: String) -> Any? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return nil
        case "true": return true
        case "false": return false
        case let level: return level
        }
    }

    /// `keep_alive`: число секунд (`"-1"` — навсегда, `"0"` — выгрузить сразу) или длительность (`"30m"`).
    static func keepAlive(_ value: String) -> Any? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let seconds = Int(trimmed) { return seconds }
        return trimmed
    }

    /// Время загрузки модели, разбора промпта и генерации из ответа Ollama (наносекунды).
    static func metrics(_ json: [String: Any], thinking: String?) -> String {
        func seconds(_ key: String) -> Double { ((json[key] as? NSNumber)?.doubleValue ?? 0) / 1e9 }
        func count(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }
        let evalSeconds = seconds("eval_duration")
        let speed = evalSeconds > 0 ? Double(count("eval_count")) / evalSeconds : 0
        var parts = [
            String(format: "всего %.2f с", seconds("total_duration")),
            String(format: "загрузка %.2f с", seconds("load_duration")),
            String(format: "промпт %ld ток. за %.2f с", count("prompt_eval_count"), seconds("prompt_eval_duration")),
            String(format: "ответ %ld ток. за %.2f с (%.0f ток/с)", count("eval_count"), evalSeconds, speed),
        ]
        if let thinking, !thinking.isEmpty { parts.append("рассуждение \(thinking.count) симв.") }
        return parts.joined(separator: ", ")
    }
}
