import Foundation
import Combine
import AppKit

// MARK: - 配置（全部可自配置：Base URL / API Key / 模型 / 系统提示词 / 参数）

// MARK: - 模型配置 Profile（可保存多份，点选其一作为生效配置）

struct ModelProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
}

enum ProfileStore {
    static let defaults = UserDefaults.standard
    static let key = "nc.profiles"
    static let activeKey = "nc.activeProfileID"
    /// 生效配置切换通知（面板头部实时刷新）
    static let changedNotification = Notification.Name("nc.profileChanged")

    static func load() -> [ModelProfile] {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([ModelProfile].self, from: data), !list.isEmpty {
            return list
        }
        // 迁移：旧版单配置（nc.baseURL/nc.apiKey/nc.model）→ 第一份 Profile，只迁移一次
        let legacy = ModelProfile(name: "默认配置",
                                  baseURL: defaults.string(forKey: "nc.baseURL") ?? "",
                                  apiKey: defaults.string(forKey: "nc.apiKey") ?? "",
                                  model: defaults.string(forKey: "nc.model") ?? "")
        guard !legacy.baseURL.isEmpty || !legacy.model.isEmpty else { return [] }
        let list = [legacy]
        save(list)
        defaults.set(legacy.id.uuidString, forKey: activeKey)
        NCLog.log("已迁移旧版单配置为多配置 Profile：\(legacy.name) · \(legacy.model)")
        return list
    }

    static func save(_ list: [ModelProfile]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }

