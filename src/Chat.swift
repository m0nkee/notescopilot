import Foundation
import Combine
import AppKit
import Security
import LocalAuthentication

// MARK: - 配置（全部可自配置：Base URL / API Key / 模型 / 系统提示词 / 参数）

// MARK: - 模型配置 Profile（可保存多份，点选其一作为生效配置）

struct ModelProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var baseURL: String = ""
    /// 仅内存中用于编辑/请求；ProfileStore 写盘前会移除。
    var apiKey: String = ""
    var model: String = ""
    var hasStoredAPIKey = false
    var credentialUnavailable = false

    init(id: UUID = UUID(), name: String = "", baseURL: String = "", apiKey: String = "", model: String = "") {
        self.id = id; self.name = name; self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }

    private enum CodingKeys: String, CodingKey { case id, name, baseURL, apiKey, model, hasStoredAPIKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        hasStoredAPIKey = try c.decodeIfPresent(Bool.self, forKey: .hasStoredAPIKey) ?? false
    }
}

/// 单项实现应在抛错时保持该项原值；ProfileStore 会补偿此前已成功的写入。
protocol ProfileSecretStore {
    func read(id: UUID) throws -> String?
    func write(_ secret: String, id: UUID) throws
    func remove(id: UUID) throws
    func allowingUserInteraction() -> any ProfileSecretStore
}

extension ProfileSecretStore {
    func allowingUserInteraction() -> any ProfileSecretStore { self }
}

final class MemoryProfileSecretStore: ProfileSecretStore {
    var values: [UUID: String] = [:]
    func read(id: UUID) throws -> String? { values[id] }
    func write(_ secret: String, id: UUID) throws { values[id] = secret }
    func remove(id: UUID) throws { values.removeValue(forKey: id) }
}

struct KeychainProfileSecretStore: ProfileSecretStore {
    private let service = "NotesCopilot.model-api-key"
    private let allowsUserInteraction: Bool

    init(allowsUserInteraction: Bool = false) { self.allowsUserInteraction = allowsUserInteraction }

