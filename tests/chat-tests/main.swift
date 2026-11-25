// Standalone: compile with scripts/run-tests.sh's COMMON_SOURCES, without NC_APP.
// All HTTP is intercepted; all configuration reads use synthetic argument-domain values.
import Foundation
import AppKit
import Combine
import Security
import LocalAuthentication

private final class ChatTestProtocol: URLProtocol {
    private struct Entry {
        let loader: ChatTestProtocol
        let request: URLRequest
        var stopped = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.entries.append(Entry(loader: self, request: captured))
        Self.lock.unlock()
    }
    override func stopLoading() {
        Self.lock.lock()
        if let index = Self.entries.firstIndex(where: { $0.loader === self }) {
            Self.entries[index].stopped = true
        }
        Self.lock.unlock()
    }
    static func reset() {
        lock.lock()
        entries = []
        lock.unlock()
    }
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
    static func wasStopped(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices.contains(index) && entries[index].stopped
    }
    static func capturedRequest(_ index: Int) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices.contains(index) ? entries[index].request : nil
    }
    static func respond(_ index: Int, status: Int = 200, body: String, finish: Bool = true, includeDone: Bool = true) {
        lock.lock()
        let entry = entries.indices.contains(index) ? entries[index] : nil
        lock.unlock()
        guard let entry, !entry.stopped else { return }
        let loader = entry.loader
        let response = HTTPURLResponse(url: entry.request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        let responseBody = finish && status == 200 && includeDone && !body.contains("[DONE]")
            ? body + "\ndata: [DONE]\n\n" : body
        loader.client?.urlProtocol(loader, didLoad: Data(responseBody.utf8))
        if finish { loader.client?.urlProtocolDidFinishLoading(loader) }
    }
}

