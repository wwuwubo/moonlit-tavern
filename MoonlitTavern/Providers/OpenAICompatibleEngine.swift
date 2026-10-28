import Foundation
import MoonlitCore

/// OpenAI Chat Completions 兼容的云端引擎（OpenRouter、各家兼容接口）。
/// 只有用户在设置里切换到「云端模式」时才会被调用；本地模式下聊天内容不会经过这里。
final class OpenAICompatibleEngine: InferenceEngine, @unchecked Sendable {
    let engineName = "OpenAI 兼容 API"
    let isLocal = false

    private let settings: CloudSettings
    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?

    init(settings: CloudSettings) {
        self.settings = settings
    }

    func tokenCounter() -> TokenCounter? { nil }

    func cancel() {
        lock.lock()
        currentTask?.cancel()
        lock.unlock()
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stats = try await self.run(request) { continuation.yield($0) }
                    continuation.yield(.finished(stats))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: InferenceError.cancelled)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: InferenceError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lock.lock()
            currentTask = task
            lock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: GenerationRequest, emit: (GenerationEvent) -> Void) async throws -> GenerationStats {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty,
              !settings.model.isBlank,
              let url = OpenAICompatible.chatCompletionsURL(base: settings.baseURL) else {
            throw InferenceError.cloudNotConfigured
        }
        let start = Date()
        emit(.progress(.connecting, nil))

        var urlRequest = URLRequest(url: url, timeoutInterval: settings.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if url.host?.contains("openrouter.ai") == true {
            urlRequest.setValue("Moonlit Tavern", forHTTPHeaderField: "X-Title")
        }
        for (key, value) in settings.extraHeaders where key.lowercased() != "authorization" {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try OpenAICompatible.requestBody(model: settings.model, request: request)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.cloudProtocol("不是 HTTP 响应")
        }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 8192 { break }
            }
            throw InferenceError.cloudHTTP(status: http.statusCode, message: OpenAICompatible.errorMessage(from: body))
        }

        var parser = OpenAICompatible.SSEParser()
        var filter = StreamingTextFilter(stopSequences: request.stopSequences, hideThinking: true)
        var firstTokenAt: Date?
        var chunks = 0
        var stopReason = "自然结束"
        emit(.progress(.generating, nil))

        lineLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parser.parse(line: line) else { continue }
            switch event {
            case .delta(let text):
                if firstTokenAt == nil { firstTokenAt = Date() }
                chunks += 1
                let visible = filter.feed(text)
                if !visible.isEmpty { emit(.text(visible)) }
                if filter.stopped { stopReason = "停止词"; break lineLoop }
            case .done(let reason):
                if reason == "length" { stopReason = "长度上限" }
                break lineLoop
            case .error(let message):
                throw InferenceError.cloudHTTP(status: http.statusCode, message: message)
            }
        }
        let rest = filter.finish()
        if !rest.isEmpty { emit(.text(rest)) }

        let end = Date()
        let first = firstTokenAt ?? end
        return GenerationStats(
            engine: engineName,
            modelName: settings.model,
            promptTokens: parser.promptTokens ?? 0,
            promptTokensEvaluated: parser.promptTokens ?? 0,
            generatedTokens: parser.completionTokens ?? chunks,
            timeToFirstToken: first.timeIntervalSince(start),
            promptSeconds: first.timeIntervalSince(start),
            generationSeconds: end.timeIntervalSince(first),
            contextLength: 0,
            stopReason: stopReason,
            peakMemoryMB: nil
        )
    }
}