    func query(_ id: UUID, quietContext: LAContext? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if !allowsUserInteraction {
            let context = quietContext ?? LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    func allowingUserInteraction() -> any ProfileSecretStore {
        // 显式恢复使用 file-based Keychain 默认的 ACL 交互，不复用 LAContext。
        return KeychainProfileSecretStore(allowsUserInteraction: true)
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
            throw APIError(status: Int(status), message: "钥匙串访问失败：" + message)
        }
    }
    func read(id: UUID) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw APIError(status: -1, message: "钥匙串中的 API Key 无法读取，请重新填写")
        }
        return secret
    }
    func write(_ secret: String, id: UUID) throws {
        let q = query(id)
        let values = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = q.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

enum ProfileStore {
    /// 测试可注入隔离的 defaults/secretStore；非 App 测试构建永不访问真实钥匙串。
    static var defaults = UserDefaults.standard { didSet { clearAuthorizedCredentialCache() } }
    #if NC_APP
    static var secretStore: any ProfileSecretStore = KeychainProfileSecretStore() { didSet { clearAuthorizedCredentialCache() } }
    #else
    static var secretStore: any ProfileSecretStore = MemoryProfileSecretStore() { didSet { clearAuthorizedCredentialCache() } }
    #endif
    static let key = "nc.profiles"
    static let activeKey = "nc.activeProfileID"
    static let changedNotification = Notification.Name("nc.profileChanged")
    static let errorNotification = Notification.Name("nc.profileStoreError")
    private(set) static var lastError: String?

    // 只缓存用户主动授权且已经完整提交的凭据，不持久化、不保留交互 LAContext。
    // 锁只保护内存映射；任何钥匙串访问、偏好设置写入和通知均在锁外执行。
    private static let credentialCacheLock = NSLock()
    private static var authorizedCredentials: [UUID: String] = [:]
    private static var credentialCacheGeneration = UUID()

    private static func clearAuthorizedCredentialCache() {
        credentialCacheLock.lock()
        authorizedCredentials.removeAll()
        credentialCacheGeneration = UUID()
        credentialCacheLock.unlock()
    }

    private static func credentialCacheScope() -> UUID {
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        return credentialCacheGeneration
    }

    private static func cachedCredential(for id: UUID) -> String? {
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        return authorizedCredentials[id]
    }

    private static func synchronizeCredentialCache(_ list: [ModelProfile], authorizing: Bool, scope: UUID) {
        let saved = Dictionary(uniqueKeysWithValues: list.filter { !$0.apiKey.isEmpty }.map { ($0.id, $0.apiKey) })
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        guard credentialCacheGeneration == scope else { return }
        if authorizing {
            authorizedCredentials = saved
        } else {
            // 常规保存只能更新已授权缓存项；不能把未授权的新 Key 顺带加入缓存。
            authorizedCredentials = authorizedCredentials.reduce(into: [:]) { result, entry in
                if let value = saved[entry.key] { result[entry.key] = value }
            }
        }
    }

    private static func invalidateCachedCredentials(_ ids: Set<UUID>, scope: UUID) {
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        guard credentialCacheGeneration == scope else { return }
        for id in ids { authorizedCredentials.removeValue(forKey: id) }
    }

    private static func report(_ error: Error) {
        let message = error.localizedDescription
        guard lastError != message else { return }
        lastError = message
        NotificationCenter.default.post(name: errorNotification, object: message)
    }

    static func load() -> [ModelProfile] {
        if let data = defaults.data(forKey: key) {
            guard var list = try? JSONDecoder().decode([ModelProfile].self, from: data) else {
                report(APIError(status: -1, message: "模型配置无法读取，请检查本机配置备份"))
                return []
            }
            // 命令行/测试的易失配置不落盘，也不访问钥匙串。
            if defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil { return list }
            // 空列表也是已保存状态，绝不重新导入旧配置。
            if list.isEmpty {
                for legacyKey in ["nc.baseURL", "nc.apiKey", "nc.model"] { defaults.removeObject(forKey: legacyKey) }
            }
            let hasPlaintext = list.contains { !$0.apiKey.isEmpty }
            for i in list.indices where list[i].apiKey.isEmpty && list[i].hasStoredAPIKey {
                if let cached = cachedCredential(for: list[i].id) {
                    list[i].apiKey = cached
                    continue
                }
                do {
                    guard let secret = try secretStore.read(id: list[i].id), !secret.isEmpty else {
                        throw APIError(status: -1, message: "配置「\(list[i].name)」的 API Key 未能从钥匙串读取，请重新填写")
                    }
                    list[i].apiKey = secret
                } catch {
                    list[i].credentialUnavailable = true
                    report(error)
                }
            }
            if hasPlaintext { _ = save(list) }
            return list
        }
        let legacy = ModelProfile(name: "默认配置",
                                  baseURL: defaults.string(forKey: "nc.baseURL") ?? "",
                                  apiKey: defaults.string(forKey: "nc.apiKey") ?? "",
                                  model: defaults.string(forKey: "nc.model") ?? "")
        guard !legacy.baseURL.isEmpty || !legacy.model.isEmpty || !legacy.apiKey.isEmpty else { return [] }
        if save([legacy]) { activeID = legacy.id }
        return [legacy]
    }

    /// 偏好设置与钥匙串不共享事务：先预检/备份，再写入；写入失败时尽力恢复并明确报告恢复失败。
    @discardableResult
    static func save(_ list: [ModelProfile]) -> Bool {
        save(list, using: secretStore, authorizing: false, cacheScope: credentialCacheScope())
    }

    private static func save(_ list: [ModelProfile], using backend: any ProfileSecretStore,
                             authorizing: Bool, cacheScope: UUID) -> Bool {
        struct SecretChange {
            let id: UUID
            let value: String
            let previous: String?
        }
        var written: [SecretChange] = []
        do {
            let old = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ModelProfile].self, from: $0) } ?? []
            // 所有配置先预检，避免前面的 Key 已改、后面才发现不可保存的配置。
            guard Set(list.map(\.id)).count == list.count else {
                throw APIError(status: -1, message: "模型配置存在重复标识，请重新建立重复的配置")
            }
            var metadata = list
            for i in list.indices {
                let p = list[i]
                if p.credentialUnavailable && p.apiKey.isEmpty {
                    throw APIError(status: -1, message: "API Key 暂时无法读取，配置尚未保存，请解锁钥匙串后重试")
                }
                metadata[i].apiKey = ""
                metadata[i].hasStoredAPIKey = !p.apiKey.isEmpty
            }
            let data = try JSONEncoder().encode(metadata)
            // 在任何覆写前读取所有旧值；无法备份时，任何 Key 都保持原样。
            var changes: [SecretChange] = []
            for p in list where !p.apiKey.isEmpty {
                let previous = try backend.read(id: p.id)
                if previous != p.apiKey { changes.append(SecretChange(id: p.id, value: p.apiKey, previous: previous)) }
            }
            for change in changes {
                try backend.write(change.value, id: change.id)
                written.append(change)
            }
            defaults.set(data, forKey: key)
            for legacyKey in ["nc.baseURL", "nc.apiKey", "nc.model"] { defaults.removeObject(forKey: legacyKey) }
            lastError = nil
            synchronizeCredentialCache(list, authorizing: authorizing, scope: cacheScope)
            let retained = Set(list.filter { !$0.apiKey.isEmpty }.map(\.id))
            var cleanupErrors: [String] = []
            for id in Set(old.map(\.id)).subtracting(retained) {
                do { try backend.remove(id: id) }
                catch { cleanupErrors.append(error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty {
                report(APIError(status: -1, message: "配置已保存，但旧 API Key 未能从钥匙串清除：" + cleanupErrors.joined(separator: "；")))
            }
            NotificationCenter.default.post(name: changedNotification, object: nil)
            return true
        } catch {
            var rollbackErrors: [String] = []
            var uncertainCredentialIDs: Set<UUID> = []
            for change in written.reversed() {
                do {
                    if let previous = change.previous { try backend.write(previous, id: change.id) }
                    else { try backend.remove(id: change.id) }
                } catch {
                    rollbackErrors.append(error.localizedDescription)
                    uncertainCredentialIDs.insert(change.id)
                }
            }
            invalidateCachedCredentials(uncertainCredentialIDs, scope: cacheScope)
            let message: String
            if !rollbackErrors.isEmpty {
                message = "配置未保存，部分 API Key 恢复失败，请重新检查相关配置。保存错误：" + error.localizedDescription
                    + "；恢复错误：" + rollbackErrors.joined(separator: "；")
            } else if wasCancelled(error) {
                message = "已取消钥匙串授权，配置尚未保存。" + (written.isEmpty ? "" : "本次已写入的 API Key 已恢复。")
            } else {
                message = "配置未保存" + (written.isEmpty ? "：" : "，已恢复本次修改的 API Key：") + error.localizedDescription
            }
            report(APIError(status: -1, message: message))
            return false
        }
    }

    /// 仅供用户主动授权：此 backend 只用于本次完整保存，不改变默认静默访问模式。
    /// 同步调用；调用方应在后台队列执行，并在完成前保留/锁定 UI 草稿。
    static func authorizeAndSave(_ drafts: [ModelProfile]) -> [ModelProfile]? {
        let scope = credentialCacheScope()
        let backend = secretStore.allowingUserInteraction()
        var resolved = drafts
        do {
            for i in resolved.indices where resolved[i].credentialUnavailable && resolved[i].apiKey.isEmpty {
                guard let secret = try backend.read(id: resolved[i].id), !secret.isEmpty else {
                    throw APIError(status: -1, message: "配置「\(resolved[i].name)」的 API Key 未在钥匙串中找到，请重新填写后保存")
                }
                resolved[i].apiKey = secret
            }
        } catch {
            let message = wasCancelled(error) ? "已取消钥匙串授权，配置尚未保存。" : "配置未保存：" + error.localizedDescription
            report(APIError(status: -1, message: message))
            return nil
        }
        guard save(resolved, using: backend, authorizing: true, cacheScope: scope) else { return nil }
        for i in resolved.indices {
            resolved[i].credentialUnavailable = false
            resolved[i].hasStoredAPIKey = !resolved[i].apiKey.isEmpty
        }
        return resolved
    }

    private static func wasCancelled(_ error: Error) -> Bool {
        (error as? APIError)?.status == Int(errSecUserCanceled) || error is CancellationError
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
    static var systemPrompt: String {
        let prompt = defaults.string(forKey: "nc.sys") ?? ""
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSystem : prompt
    }
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
    var errorDescription: String? { status < 0 ? message : "HTTP \(status)：\(message)" }
}

/// 一轮请求使用同一份值，避免调度、切换配置及重试时混用服务商凭据。
struct AIRequestConfiguration: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    let systemPrompt: String
    let temperature: Double
    let maxTokens: Int
    let profileIdentity: String

    static func current() throws -> AIRequestConfiguration {
        let profile = Config.activeProfile
        guard let base = Config.apiBase(profile?.baseURL ?? ""),
              let url = URL(string: base), let host = url.host, !host.isEmpty,
              url.scheme == "https" || url.scheme == "http" else {
            throw APIError(status: -1, message: "Base URL 为空或无效，请检查设置")
        }
        if profile?.credentialUnavailable == true {
            throw APIError(status: -1, message: ProfileStore.lastError ?? "API Key 暂时无法读取，请检查钥匙串")
        }
        guard let model = profile?.model.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw APIError(status: -1, message: "尚未配置模型名，请先打开设置")
        }
        return AIRequestConfiguration(baseURL: base, apiKey: profile?.apiKey ?? "", model: model,
                                      systemPrompt: Config.systemPrompt, temperature: Config.temperature,
                                      maxTokens: Config.maxTokens,
                                      profileIdentity: (profile?.id.uuidString ?? "") + "|" + base + "|" + model)
    }
}

