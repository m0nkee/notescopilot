// TemplateRunner 回归测试：只使用内存配置和合成响应，不启动 App、不写笔记。
// 编译源文件与 scripts/run-tests.sh 的 COMMON_SOURCES 相同，产物放入 scratch。
import Foundation
import AppKit
import Accessibility

final class TemplateResponseProtocol: URLProtocol {
    struct Request {
        let instruction: String
        let url: String
        let authorization: String
        let model: String
        let system: String
        let temperature: Double
        let maxTokens: Int
    }

    private static let lock = NSLock()
    private static var seen: [String] = []
    private static var seenUsers: [String] = []
    private static var recorded: [Request] = []
    private static var failedAttempts = 0

    static var users: [String] {
        lock.lock(); defer { lock.unlock() }
        return seenUsers
    }

    static var instructions: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        } else {
            data = Data()
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]]
        let user = messages?.last?["content"] as? String ?? ""
        let instruction = user.components(separatedBy: "【任务】\n").last ?? user
        Self.lock.lock()
        Self.seen.append(instruction)
        Self.seenUsers.append(user)
        Self.recorded.append(Request(instruction: instruction, url: request.url?.absoluteString ?? "",
                                     authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
                                     model: object?["model"] as? String ?? "",
                                     system: messages?.first?["content"] as? String ?? "",
                                     temperature: object?["temperature"] as? Double ?? -1,
                                     maxTokens: object?["max_tokens"] as? Int ?? -1))
        let isBroken = instruction == "broken"
        if isBroken { Self.failedAttempts += 1 }
        // 旧实现会无限重试：第三次才放行，确保测试能退出并报告多余请求。
        let shouldFail = isBroken && Self.failedAttempts <= 2
        Self.lock.unlock()
        if instruction == "snapshot-first" {
            UserDefaults.standard.setVolatileDomain(testDefaults("third", temperature: 0.9, maxTokens: 256),
                                                    forName: UserDefaults.argumentDomain)
        }
        let status = shouldFail ? 503 : 200
        let body: [String: Any] = shouldFail
            ? ["error": ["message": "synthetic first failure"]]
            : ["choices": [["message": ["content": "result-\(instruction)"]]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class Checks {
    var passed = 0
    var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { passed += 1; print("PASS  \(name)") }
        else { failed += 1; print("FAIL  \(name)") }
    }
}

@MainActor
final class Suspension {
    private var pending: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            pending = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func resume(_ value: String) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: value)
    }
}

func testDefaults(_ name: String = "template", temperature: Double = 0.25, maxTokens: Int = 64) -> [String: Any] {
    let profile = ModelProfile(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                               name: "\(name)-test", baseURL: "https://\(name)-test.invalid",
                               apiKey: "synthetic-\(name)-key", model: "\(name)-model")
    return ["nc.profiles": try! JSONEncoder().encode([profile]),
            "nc.activeProfileID": profile.id.uuidString,
            "nc.baseURL": "https://\(name)-test.invalid", "nc.apiKey": "synthetic-\(name)-key",
            "nc.model": "\(name)-model", "nc.sys": "\(name)-system", "nc.temp": temperature,
            "nc.maxTokens": maxTokens]
}

@MainActor
final class DelayedActivation {
    private var pending: (() -> Void)?
    private var arrival: CheckedContinuation<Void, Never>?
    func schedule(_ action: @escaping () -> Void) {
        pending = action
        arrival?.resume()
        arrival = nil
    }
    func waitUntilScheduled() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func finish() {
        let action = pending
        pending = nil
        action?()
    }
}

