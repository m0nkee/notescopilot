import Foundation
import Combine
import AppKit

// MARK: - 配置（全部可自配置：Base URL / API Key / 模型 / 系统提示词 / 参数）

// MARK: - 模型配置 Profile（可保存多份，点选其一作为生效配置）

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal, low, medium, high

    var id: String { rawValue }
    var label: String {
        switch self {
        case .minimal: return L10n.text("Minimal")
        case .low: return L10n.text("Low")
        case .medium: return L10n.text("Medium")
        case .high: return L10n.text("High")
        }
    }

    static func parse(_ raw: String?) -> ReasoningEffort? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        return ReasoningEffort(rawValue: normalized)
    }
}

struct ModelProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
    /// nil 表示沿用全局默认值，便于旧配置无感升级。
    var temperature: Double?
    var maxTokens: Int?
    /// nil 表示不发送 reasoning_effort，由服务商使用模型默认推理强度。
    var reasoningEffort: ReasoningEffort?

    init(id: UUID = UUID(), name: String = "", baseURL: String = "", apiKey: String = "", model: String = "",
         temperature: Double? = nil, maxTokens: Int? = nil, reasoningEffort: ReasoningEffort? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
        self.temperature = temperature; self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
    }
}

enum ProfileStore {
    /// 测试可注入隔离的 defaults；非 App 测试构建不访问真实用户配置。
    static var defaults = UserDefaults.standard
    static let key = "nc.profiles"
    static let activeKey = "nc.activeProfileID"
    /// 生效配置切换通知（面板头部实时刷新）
    static let changedNotification = Notification.Name("nc.profileChanged")
    static let errorNotification = Notification.Name("nc.profileStoreError")
    private(set) static var lastError: String?

    private static func report(_ error: Error) {
        let message = error.localizedDescription
        guard lastError != message else { return }
        lastError = message
        NotificationCenter.default.post(name: errorNotification, object: message)
    }

    static func load() -> [ModelProfile] {
        if let data = defaults.data(forKey: key) {
            do {
                let list = try JSONDecoder().decode([ModelProfile].self, from: data)
                // 空列表也是已保存状态，绝不重新导入旧配置。
                if list.isEmpty {
                    for legacyKey in ["nc.baseURL", "nc.apiKey", "nc.model"] { defaults.removeObject(forKey: legacyKey) }
                }
                return list
            } catch {
                report(APIError(status: -1, message: L10n.text("Couldn't read the model profiles. Check your local settings backup.")))
                return []
            }
        }
        // 迁移：旧版单配置（nc.baseURL/nc.apiKey/nc.model）→ 第一份 Profile，只迁移一次。
        let legacy = ModelProfile(name: "默认配置",
                                  baseURL: defaults.string(forKey: "nc.baseURL") ?? "",
                                  apiKey: defaults.string(forKey: "nc.apiKey") ?? "",
                                  model: defaults.string(forKey: "nc.model") ?? "")
        guard !legacy.baseURL.isEmpty || !legacy.model.isEmpty || !legacy.apiKey.isEmpty else { return [] }
        if save([legacy]) { activeID = legacy.id }
        return [legacy]
    }

    /// API Key 随 Profile 一起保存在应用偏好配置中，不访问系统钥匙串。
    @discardableResult
    static func save(_ list: [ModelProfile]) -> Bool {
        guard Set(list.map(\.id)).count == list.count else {
            report(APIError(status: -1, message: L10n.text("Some model profiles have duplicate IDs. Recreate the duplicate profiles.")))
            return false
        }
        do {
            let data = try JSONEncoder().encode(list)
            defaults.set(data, forKey: key)
            for legacyKey in ["nc.baseURL", "nc.apiKey", "nc.model"] { defaults.removeObject(forKey: legacyKey) }
            lastError = nil
            NotificationCenter.default.post(name: changedNotification, object: nil)
            return true
        } catch {
            report(APIError(status: -1, message: L10n.format("Couldn't save the model profiles: %@", error.localizedDescription)))
            return false
        }
    }