    static var activeID: UUID? {
        get {
            guard let s = defaults.string(forKey: activeKey) else { return nil }
            return UUID(uuidString: s)
        }
        set {
            if let id = newValue {
                defaults.set(id.uuidString, forKey: activeKey)
            } else {
                defaults.removeObject(forKey: activeKey)
            }
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }
}

enum Config {
    static let defaults = UserDefaults.standard
    static let defaultSystem = """
    你是 NotesCopilot，一个嵌入 Apple Notes 工作流的 AI 写作助手。
    直接给出结果内容本身，不要寒暄与多余解释；默认输出 Markdown。
    用户给出的「笔记上下文」来自 Apple Notes 中选中的文字；改写时不要改变其原意。
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
    static var systemPrompt: String { defaults.string(forKey: "nc.sys") ?? defaultSystem }
    static var temperature: Double { defaults.object(forKey: "nc.temp") as? Double ?? 0.7 }
    static var maxTokens: Int { defaults.object(forKey: "nc.maxTokens") as? Int ?? 2048 }

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
    var errorDescription: String? { "HTTP \(status)：\(message)" }
}

// MARK: - 模型列表探测（GET /models，OpenAI 兼容）

enum AIService {
    static func fetchModels(base: String, key: String) async throws -> [String] {
        var req = URLRequest(url: URL(string: base + "/models")!)
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError(status: http.statusCode,
                           message: Self.extractMessage(String(data: data, encoding: .utf8) ?? ""))
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let arr = obj?["data"] as? [[String: Any]] ?? []
        return arr.compactMap { $0["id"] as? String }.sorted()
    }

    /// 非流式单轮补全（模板 {{ai:指令}} 片段用）：走当前生效配置，
    /// 笔记上下文非空时自动拼入。与面板流式通道互不干扰。
    static func complete(instruction: String, context: String) async throws -> String {
        guard let base = Config.apiBase() else {
            throw APIError(status: -1, message: "尚未配置 Base URL，请先打开设置")
        }
        guard !Config.model.isEmpty else {
            throw APIError(status: -1, message: "尚未配置模型名，请先打开设置")
        }
        var user = instruction
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            user = "【笔记上下文】\n\(ctx)\n\n【任务】\n\(instruction)"
        }
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let key = Config.apiKey
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Config.model,
            "messages": [
                ["role": "system", "content": Config.systemPrompt],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "temperature": Config.temperature,
            "max_tokens": Config.maxTokens,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError(status: http.statusCode,
                           message: Self.extractMessage(String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String, !text.isEmpty else {
            throw APIError(status: -2, message: "响应格式无法解析或内容为空")
        }
        return text
    }

    static func extractMessage(_ raw: String) -> String {
        guard let d = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return raw }
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = o["message"] as? String { return m }
        return raw
    }
}

// MARK: - 图片附件（对应 ProNotes chatCompletionContentPartImageParam）

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let dataURL: String

    static func make(_ image: NSImage) -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ImageAttachment(image: image,
                                dataURL: "data:image/png;base64," + png.base64EncodedString())
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

@MainActor
final class ChatEngine: ObservableObject {
    @Published var output = ""
    @Published var busy = false
    @Published var lastError: String?
    /// Apple Notes 选中文本（通过 AX API 抓取），作为对话上下文
    @Published var noteContext = ""
    /// 上下文来源（"选中文本"/"光标段落"/"手动输入"），面板展示用
    @Published var contextSource = ""
    /// 多轮会话历史（role/content 数组，对应 ChatStore）
    @Published var history: [[String: Any]] = []
    @Published var continuous = Config.continuous { didSet { Config.continuous = continuous } }
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
    @Published var pendingResult = ""

    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
        busy = false
    }

    /// 对应 ProNotes 的 transactionCompletion：新会话清空 ChatStore
    func resetSession() {
        history = []
        output = ""
        lastError = nil
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

    func run(prompt raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let base = Config.apiBase() else {
            lastError = "尚未配置 Base URL，请先打开设置。"; return
        }
        guard !Config.model.isEmpty else {
            lastError = "尚未配置模型名，请先打开设置。"; return
        }
        stop()
        output = ""
        lastError = nil
        busy = true
        promptTokens = 0
        completionTokens = 0
        tokensEstimated = false

        let context = noteContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = prompt
        if !context.isEmpty {
            user = "【笔记上下文】\n\(context)\n\n【任务】\n\(prompt)"
        }
        let images = self.images
        let nImages = images.count
        // 历史里记录纯文本版（图片不重复入历史）
        var userForHistory = user
        if nImages > 0 { userForHistory += "\n[本轮附带 \(nImages) 张图片]" }

        let messages = Self.buildMessages(system: Config.systemPrompt,
                                          history: history,
                                          userText: user,
                                          images: images,
                                          continuous: continuous)
        let promptEstimate = TokenMath.estimate(messages
            .compactMap { ($0["content"] as? String) }
            .joined(separator: " "))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.stream(base: base, messages: messages, includeUsage: true)
            } catch let e as APIError where e.status == 400 && e.message.contains("stream_options") {
                // 个别 OpenAI 兼容端点不支持 stream_options，去掉后重试一次
                do { try await self.stream(base: base, messages: messages, includeUsage: false) }
                catch { self.lastError = "请求失败：" + error.localizedDescription }
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    self.lastError = "请求失败：" + error.localizedDescription
                }
            }
            self.busy = false

            // 结算：token 用量 + 历史追加
            if !self.output.isEmpty {
                if self.promptTokens == 0 {
                    self.promptTokens = promptEstimate
                    self.tokensEstimated = true
                }
                if self.completionTokens == 0 {
                    self.completionTokens = TokenMath.estimate(self.output)
                    self.tokensEstimated = true
                }
                self.totalPromptTokens += self.promptTokens
                self.totalCompletionTokens += self.completionTokens
                self.images = []
                if self.continuous && !Task.isCancelled {
                    self.history.append(["role": "user", "content": userForHistory])
                    self.history.append(["role": "assistant", "content": self.output])
                }
                // 全局斜杠命令：完成后不再自动插入——改为在面板顶部弹 review 横幅，
                // 用户确认「插入光标处 / 替换选中 / 复制」，防误写、可预览（体验重设计）
                if self.autoInsertNext {
                    self.autoInsertNext = false
                    self.pendingResult = self.output
                }
            }
        }
    }

    /// 发起 SSE 流式请求；includeUsage 时带 stream_options.include_usage
    private func stream(base: String, messages: [[String: Any]], includeUsage: Bool) async throws {
        var body: [String: Any] = [
            "model": Config.model,
            "messages": messages,
            "stream": true,
            "temperature": Config.temperature,
            "max_tokens": Config.maxTokens,
        ]
        if includeUsage { body["stream_options"] = ["include_usage": true] }

        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Config.apiKey.isEmpty {
            req.setValue("Bearer " + Config.apiKey, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var errText = ""
            for try await l in bytes.lines { errText += l }
            throw APIError(status: http.statusCode, message: AIService.extractMessage(errText))
        }
        // 逐行读取（AsyncLinesSequence 按 UTF-8 正确解码多字节中文；
        // 不能逐字节 Character(UnicodeScalar(byte)) 拼接——那会把中文拆成 Latin-1 乱码）
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            handle(line: line)
        }
    }

    /// 解析 SSE 行：data: {"choices":[{"delta":{"content":"..."}}]} 及末尾 usage 块
    private func handle(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return }
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // token 用量（stream_options.include_usage 的末尾块，或部分端点随块携带）
        if let usage = obj["usage"] as? [String: Any] {
            if let p = usage["prompt_tokens"] as? Int { promptTokens = p; tokensEstimated = false }
            if let c = usage["completion_tokens"] as? Int { completionTokens = c; tokensEstimated = false }
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return }
        output += content
    }
}