@MainActor
func runTests() async {
    let defaults = UserDefaults.standard
    let oldDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(testDefaults(), forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(oldDomain, forName: UserDefaults.argumentDomain) }
    URLProtocol.registerClass(TemplateResponseProtocol.self)
    defer { URLProtocol.unregisterClass(TemplateResponseProtocol.self) }

    let checks = Checks()
    var insertions: [String] = []
    var errors: [String] = []
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        TemplateRunner.run(TemplateNote(name: "failure", content: "{{ai:broken}}|{{ai:healthy}}"),
                           selection: "", clipboard: "") { text in
            insertions.append(text)
            done.resume()
        } onError: { errors.append($0) }
    }
    checks.check(TemplateResponseProtocol.instructions == ["broken", "healthy"],
                 "失败槽位只尝试一次并继续下一槽（实际：\(TemplateResponseProtocol.instructions)）")
    checks.check(insertions == ["{{ai:broken}}|result-healthy"], "失败保留原占位符，成功槽位正常回填")
    checks.check(errors.count == 1 && errors[0].contains("synthetic first failure"), "只上报首个错误一次")
    checks.check(insertions.count == 1, "最终插入回调恰一次")

    let userStart = TemplateResponseProtocol.users.count
    var contexts: [String: String] = [:]
    var contextErrors: [String] = []
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        func finished(_ key: String, _ text: String) {
            contexts[key] = text
            if contexts.count == 2 { done.resume() }
        }
        TemplateRunner.run(TemplateNote(name: "context-a", content: "{{selection}}|{{ai:a1}}|{{ai:a2}}"),
                           selection: "selection-A", clipboard: "") { finished("A", $0) }
            onError: { contextErrors.append($0) }
        TemplateRunner.run(TemplateNote(name: "context-b", content: "{{selection}}|{{ai:b1}}|{{ai:b2}}"),
                           selection: "selection-B", clipboard: "") { finished("B", $0) }
            onError: { contextErrors.append($0) }
    }
    let users = Array(TemplateResponseProtocol.users.dropFirst(userStart))
    checks.check(Set(users) == Set([
        "【笔记上下文】\nselection-A\n\n【任务】\na1", "【笔记上下文】\nselection-A\n\n【任务】\na2",
        "【笔记上下文】\nselection-B\n\n【任务】\nb1", "【笔记上下文】\nselection-B\n\n【任务】\nb2",
    ]), "并发执行的每个 AI 槽使用所属 selection（实际：\(users)）")
    checks.check(contexts["A"] == "selection-A|result-a1|result-a2"
                 && contexts["B"] == "selection-B|result-b1|result-b2" && contextErrors.isEmpty,
                 "静态 selection 和 AI 结果均属于当前执行")

    let askStart = TemplateResponseProtocol.instructions.count
    var asked: [String] = []
    var cancelledInsertions: [String] = []
    var cancelledErrors: [String] = []
    let askCancelled = TemplateRunner.run(
        TemplateNote(name: "ask-cancel", content: "{{ask:first}}|{{ask:second}}|{{ai:never}}"),
        selection: "ask-selection", clipboard: "",
        ask: { question in asked.append(question); return nil },
        insert: { cancelledInsertions.append($0) }, onError: { cancelledErrors.append($0) })
    await askCancelled.value
    checks.check(asked == ["first"] && TemplateResponseProtocol.instructions.count == askStart,
                 "取消 ask 后停止其余询问及 AI 请求")
    checks.check(cancelledInsertions.isEmpty && cancelledErrors.isEmpty, "取消 ask 不插入、不上报请求错误")

    let completionGate = Suspension()
    var cancelledCalls: [String] = []
    let inFlight = TemplateRunner.run(
        TemplateNote(name: "cancel-in-flight", content: "{{ai:slow}}|{{ai:unreachable}}"),
        selection: "cancel-selection", clipboard: "",
        complete: { instruction, _ in
            cancelledCalls.append(instruction)
            if instruction == "slow" { return await completionGate.wait() }
            return "unexpected"
        }, insert: { cancelledInsertions.append($0) }, onError: { cancelledErrors.append($0) })
    await completionGate.waitUntilSuspended()
    inFlight.cancel()
    completionGate.resume("late-result")
    await inFlight.value
    checks.check(cancelledCalls == ["slow"], "请求期间取消后不再请求下一槽")
    checks.check(cancelledInsertions.isEmpty && cancelledErrors.isEmpty, "取消后忽略迟到结果，不插入、不报错")

    defaults.setVolatileDomain(testDefaults(), forName: UserDefaults.argumentDomain)
    let snapshotStart = TemplateResponseProtocol.requests.count
    let askGate = Suspension()
    var snapshotInsertions: [String] = []
    var snapshotErrors: [String] = []
    let snapshotTask = TemplateRunner.run(
        TemplateNote(name: "snapshot", content: "{{ask:pause}}|{{ai:snapshot-first}}|{{ai:snapshot-second}}"),
        selection: "snapshot-selection", clipboard: "",
        ask: { _ in await askGate.wait() }, insert: { snapshotInsertions.append($0) },
        onError: { snapshotErrors.append($0) })
    await askGate.waitUntilSuspended()
    defaults.setVolatileDomain(testDefaults("second", temperature: 0.6, maxTokens: 128),
                               forName: UserDefaults.argumentDomain)
    askGate.resume("answer")
    await snapshotTask.value
    let snapshotRequests = Array(TemplateResponseProtocol.requests.dropFirst(snapshotStart))
    checks.check(snapshotRequests.count == 2 && snapshotRequests.allSatisfy {
        $0.url == "https://template-test.invalid/v1/chat/completions"
            && $0.authorization == "Bearer synthetic-template-key" && $0.model == "template-model"
            && $0.system == "template-system" && $0.temperature == 0.25 && $0.maxTokens == 64
    }, "入口配置快照贯穿 ask 和多个 AI 槽（实际模型：\(snapshotRequests.map(\.model))）")
    checks.check(snapshotInsertions == ["answer|result-snapshot-first|result-snapshot-second"] && snapshotErrors.isEmpty,
                 "切换配置期间仍完整执行原模板一次")

    let syntheticElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let target = NotesBridge.SelectionSnapshot(element: syntheticElement,
                                               range: CFRange(location: 4, length: 0), text: "", bounds: .zero,
                                               noteID: "synthetic-note-A", documentText: "text")
    var currentTarget: NotesBridge.SelectionSnapshot? = target
    var writes: [String] = []
    var targetErrors: [String] = []
    let bridge = NotesBridge(snapshotReader: { currentTarget }, replacementWriter: { snap, range, text, _ in
        writes.append("\(snap.noteID)|\(range.location):\(range.length)|\(text)")
        return nil
    })
    let targetTask = TemplateRunner.runInNotes(
        TemplateNote(name: "target", content: "{{selection}}"), selection: "captured",
        bridge: bridge, clipboard: "", onError: { targetErrors.append($0) })
    await targetTask?.value
    checks.check(writes == ["synthetic-note-A|4:0|captured"] && targetErrors.isEmpty,
                 "全局模板使用入口捕获的零长光标快照写回")

    var richWrites: [(text: String, html: String?)] = []
    let richBridge = NotesBridge(snapshotReader: { target }, replacementWriter: { _, _, text, html in
        richWrites.append((text, html))
        return nil
    })
    let markdownTask = TemplateRunner.runInNotes(
        TemplateNote(name: "formatted-local", content: "# Local heading\n\n**Bold**\n\n```\nline one\nline two\n```"),
        selection: "", bridge: richBridge, clipboard: "", onError: { targetErrors.append($0) })
    await markdownTask?.value
    checks.check(richWrites.count == 1 && richWrites[0].html?.contains("<h1>Local heading</h1>") == true
                 && richWrites[0].html?.contains("<strong>Bold</strong>") == true
                 && richWrites[0].html?.contains("<pre><code>line one\nline two</code></pre>") == true,
                 "模板真实写回桥接同时接收 HTML，标题/加粗/多行代码不以 Markdown 标记插入")

    let nativeText = "Native {{date}}\nBold {{ask:who}}\n{{ai:summary}}\nsecond code line"
    var nativeHeading = TopotextRun()
    nativeHeading.length = "Native {{date}}\n".utf16.count
    nativeHeading.paragraphType = 1
    var nativeBold = TopotextRun()
    nativeBold.length = "Bold {{ask:who}}\n".utf16.count
    nativeBold.bold = true
    var nativeCode = TopotextRun()
    nativeCode.length = "{{ai:summary}}\nsecond code line".utf16.count
    nativeCode.monospaced = true
    nativeCode.monospacedBlock = true
    let nativeDocument = TopotextDoc(runs: [nativeHeading, nativeBold, nativeCode], text: nativeText,
                                     totalLength: nativeText.utf16.count)
    var nativeAskCount = 0
    var nativeAICount = 0
    let nativeTask = TemplateRunner.runInNotes(
        TemplateNote(name: "native-rich", content: nativeText, sourceNotesID: "native-source", sourceDocument: nativeDocument),
        selection: "captured", bridge: richBridge, clipboard: "",
        ask: { _ in nativeAskCount += 1; return "A&B <user>" },
        complete: { _, _ in nativeAICount += 1; return "AI <script>& *raw*" },
        onError: { targetErrors.append($0) })
    await nativeTask?.value
    let nativeWrite = richWrites.last
    checks.check(nativeAskCount == 1 && nativeAICount == 1 && richWrites.count == 2,
                 "富文本模板日期/询问/AI 共享一次执行，不因生成 HTML 重复弹窗或请求")
    checks.check(nativeWrite?.text.contains("Bold A&B <user>") == true
                 && nativeWrite?.text.contains("AI <script>& *raw*") == true
                 && !nativeWrite!.text.contains("{{date}}"),
                 "原生模板变量展开后保留纯文本回退及原始段落内容")
    checks.check(nativeWrite?.html?.contains("<h1") == true
                 && nativeWrite?.html?.contains("<strong>") == true
                 && nativeWrite?.html?.contains("A&amp;B &lt;user&gt;") == true
                 && nativeWrite?.html?.contains("<pre") == true
                 && nativeWrite?.html?.contains("background") == true
                 && nativeWrite?.html?.contains("AI &lt;script&gt;&amp; *raw*") == true
                 && nativeWrite?.html?.contains("<script>") == false,
                 "原生样式直接生成 HTML，保留标题/加粗/灰色等宽块并安全转义变量文本")

    let commandText = "/NativeTemplate"
    let commandTarget = NotesBridge.SelectionSnapshot(element: syntheticElement,
        range: CFRange(location: commandText.utf16.count, length: 0), text: "", bounds: .zero,
        noteID: "synthetic-empty-title", documentText: commandText)
    var commandCurrent: NotesBridge.SelectionSnapshot? = commandTarget
    var commandReads = 0
    var atomicWrites: [(range: CFRange, text: String, html: String?)] = []
    var atomicErrors: [String] = []
    let commandBridge = NotesBridge(snapshotReader: { commandReads += 1; return commandCurrent },
                                   replacementWriter: { snapshot, range, text, html in
        checks.check(snapshot.matches(commandTarget), "原子模板写回仍使用包含原斜杠命令的同一笔记快照")
        atomicWrites.append((range, text, html))
        return nil
    })
    let commandRange = CFRange(location: 0, length: commandText.utf16.count)
    let atomicGate = Suspension()
    let atomicTask = TemplateRunner.runInNotes(
        TemplateNote(name: "atomic", content: "# Inserted {{ai:replace}}"), selection: "",
        bridge: commandBridge, clipboard: "", complete: { _, _ in await atomicGate.wait() },
        target: commandTarget, replacementRange: commandRange, onError: { atomicErrors.append($0) })
    checks.check(commandReads == 0, "传入原始命令目标后不先删除或重新抓取空标题光标")
    await atomicGate.waitUntilSuspended()
    checks.check(atomicWrites.isEmpty && commandCurrent?.documentText == commandText,
                 "询问或 AI 等待期间保留原斜杠命令，直到富文本可一次写入")
    atomicGate.resume("ready")
    await atomicTask?.value
    checks.check(atomicWrites.count == 1 && atomicWrites[0].range.location == 0
                 && atomicWrites[0].range.length == commandText.utf16.count
                 && atomicWrites[0].text == "# Inserted ready"
                 && atomicWrites[0].html?.contains("<h1>Inserted ready</h1>") == true && atomicErrors.isEmpty,
                 "模板以一次带 HTML 的精确范围写回替换整个斜杠命令，支持原本空白标题")
    let atomicCancelGate = Suspension()
    let atomicCancelled = TemplateRunner.runInNotes(
        TemplateNote(name: "atomic-cancel", content: "{{ai:cancel}}"), selection: "",
        bridge: commandBridge, clipboard: "", complete: { _, _ in await atomicCancelGate.wait() },
        target: commandTarget, replacementRange: commandRange, onError: { atomicErrors.append($0) })
    await atomicCancelGate.waitUntilSuspended()
    atomicCancelled?.cancel()
    atomicCancelGate.resume("late")
    await atomicCancelled?.value
    checks.check(atomicWrites.count == 1 && atomicErrors.isEmpty && commandCurrent?.documentText == commandText,
                 "取消异步原子模板不删除命令、不写回迟到富文本且保留原始目标")
    let atomicStaleGate = Suspension()
    let atomicStale = TemplateRunner.runInNotes(
        TemplateNote(name: "atomic-stale", content: "{{ai:stale}}"), selection: "",
        bridge: commandBridge, clipboard: "", complete: { _, _ in await atomicStaleGate.wait() },
        target: commandTarget, replacementRange: commandRange, onError: { atomicErrors.append($0) })
    await atomicStaleGate.waitUntilSuspended()
    commandCurrent = NotesBridge.SelectionSnapshot(element: syntheticElement, range: commandTarget.range,
        text: "", bounds: .zero, noteID: "different-note", documentText: commandText)
    atomicStaleGate.resume("late")
    await atomicStale?.value
    checks.check(atomicWrites.count == 1 && atomicErrors.count == 1,
                 "原子模板等待时切换笔记仍拒绝替换命令范围")

    let splitText = "Title {{ask:Name}}\nSafe {{selection}} {{clipboard}} \\{{date}} {{unknown}}"
    var splitHeading = TopotextRun()
    splitHeading.length = "Title {{a".utf16.count
    splitHeading.paragraphType = 1
    var splitTail = TopotextRun()
    splitTail.length = "sk:Name}}\n".utf16.count
    splitTail.paragraphType = 1
    splitTail.bold = true
    var splitBody = TopotextRun()
    splitBody.length = "Safe {{selection}} {{clipboard}} \\{{date}} {{unknown}}".utf16.count
    let splitDoc = TopotextDoc(runs: [splitHeading, splitTail, splitBody], text: splitText, totalLength: splitText.utf16.count)
    var splitAsks = 0
    let splitTask = TemplateRunner.runInNotes(
        TemplateNote(name: "split-rich", content: splitText, sourceNotesID: "split-source", sourceDocument: splitDoc),
        selection: "<selected>", bridge: richBridge, clipboard: "A&B", ask: { _ in splitAsks += 1; return "X&Y" },
        onError: { targetErrors.append($0) })
    await splitTask?.value
    let splitWrite = richWrites.last
    checks.check(splitAsks == 1 && splitWrite?.text == "Title X&Y\nSafe <selected> A&B {{date}} {{unknown}}"
                 && splitWrite?.html?.contains("X&amp;Y") == true
                 && splitWrite?.html?.contains("&lt;selected&gt; A&amp;B {{date}} {{unknown}}") == true
                 && splitWrite?.html?.contains("<h1") == true,
                 "跨多个样式 run 的变量只展开一次，选区/剪贴板安全转义且保留转义及未知变量")

    let targetGate = Suspension()
    let staleTask = TemplateRunner.runInNotes(
        TemplateNote(name: "stale-target", content: "{{ai:slow}}"), selection: "captured",
        bridge: bridge, clipboard: "", complete: { _, _ in await targetGate.wait() },
        onError: { targetErrors.append($0) })
    await targetGate.waitUntilSuspended()
    currentTarget = NotesBridge.SelectionSnapshot(element: syntheticElement, range: target.range,
                                                  text: "", bounds: .zero, noteID: "synthetic-note-B", documentText: "text")
    targetGate.resume("late-text")
    await staleTask?.value
    checks.check(writes.count == 1 && targetErrors.count == 1, "模板期间切换笔记后拒绝写入")

    currentTarget = nil
    var absentRequests = 0
    let absent = TemplateRunner.runInNotes(
        TemplateNote(name: "absent", content: "{{ai:never}}"), selection: "",
        bridge: bridge, clipboard: "", complete: { _, _ in absentRequests += 1; return "unexpected" },
        onError: { targetErrors.append($0) })
    checks.check(absent == nil && absentRequests == 0 && writes.count == 1 && targetErrors.count == 2,
                 "入口没有可绑定目标时立即停止，不请求也不写入")

    var cancelledTransportCalls: [String] = []
    var cancelledTransportInsertions: [String] = []
    var cancelledTransportErrors: [String] = []
    let transportCancelled = TemplateRunner.run(
        TemplateNote(name: "transport-cancel", content: "{{ai:cancelled}}|{{ai:never}}"),
        selection: "", clipboard: "", complete: { instruction, _ in
            cancelledTransportCalls.append(instruction)
            throw URLError(.cancelled)
        }, insert: { cancelledTransportInsertions.append($0) }, onError: { cancelledTransportErrors.append($0) })
    await transportCancelled.value
    checks.check(cancelledTransportCalls == ["cancelled"] && cancelledTransportInsertions.isEmpty
                 && cancelledTransportErrors.isEmpty, "网络取消错误中止后续槽与插入")

    // 即使入口配置无效，ask 期间新增有效配置也不能更换本次运行的配置。
    var invalidDefaults = testDefaults("missing")
    let invalidProfile = ModelProfile(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                                      name: "missing", baseURL: "", apiKey: "", model: "")
    invalidDefaults["nc.profiles"] = try! JSONEncoder().encode([invalidProfile])
    invalidDefaults["nc.activeProfileID"] = invalidProfile.id.uuidString
    invalidDefaults["nc.baseURL"] = ""
    invalidDefaults["nc.model"] = ""
    defaults.setVolatileDomain(invalidDefaults, forName: UserDefaults.argumentDomain)
    let invalidStart = TemplateResponseProtocol.instructions.count
    var invalidInsertions: [String] = []
    var invalidErrors: [String] = []
    let invalidTask = TemplateRunner.run(
        TemplateNote(name: "missing-config", content: "{{ask:fix}}|{{ai:one}}|{{ai:two}}"),
        selection: "", clipboard: "", ask: { _ in
            defaults.setVolatileDomain(testDefaults(), forName: UserDefaults.argumentDomain)
            return "fixed-later"
        }, insert: { invalidInsertions.append($0) }, onError: { invalidErrors.append($0) })
    await invalidTask.value
    checks.check(TemplateResponseProtocol.instructions.count == invalidStart
                 && invalidInsertions == ["fixed-later|{{ai:one}}|{{ai:two}}"] && invalidErrors.count == 1,
                 "入口配置失败也固定于本次执行：无请求、保留全部失败槽、只上报一次")

    var boundedAttempts: [String] = []
    var boundedInsertions: [String] = []
    var boundedErrors: [String] = []
    let boundedTask = TemplateRunner.run(
        TemplateNote(name: "all-failed", content: "{{ai:first}}|{{ai:second}}|{{ai:third}}"),
        selection: "", clipboard: "", complete: { instruction, _ in
            boundedAttempts.append(instruction)
            throw APIError(status: 503, message: "failure-\(instruction)")
        }, insert: { boundedInsertions.append($0) }, onError: { boundedErrors.append($0) })
    await boundedTask.value
    checks.check(boundedAttempts == ["first", "second", "third"]
                 && boundedInsertions == ["{{ai:first}}|{{ai:second}}|{{ai:third}}"],
                 "全部槽持续失败时仍逐槽恰一次并完成一次")
    checks.check(boundedErrors.count == 1 && boundedErrors.first?.contains("failure-first") == true,
                 "多个失败只上报出现顺序最早的错误")

    // 中央取消覆盖所有模板，而不是仅取消某个 ChatEngine 的网络 Task。
    let allGateA = Suspension(), allGateB = Suspension()
    var allCancelledInsertions: [String] = []
    var allCancelledErrors: [String] = []
    let allTaskA = TemplateRunner.run(TemplateNote(name: "all-a", content: "{{ai:a}}"), selection: "", clipboard: "",
                                     complete: { _, _ in await allGateA.wait() },
                                     insert: { allCancelledInsertions.append($0) }, onError: { allCancelledErrors.append($0) })
    let allTaskB = TemplateRunner.run(TemplateNote(name: "all-b", content: "{{ai:b}}"), selection: "", clipboard: "",
                                     complete: { _, _ in await allGateB.wait() },
                                     insert: { allCancelledInsertions.append($0) }, onError: { allCancelledErrors.append($0) })
    await allGateA.waitUntilSuspended()
    await allGateB.waitUntilSuspended()
    TemplateRunner.cancelAll()
    allGateA.resume("late-a"); allGateB.resume("late-b")
    await allTaskA.value; await allTaskB.value
    checks.check(allTaskA.isCancelled && allTaskB.isCancelled, "cancelAll 取消所有已登记模板任务")
    checks.check(allCancelledInsertions.isEmpty && allCancelledErrors.isEmpty, "中央取消忽略全部迟到模板结果及错误")

    let activation = DelayedActivation()
    var delayedWrites = 0
    var delayedErrors: [String] = []
    let delayedBridge = NotesBridge(snapshotReader: { target }, replacementWriter: { _, _, _, _ in
        delayedWrites += 1
        return nil
    }, activationScheduler: { activation.schedule($0) })
    let delayedTask = TemplateRunner.runInNotes(TemplateNote(name: "delayed", content: "ready"), selection: "",
                                              bridge: delayedBridge, clipboard: "", onError: { delayedErrors.append($0) })!
    await activation.waitUntilScheduled()
    delayedTask.cancel()
    activation.finish()
    await delayedTask.value
    checks.check(delayedWrites == 0 && delayedErrors.isEmpty, "Task.cancel 在等待 Notes 写入期间阻止真实写入")

    let centrallyCancelled = TemplateRunner.runInNotes(TemplateNote(name: "central-delay", content: "ready"), selection: "",
                                                      bridge: delayedBridge, clipboard: "", onError: { delayedErrors.append($0) })!
    await activation.waitUntilScheduled()
    TemplateRunner.cancelAll()
    activation.finish()
    await centrallyCancelled.value
    checks.check(delayedWrites == 0 && delayedErrors.isEmpty, "cancelAll 使已经排队的 Notes 激活写入失效")

    var callerValid = true
    let invalidatedTask = TemplateRunner.runInNotes(TemplateNote(name: "caller-delay", content: "ready"), selection: "",
                                                    bridge: delayedBridge, clipboard: "", isOperationValid: { callerValid },
                                                    onError: { delayedErrors.append($0) })!
    await activation.waitUntilScheduled()
    callerValid = false
    activation.finish()
    await invalidatedTask.value
    checks.check(delayedWrites == 0 && delayedErrors.isEmpty, "会话 generation 失效也阻止模板延迟写入")

    let freshTask = TemplateRunner.runInNotes(TemplateNote(name: "fresh-delay", content: "fresh"), selection: "",
                                            bridge: delayedBridge, clipboard: "", onError: { delayedErrors.append($0) })!
    await activation.waitUntilScheduled()
    activation.finish()
    await freshTask.value
    checks.check(delayedWrites == 1 && delayedErrors.isEmpty, "取消后的新模板获得独立有效身份并正常写入")

    // Importer -> expansion -> actual writeback seam: the template name is metadata,
    // while the second source line becomes the generated document title.
    let weeklyPrefix = "Weekly Work Templates\n{{date: yyyy-MM-dd}}周记录\n"
    var weeklyTitleRun = TopotextRun()
    weeklyTitleRun.length = weeklyPrefix.utf16.count
    var weeklyBoldRun = TopotextRun()
    weeklyBoldRun.length = "Bold body\n".utf16.count
    weeklyBoldRun.bold = true
    var weeklyCodeRun = TopotextRun()
    weeklyCodeRun.length = "code one\ncode two\n".utf16.count
    weeklyCodeRun.monospaced = true
    weeklyCodeRun.monospacedBlock = true
    let weeklySourceText = weeklyPrefix + "Bold body\ncode one\ncode two\n"
    let weeklySource = TopotextDoc(runs: [weeklyTitleRun, weeklyBoldRun, weeklyCodeRun],
                                  text: weeklySourceText, totalLength: weeklySourceText.utf16.count)
    if let split = NotesTemplateImporter.splitTemplate(weeklySource) {
        let weeklyTemplate = TemplateNote(name: split.name, content: split.document.text,
                                          sourceNotesID: "weekly-fixture", sourceDocument: split.document)
        let original = "Before\n/templates\nAfter"
        let commandRange = (original as NSString).range(of: "/templates")
        let weeklyTarget = NotesBridge.SelectionSnapshot(element: syntheticElement,
            range: CFRange(location: NSMaxRange(commandRange), length: 0), text: "", bounds: .zero,
            noteID: "weekly-target", documentText: original)
        var weeklyResult: String?
        var weeklyHTML: String?
        var weeklyErrors: [String] = []
        let weeklyBridge = NotesBridge(snapshotReader: { weeklyTarget }, replacementWriter: { snap, range, text, html in
            weeklyResult = (snap.documentText as NSString).replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: text)
            weeklyHTML = html
            return nil
        })
        let weeklyTask = TemplateRunner.runInNotes(weeklyTemplate, selection: "", bridge: weeklyBridge,
            clipboard: "", target: weeklyTarget,
            replacementRange: CFRange(location: commandRange.location, length: commandRange.length),
            onError: { weeklyErrors.append($0) })
        await weeklyTask?.value
        checks.check(weeklyErrors.isEmpty && weeklyResult?.range(
            of: "^Before\\n[0-9]{4}-[0-9]{2}-[0-9]{2}周记录\\nBold body\\ncode one\\ncode two\\n\\nAfter$",
            options: .regularExpression) != nil && weeklyResult?.contains("Weekly Work Templates") == false,
            "首行模板名经导入到真实写回不进入文档，第二行日期标题展开且保留命令前后文本")
        checks.check(weeklyHTML?.contains("<h1 ") == true
                     && weeklyHTML?.contains("周记录</h1>") == true
                     && weeklyHTML?.contains("<strong>Bold body</strong>") == true
                     && weeklyHTML?.contains("<pre ") == true
                     && weeklyHTML?.contains("Weekly Work Templates") == false,
                     "去掉模板名后日期标题、正文粗体和多行代码同时进入富文本写回")
        var panelText = "", panelHTML: String?
        let panelTask = TemplateRunner.runRich(weeklyTemplate, selection: "", clipboard: "",
            insert: { panelText = $0; panelHTML = $1 }, onError: { weeklyErrors.append($0) })
        await panelTask.value
        checks.check(panelText.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}周记录\\n", options: .regularExpression) != nil
                     && !panelText.contains("Weekly Work Templates") && panelHTML?.contains("周记录</h1>") == true,
                     "AI 面板与 Notes 插入共用去除模板名后的载荷及日期标题")
    } else {
        checks.check(false, "Weekly Work Templates 示例必须成功拆分为名称和生成内容")
    }

    print(checks.failed == 0 ? "全部通过：\(checks.passed) 项" : "失败 \(checks.failed) 项 / 共 \(checks.passed + checks.failed) 项")
    exit(checks.failed == 0 ? 0 : 1)
}

Task { @MainActor in await runTests() }
Task {
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    print("FAIL  模板执行超时（可能仍在无限请求）")
    exit(2)
}
dispatchMain()