    static var activeID: UUID? {
        get { defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let id = newValue { defaults.set(id.uuidString, forKey: activeKey) }
            else { defaults.removeObject(forKey: activeKey) }
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }
}

enum Config {
    static var defaults = UserDefaults.standard
    static let defaultSystem = """
    你是 NotesCopilot，帮助用户处理 Apple Notes 笔记和在 Mac 上选中的文字。
    直接给出结果内容本身，不要寒暄与多余解释；默认输出 Markdown。
    改写用户提供的文字时保留原意。
    """

    /// 全部已保存配置（多份），编辑后由设置页写回
    static var profiles: [ModelProfile] {
        get { ProfileStore.load() }
        set { ProfileStore.save(newValue) }
    }

    /// 当前生效配置：按 activeID 命中，否则取第一份
    static var activeProfile: ModelProfile? {
        let list = ProfileStore.load()
        if let id = ProfileStore.activeID, let p = list.first(where: { $0.id == id }) { return p }
        return list.first
    }

    static var baseURL: String { activeProfile?.baseURL ?? "" }
    static var apiKey: String { activeProfile?.apiKey ?? "" }
    static var model: String { activeProfile?.model ?? "" }
    static var systemPrompt: String {
        let prompt = defaults.string(forKey: "nc.sys") ?? ""
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSystem : prompt
    }
    static var temperature: Double {
        activeProfile?.temperature ?? defaults.object(forKey: "nc.temp") as? Double ?? 0.7
    }
    static var maxTokens: Int {
        activeProfile?.maxTokens ?? defaults.object(forKey: "nc.maxTokens") as? Int ?? 2048
    }

    /// 多轮对话开关（对应 ProNotes ChatStore 的会话保持）
    static var continuous: Bool {
        get { defaults.object(forKey: "nc.continuous") == nil ? true : defaults.bool(forKey: "nc.continuous") }
        set { defaults.set(newValue, forKey: "nc.continuous") }
    }

    /// 归一化 Base URL：自动补 https:// 前缀与 /v1 后缀（OpenAI 兼容端点）
    static func apiBase(_ raw: String? = nil) -> String? {
        var b = (raw ?? baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return nil }
        if !b.hasPrefix("http://") && !b.hasPrefix("https://") { b = "https://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        if !b.hasSuffix("/v1") && !b.contains("/v1/") { b += "/v1" }
        return b
    }
}

// MARK: - 错误

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status < 0 ? message : L10n.format("HTTP %lld: %@", status, message) }
}

/// 一轮请求使用同一份值，避免调度、切换配置及重试时混用服务商凭据。
struct AIRequestConfiguration: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    let systemPrompt: String
    let temperature: Double?
    let maxTokens: Int
    let reasoningEffort: ReasoningEffort?
    let profileIdentity: String

    /// 一些模型只接受服务端默认采样温度（例如 gpt-6.1-terra）。
    /// 对这类模型必须省略 temperature，而不是强行发送 1。
    static func temperatureIsSupported(for model: String) -> Bool {
        let normalized = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.contains("gpt-6.1-terra")
    }

    static func isTemperatureUnsupportedError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("temperature")
            && (message.localizedCaseInsensitiveContains("unsupported")
                || message.localizedCaseInsensitiveContains("does not support")
                || message.localizedCaseInsensitiveContains("only the default"))
    }

    func omittingTemperature() -> AIRequestConfiguration {
        AIRequestConfiguration(baseURL: baseURL, apiKey: apiKey, model: model,
                               systemPrompt: systemPrompt, temperature: nil, maxTokens: maxTokens,
                               reasoningEffort: reasoningEffort, profileIdentity: profileIdentity)
    }

    static func current() throws -> AIRequestConfiguration {
        let profile = Config.activeProfile
        guard let base = Config.apiBase(profile?.baseURL ?? ""),
              let url = URL(string: base), let host = url.host, !host.isEmpty,
              url.scheme == "https" || url.scheme == "http" else {
            throw APIError(status: -1, message: L10n.text("The Base URL is missing or invalid. Check Settings."))
        }
        guard let model = profile?.model.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw APIError(status: -1, message: L10n.text("No model name is configured. Open Settings to add one."))
        }
        let temperature = Self.temperatureIsSupported(for: model) ? Config.temperature : nil
        let temperatureIdentity = temperature.map { "\($0)" } ?? "default"
        let reasoningEffort = ReasoningEffort.parse(profile?.reasoningEffort?.rawValue)
        return AIRequestConfiguration(baseURL: base, apiKey: profile?.apiKey ?? "", model: model,
                                      systemPrompt: Config.systemPrompt, temperature: temperature,
                                      maxTokens: Config.maxTokens, reasoningEffort: reasoningEffort,
                                      profileIdentity: (profile?.id.uuidString ?? "") + "|" + base + "|" + model
                                          + "|t\(temperatureIdentity)|m\(Config.maxTokens)"
                                          + "|r\(reasoningEffort?.rawValue ?? "default")")
    }
}