// MARK: - 模型列表探测（GET /models，OpenAI 兼容）

enum AIService {
    static func fetchModels(base: String, key: String) async throws -> [String] {
        guard let url = URL(string: base + "/models"),
              let host = url.host, !host.isEmpty,
              url.scheme == "https" || url.scheme == "http" else {
            throw APIError(status: -1, message: "Base URL 无效，请填写完整的 HTTP/HTTPS 服务地址")
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
            throw APIError(status: -2, message: "模型列表响应格式无效，请检查服务地址与 API 兼容性")
        }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }

    /// 非流式单轮补全（模板 {{ai:指令}} 片段用）：走当前生效配置，
    /// 笔记上下文非空时自动拼入。与面板流式通道互不干扰。
    static func complete(instruction: String, context: String,
                         configuration: AIRequestConfiguration? = nil) async throws -> String {
        let configuration = try configuration ?? AIRequestConfiguration.current()
        try Task.checkCancellation()
        var user = instruction
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            user = "【笔记上下文】\n\(ctx)\n\n【任务】\n\(instruction)"
        }
        guard let url = URL(string: configuration.baseURL + "/chat/completions") else {
            throw APIError(status: -1, message: "Base URL 无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let key = configuration.apiKey
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": configuration.systemPrompt],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
        ])
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
            throw APIError(status: -2, message: "响应格式无法解析或内容为空")
        }
        if let reason = choices.first?["finish_reason"] as? String, reason != "stop" {
            let message = reason == "length" ? "已达到输出长度限制，回答尚未完成，请调高输出 tokens 后重试" : "回答未正常完成（\(reason)），请重试"
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

@MainActor
final class ChatEngine: ObservableObject {
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
            if !continuous { history = [] }
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

    @Published private(set) var responseStatus = ""
    @Published private(set) var sessionNotice: String?
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
            responseStatus = "已停止，结果尚未完成"
            canRetry = lastRequest != nil
            canContinue = lastRequest != nil && !output.isEmpty
        }
    }

    func dismissReview() {
        pendingReviewID = nil
        pendingResult = ""
        pendingTarget = nil
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
        responseStatus = ""
        sessionNotice = nil
        promptTokens = 0
        completionTokens = 0
        tokensEstimated = false
        totalPromptTokens = 0
        totalCompletionTokens = 0
    }

    func setContext(_ text: String, source: String, noteID: String? = nil) {
        let newID = noteID.flatMap { $0.isEmpty ? nil : $0 }
        let cleared = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !noteContext.isEmpty
        let changed = contextNoteID != newID || (newID == nil && text != noteContext) || cleared
        if changed {
            let hadConversation = !history.isEmpty || busy || !output.isEmpty
            beginSession(clearSubmittedPrompt: false)
            images = []
            if hadConversation { sessionNotice = "笔记来源已变化，已开始新会话" }
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
        sessionNotice = nil
        images = []
    }

    @discardableResult
    func addImage(_ image: NSImage) -> Bool {
        guard images.count < ImageAttachment.maximumCount else {
            lastError = "每次最多附带 \(ImageAttachment.maximumCount) 张图片"; return false
        }
        guard let attachment = ImageAttachment.make(image) else {
            lastError = "图片无法读取或压缩后仍超过 10 MB，请换用较小图片"; return false
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
                lastError = "模型配置已变化，请在当前配置下重新生成"; return
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
        catch { lastError = error.localizedDescription; responseStatus = "配置不可用"; return }
        guard images.count <= ImageAttachment.maximumCount else {
            lastError = "每次最多附带 \(ImageAttachment.maximumCount) 张图片"; return
        }
        if let previous = sessionProfileIdentity, previous != configuration.profileIdentity {
            history = []
            totalPromptTokens = 0
            totalCompletionTokens = 0
            sessionNotice = "模型配置已切换，已开始新会话"
        }
        sessionProfileIdentity = configuration.profileIdentity
        output = continuationPrefix
        lastError = nil
        busy = true
        responseStatus = continuationPrefix.isEmpty ? "生成中…" : "续写中…"
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
                try await self.stream(configuration: configuration, messages: messages, includeUsage: true, requestID: requestID, result: &result)
                completed = true
            } catch let e as APIError where e.status == 400 && e.message.contains("stream_options") {
                guard self.currentRequestID == requestID, !Task.isCancelled else { return }
                do {
                    result = StreamResult(output: continuationPrefix)
                    try await self.stream(configuration: configuration, messages: messages, includeUsage: false, requestID: requestID, result: &result)
                    completed = true
                } catch {
                    guard self.currentRequestID == requestID, !Task.isCancelled else { return }
                    self.lastError = "请求失败：" + error.localizedDescription
                }
            } catch {
                guard self.currentRequestID == requestID, !Task.isCancelled else { return }
                if !(error is CancellationError) { self.lastError = "请求失败：" + error.localizedDescription }
            }
            guard self.currentRequestID == requestID, !Task.isCancelled else { return }
            self.busy = false
            self.task = nil
            self.currentRequestID = nil
            self.output = result.output
            self.responseStatus = completed ? "已完成" : (result.output.isEmpty ? "生成失败，可重试" : "响应未完成，已保留部分结果")
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
        }
    }

    /// 发起 SSE 流式请求；includeUsage 时带 stream_options.include_usage
    private func stream(configuration: AIRequestConfiguration, messages: [[String: Any]], includeUsage: Bool, requestID: UUID,
                        result: inout StreamResult) async throws {
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": true,
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
        ]
        if includeUsage { body["stream_options"] = ["include_usage": true] }

        guard let url = URL(string: configuration.baseURL + "/chat/completions") else {
            throw APIError(status: -1, message: "Base URL 无效")
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
        guard result.sawContent else { throw APIError(status: -2, message: "服务未返回有效内容，请检查模型与端点后重试") }
        guard result.sawDone || result.finishReason == "stop" else {
            throw APIError(status: -3, message: "响应在完成标记前结束，已保留部分结果，可重试或续写")
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
            throw APIError(status: -2, message: "流式响应格式无法解析，已保留部分结果，请重试")
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
            case "length": throw APIError(status: -3, message: "已达到输出长度限制，回答尚未完成，可续写或调高输出 tokens 后重试")
            case "content_filter": throw APIError(status: -3, message: "服务商的内容过滤中止了回答，已保留返回内容")
            default: throw APIError(status: -3, message: "回答未正常完成（\(reason)），请调整模型或重试")
            }
        }
    }
}
