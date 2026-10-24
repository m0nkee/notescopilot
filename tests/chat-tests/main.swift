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

    func configure(_ suffix: String = "a", profileID: UUID = UUID(), model: String? = nil) {
        let profile = ModelProfile(id: profileID, name: "synthetic \(suffix)", baseURL: "https://chat-\(suffix).invalid/v1",
                                   apiKey: "synthetic-\(suffix)", model: model ?? "model-\(suffix)")
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
        let task = Task {
            do { _ = try await AIService.complete(instruction: "complete", context: "") }
            catch let failure { error = failure.localizedDescription }
        }
        await wait("nonstreaming starts") { ChatTestProtocol.count == 1 }
        ChatTestProtocol.respond(0, body: "{\"choices\":[{\"message\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}", includeDone: false)
        await task.value
        check(error?.contains("长度限制") == true, "nonstreaming selection/template calls reject truncated responses")
    }

    func profileMigrationAndSecretFailures() {
        final class FailingSecrets: ProfileSecretStore {
            func read(id: UUID) throws -> String? { throw APIError(status: -1, message: "synthetic keychain locked") }
            func write(_ secret: String, id: UUID) throws { throw APIError(status: -1, message: "synthetic keychain locked") }
            func remove(id: UUID) throws { throw APIError(status: -1, message: "synthetic keychain locked") }
        }
        let suite = "nc.chat-tests." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let originalDefaults = ProfileStore.defaults
        let originalConfigDefaults = Config.defaults
        let originalArgumentDomain = originalDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let originalSecrets = ProfileStore.secretStore
        ProfileStore.defaults = isolated
        Config.defaults = isolated
        ProfileStore.secretStore = MemoryProfileSecretStore()
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = originalDefaults
            Config.defaults = originalConfigDefaults
            originalDefaults.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain)
            ProfileStore.secretStore = originalSecrets
        }
        isolated.set("https://legacy.invalid", forKey: "nc.baseURL")
        isolated.set("legacy-secret", forKey: "nc.apiKey")
        isolated.set("legacy-model", forKey: "nc.model")
        let migrated = ProfileStore.load()
        check(migrated.first?.apiKey == "legacy-secret", "legacy migration retains the working key")
        let stored = isolated.data(forKey: ProfileStore.key)!
        check(!String(decoding: stored, as: UTF8.self).contains("legacy-secret"), "persisted profile metadata contains no plaintext key")
        check(isolated.string(forKey: "nc.apiKey") == nil, "successful migration removes the legacy plaintext key")
        check(ProfileStore.load().first?.apiKey == "legacy-secret", "profile credentials are restored from the injected secret store")
        var mixed = try! JSONDecoder().decode([ModelProfile].self, from: stored)
        mixed.append(ModelProfile(name: "inline", baseURL: "https://other.invalid", apiKey: "another-secret", model: "m"))
        isolated.set(try! JSONEncoder().encode(mixed), forKey: ProfileStore.key)
        let mixedLoaded = ProfileStore.load()
        check(mixedLoaded.map(\.apiKey) == ["legacy-secret", "another-secret"], "mixed migration retains both existing secure and legacy inline keys")
        check(ProfileStore.load().map(\.apiKey) == ["legacy-secret", "another-secret"], "migrating an inline key never deletes another profile's secured key")
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
        let beforeFailure = isolated.data(forKey: ProfileStore.key)
        ProfileStore.secretStore = FailingSecrets()
        profile.apiKey = "replacement-key"
        check(!ProfileStore.save([profile]) && ProfileStore.lastError?.contains("keychain locked") == true,
              "secret write failure is visible")
        check(isolated.data(forKey: ProfileStore.key) == beforeFailure, "secret write failure preserves previous metadata")
        let unavailable = ProfileStore.load()
        check(unavailable.first?.credentialUnavailable == true, "secret read failure is marked instead of silently using an empty key")
        check(!ProfileStore.save(unavailable), "an unreadable secret cannot be silently overwritten by an unrelated edit")
        isolated.set("   \n", forKey: "nc.sys")
        check(Config.systemPrompt == Config.defaultSystem, "blank system prompt uses the documented default")
    }

    func multiProfileSaveRestoresEarlierSecretsOnFailure() {
        final class SelectiveSecrets: ProfileSecretStore {
            var values: [UUID: String] = [:]
            var writeAttempts: [UUID] = []
            var readFailures: Set<UUID> = []
            var writeFailures: [UUID: Set<String>] = [:]
            var removeFailures: Set<UUID> = []
            func read(id: UUID) throws -> String? {
                if readFailures.contains(id) { throw APIError(status: -1, message: "synthetic backup failure") }
                return values[id]
            }
            func write(_ secret: String, id: UUID) throws {
                writeAttempts.append(id)
                if writeFailures[id]?.contains(secret) == true { throw APIError(status: -1, message: "synthetic write failure") }
                values[id] = secret
            }
            func remove(id: UUID) throws {
                if removeFailures.contains(id) { throw APIError(status: -1, message: "synthetic cleanup failure") }
                values.removeValue(forKey: id)
            }
        }
        let suite = "nc.chat-tests.rollback." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ProfileStore.defaults
        let previousSecrets = ProfileStore.secretStore
        let previousArguments = previousDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let secrets = SelectiveSecrets()
        ProfileStore.defaults = isolated
        ProfileStore.secretStore = secrets
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = previousDefaults
            ProfileStore.secretStore = previousSecrets
            previousDefaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        let first = ModelProfile(name: "A", baseURL: "https://a.invalid", apiKey: "old-a", model: "m")
        let second = ModelProfile(name: "B", baseURL: "https://b.invalid", apiKey: "old-b", model: "m")
        check(ProfileStore.save([first, second]), "rollback fixture saves the original profile secrets")
        let previousMetadata = isolated.data(forKey: ProfileStore.key)
        var editedFirst = first
        var editedSecond = second
        editedFirst.apiKey = "new-a"
        editedSecond.apiKey = "new-b"
        secrets.writeFailures[second.id] = ["new-b"]
        check(!ProfileStore.save([editedFirst, editedSecond]), "a later profile's failed secret write rejects the save")
        check(secrets.values[first.id] == "old-a" && secrets.values[second.id] == "old-b", "later write failure restores the earlier profile's original key")
        check(isolated.data(forKey: ProfileStore.key) == previousMetadata, "later write failure preserves the previous metadata")
        check(ProfileStore.lastError?.contains("已恢复") == true, "successful compensation is reported accurately")

        secrets.writeAttempts = []
        var unavailableSecond = second
        unavailableSecond.apiKey = ""
        unavailableSecond.credentialUnavailable = true
        check(!ProfileStore.save([editedFirst, unavailableSecond]) && secrets.writeAttempts.isEmpty,
              "all unavailable credentials are rejected before any secret is modified")
        secrets.readFailures = [second.id]
        secrets.writeAttempts = []
        check(!ProfileStore.save([editedFirst, editedSecond]) && secrets.writeAttempts.isEmpty,
              "all old keys are backed up before the first overwrite")
        secrets.readFailures = []

        secrets.writeFailures[first.id] = ["old-a"]
        check(!ProfileStore.save([editedFirst, editedSecond]), "rollback failure still rejects the save")
        check(ProfileStore.lastError?.contains("恢复失败") == true && secrets.values[first.id] == "new-a",
              "failed compensation explicitly warns that a key needs attention")
        check(isolated.data(forKey: ProfileStore.key) == previousMetadata, "failed compensation does not commit new metadata")

        secrets.writeFailures = [:]
        secrets.removeFailures = [first.id]
        check(ProfileStore.save([]), "profile removal commits even if orphaned key cleanup fails")
        check(ProfileStore.load().isEmpty && ProfileStore.lastError?.contains("未能从钥匙串清除") == true,
              "failed deletion cleanup is visible without reviving removed profiles")
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

    func userCanAuthorizeAndSaveUnavailableCredentials() {
        final class Storage {
            var values: [UUID: String] = [:]
            var requiresAuthorization = false
            var authorizationFailure: APIError?
            var writeFailures: [UUID: APIError] = [:]
            var writeFailureValues: [UUID: Set<String>] = [:]
            var authorizationRequests = 0
            var readModes: [Bool] = []
            var writeModes: [Bool] = []
            var removeModes: [Bool] = []
            func clearTrace() {
                authorizationRequests = 0
                readModes = []; writeModes = []; removeModes = []
            }
        }
        final class Secrets: ProfileSecretStore {
            let storage: Storage
            let interactive: Bool
            init(_ storage: Storage, interactive: Bool = false) {
                self.storage = storage; self.interactive = interactive
            }
            func read(id: UUID) throws -> String? {
                storage.readModes.append(interactive)
                guard let value = storage.values[id] else { return nil }
                if interactive, let failure = storage.authorizationFailure { throw failure }
                if storage.requiresAuthorization && !interactive {
                    throw APIError(status: -25308, message: "synthetic authorization required")
                }
                return value
            }
            func write(_ secret: String, id: UUID) throws {
                storage.writeModes.append(interactive)
                if let failure = storage.writeFailures[id], storage.writeFailureValues[id]?.contains(secret) ?? true { throw failure }
                storage.values[id] = secret
            }
            func remove(id: UUID) throws {
                storage.removeModes.append(interactive)
                storage.values.removeValue(forKey: id)
            }
            func allowingUserInteraction() -> any ProfileSecretStore {
                storage.authorizationRequests += 1
                return Secrets(storage, interactive: true)
            }
        }
        let suite = "nc.chat-tests.authorization." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ProfileStore.defaults
        let previousSecrets = ProfileStore.secretStore
        let previousArguments = previousDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let storage = Storage()
        ProfileStore.defaults = isolated
        ProfileStore.secretStore = Secrets(storage)
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = previousDefaults
            ProfileStore.secretStore = previousSecrets
            previousDefaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        let original = ModelProfile(name: "original", baseURL: "https://original.invalid", apiKey: "synthetic-original", model: "original-model")
        guard ProfileStore.save([original]) else { check(false, "authorization fixture saves the original credential"); return }
        check(storage.values[original.id] == "synthetic-original" && storage.authorizationRequests == 0,
              "a new credential with no previous item can be saved without interactive authorization")
        check(storage.readModes.allSatisfy { !$0 } && storage.writeModes.allSatisfy { !$0 },
              "default save keeps both credential preflight and writes noninteractive")
        storage.requiresAuthorization = true
        storage.clearTrace()
        var draft = original
        draft.apiKey = ""
        draft.credentialUnavailable = true
        draft.name = "edited name"
        draft.baseURL = "https://edited.invalid"
        draft.model = "edited-model"
        var notifiedCredentialWasAvailable = false
        let observer = NotificationCenter.default.addObserver(forName: ProfileStore.changedNotification, object: nil, queue: nil) { _ in
            let loaded = ProfileStore.load().first
            notifiedCredentialWasAvailable = loaded?.apiKey == "synthetic-original" && loaded?.credentialUnavailable == false
        }
        let resolved = ProfileStore.authorizeAndSave([draft])
        NotificationCenter.default.removeObserver(observer)
        check(notifiedCredentialWasAvailable, "authorized credentials are available before the saved-profile notification is published")
        check(resolved?.first?.apiKey == "synthetic-original" && resolved?.first?.name == "edited name"
              && resolved?.first?.baseURL == "https://edited.invalid" && resolved?.first?.model == "edited-model"
              && resolved?.first?.credentialUnavailable == false && resolved?.first?.hasStoredAPIKey == true,
              "explicit authorization restores an unreadable key while preserving the edited profile")
        check(storage.authorizationRequests == 1 && !storage.readModes.isEmpty && storage.readModes.allSatisfy { $0 }
              && (ProfileStore.secretStore as? Secrets)?.interactive == false,
              "interactive authorization is scoped to one save and never replaces the default backend")
        let loadedAfterAuthorization = ProfileStore.load().first
        check(loadedAfterAuthorization?.apiKey == "synthetic-original" && loadedAfterAuthorization?.credentialUnavailable == false,
              "saved authorization remains usable by the ordinary profile loading path")
        let configurationAfterAuthorization = try? AIRequestConfiguration.current()
        check(configurationAfterAuthorization?.apiKey == "synthetic-original" && configurationAfterAuthorization?.model == "edited-model",
              "the next AI request can use the explicitly authorized credential without another interactive read")

        var replacement = draft
        replacement.apiKey = "synthetic-replacement"
        let additional = ModelProfile(name: "additional", baseURL: "https://additional.invalid", apiKey: "synthetic-additional", model: "another-model")
        storage.clearTrace()
        let replaced = ProfileStore.authorizeAndSave([replacement, additional])
        check(replaced?.first?.apiKey == "synthetic-replacement" && replaced?.first?.credentialUnavailable == false,
              "authorization preserves a re-entered key instead of restoring over the user's draft")
        check(replaced?.count == 2 && replaced?.allSatisfy { $0.hasStoredAPIKey && !$0.credentialUnavailable } == true
              && storage.values[additional.id] == "synthetic-additional",
              "interactive save can add a new key and returns accurate credential flags for every saved profile")
        check(storage.authorizationRequests == 1 && storage.readModes.allSatisfy { $0 } && storage.writeModes.allSatisfy { $0 },
              "the same interactive backend handles restoration, preflight and all writes")
        let savedMetadata = isolated.data(forKey: ProfileStore.key)
        let savedValues = storage.values
        let serialized = savedMetadata.map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!serialized.contains("synthetic-replacement") && !serialized.contains("synthetic-additional"),
              "explicit authorization never persists plaintext keys in profile metadata")

        storage.clearTrace()
        let silentResult = ProfileStore.save(replaced ?? [])
        check(!silentResult && storage.authorizationRequests == 0 && storage.readModes.allSatisfy { !$0 }
              && storage.writeModes.isEmpty && isolated.data(forKey: ProfileStore.key) == savedMetadata,
              "a later default save remains silent and cannot implicitly request another authorization")

        var unavailableAgain = replaced?.first ?? replacement
        unavailableAgain.apiKey = ""
        unavailableAgain.credentialUnavailable = true
        unavailableAgain.name = "unsaved draft name"
        for (status, message) in [(-25293, "synthetic authorization denied"), (-128, "synthetic user cancelled")] {
            storage.clearTrace()
            storage.authorizationFailure = APIError(status: status, message: message)
            let failed = ProfileStore.authorizeAndSave([unavailableAgain, additional])
            check(failed == nil && isolated.data(forKey: ProfileStore.key) == savedMetadata
                  && storage.values == savedValues && storage.writeModes.isEmpty && storage.removeModes.isEmpty,
                  status == -128 ? "cancelled authorization preserves metadata and all existing keys" : "denied authorization preserves metadata and all existing keys")
            check(storage.authorizationRequests == 1 && storage.readModes.count == 1,
                  status == -128 ? "cancelled authorization is never automatically retried" : "denied authorization is never automatically retried")
            check(unavailableAgain.name == "unsaved draft name" && unavailableAgain.apiKey.isEmpty && unavailableAgain.credentialUnavailable,
                  status == -128 ? "cancelled authorization leaves the caller's draft untouched" : "denied authorization leaves the caller's draft untouched")
            if status == -128 { check(ProfileStore.lastError?.contains("取消") == true, "user cancellation has a clear recoverable message") }
            check(ProfileStore.load().map(\.apiKey) == ["synthetic-replacement", "synthetic-additional"],
                  status == -128 ? "cancelled authorization preserves the committed credential cache" : "denied authorization preserves the committed credential cache")
        }
        storage.authorizationFailure = nil

        var changedFirst = replaced?.first ?? replacement
        changedFirst.apiKey = "synthetic-next-first"
        var changedSecond = additional
        changedSecond.apiKey = "synthetic-next-second"
        for status in [-1, -128] {
            storage.clearTrace()
            storage.writeFailures = [additional.id: APIError(status: status, message: "synthetic later write failure")]
            let failed = ProfileStore.authorizeAndSave([changedFirst, changedSecond])
            check(failed == nil && storage.values == savedValues && isolated.data(forKey: ProfileStore.key) == savedMetadata,
                  status == -128 ? "cancellation after an earlier write restores that key and never commits metadata" : "interactive save still rolls back earlier keys when a later write fails")
            check(storage.authorizationRequests == 1 && storage.writeModes.count == 3 && storage.writeModes.allSatisfy { $0 },
                  "interactive save compensation uses the same scoped backend without an automatic retry")
            check(ProfileStore.load().map(\.apiKey) == ["synthetic-replacement", "synthetic-additional"],
                  "failed writes never replace cached committed credentials with uncommitted drafts")
        }
        storage.writeFailures = [:]

        guard let previous = replaced else { return }
        storage.writeFailures = [original.id: APIError(status: -1, message: "synthetic compensation failure"),
                                 additional.id: APIError(status: -1, message: "synthetic later write failure")]
        storage.writeFailureValues = [original.id: ["synthetic-replacement"]]
        let failedRollback = ProfileStore.authorizeAndSave([changedFirst, changedSecond])
        check(failedRollback == nil && isolated.data(forKey: ProfileStore.key) == savedMetadata
              && storage.values[original.id] == "synthetic-next-first" && ProfileStore.lastError?.contains("恢复失败") == true,
              "a failed compensation is visible and never commits edited metadata")
        let afterFailedRollback = ProfileStore.load()
        check(afterFailedRollback.first?.credentialUnavailable == true && afterFailedRollback.first?.apiKey.isEmpty == true
              && afterFailedRollback.last?.apiKey == "synthetic-additional" && afterFailedRollback.last?.credentialUnavailable == false,
              "failed compensation invalidates only the uncertain credential instead of serving its stale cache")
        storage.writeFailures = [:]
        storage.writeFailureValues = [:]
        storage.requiresAuthorization = false
        check(ProfileStore.save(previous), "a normal save can repair the synthetic backend after compensation fails")
        storage.requiresAuthorization = true
        let afterOrdinaryRepair = ProfileStore.load()
        check(afterOrdinaryRepair.first?.credentialUnavailable == true && afterOrdinaryRepair.last?.apiKey == "synthetic-additional",
              "an ordinary repair cannot silently reauthorize an invalidated cache entry")
        check(ProfileStore.authorizeAndSave(previous) != nil, "explicit authorization can restore the invalidated cache entry")

        storage.clearTrace()
        let reduced = ProfileStore.authorizeAndSave([previous[0]])
        check(reduced != nil && storage.values[additional.id] == nil && storage.removeModes == [true],
              "explicit credential cleanup also uses the scoped interactive backend")

        var updated = previous[0]
        updated.apiKey = "synthetic-ordinary-update"
        storage.requiresAuthorization = false
        check(ProfileStore.save([updated, additional]), "normal saves can update authorized keys and recreate a removed profile")
        storage.requiresAuthorization = true
        let afterOrdinaryUpdate = ProfileStore.load()
        check(afterOrdinaryUpdate.first?.apiKey == "synthetic-ordinary-update" && afterOrdinaryUpdate.first?.credentialUnavailable == false,
              "ordinary saves synchronize an already authorized cache entry")
        check(afterOrdinaryUpdate.last?.apiKey.isEmpty == true && afterOrdinaryUpdate.last?.credentialUnavailable == true,
              "removing a profile clears its authorization and ordinary re-creation never adds it back to the cache")

        var cleared = updated
        cleared.apiKey = ""
        storage.requiresAuthorization = false
        check(ProfileStore.save([cleared, additional]) && storage.values[original.id] == nil,
              "clearing an API key removes the stored credential")
        check(ProfileStore.save([updated, additional]), "a cleared key can be saved again without interactive access when available")
        storage.requiresAuthorization = true
        check(ProfileStore.load().first?.credentialUnavailable == true,
              "clearing an API key also removes its cached authorization")

        check(ProfileStore.authorizeAndSave([updated, additional]) != nil, "explicit authorization restores the cache before scope-isolation checks")
        let secondSuite = suite + ".replacement"
        let replacementDefaults = UserDefaults(suiteName: secondSuite)!
        replacementDefaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        replacementDefaults.set(isolated.data(forKey: ProfileStore.key), forKey: ProfileStore.key)
        ProfileStore.defaults = replacementDefaults
        check(ProfileStore.load().allSatisfy { $0.apiKey.isEmpty && $0.credentialUnavailable },
              "replacing defaults clears cached authorization even for matching profile identifiers")
        ProfileStore.defaults = isolated
        replacementDefaults.removePersistentDomain(forName: secondSuite)
        check(ProfileStore.authorizeAndSave([updated, additional]) != nil, "explicit authorization restores the cache before backend isolation")
        ProfileStore.secretStore = Secrets(storage)
        check(ProfileStore.load().allSatisfy { $0.apiKey.isEmpty && $0.credentialUnavailable },
              "replacing the secret backend clears cached authorization even for matching profile identifiers")

        var newDraft = ModelProfile(name: "uncommitted", baseURL: "https://uncommitted.invalid", apiKey: "synthetic-uncommitted", model: "model")
        storage.writeFailures = [newDraft.id: APIError(status: -128, message: "synthetic new-key cancellation")]
        let beforeNewDraft = isolated.data(forKey: ProfileStore.key)
        check(ProfileStore.authorizeAndSave([updated, additional, newDraft]) == nil
              && isolated.data(forKey: ProfileStore.key) == beforeNewDraft && storage.values[newDraft.id] == nil,
              "cancelled new-key writes never persist metadata or a draft credential")
        storage.writeFailures = [:]
        newDraft.apiKey = "synthetic-after-cancellation"
        storage.requiresAuthorization = false
        check(ProfileStore.save([updated, additional, newDraft]), "a previously cancelled profile can later be saved normally")
        storage.requiresAuthorization = true
        check(ProfileStore.load().allSatisfy { $0.apiKey.isEmpty && $0.credentialUnavailable },
              "failed authorization never caches any uncommitted profile or new-key draft")
    }

    func unrelatedProfileErrorsDoNotPolluteGeneration() async {
        final class Secrets: ProfileSecretStore {
            var values: [UUID: String] = [:]
            var readFailures: [UUID: String] = [:]
            func read(id: UUID) throws -> String? {
                if let message = readFailures[id] { throw APIError(status: -25308, message: message) }
                return values[id]
            }
            func write(_ secret: String, id: UUID) throws { values[id] = secret }
            func remove(id: UUID) throws { values.removeValue(forKey: id) }
        }
        let suite = "nc.chat-tests.request-errors." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        let previousDefaults = ProfileStore.defaults
        let previousConfigDefaults = Config.defaults
        let previousSecrets = ProfileStore.secretStore
        let previousArguments = previousDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        isolated.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let secrets = Secrets()
        ProfileStore.defaults = isolated
        Config.defaults = isolated
        ProfileStore.secretStore = secrets
        defer {
            isolated.removePersistentDomain(forName: suite)
            ProfileStore.defaults = previousDefaults
            Config.defaults = previousConfigDefaults
            ProfileStore.secretStore = previousSecrets
            previousDefaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        let active = ModelProfile(name: "active", baseURL: "https://active.invalid/v1", apiKey: "synthetic-active", model: "active-model")
        let inactive = ModelProfile(name: "inactive", baseURL: "https://inactive.invalid/v1", apiKey: "synthetic-inactive", model: "inactive-model")
        guard ProfileStore.save([active, inactive]) else { check(false, "request-error fixture saves isolated profiles"); return }
        ProfileStore.activeID = active.id
        secrets.readFailures[inactive.id] = "synthetic inactive credential unavailable"
        ChatTestProtocol.reset()
        let engine = ChatEngine()
        engine.run(prompt: "use the available active model")
        await wait("active request starts despite inactive credential error") { ChatTestProtocol.count == 1 }
        check(engine.busy && engine.lastError == nil,
              "an inactive profile credential error does not appear as an error on a valid active request")
        check(ProfileStore.lastError?.contains("inactive credential") == true,
              "unrelated profile errors remain available to the settings view")
        ChatTestProtocol.respond(0, body: "data: {\"choices\":[{\"delta\":{\"content\":\"active result\"},\"finish_reason\":\"stop\"}]}\n\n")
        await wait("active request completes despite inactive credential error") { !engine.busy }
        check(engine.output == "active result" && engine.responseStatus == "已完成" && engine.lastError == nil,
              "a successful active response does not retain the unrelated profile error")

        secrets.readFailures = [:]
        engine.lastError = "synthetic earlier request error"
        engine.run(prompt: "ignore an older global profile error")
        await wait("request starts after inactive credential recovers") { ChatTestProtocol.count == 2 }
        check(engine.lastError == nil && ProfileStore.lastError?.contains("inactive credential") == true,
              "a valid new request clears its own previous error without copying a stale global save error")
        ChatTestProtocol.respond(1, body: "data: {\"choices\":[{\"delta\":{\"content\":\"next result\"},\"finish_reason\":\"stop\"}]}\n\n")
        await wait("request completes with stale global profile error") { !engine.busy }
        check(engine.output == "next result" && engine.lastError == nil,
              "stale global profile errors remain separate after a valid response completes")

        secrets.readFailures[active.id] = "synthetic active credential unavailable"
        engine.run(prompt: "must not send with an unreadable active credential")
        await settle()
        check(ChatTestProtocol.count == 2 && !engine.busy && engine.responseStatus == "配置不可用"
              && engine.lastError == "synthetic active credential unavailable",
              "an unreadable active credential still blocks HTTP and displays the current configuration failure")
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

    func explicitKeychainRecoveryUsesDefaultSystemInteraction() {
        final class AuthenticationContext: LAContext {
            private var forbidden = false
            override var interactionNotAllowed: Bool {
                get { forbidden }
                set { forbidden = newValue }
            }
        }
        let id = UUID()
        let quiet = KeychainProfileSecretStore()
        let quietQuery = quiet.query(id, quietContext: AuthenticationContext())
        guard let authorized = quiet.allowingUserInteraction() as? KeychainProfileSecretStore else {
            check(false, "explicit recovery returns a scoped Keychain backend"); return
        }
        let explicitQuery = authorized.query(id)
        check(quietQuery[kSecClass as String] as? String == kSecClassGenericPassword as String
              && explicitQuery[kSecClass as String] as? String == kSecClassGenericPassword as String
              && quietQuery[kSecAttrService as String] as? String == "NotesCopilot.model-api-key"
              && explicitQuery[kSecAttrService as String] as? String == "NotesCopilot.model-api-key"
              && quietQuery[kSecAttrAccount as String] as? String == id.uuidString
              && explicitQuery[kSecAttrAccount as String] as? String == id.uuidString,
              "quiet and explicit Keychain queries target the same credential class service and account")
        check((quietQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true,
              "ordinary Keychain queries still forbid authentication interaction")
        check(explicitQuery[kSecUseAuthenticationContext as String] == nil
              && explicitQuery[kSecUseAuthenticationUI as String] == nil,
              "explicit file-based Keychain recovery leaves authentication to the default system ACL interaction")
        check((quiet.query(id, quietContext: AuthenticationContext())[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true,
              "creating an explicit recovery backend never changes later ordinary queries")
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
        await malformedModelURLIsRecoverable()
        await invalidStreamsCannotPublishCompletedResults()
        await continuationCompletesTheOriginalResponse()
        await retryPreservesOriginalInput()
        await conversationBoundariesDiscardOldHistory()
        imagesAreBoundedBeforeSending()
        await nonStreamingTruncationIsAnError()
        profileMigrationAndSecretFailures()
        multiProfileSaveRestoresEarlierSecretsOnFailure()
        await reviewIdentityIsInvalidatedWhenDismissed()
        operationGenerationInvalidatesPendingWrites()
        await changingModelWithinProfileStartsANewConversation()
        userCanAuthorizeAndSaveUnavailableCredentials()
        await unrelatedProfileErrorsDoNotPolluteGeneration()
        await submittedTaskMatchesExternalRequests()
        explicitKeychainRecoveryUsesDefaultSystemInteraction()
        print("chat-tests: \(passed) passed, \(failed) failed")
        chatTestDefaults.removePersistentDomain(forName: chatTestSuite)
        exit(failed == 0 ? 0 : 1)
    }
}

let chatTestSuite = "nc.chat-tests.session." + UUID().uuidString
let chatTestDefaults = UserDefaults(suiteName: chatTestSuite)!
ProfileStore.defaults = chatTestDefaults
Config.defaults = chatTestDefaults
URLProtocol.registerClass(ChatTestProtocol.self)
Task { @MainActor in await ChatTests().run() }
RunLoop.main.run()