// MARK: - 模型列表探测（GET /models，OpenAI 兼容）

enum AIService {
    static func fetchModels(base: String, key: String) async throws -> [String] {
        guard let url = URL(string: base + "/models"),
              let host = url.host, !host.isEmpty,
              url.scheme == "https" || url.scheme == "http" else {
            throw APIError(status: -1, message: L10n.text("The Base URL is invalid. Enter a full HTTP or HTTPS service address."))
        }
        var req = URLRequest(url: url)
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError(status: http.statusCode,
                           message: Self.extractMessage(String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            throw APIError(status: -2, message: L10n.text("The model list response is invalid. Check the service address and API compatibility."))
        }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }

    enum ContextKind: String { case note = "笔记上下文", selection = "选中文本" }

    /// 模板片段与选区工具独立发起单轮补全。选区中的缩进和首尾换行也属于用户的输入。
    static func complete(instruction: String, context: String,
                         contextKind: ContextKind = .note,
                         configuration: AIRequestConfiguration? = nil) async throws -> String {
        let configuration = try configuration ?? AIRequestConfiguration.current()
        try Task.checkCancellation()
        var user = instruction
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let content = contextKind == .selection ? context : trimmed
            user = "【\(contextKind.rawValue)】\n\(content)\n\n【任务】\n\(instruction)"
        }
        guard let url = URL(string: configuration.baseURL + "/chat/completions") else {
            throw APIError(status: -1, message: L10n.text("The Base URL is invalid."))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let key = configuration.apiKey
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": configuration.systemPrompt],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "max_tokens": configuration.maxTokens,
        ]
        if let temperature = configuration.temperature { body["temperature"] = temperature }
        if let reasoningEffort = configuration.reasoningEffort {
            body["reasoning_effort"] = reasoningEffort.rawValue
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError(status: http.statusCode,
                           message: Self.extractMessage(String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String, !text.isEmpty else {
            throw APIError(status: -2, message: L10n.text("The response is empty or could not be read."))
        }
        if let reason = choices.first?["finish_reason"] as? String, reason != "stop" {
            let message = reason == "length" ? L10n.text("The response reached the output limit. Increase the output token limit and try again.") : L10n.format("The response ended early (%@). Try again.", reason)
            throw APIError(status: -3, message: message)
        }
        return text
    }

    static func extractMessage(_ raw: String) -> String {
        guard let d = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return raw }
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = o["error"] as? String { return m }
        if let m = o["message"] as? String { return m }
        return raw
    }
}

// MARK: - 图片附件（对应 ProNotes chatCompletionContentPartImageParam）

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let dataURL: String

    static let maximumCount = 6
    static let maximumEncodedBytes = 10 * 1024 * 1024
    static func make(_ image: NSImage) -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let original = NSBitmapImageRep(data: tiff) else { return nil }
        let longest = max(original.pixelsWide, original.pixelsHigh)
        guard longest > 0 else { return nil }
        let scale = min(1, 2048.0 / Double(longest))
        let width = max(1, Int(Double(original.pixelsWide) * scale))
        let height = max(1, Int(Double(original.pixelsHigh) * scale))
        let rep: NSBitmapImageRep
        if scale < 1 {
            guard let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: resized) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            rep = resized
        } else { rep = original }
        guard let png = rep.representation(using: .png, properties: [:]), png.count <= maximumEncodedBytes else { return nil }
        let preview = NSImage(size: NSSize(width: width, height: height))
        preview.addRepresentation(rep)
        return ImageAttachment(image: preview, dataURL: "data:image/png;base64," + png.base64EncodedString())
    }
}

