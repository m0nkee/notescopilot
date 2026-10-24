import AppKit
import Foundation

// MARK: - URL 自动转标题超链（输入 URL + 空格 → 取网页标题 → 蓝字超链）
//
// 交互对齐行首 Markdown 展开：在 Notes 里键入 URL 再敲空格即触发。
//   https://www.apple.com ␣
//     → 删除 URL token → 粘贴 <a href="URL">网页标题</a>
// 标题解析失败/SSO 登录页时回退为「URL 本身做链接文字」（仍是可点超链）。

enum UrlTitleLinker {

    // MARK: 纯逻辑（可单测）

    /// 从光标前文本提取「最后一个空格前的 URL token」；
    /// 要求尾字符为触发空格、token 无空白且形如 http(s)://…。
    /// 返回 (url, 应删除字符数 = token + 触发空格)
    nonisolated static func lastURLToken(in tail: String) -> (url: String, deleteCount: Int)? {
        guard let last = tail.last, last == " " || last == "\n" || last == "\t" else { return nil }
        let body = String(tail.dropLast())
        guard !body.isEmpty else { return nil }
        // 最后一个空白段
        let token = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).last.map(String.init) ?? ""
        guard token.count >= 11, looksLikeURL(token) else { return nil }   // 最短合法 http://a.bc
        return (token, token.count + 1)
    }

    nonisolated static func looksLikeURL(_ s: String) -> Bool {
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        let rest = s.dropFirst(s.hasPrefix("https://") ? 8 : 7)
        guard let hostEnd = rest.firstIndex(of: "/") else {
            return rest.contains(".")   // 无 path：http://example.com
        }
        let host = rest[..<hostEnd]
        return host.contains(".")
    }

    /// 从 HTML 提取标题：<title> 优先，og:title 兜底
    nonisolated static func parseTitle(from html: String) -> String? {
        if let m = firstGroup(#"<title[^>]*>(.*?)</title>"#, html, dotNewline: true) {
            let t = decodeEntities(m).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let m = firstGroup(
            #"<meta[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#, html)
            ?? firstGroup(
            #"<meta[^>]*content=["']([^"']+)["'][^>]*property=["']og:title["']"#, html) {
            let t = decodeEntities(m).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    nonisolated private static func firstGroup(_ pattern: String, _ s: String, dotNewline: Bool = false) -> String? {
        var opts: NSRegularExpression.Options = [.caseInsensitive]
        if dotNewline { opts.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 最小 HTML 实体解码（标题常见集 + 数字实体）
    nonisolated static func decodeEntities(_ s: String) -> String {
        var map: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
        ]
        // 数字实体 &#123; / &#x1F600;
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);|&#x([0-9a-fA-F]+);") {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let full = ns.substring(with: m.range)
                var scalar: Unicode.Scalar?
                if m.range(at: 1).location != NSNotFound,
                   let v = UInt32(ns.substring(with: m.range(at: 1))), let sc = Unicode.Scalar(v) {
                    scalar = sc
                } else if m.range(at: 2).location != NSNotFound,
                          let v = UInt32(ns.substring(with: m.range(at: 2)), radix: 16), let sc = Unicode.Scalar(v) {
                    scalar = sc
                }
                if let sc = scalar { map[full] = String(Character(sc)) }
            }
        }
        var out = s
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// 超链 HTML（Notes 粘贴 public.html 生成真超链）
    nonisolated static func makeLinkHTML(title: String, url: String) -> String {
        let esc = url
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "%22")
        let t = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<a href=\"\(esc)\">\(t)</a>"
    }

    /// 标题明显是登录页 → 不用（回退 URL 文字）
    nonisolated static func isLoginTitle(_ t: String) -> Bool {
        let lower = t.lowercased()
        return ["登录", "sign in", "sign-in", "login", "log in", "统一认证", "sso"]
            .contains { lower.contains($0) }
    }

    // MARK: 运行时编排（MainActor：驱动键入通道）

    /// 标题抓取器（测试可注入）
    nonisolated(unsafe) static var fetcher: (String) async -> String? = { url in
        await fetchTitle(url)
    }

    /// 最近已处理 URL：防止「回退 URL 文字 + 再敲空格」造成重抓循环
    private static var recentProcessed: [String: Date] = [:]
    private static let recentWindow: TimeInterval = 30

    @MainActor static var bridge = NotesBridge.shared
    @MainActor private static var pendingTarget: NotesBridge.SelectionSnapshot?
    @MainActor private static var pendingID: UUID?
    @MainActor private(set) static var pendingTask: Task<Void, Never>?

    /// 保留原 URL，抓取完成且目标未变时才原位替换。
    @MainActor
    static func hit(_ tail: String) -> Bool {
        guard enabled, let (url, _) = lastURLToken(in: tail),
              let target = bridge.readTextSnapshot(), target.range.length == 0 else { return false }
        let before = (target.documentText as NSString).substring(to: target.range.location)
        guard let token = lastURLToken(in: before), token.url == url,
              let last = before.last, last == " " || last == "\n" || last == "\t" else { return false }
        let whitespace = String(before.reversed().prefix(while: { $0 == " " || $0 == "\n" || $0 == "\t" }).reversed())
        let original = url + whitespace
        let length = original.utf16.count
        guard target.range.location >= length, before.hasSuffix(original) else { return false }
        let range = CFRange(location: target.range.location - length, length: length)
        let key = "\(target.noteID):\(range.location):\(url)"
        // 30 秒内处理过的 URL 不再触发（回退场景防循环）
        recentProcessed = recentProcessed.filter { Date().timeIntervalSince($0.value) < recentWindow }
        guard recentProcessed[key] == nil else { return false }
        recentProcessed[key] = Date()

        cancelPending()
        let id = UUID()
        pendingID = id
        pendingTarget = target
        pendingTask = Task { @MainActor in
            var title = await fetcher(url)
            guard !Task.isCancelled, pendingID == id else { return }
            defer {
                pendingID = nil
                pendingTarget = nil
                pendingTask = nil
            }
            guard enabled, bridge.isCurrent(target) else { return }
            if let value = title, isLoginTitle(value) { title = nil }
            let linkText = title ?? url
            let html = makeLinkHTML(title: linkText, url: url) + whitespace
            if let error = bridge.replaceText(in: target, range: range,
                                              with: linkText + whitespace, html: html) {
                NCLog.log("URL 超链已取消：\(error)")
            }
        }
        return true
    }

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "nc.urltitle.enabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.urltitle.enabled")
    }

    @MainActor
    static func cancelIfTargetChanged() {
        guard let target = pendingTarget else { return }
        if !enabled || !bridge.isCurrent(target) { cancelPending() }
    }

    @MainActor
    private static func cancelPending() {
        pendingID = nil
        pendingTarget = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    // MARK: 标题抓取

    /// 三级策略：① HTTP 直抓（公网站点）② 共享 Cookie 注入后重抓（内网 WebKit 应用登录过则可用）
    /// ③ 浏览器标签页标题（Safari/Chrome/Edge 正开着该页面——SSO 内网文档最可靠来源）
    nonisolated static func fetchTitle(_ url: String) async -> String? {
        await firstUsableTitle([
            { await fetchViaHTTP(url, cookies: nil) },
            {
                let cookieHeader = sharedCookieHeader(for: url)
                return cookieHeader.isEmpty ? nil : await fetchViaHTTP(url, cookies: cookieHeader)
            },
            { fetchViaBrowserTab(url) },
        ])
    }

    /// A login page is a failed strategy, so an authenticated source still gets a turn.
    nonisolated static func firstUsableTitle(_ sources: [() async -> String?]) async -> String? {
        for source in sources {
            guard !Task.isCancelled else { return nil }
            guard let title = await source()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, !isLoginTitle(title) else { continue }
            guard !Task.isCancelled else { return nil }
            return title
        }
        return nil
    }

    /// 从系统共享 HTTPCookieStorage 取该域可用 cookie（Cookie 头形式）
    nonisolated static func sharedCookieHeader(for url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        guard !cookies.isEmpty else { return "" }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    nonisolated static func fetchViaHTTP(_ url: String, cookies: String?) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 6
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if let c = cookies, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parseTitle(from: html)
    }

    /// 浏览器标签页兜底：只查「正在运行」的浏览器（避免 AppleScript 拉起浏览器），
    /// 遍历窗口标签找 URL 匹配的页签，返回其标题。SSO 内网页面（km/oa/ones）通常正开着。
    nonisolated static func fetchViaBrowserTab(_ url: String) -> String? {
        // 归一化匹配前缀：去 #fragment、尾 /
        var base = url.split(separator: "#").first.map(String.init) ?? url
        while base.hasSuffix("/") { base.removeLast() }
        let ws = NSWorkspace.shared
        let browsers: [(bundle: String, app: String, field: String)] = [
            ("com.apple.Safari", "Safari", "URL"),
            ("com.google.Chrome", "Google Chrome", "URL"),
            ("com.microsoft.edge", "Microsoft Edge", "URL"),
        ]
        for b in browsers where ws.runningApplications.contains(where: { $0.bundleIdentifier == b.bundle }) {
            let script = """
            tell application "\(b.app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if u is "\(NotesBridge.appleScriptEscaped(base))" or u is "\(NotesBridge.appleScriptEscaped(base))/" or u starts with "\(NotesBridge.appleScriptEscaped(base))#" then
                            return name of t
                        end if
                    end repeat
                end repeat
            end tell
            """
            if let title = runAppleScriptGetOutput(script),
               !title.isEmpty {
                return title
            }
        }
        return nil
    }

    /// 独立 AppleScript 执行（错误时返回 nil，不与正常输出混淆——NotesBridge.runScript 会把错误文案当返回值）
    nonisolated private static func runAppleScriptGetOutput(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return out.stringValue
    }
}