@MainActor
private final class ChatTests {
    private var passed = 0
    private var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() { passed += 1; print("PASS  \(label)") }
        else { failed += 1; print("FAIL  \(label)") }
    }
    func wait(_ label: String, until condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, "timeout: \(label)")
    }
    func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    func configure(_ suffix: String = "a", profileID: UUID = UUID(), model: String? = nil,
                   reasoningEffort: ReasoningEffort? = nil) {
        let profile = ModelProfile(id: profileID, name: "synthetic \(suffix)", baseURL: "https://chat-\(suffix).invalid/v1",
                                   apiKey: "synthetic-\(suffix)", model: model ?? "model-\(suffix)",
                                   reasoningEffort: reasoningEffort)
        Config.defaults.setVolatileDomain([
            "nc.profiles": try! JSONEncoder().encode([profile]),
            "nc.activeProfileID": profile.id.uuidString,
            "nc.baseURL": "", "nc.apiKey": "", "nc.model": "",
            "nc.sys": "system-\(suffix)", "nc.temp": suffix == "a" ? 0.25 : 0.75,
            "nc.maxTokens": suffix == "a" ? 321 : 654,
            "nc.continuous": true,
        ], forName: UserDefaults.argumentDomain)
    }

    func replacingRequestKeepsNewRequestBusy() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "request A")
        await wait("request A starts") { ChatTestProtocol.count == 1 }
        engine.run(prompt: "request B")
        await wait("request B starts") { ChatTestProtocol.count == 2 }
        await wait("request A cancellation") { ChatTestProtocol.wasStopped(0) }
        await settle()
        check(engine.busy, "cancelled A cannot clear busy while B is pending")
        check(engine.lastError == nil, "cancelled A does not report an error")
        engine.stop()
        await settle()
    }

    func resettingSessionCancelsAndClearsState() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.history = [["role": "user", "content": "previous turn"]]
        engine.noteContext = "previous context"
        engine.contextSource = "manual"
        engine.images = [ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)),
                                         dataURL: "data:image/png;base64,c3ludGhldGlj")]
        engine.totalPromptTokens = 17
        engine.totalCompletionTokens = 9
        engine.autoInsertNext = true
        engine.pendingResult = "previous review"
        engine.run(prompt: "request to reset")
        await wait("reset request starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"partial before reset\"}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}\n\n", finish: false)
        await wait("partial output before reset") { engine.output == "partial before reset" }
        engine.lastError = "previous error"
        engine.resetSession()
        await settle()
        check(ChatTestProtocol.wasStopped(0), "resetSession cancels the in-flight request")
        check(!engine.busy, "resetSession clears busy")
        check(engine.history.isEmpty && engine.output.isEmpty && engine.lastError == nil,
              "resetSession clears history, output and error")
        check(engine.pendingResult.isEmpty && !engine.autoInsertNext,
              "resetSession clears pending review and review intent")
        check(engine.images.isEmpty, "resetSession clears image attachments")
        check(engine.noteContext.isEmpty && engine.contextSource.isEmpty,
              "resetSession clears note context and source")
        check(engine.promptTokens == 0 && engine.completionTokens == 0 && !engine.tokensEstimated,
              "resetSession clears current usage")
        check(engine.totalPromptTokens == 0 && engine.totalCompletionTokens == 0,
              "resetSession clears session usage totals")
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"late after reset\"}}]}\n\n")
        await settle()
        check(engine.output.isEmpty && engine.history.isEmpty && engine.pendingResult.isEmpty,
              "late reset response cannot resurrect output, history or review")
        engine.stop()
        await settle()
    }

    func stoppingPreservesPartialOutputWithoutSettlement() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        let attachment = ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)),
                                         dataURL: "data:image/png;base64,c3RvcA==")
        engine.images = [attachment]
        engine.autoInsertNext = true
        engine.run(prompt: "stop this request")
        await wait("stop request starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"keep partial\"}}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":4}}\n\n", finish: false)
        await wait("stop partial output") { engine.output == "keep partial" }
        engine.stop()
        await settle()
        check(ChatTestProtocol.wasStopped(0) && !engine.busy, "stop cancels the active request and clears busy")
        check(engine.output == "keep partial", "stop preserves the visible partial output")
        check(engine.history.isEmpty && engine.pendingResult.isEmpty, "stop cannot append history or show a review")
        check(engine.totalPromptTokens == 0 && engine.totalCompletionTokens == 0, "stop cannot settle session usage")
        check(engine.images.map(\.id) == [attachment.id], "stop keeps attachments for retry")
        check(!engine.autoInsertNext, "stop discards the cancelled request's review intent")
        check(engine.lastError == nil, "stop does not report cancellation as an error")
    }

    func settlementUsesRequestLocalState() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        let sent = ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)),
                                   dataURL: "data:image/png;base64,c2VudA==")
        let next = ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)),
                                   dataURL: "data:image/png;base64,bmV4dA==")
        engine.images = [sent]
        engine.autoInsertNext = true
        engine.run(prompt: "completed request")
        await wait("local-state request starts") { ChatTestProtocol.count == 1 }
        check(!engine.autoInsertNext, "run consumes review intent into its own request")
        engine.images.append(next)
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"request result\"}}],\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":6}}\n\n", finish: false)
        await wait("local-state partial") { engine.output == "request result" }
        // Published display fields can change; final history/review/usage belong to the response itself.
        engine.output = "unrelated display content"
        engine.promptTokens = 999
        engine.completionTokens = 999
        ChatTestProtocol.respond(0, body: "data: [DONE]\n\n")
        await wait("local-state settlement") { !engine.busy }
        check(engine.output == "request result", "settlement restores the request-local response")
        check(engine.images.map(\.id) == [next.id], "settlement consumes sent images and retains newly added images")
        check(engine.history.count == 2 && engine.history.last?["content"] as? String == "request result",
              "history contains the request-local result")
        check(engine.history.first?["content"] as? String == "completed request\n[本轮附带 1 张图片]",
              "history records only this request's attachments")
        check(engine.pendingResult == "request result", "review uses this request's captured intent and result")
        check(engine.promptTokens == 13 && engine.completionTokens == 6 && !engine.tokensEstimated,
              "current usage comes from the request-local server usage")
        check(engine.totalPromptTokens == 13 && engine.totalCompletionTokens == 6,
              "session usage settles the request-local server usage once")
    }

    func stopClearsExistingReview() async {
        configure()
        let engine = ChatEngine()
        engine.pendingResult = "stale review"
        engine.stop()
        check(engine.pendingResult.isEmpty, "stop clears an existing pending review")
        check(Mirror(reflecting: engine).children.contains { $0.label == "_pendingTarget" },
              "pending review has a published original writeback target")
    }

    func reviewTargetBelongsToTheCompletedRequest() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        let targetA = NotesBridge.SelectionSnapshot(element: AXUIElementCreateApplication(getpid()),
                                                    range: CFRange(location: 1, length: 2), text: "A",
                                                    bounds: .zero, noteID: "synthetic-note-a", documentText: "doc A")
        let targetB = NotesBridge.SelectionSnapshot(element: AXUIElementCreateApplication(getpid()),
                                                    range: CFRange(location: 3, length: 4), text: "B",
                                                    bounds: .zero, noteID: "synthetic-note-b", documentText: "doc B")
        engine.autoInsertNext = true
        engine.run(prompt: "review A", writebackTarget: targetA)
        await wait("review A starts") { ChatTestProtocol.count == 1 }
        engine.autoInsertNext = true
        engine.run(prompt: "review B", writebackTarget: targetB)
        await wait("review B starts") { ChatTestProtocol.count == 2 }
        await settle()
        check(engine.pendingTarget == nil && engine.pendingResult.isEmpty,
              "replacing review request clears its previous pending target and result")
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\"review B result\"}}]}\n\n")
        await wait("review B finishes") { !engine.busy }
        check(engine.pendingResult == "review B result" && engine.pendingTarget?.matches(targetB) == true,
              "completed review publishes B's captured original target with B's result")
        engine.stop()
        check(engine.pendingTarget == nil && engine.pendingResult.isEmpty,
              "stop clears both pending review target and result")
        engine.pendingTarget = targetA
        engine.resetSession()
        check(engine.pendingTarget == nil, "resetSession clears the pending writeback target")
        engine.autoInsertNext = true
        engine.run(prompt: "legacy review without target")
        await wait("legacy review starts") { ChatTestProtocol.count == 3 }
        ChatTestProtocol.respond(2, body: "data: {\"choices\":[{\"delta\":{\"content\":\"copy-only result\"}}]}\n\n")
        await wait("legacy review finishes") { !engine.busy }
        check(engine.pendingResult == "copy-only result" && engine.pendingTarget == nil,
              "review without an original target does not invent a current-cursor target")
    }

    func checkConfiguration(_ index: Int, suffix: String, label: String) {
        guard let request = ChatTestProtocol.capturedRequest(index), let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            check(false, "\(label): captured JSON body")
            return
        }
        let messages = body["messages"] as? [[String: Any]]
        check(request.url?.host == "chat-\(suffix).invalid", "\(label): original endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-\(suffix)",
              "\(label): original credential")
        check(body["model"] as? String == "model-\(suffix)", "\(label): original model")
        check(messages?.first?["content"] as? String == "system-\(suffix)", "\(label): original system prompt")
        check(body["temperature"] as? Double == (suffix == "a" ? 0.25 : 0.75), "\(label): original temperature")
        check(body["max_tokens"] as? Int == (suffix == "a" ? 321 : 654), "\(label): original token limit")
    }

    func configurationBelongsToTheRequest() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "snapshot before scheduling")
        configure("b")
        await wait("configuration request starts") { ChatTestProtocol.count == 1 }
        checkConfiguration(0, suffix: "a", label: "initial request")
        engine.stop()
        await settle()
    }

    func retryUsesTheOriginalConfiguration() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "retry snapshot")
        await wait("retry first request starts") { ChatTestProtocol.count == 1 }
        configure("b")
        ChatTestProtocol.respond(0, status: 400, body: "{\"error\":{\"message\":\"stream_options unsupported\"}}")
        await wait("retry request starts") { ChatTestProtocol.count == 2 }
        checkConfiguration(1, suffix: "a", label: "compatibility retry")
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["stream_options"] == nil, "compatibility retry omits unsupported stream_options")
        engine.stop()
        await settle()
    }

    func defaultOnlyTemperatureModelsOmitParameter() async {
        configure(model: "gpt-6.1-terra")
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "default temperature model")
        await wait("default temperature request starts") { ChatTestProtocol.count == 1 }
        let body = ChatTestProtocol.capturedRequest(0)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["temperature"] == nil, "gpt-6.1-terra requests omit unsupported temperature")
        check(body?["model"] as? String == "gpt-6.1-terra", "gpt-6.1-terra requests keep the configured model")
        check(body?["stream_options"] != nil, "gpt-6.1-terra requests still request usage accounting")
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"default temperature result\"}}]}\n\n")
        await wait("default temperature request finishes") { !engine.busy }
        check(engine.lastError == nil && engine.output == "default temperature result",
              "omitting temperature lets gpt-6.1-terra complete normally")
    }

    func reasoningEffortDefaultsToOmittedAndUsesRequestSnapshot() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "default reasoning effort")
        await wait("default reasoning effort request starts") { ChatTestProtocol.count == 1 }
        let body = ChatTestProtocol.capturedRequest(0)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["reasoning_effort"] == nil, "default reasoning effort is omitted")
        configure(reasoningEffort: .high)
        check(body?["reasoning_effort"] == nil,
              "changing reasoning effort after scheduling cannot alter the captured request")
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"default effort result\"}}]}\n\n")
        await wait("default reasoning effort request finishes") { !engine.busy }
        check(engine.lastError == nil && engine.output == "default effort result",
              "omitting reasoning effort keeps ordinary models working")
    }

    func configuredReasoningEffortIsSentAndBoundToItsProfile() async {
        configure(reasoningEffort: .high)
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "high reasoning effort")
        await wait("high reasoning effort request starts") { ChatTestProtocol.count == 1 }
        let body = ChatTestProtocol.capturedRequest(0)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["reasoning_effort"] as? String == "high",
              "configured reasoning effort is sent as reasoning_effort")
        check(body?["stream_options"] != nil,
              "reasoning effort preserves usage accounting")
        configure(reasoningEffort: .low)
        check(body?["reasoning_effort"] as? String == "high",
              "reasoning effort uses the request configuration snapshot")
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"high effort result\"}}]}\n\n")
        await wait("high reasoning effort request finishes") { !engine.busy }
        check(engine.lastError == nil && engine.output == "high effort result",
              "high reasoning effort completes normally")
    }

    func nonStreamingRequestsUseReasoningEffort() async {
        configure(reasoningEffort: .medium)
        ChatTestProtocol.reset()
        var result: String?
        let task = Task {
            do { result = try await AIService.complete(instruction: "reasoning", context: "", configuration: nil) }
            catch { result = "error: \(error.localizedDescription)" }
        }
        await wait("nonstreaming reasoning effort request starts") { ChatTestProtocol.count == 1 }
        let body = ChatTestProtocol.capturedRequest(0)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["reasoning_effort"] as? String == "medium",
              "nonstreaming requests use the configured reasoning effort")
        ChatTestProtocol.respond(0, body: "{\"choices\":[{\"message\":{\"content\":\"medium effort result\"},\"finish_reason\":\"stop\"}]}", includeDone: false)
        await task.value
        check(result == "medium effort result",
              "nonstreaming reasoning effort request completes")
    }

    func changingReasoningEffortStartsANewConversation() async {
        let profileID = UUID()
        configure(profileID: profileID, reasoningEffort: .low)
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "low effort conversation")
        await wait("low effort conversation starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"low effort answer\"}}]}\n\n")
        await wait("low effort conversation finishes") { !engine.busy }
        configure(profileID: profileID, reasoningEffort: .high)
        engine.run(prompt: "high effort conversation")
        await wait("high effort conversation starts") { ChatTestProtocol.count == 2 }
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        check(body?["reasoning_effort"] as? String == "high" && messages?.count == 2,
              "changing reasoning effort sends the new effort without old history")
        check(engine.sessionNotice?.contains("模型配置") == true,
              "reasoning effort boundary is explained to the user")
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\"high effort answer\"}}]}\n\n")
        await wait("high effort conversation finishes") { !engine.busy }
    }

    func temperatureCompatibilityRetryOmitsParameter() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "temperature compatibility")
        await wait("temperature compatibility first request starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(
            0, status: 400,
            body: #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.25 with this model. Only the default (1) value is supported."}}"#
        )
        await wait("temperature compatibility retry starts") { ChatTestProtocol.count == 2 }
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(body?["temperature"] == nil, "temperature compatibility retry omits the rejected parameter")
        check(body?["stream_options"] != nil, "temperature compatibility retry preserves usage accounting")
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\"temperature retry result\"}}]}\n\n")
        await wait("temperature compatibility retry finishes") { !engine.busy }
        check(engine.lastError == nil && engine.output == "temperature retry result",
              "temperature compatibility retry publishes the completed response")
    }

    func malformedModelURLIsRecoverable() async {
        do {
            _ = try await AIService.fetchModels(base: "https://bad host/v1", key: "")
            check(false, "invalid model URL must throw")
        } catch { check(error is APIError, "invalid model URL returns a visible configuration error") }
    }

    func invalidStreamsCannotPublishCompletedResults() async {
        let cases: [(String, String, String, String)] = [
            ("SSE error", "data: {\"error\":{\"message\":\"quota exhausted\"}}\n\n", "", "quota exhausted"),
            ("empty response", "data: [DONE]\n\n", "", "有效内容"),
            ("missing completion", "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", "partial", "完成标记"),
            ("length limit", "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\n\n", "partial", "长度限制"),
            ("content filter", "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"content_filter\"}]}\n\n", "partial", "内容过滤"),
        ]
        for (label, body, expected, error) in cases {
            configure()
            ChatTestProtocol.reset()
            let engine = ChatEngine()
            let attachment = ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)), dataURL: "synthetic")
            engine.images = [attachment]
            engine.autoInsertNext = true
            engine.run(prompt: label)
            await wait(label + " starts") { ChatTestProtocol.count == 1 }
            ChatTestProtocol.respond(0, body: body, includeDone: false)
            await wait(label + " finishes") { !engine.busy }
            check(engine.lastError?.contains(error) == true, label + " explains the failure")
            check(engine.output == expected, label + " preserves returned text")
            check(engine.history.isEmpty && engine.pendingResult.isEmpty, label + " never commits history or review")
            check(engine.images.map(\.id) == [attachment.id], label + " retains attachments for retry")
            check(engine.canRetry && engine.canContinue == !expected.isEmpty, label + " exposes recovery actions")
        }
    }

    func continuationCompletesTheOriginalResponse() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.autoInsertNext = true
        engine.run(prompt: "write a complete answer")
        await wait("continuation original") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"first\"},\"finish_reason\":\"length\"}]}\n\n", includeDone: false)
        await wait("continuation original ends") { !engine.busy }
        engine.continueLastResponse()
        await wait("continuation starts") { ChatTestProtocol.count == 2 }
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        check(messages?.contains { $0["role"] as? String == "assistant" && $0["content"] as? String == "first" } == true,
              "continuation sends the incomplete answer to the model")
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\" second\"},\"finish_reason\":\"stop\"}]}\n\n", includeDone: false)
        await wait("continuation completes") { !engine.busy }
        check(engine.output == "first second" && engine.pendingResult == "first second", "continuation reviews the combined result only after success")
        check(engine.history.count == 2 && engine.history.last?["content"] as? String == "first second", "continuation commits one complete turn")
        check(!engine.canContinue && !engine.canRetry && engine.lastError == nil, "successful continuation clears recovery state")
    }

    func retryPreservesOriginalInput() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.setContext("original context", source: "选中文本", noteID: "note-a")
        engine.run(prompt: "retry me")
        await wait("retry original starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"error\":{\"message\":\"temporary error\"}}\n\n", includeDone: false)
        await wait("retry original ends") { !engine.busy }
        engine.retryLastRequest()
        await wait("retry starts") { ChatTestProtocol.count == 2 }
        let request = ChatTestProtocol.capturedRequest(1)
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        check(messages?.last?["content"] as? String == "【笔记上下文】\noriginal context\n\n【任务】\nretry me", "retry restores the original prompt and note context")
        engine.stop()
        await settle()
    }

    func conversationBoundariesDiscardOldHistory() async {
        configure()
        let engine = ChatEngine()
        engine.setContext("A", source: "选中文本", noteID: "note-a")
        engine.history = [["role": "user", "content": "old note A"]]
        engine.setContext("another selection", source: "选中文本", noteID: "note-a")
        check(engine.history.count == 1, "same note can continue the conversation")
        engine.setContext("B", source: "光标段落", noteID: "note-b")
        check(engine.history.isEmpty, "different note starts a new conversation")
        engine.history = [["role": "user", "content": "context to clear"]]
        engine.setContext("", source: "", noteID: "note-b")
        check(engine.history.isEmpty, "explicitly clearing context also removes context hidden in history")
        engine.history = [["role": "user", "content": "old turn"]]
        engine.continuous = false
        check(engine.history.isEmpty, "disabling continuous chat clears the previous history")
        engine.continuous = true
        check(engine.history.isEmpty, "re-enabling continuous chat cannot revive the old history")
        ChatTestProtocol.reset()
        engine.run(prompt: "first provider")
        await wait("first provider starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"provider A secret\"}}]}\n\n")
        await wait("first provider settles") { !engine.busy }
        configure("b")
        engine.run(prompt: "second provider")
        await wait("second provider starts") { ChatTestProtocol.count == 2 }
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        check(messages?.count == 2, "switching provider never sends previous provider's history")
        check(engine.sessionNotice?.contains("模型配置") == true, "provider boundary is explained to the user")
        engine.stop()
        await settle()
    }

    func imagesAreBoundedBeforeSending() {
        configure()
        let engine = ChatEngine()
        let attachment = ImageAttachment(image: NSImage(size: NSSize(width: 1, height: 1)), dataURL: "synthetic")
        engine.images = Array(repeating: attachment, count: ImageAttachment.maximumCount)
        check(!engine.addImage(NSImage()) && engine.lastError?.contains("最多") == true, "image picker refuses attachments beyond the count limit")
        engine.images.append(attachment)
        ChatTestProtocol.reset()
        engine.run(prompt: "too many images")
        check(!engine.busy && ChatTestProtocol.count == 0, "send validates the image count even if attachment state was changed directly")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 4096, height: 128))
        image.addRepresentation(bitmap)
        let resized = ImageAttachment.make(image)
        let data = resized.flatMap { $0.dataURL.split(separator: ",").last }.flatMap { Data(base64Encoded: String($0)) }
        let resizedBitmap = data.flatMap(NSBitmapImageRep.init(data:))
        check(resizedBitmap?.pixelsWide == 2048 && resizedBitmap?.pixelsHigh == 64, "large images are resized before base64 encoding")
    }

    func nonStreamingTruncationIsAnError() async {
        configure()
        ChatTestProtocol.reset()
        var error: String?
        let selection = "    第一行\n第二行\n"
        let task = Task {
            do { _ = try await AIService.complete(instruction: "complete", context: selection, contextKind: .selection) }
            catch let failure { error = failure.localizedDescription }
        }
        await wait("nonstreaming starts") { ChatTestProtocol.count == 1 }
        let payload = ChatTestProtocol.capturedRequest(0)?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = payload?["messages"] as? [[String: String]]
        check(messages?.last?["content"] == "【选中文本】\n\(selection)\n\n【任务】\ncomplete",
              "selection requests identify the excerpt and preserve its indentation and trailing newline")
        ChatTestProtocol.respond(0, body: "{\"choices\":[{\"message\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}", includeDone: false)
        await task.value
        check(error?.contains("长度限制") == true, "nonstreaming selection/template calls reject truncated responses")
    }

    func profileStorageUsesOriginalPlaintextLogic() {
        let suite = "nc.chat-tests." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let originalDefaults = ProfileStore.defaults
        let originalConfigDefaults = Config.defaults
        let originalArgumentDomain = originalDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        ProfileStore.defaults = isolated
        Config.defaults = isolated
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = originalDefaults
            Config.defaults = originalConfigDefaults
            originalDefaults.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain)
        }
        isolated.set("https://legacy.invalid", forKey: "nc.baseURL")
        isolated.set("legacy-secret", forKey: "nc.apiKey")
        isolated.set("legacy-model", forKey: "nc.model")
        let migrated = ProfileStore.load()
        check(migrated.first?.apiKey == "legacy-secret", "legacy migration retains the working key")
        let stored = isolated.data(forKey: ProfileStore.key)!
        check(String(decoding: stored, as: UTF8.self).contains("legacy-secret"),
              "persisted profiles use the original plaintext API Key storage")
        check(isolated.string(forKey: "nc.apiKey") == nil, "successful migration removes the legacy single-profile key")
        check(ProfileStore.load().first?.apiKey == "legacy-secret", "profile credentials are restored directly from preferences")
        var mixed = try! JSONDecoder().decode([ModelProfile].self, from: stored)
        mixed.append(ModelProfile(name: "inline", baseURL: "https://other.invalid", apiKey: "another-secret", model: "m"))
        isolated.set(try! JSONEncoder().encode(mixed), forKey: ProfileStore.key)
        check(ProfileStore.load().map(\.apiKey) == ["legacy-secret", "another-secret"],
              "mixed profile keys remain stable in preferences")
        ProfileStore.save([])
        check(ProfileStore.load().isEmpty, "deleting the last profile cannot resurrect legacy configuration")
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ProfileStore.changedNotification, object: nil, queue: nil) { _ in notifications += 1 }
        var profile = ModelProfile(name: "test", baseURL: "https://test.invalid", apiKey: "safe-key", model: "m1")
        ProfileStore.save([profile])
        profile.model = "m2"
        ProfileStore.save([profile])
        NotificationCenter.default.removeObserver(observer)
        check(notifications == 2, "editing a profile notifies active model labels")
        isolated.set("   \n", forKey: "nc.sys")
        check(Config.systemPrompt == Config.defaultSystem, "blank system prompt uses the documented default")
    }

    func duplicateProfilesAreRejectedWithoutPartialWrites() {
        let suite = "nc.chat-tests.duplicate." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ProfileStore.defaults
        let previousArguments = previousDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        ProfileStore.defaults = isolated
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = previousDefaults
            previousDefaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        let profile = ModelProfile(name: "唯一配置", baseURL: "https://one.invalid/v1", apiKey: "one-key", model: "m")
        check(ProfileStore.save([profile]), "the duplicate fixture saves the original profile")
        let before = isolated.data(forKey: ProfileStore.key)
        let duplicate = ModelProfile(id: profile.id, name: "重复配置", baseURL: "https://two.invalid/v1", apiKey: "two-key", model: "m")
        check(!ProfileStore.save([profile, duplicate]) && ProfileStore.lastError?.contains("重复标识") == true,
              "duplicate profile identifiers are rejected")
        check(isolated.data(forKey: ProfileStore.key) == before, "a rejected duplicate save preserves previous profiles")
    }

    func reviewIdentityIsInvalidatedWhenDismissed() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.autoInsertNext = true
        engine.run(prompt: "first review")
        await wait("first review identity starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"first result\"}}]}\n\n")
        await wait("first review identity settles") { !engine.busy }
        let firstID = engine.pendingReviewID
        check(firstID != nil, "completed review gets an operation identity")
        engine.dismissReview()
        check(engine.pendingReviewID == nil && engine.pendingResult.isEmpty && engine.pendingTarget == nil,
              "dismissReview invalidates pending writes and clears the review")
        engine.autoInsertNext = true
        engine.run(prompt: "second review")
        await wait("second review identity starts") { ChatTestProtocol.count == 2 }
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\"second result\"}}]}\n\n")
        await wait("second review identity settles") { !engine.busy }
        check(engine.pendingReviewID != nil && engine.pendingReviewID != firstID, "each completed review uses a fresh identity")
        engine.pendingResult = ""
        check(engine.pendingReviewID == nil, "legacy direct review clearing also invalidates pending writes")
    }

    func operationGenerationInvalidatesPendingWrites() {
        configure()
        let engine = ChatEngine()
        let initial = engine.operationGeneration
        engine.stop()
        let stopped = engine.operationGeneration
        check(stopped != initial, "stop invalidates pending side effects even when chat is idle")
        engine.stop()
        check(engine.operationGeneration != stopped, "every stop starts a fresh operation generation")
        let beforeSession = engine.operationGeneration
        engine.beginSession()
        check(engine.operationGeneration != beforeSession, "new session invalidates pending side effects")
        let beforeRun = engine.operationGeneration
        engine.run(prompt: "new work")
        check(engine.operationGeneration != beforeRun, "starting a request invalidates older pending writes")
        engine.stop()
        let beforeContext = engine.operationGeneration
        engine.setContext("another note", source: "manual", noteID: "another-note")
        check(engine.operationGeneration != beforeContext, "changing note source invalidates pending side effects")
    }

    func changingModelWithinProfileStartsANewConversation() async {
        let profileID = UUID()
        configure(profileID: profileID, model: "model-original")
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "first model")
        await wait("original model starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"old model answer\"}}]}\n\n")
        await wait("original model settles") { !engine.busy }
        check(engine.history.count == 2, "original model has a completed conversation to isolate")
        configure(profileID: profileID, model: "model-replacement")
        engine.run(prompt: "replacement model")
        await wait("replacement model starts") { ChatTestProtocol.count == 2 }
        let body = ChatTestProtocol.capturedRequest(1)?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        check(body?["model"] as? String == "model-replacement" && messages?.count == 2 && engine.history.isEmpty,
              "editing the model within the same profile starts a conversation without old model history")
        check(engine.sessionNotice?.contains("模型配置") == true, "same-profile model boundary is explained to the user")
        ChatTestProtocol.respond(1, body: "data: {\"error\":{\"message\":\"temporary model failure\"}}\n\n", includeDone: false)
        await wait("replacement model fails") { !engine.busy }
        check(engine.canRetry, "failed model request is available for recovery")
        configure(profileID: profileID, model: "model-third")
        engine.retryLastRequest()
        await settle()
        check(ChatTestProtocol.count == 2 && !engine.busy && engine.lastError?.contains("模型配置已变化") == true,
              "changing a model within the same profile rejects retrying an older model's input")
    }

    func generationParametersFollowActiveProfile() {
        let suite = "nc.chat-tests.profile-generation." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ProfileStore.defaults
        let previousConfigDefaults = Config.defaults
        let previousArguments = previousDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        ProfileStore.defaults = isolated
        Config.defaults = isolated
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = previousDefaults
            Config.defaults = previousConfigDefaults
            previousDefaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        isolated.set(0.2, forKey: "nc.temp")
        isolated.set(1024, forKey: "nc.maxTokens")
        let fallback = ModelProfile(name: "fallback", baseURL: "https://fallback.invalid/v1", model: "fallback-model")
        let tuned = ModelProfile(name: "tuned", baseURL: "https://tuned.invalid/v1", model: "tuned-model",
                                 temperature: 0.4, maxTokens: 4096, reasoningEffort: .high)
        guard ProfileStore.save([fallback, tuned]) else {
            check(false, "profile-generation fixture saves isolated profiles")
            return
        }
        ProfileStore.activeID = tuned.id
        let tunedConfiguration = try? AIRequestConfiguration.current()
        check(tunedConfiguration?.temperature == 0.4 && tunedConfiguration?.maxTokens == 4096,
              "生效配置的采样温度和输出上限优先于全局默认值")
        check(tunedConfiguration?.reasoningEffort == .high,
              "生效配置的推理强度随 Profile 保存")
        ProfileStore.activeID = fallback.id
        let fallbackConfiguration = try? AIRequestConfiguration.current()
        check(fallbackConfiguration?.temperature == 0.2 && fallbackConfiguration?.maxTokens == 1024,
              "未覆盖参数的配置回退到全局默认值")
        check(fallbackConfiguration?.reasoningEffort == nil,
              "未设置推理强度时不发送参数")
        let stored = ProfileStore.load()
        check(stored.first { $0.id == tuned.id }?.temperature == 0.4
              && stored.first { $0.id == tuned.id }?.maxTokens == 4096
              && stored.first { $0.id == tuned.id }?.reasoningEffort == .high
              && stored.first { $0.id == fallback.id }?.temperature == nil
              && stored.first { $0.id == fallback.id }?.reasoningEffort == nil,
              "Profile 参数持久化且空值保持回退语义")
    }

    func chatSessionPersistsAcrossEngineRestart() {
        let suite = "nc.chat-tests.session-persistence." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ChatSessionStore.defaults
        ChatSessionStore.defaults = isolated
        defer {
            isolated.removePersistentDomain(forName: suite)
            ChatSessionStore.defaults = previousDefaults
        }
        let record = ChatSessionRecord(
            history: [ChatMessageRecord(role: "user", content: "上次问题"),
                      ChatMessageRecord(role: "assistant", content: "上次回答")],
            output: "上次回答",
            submittedPrompt: "上次问题",
            noteContext: "笔记上下文",
            contextSource: "选中文本",
            profileIdentity: "profile|https://model.invalid|model",
            promptTokens: 11,
            completionTokens: 7,
            totalPromptTokens: 22,
            totalCompletionTokens: 14,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        ChatSessionStore.save(record)
        check(ChatSessionStore.load()?.history == record.history && ChatSessionStore.load()?.profileIdentity == record.profileIdentity,
              "会话记录可本地持久化且不包含 API Key 字段")
        let engine = ChatEngine()
        check(engine.history.count == 2 && engine.output == "上次回答"
              && engine.submittedPrompt == "上次问题" && engine.noteContext == "笔记上下文",
              "新引擎恢复上一次多轮对话与上下文")
        check(engine.responseStatus == "已恢复上次会话", "恢复状态对用户可见")
        engine.stop()
        check(ChatSessionStore.load()?.output == "上次回答", "停止生成也会保留可恢复的当前输出")
        engine.continuous = false
        check(engine.history.isEmpty && ChatSessionStore.load() == nil, "关闭连续对话会清除本地会话记录")
        engine.continuous = true
        engine.beginSession()
        check(engine.history.isEmpty && engine.output.isEmpty && ChatSessionStore.load() == nil,
              "新会话会清除本地恢复记录")
    }

    func submittedTaskMatchesExternalRequests() async {
        configure()
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        var displayedDraft = "older manual draft"
        var submissions: [String] = []
        let subscription = engine.$submittedPrompt.dropFirst().sink { value in
            displayedDraft = value
            submissions.append(value)
        }
        defer { subscription.cancel(); engine.stop() }
        engine.run(prompt: "  synthetic external command  ")
        await wait("external task starts") { ChatTestProtocol.count == 1 }
        check(displayedDraft == "synthetic external command", "external commands publish the actual submitted task for the panel")
        displayedDraft = "next draft while generating"
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"synthetic result\"},\"finish_reason\":\"stop\"}]}\n\n")
        await wait("external task completes") { !engine.busy }
        check(displayedDraft == "next draft while generating", "response updates do not overwrite the user's next draft")
        engine.run(prompt: "synthetic external command")
        await wait("repeated external task starts") { ChatTestProtocol.count == 2 }
        check(displayedDraft == "synthetic external command" && submissions == ["synthetic external command", "synthetic external command"],
              "repeated external commands publish a new submission even when the task text matches")
        displayedDraft = "draft kept while editing context"
        engine.setContext("different synthetic context", source: "manual")
        check(displayedDraft == "draft kept while editing context", "context boundaries do not erase a task draft the user is editing")
        engine.beginSession()
        check(displayedDraft.isEmpty && engine.submittedPrompt.isEmpty, "new sessions clear the displayed submitted task")
    }

    func run() async {
        await replacingRequestKeepsNewRequestBusy()
        await resettingSessionCancelsAndClearsState()
        await stoppingPreservesPartialOutputWithoutSettlement()
        await settlementUsesRequestLocalState()
        await stopClearsExistingReview()
        await reviewTargetBelongsToTheCompletedRequest()
        await configurationBelongsToTheRequest()
        await retryUsesTheOriginalConfiguration()
        await defaultOnlyTemperatureModelsOmitParameter()
        await temperatureCompatibilityRetryOmitsParameter()
        await reasoningEffortDefaultsToOmittedAndUsesRequestSnapshot()
        await configuredReasoningEffortIsSentAndBoundToItsProfile()
        await nonStreamingRequestsUseReasoningEffort()
        await changingReasoningEffortStartsANewConversation()
        await malformedModelURLIsRecoverable()
        await invalidStreamsCannotPublishCompletedResults()
        await continuationCompletesTheOriginalResponse()
        await retryPreservesOriginalInput()
        await conversationBoundariesDiscardOldHistory()
        imagesAreBoundedBeforeSending()
        await nonStreamingTruncationIsAnError()
        profileStorageUsesOriginalPlaintextLogic()
        duplicateProfilesAreRejectedWithoutPartialWrites()
        await reviewIdentityIsInvalidatedWhenDismissed()
        operationGenerationInvalidatesPendingWrites()
        await changingModelWithinProfileStartsANewConversation()
        generationParametersFollowActiveProfile()
        chatSessionPersistsAcrossEngineRestart()
        await submittedTaskMatchesExternalRequests()
        print("chat-tests: \(passed) passed, \(failed) failed")
        chatTestDefaults.removePersistentDomain(forName: chatTestSuite)
        exit(failed == 0 ? 0 : 1)
    }
}

let chatTestSuite = "nc.chat-tests.session." + UUID().uuidString
let chatTestDefaults = UserDefaults(suiteName: chatTestSuite)!
ProfileStore.defaults = chatTestDefaults
Config.defaults = chatTestDefaults
ChatSessionStore.defaults = chatTestDefaults
URLProtocol.registerClass(ChatTestProtocol.self)
Task { @MainActor in await ChatTests().run() }
RunLoop.main.run()