// MARK: - Token 用量（对应 ProNotes promptTokens / completionTokens 统计）

enum TokenMath {
    /// 无服务端 usage 时的粗略估算：CJK 按 1 字 ≈ 1 token，其余按 4 字符 ≈ 1 token
    static func estimate(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF, 0x3000...0x303F, 0xFF00...0xFFEF: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other + 3) / 4
    }
}

// MARK: - 对话引擎（对应 ProNotes 的 ChatStore + openAIClient，SSE 流式 + 多轮 + 多模态）

// MARK: - 本地会话持久化（只保存对话内容，不保存 API Key）

struct ChatMessageRecord: Codable, Equatable {
    let role: String
    let content: String
}

struct ChatSessionRecord: Codable, Equatable {
    var history: [ChatMessageRecord] = []
    var output = ""
    var submittedPrompt = ""
    var noteContext = ""
    var contextSource = ""
    var profileIdentity = ""
    var promptTokens = 0
    var completionTokens = 0
    var totalPromptTokens = 0
    var totalCompletionTokens = 0
    var savedAt = Date.distantPast
}

enum ChatSessionStore {
    static let key = "nc.chat.session"
    static var defaults = UserDefaults.standard

    static func save(_ record: ChatSessionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> ChatSessionRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ChatSessionRecord.self, from: data)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class ChatEngine: ObservableObject {
    init() { restoreSession() }

    /// 每次提交都发布，包括重复命令；面板草稿只在提交或新会话时同步。
    @Published private(set) var submittedPrompt = ""
    @Published var output = ""
    @Published var busy = false
    @Published var lastError: String?
    /// Apple Notes 选中文本（通过 AX API 抓取），作为对话上下文
    @Published var noteContext = ""
    /// 上下文来源（"选中文本"/"光标段落"/"手动输入"），面板展示用
    @Published var contextSource = ""
    /// 多轮会话历史（role/content 数组，对应 ChatStore）
    @Published var history: [[String: Any]] = []
    @Published var continuous = Config.continuous {
        didSet {
            Config.continuous = continuous
            if !continuous {
                history = []
                ChatSessionStore.clear()
            }
        }
    }
    /// 本轮附带图片（多模态 content parts）
    @Published var images: [ImageAttachment] = []
    /// token 用量：本轮 / 累计
    @Published var promptTokens = 0
    @Published var completionTokens = 0
    @Published var tokensEstimated = false
    @Published var totalPromptTokens = 0
    @Published var totalCompletionTokens = 0
    /// 全局斜杠命令置位：本轮完成后自动把结果回写到 Notes 光标处
    var autoInsertNext = false
    /// 斜杠命令完成后待确认的结果（review 制：不自动插入，用户在面板确认后回写）
    @Published var pendingResult = "" {
        didSet { if pendingResult.isEmpty { pendingReviewID = nil } }
    }
    @Published var pendingTarget: NotesBridge.SelectionSnapshot?
    @Published private(set) var pendingReviewID: UUID?
    /// 覆盖等待 Notes 激活及模板等副作用；停止或开始新工作后，旧代操作必须失效。
    @Published private(set) var operationGeneration = UUID()

    @Published private var responseState: ResponseState?
    @Published private var sessionChange: SessionChange?
    var responseStatus: String { responseState?.label ?? "" }
    var sessionNotice: String? { sessionChange?.label }
    @Published private(set) var canRetry = false
    @Published private(set) var canContinue = false

    private var contextNoteID: String?
    private var sessionProfileIdentity: String?
    private struct LastRequest {
        let prompt: String
        let context: String
        let source: String
        let noteID: String?
        let images: [ImageAttachment]
        let target: NotesBridge.SelectionSnapshot?
        let review: Bool
        let profileIdentity: String
    }
    private var lastRequest: LastRequest?
    private var task: Task<Void, Never>?
    private var currentRequestID: UUID?

    var contextSourceLabel: String {
        switch contextSource {
        case "选中文本": return L10n.text("Selected Text")
        case "光标段落": return L10n.text("Paragraph at Cursor")
        case "手动输入": return L10n.text("Manual Input")
        default:
            let libraryPrefix = "笔记库 · "
            if contextSource.hasPrefix(libraryPrefix) {
                let title = String(contextSource.dropFirst(libraryPrefix.count))
                return L10n.format("Notes Library · %@", title)
            }
            return contextSource
        }
    }

    static func historyDisplayContent(_ message: [String: Any]) -> String {
        let content = message["content"] as? String ?? ""
        let suffix = " 张图片]"
        guard message["role"] as? String == "user", content.hasSuffix(suffix),
              let marker = content.range(of: "\n[本轮附带 ", options: .backwards),
              let count = Int(content[marker.upperBound...].dropLast(suffix.count)), count > 0 else {
            return content
        }
        let note = count == 1
            ? L10n.text("\n[1 image attached]")
            : L10n.format("\n[%lld images attached]", count)
        return String(content[..<marker.lowerBound]) + note
    }

    private enum ResponseState {
        case stopped, restored, invalidConfiguration, generating, continuing, completed, failed, incomplete

        var label: String {
            switch self {
            case .stopped: return L10n.text("Stopped with an incomplete result")
            case .restored: return L10n.text("Previous conversation restored")
            case .invalidConfiguration: return L10n.text("Model configuration unavailable")
            case .generating: return L10n.text("Generating…")
            case .continuing: return L10n.text("Continuing…")
            case .completed: return L10n.text("Complete")
            case .failed: return L10n.text("Generation failed. You can retry.")
            case .incomplete: return L10n.text("Response incomplete. The partial result was kept.")
            }
        }
    }

    private enum SessionChange {
        case note, profile

        var label: String {
            switch self {
            case .note: return L10n.text("The source note changed. A new conversation was started.")
            case .profile: return L10n.text("The model profile changed. A new conversation was started.")
            }
        }
    }

    /// 每轮响应独立累积；Published 属性只负责显示，不能作为旧任务的结算来源。
    private struct StreamResult {
        var output = ""
        var promptTokens = 0
        var completionTokens = 0
        var sawContent = false
        var sawDone = false
        var finishReason: String?
    }

    func stop() {
        operationGeneration = UUID()
        TemplateRunner.cancelAll()
        let wasBusy = busy
        currentRequestID = nil
        task?.cancel()
        task = nil
        busy = false
        autoInsertNext = false
        dismissReview()
        if wasBusy {
            responseState = .stopped
            canRetry = lastRequest != nil
            canContinue = lastRequest != nil && !output.isEmpty
        }
        // Preserve an interrupted response for the next launch, just as
        // completed responses are preserved.
        persistSession()
    }

    func dismissReview() {
        pendingReviewID = nil
        pendingResult = ""
        pendingTarget = nil
    }

    private func persistSession() {
        guard continuous, !history.isEmpty || !output.isEmpty else { ChatSessionStore.clear(); return }
        let record = ChatSessionRecord(
            history: history.compactMap { message in
                guard let role = message["role"] as? String,
                      let content = message["content"] as? String else { return nil }
                return ChatMessageRecord(role: role, content: content)
            },
            output: output,
            submittedPrompt: submittedPrompt,
            noteContext: noteContext,
            contextSource: contextSource,
            profileIdentity: sessionProfileIdentity ?? "",
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalPromptTokens: totalPromptTokens,
            totalCompletionTokens: totalCompletionTokens,
            savedAt: Date())
        ChatSessionStore.save(record)
    }

    private func restoreSession() {
        guard continuous, let record = ChatSessionStore.load() else { return }
        history = record.history.map { ["role": $0.role, "content": $0.content] }
        output = record.output
        submittedPrompt = record.submittedPrompt
        noteContext = record.noteContext
        contextSource = record.contextSource
        sessionProfileIdentity = record.profileIdentity.isEmpty ? nil : record.profileIdentity
        promptTokens = record.promptTokens
        completionTokens = record.completionTokens
        totalPromptTokens = record.totalPromptTokens
        totalCompletionTokens = record.totalCompletionTokens
        responseState = .restored
    }

    /// 新会话保留当前笔记上下文；换来源时由 setContext 自动调用。
    func beginSession(clearSubmittedPrompt: Bool = true) {
        stop()
        if clearSubmittedPrompt { submittedPrompt = "" }
        history = []
        output = ""
        lastError = nil
        lastRequest = nil
        canRetry = false
        canContinue = false
        responseState = nil
        sessionChange = nil
        promptTokens = 0
        completionTokens = 0
        tokensEstimated = false
        totalPromptTokens = 0
        totalCompletionTokens = 0
        ChatSessionStore.clear()
    }

    func setContext(_ text: String, source: String, noteID: String? = nil) {
        let newID = noteID.flatMap { $0.isEmpty ? nil : $0 }
        let cleared = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !noteContext.isEmpty
        let changed = contextNoteID != newID || (newID == nil && text != noteContext) || cleared
        if changed {
            let hadConversation = !history.isEmpty || busy || !output.isEmpty
            beginSession(clearSubmittedPrompt: false)
            images = []
            if hadConversation { sessionChange = .note }
        }
        noteContext = text
        contextSource = source
        contextNoteID = newID
    }

    func resetSession() {
        beginSession()
        noteContext = ""
        contextSource = ""
        contextNoteID = nil
        sessionProfileIdentity = nil
        sessionChange = nil
        images = []
    }

    @discardableResult
    func addImage(_ image: NSImage) -> Bool {
        guard images.count < ImageAttachment.maximumCount else {
            lastError = L10n.format("You can attach up to %lld images per request.", ImageAttachment.maximumCount); return false
        }
        guard let attachment = ImageAttachment.make(image) else {
            lastError = L10n.text("The image couldn't be read or is still over 10 MB after compression. Try a smaller image."); return false
        }
        images.append(attachment)
        return true
    }

    func retryLastRequest() { restoreLastRequest(continuing: false) }
    func continueLastResponse() { restoreLastRequest(continuing: true) }

    private func restoreLastRequest(continuing: Bool) {
        guard !busy, let previous = lastRequest else { return }
        do {
            guard try AIRequestConfiguration.current().profileIdentity == previous.profileIdentity else {
                lastError = L10n.text("The model profile has changed. Generate again with the current profile."); return
            }
        } catch { lastError = error.localizedDescription; return }
        let prefix = continuing ? output : ""
        noteContext = previous.context
        contextSource = previous.source
        contextNoteID = previous.noteID
        images = previous.images
        autoInsertNext = previous.review
        start(prompt: previous.prompt, writebackTarget: previous.target, continuationPrefix: prefix)
    }

    /// 组装 messages（独立出来便于测试）：system + 历史 + 多模态 user
    nonisolated static func buildMessages(system: String,
                                          history: [[String: Any]],
                                          userText: String,
                                          images: [ImageAttachment],
                                          continuous: Bool) -> [[String: Any]] {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        if continuous { msgs += history.suffix(12) }
        var content: Any = userText
        if !images.isEmpty {
            var parts: [[String: Any]] = [["type": "text", "text": userText]]
            for img in images {
                parts.append(["type": "image_url", "image_url": ["url": img.dataURL]])
            }
            content = parts
        }
        msgs.append(["role": "user", "content": content])
        return msgs
    }

    func run(prompt raw: String, writebackTarget: NotesBridge.SelectionSnapshot? = nil) {
        start(prompt: raw, writebackTarget: writebackTarget, continuationPrefix: "")
    }

    private func start(prompt raw: String, writebackTarget: NotesBridge.SelectionSnapshot?, continuationPrefix: String) {
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        submittedPrompt = prompt
        let reviewOnCompletion = autoInsertNext
        stop()
        let configuration: AIRequestConfiguration
        do { configuration = try AIRequestConfiguration.current() }
        catch { lastError = error.localizedDescription; responseState = .invalidConfiguration; return }
        guard images.count <= ImageAttachment.maximumCount else {
            lastError = L10n.format("You can attach up to %lld images per request.", ImageAttachment.maximumCount); return
        }
        if let previous = sessionProfileIdentity, previous != configuration.profileIdentity {
            history = []
            totalPromptTokens = 0
            totalCompletionTokens = 0
            sessionChange = .profile
        }
        sessionProfileIdentity = configuration.profileIdentity
        output = continuationPrefix
        lastError = nil
        busy = true
        responseState = continuationPrefix.isEmpty ? .generating : .continuing
        canRetry = false
        canContinue = false
        promptTokens = 0
        completionTokens = 0
        tokensEstimated = false

        let context = noteContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = prompt
        if !context.isEmpty { user = "【笔记上下文】\n\(context)\n\n【任务】\n\(prompt)" }
        let images = self.images
        var userForHistory = user
        if !images.isEmpty { userForHistory += "\n[本轮附带 \(images.count) 张图片]" }
        lastRequest = LastRequest(prompt: prompt, context: noteContext, source: contextSource,
            noteID: contextNoteID, images: images, target: writebackTarget, review: reviewOnCompletion,
            profileIdentity: configuration.profileIdentity)
        let requestHistory = history
        let requestContinuous = continuous
        var messages = Self.buildMessages(system: configuration.systemPrompt, history: requestHistory,
            userText: user, images: images, continuous: requestContinuous)
        if !continuationPrefix.isEmpty {
            messages += [["role": "assistant", "content": continuationPrefix],
                         ["role": "user", "content": "请从上面回答的中断处继续完成原任务，只输出续写部分，不要重复已有内容。"]]
        }
        let promptEstimate = TokenMath.estimate(messages.compactMap { $0["content"] as? String }.joined(separator: " "))
        let requestID = UUID()
        currentRequestID = requestID
        task = Task { [weak self] in
            guard let self, self.currentRequestID == requestID, !Task.isCancelled else { return }
            var result = StreamResult(output: continuationPrefix)
            var completed = false
            do {
                try await self.streamWithCompatibility(configuration: configuration, messages: messages,
                                                        includeUsage: true, requestID: requestID,
                                                        continuationPrefix: continuationPrefix, result: &result)
                completed = true
            } catch {
                guard self.currentRequestID == requestID, !Task.isCancelled else { return }
                if !(error is CancellationError) { self.lastError = L10n.format("Request failed: %@", error.localizedDescription) }
            }
            guard self.currentRequestID == requestID, !Task.isCancelled else { return }
            self.busy = false
            self.task = nil
            self.currentRequestID = nil
            self.output = result.output
            self.responseState = completed ? .completed : (result.output.isEmpty ? .failed : .incomplete)
            self.canRetry = !completed
            self.canContinue = !completed && !result.output.isEmpty
            if result.sawContent {
                self.promptTokens = result.promptTokens == 0 ? promptEstimate : result.promptTokens
                self.completionTokens = result.completionTokens == 0 ? TokenMath.estimate(String(result.output.dropFirst(continuationPrefix.count))) : result.completionTokens
                self.tokensEstimated = result.promptTokens == 0 || result.completionTokens == 0
                self.totalPromptTokens += self.promptTokens
                self.totalCompletionTokens += self.completionTokens
            }
            // 不完整结果保留附件供重试，不能进入正式历史或写回 review。
            if completed {
                let sentImageIDs = Set(images.map(\.id))
                self.images.removeAll { sentImageIDs.contains($0.id) }
                if requestContinuous && self.continuous {
                    self.history = requestHistory + [["role": "user", "content": userForHistory],
                                                     ["role": "assistant", "content": result.output]]
                }
                if reviewOnCompletion {
                    self.pendingReviewID = UUID()
                    self.pendingTarget = writebackTarget
                    self.pendingResult = result.output
                }
            }
            self.persistSession()
        }
    }

    /// 兼容不支持 stream_options 或自定义 temperature 的服务商；每种兼容问题最多重试一次。
    private func streamWithCompatibility(configuration: AIRequestConfiguration, messages: [[String: Any]],
                                          includeUsage: Bool, requestID: UUID, continuationPrefix: String,
                                          result: inout StreamResult) async throws {
        do {
            try await stream(configuration: configuration, messages: messages, includeUsage: includeUsage,
                             requestID: requestID, result: &result)
        } catch let error as APIError
            where error.status == 400 && includeUsage && error.message.contains("stream_options") {
            result = StreamResult(output: continuationPrefix)
            try await streamWithCompatibility(configuration: configuration, messages: messages,
                                              includeUsage: false, requestID: requestID,
                                              continuationPrefix: continuationPrefix, result: &result)
        } catch let error as APIError
            where error.status == 400 && configuration.temperature != nil
                && AIRequestConfiguration.isTemperatureUnsupportedError(error.message) {
            result = StreamResult(output: continuationPrefix)
            try await streamWithCompatibility(configuration: configuration.omittingTemperature(), messages: messages,
                                              includeUsage: includeUsage, requestID: requestID,
                                              continuationPrefix: continuationPrefix, result: &result)
        }
    }

    /// 发起 SSE 流式请求；includeUsage 时带 stream_options.include_usage
    private func stream(configuration: AIRequestConfiguration, messages: [[String: Any]], includeUsage: Bool, requestID: UUID,
                        result: inout StreamResult) async throws {
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": true,
            "max_tokens": configuration.maxTokens,
        ]
        if let temperature = configuration.temperature { body["temperature"] = temperature }
        if let reasoningEffort = configuration.reasoningEffort {
            body["reasoning_effort"] = reasoningEffort.rawValue
        }
        if includeUsage { body["stream_options"] = ["include_usage": true] }

        guard let url = URL(string: configuration.baseURL + "/chat/completions") else {
            throw APIError(status: -1, message: L10n.text("The Base URL is invalid."))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            req.setValue("Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard currentRequestID == requestID, !Task.isCancelled else { throw CancellationError() }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var errText = ""
            for try await l in bytes.lines {
                guard currentRequestID == requestID, !Task.isCancelled else { throw CancellationError() }
                errText += l
            }
            guard currentRequestID == requestID, !Task.isCancelled else { throw CancellationError() }
            throw APIError(status: http.statusCode, message: AIService.extractMessage(errText))
        }
        // 逐行读取（AsyncLinesSequence 按 UTF-8 正确解码多字节中文；
        // 不能逐字节 Character(UnicodeScalar(byte)) 拼接——那会把中文拆成 Latin-1 乱码）
        for try await line in bytes.lines {
            guard currentRequestID == requestID, !Task.isCancelled else { throw CancellationError() }
            try handle(line: line, result: &result)
            output = result.output
            promptTokens = result.promptTokens
            completionTokens = result.completionTokens
            tokensEstimated = false
            if result.sawDone { break }
        }
        guard result.sawContent else { throw APIError(status: -2, message: L10n.text("The service returned no usable content. Check the model and endpoint, then try again.")) }
        guard result.sawDone || result.finishReason == "stop" else {
            throw APIError(status: -3, message: L10n.text("The stream ended before the completion marker. The partial result was kept. You can retry or continue it."))
        }
    }

    /// 解析 SSE 行：data: {"choices":[{"delta":{"content":"..."}}]} 及末尾 usage 块
    private func handle(line: String, result: inout StreamResult) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { result.sawDone = true; return }
        guard !payload.isEmpty else { return }
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(status: -2, message: L10n.text("Couldn't read the streamed response. The partial result was kept. Try again."))
        }
        if let error = obj["error"], !(error is NSNull) {
            throw APIError(status: -2, message: AIService.extractMessage(String(payload)))
        }
        if let usage = obj["usage"] as? [String: Any] {
            if let p = usage["prompt_tokens"] as? Int { result.promptTokens = p }
            if let c = usage["completion_tokens"] as? Int { result.completionTokens = c }
        }
        guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { return }
        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            result.output += content
            result.sawContent = true
        }
        if let reason = choice["finish_reason"] as? String {
            result.finishReason = reason
            switch reason {
            case "stop": break
            case "length": throw APIError(status: -3, message: L10n.text("The response reached the output limit. Continue it, or increase the output token limit and try again."))
            case "content_filter": throw APIError(status: -3, message: L10n.text("The provider's content filter stopped the response. The partial result was kept."))
            default: throw APIError(status: -3, message: L10n.format("The response ended early (%@). Adjust the model or try again.", reason))
            }
        }
    }
}
