import Foundation
import AppKit

// MARK: - 模板系统（对应 ProNotes TemplateNote / TemplateNoteManager：
// "Templates allow you to insert repetitive snippets using slash commands"）

struct TemplateNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    /// 内置模板（Optional 兼容旧数据：缺 key 反序列化为 nil）
    var builtin: Bool?

    init(id: UUID = UUID(), name: String, content: String, builtin: Bool? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.builtin = builtin
    }

    var isBuiltin: Bool { builtin ?? false }
}

enum TemplateStore {
    private static let key = "nc.templates"
    static var templates: [TemplateNote] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([TemplateNote].self, from: d) else { return [] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

// MARK: - 斜杠命令（对应 ProNotes 的 slash 命令面板 + Ask AI 指令）

enum SlashAction {
    case run(String)              // 填入提示词并立即执行
    case fill(String)             // 仅填入提示词
    case format(FormatStyle)      // 触发 Notes 原生格式化（菜单/快捷键）
    case clearContext             // 清空笔记上下文
    case newSession               // 新会话（清空 ChatStore）
    case insertOutput             // 结果插入 Notes 光标处
    case saveAsNote               // 结果存为新笔记
    case openSettings
    case stopGeneration
    case insertTemplate(TemplateNote) // 模板展开后插入 Notes（含变量引擎：ask/ai/日期等）
}

/// 斜杠命令分组（面板分类展示用）：由 action 类型推导，零调用方改动
enum SlashGroup: CaseIterable {
    case ai         // AI 优化（.run 提示词执行）
    case markdown   // Markdown/样式格式化（.format）
    case template   // 用户模板插入
    case tool       // 面板控制（自定义/停止/设置…）

    var title: String {
        switch self {
        case .ai: return "AI 优化"
        case .markdown: return "Markdown 格式"
        case .template: return "模板"
        case .tool: return "工具"
        }
    }

    var icon: String {
        switch self {
        case .ai: return "sparkles"
        case .markdown: return "text.format"
        case .template: return "doc.on.doc"
        case .tool: return "slider.horizontal.3"
        }
    }

    /// 面板分组展示顺序
    static let displayOrder: [SlashGroup] = [.ai, .markdown, .template, .tool]
}

struct SlashCommand: Identifiable {
    let id = UUID()
    let name: String      // 不带斜杠的命令名
    /// 英文命令别名；菜单筛选和 AX 正文执行也支持直接匹配中文 name。
    let alias: String
    let detail: String
    let action: SlashAction

    /// 所属分组：由 action 推导（.format→Markdown，模板→模板，.run→AI，其余→工具）
    var group: SlashGroup {
        switch action {
        case .format: return .markdown
        case .insertTemplate: return .template
        case .run: return .ai
        default: return .tool
        }
    }
}

func buildSlashCommands() -> [SlashCommand] {
    var cmds: [SlashCommand] = [
        SlashCommand(name: "续写", alias: "continue", detail: "基于笔记上下文自然续写", action: .run("请基于上文内容自然地续写下去，保持原文的风格与格式。")),
        SlashCommand(name: "总结", alias: "summarize", detail: "总结笔记上下文的要点", action: .run("请用简洁的要点总结以下内容的核心信息。")),
        SlashCommand(name: "翻译", alias: "translate", detail: "翻译成英文", action: .run("请将以下内容翻译成英文，保持原意与语气。")),
        SlashCommand(name: "润色", alias: "polish", detail: "让文字更通顺专业", action: .run("请润色以下文字，使其更通顺、专业，保持原意与格式。")),
        SlashCommand(name: "解释", alias: "explain", detail: "解释关键概念与逻辑", action: .run("请解释以下内容的关键概念与逻辑。")),
        SlashCommand(name: "扩写", alias: "expand", detail: "补充细节与论据", action: .run("请扩展以下内容，补充细节与论据，保持原有结构。")),
        SlashCommand(name: "要点", alias: "keypoints", detail: "改写为要点清单", action: .run("请把以下内容改写成结构清晰的要点清单（Markdown 列表）。")),
        SlashCommand(name: "标题", alias: "titles", detail: "为笔记拟 3 个候选标题", action: .run("请为以下笔记拟 3 个候选标题，每行一个。")),
        SlashCommand(name: "修拼写", alias: "fixgrammar", detail: "修复拼写与语法（Ask AI）", action: .run("请修复以下文字的拼写与语法错误，只输出修正后的文本，不要解释。")),
        SlashCommand(name: "格式检查", alias: "format", detail: "检查格式问题并列出修改建议（Ask AI）", action: .run("请检查以下内容的格式问题（标点符号、多余空格、标题层级、列表结构、错别字），逐条列出：问题位置、问题描述、修改建议。不要直接改写原文，只输出问题清单。")),
        SlashCommand(name: "变短", alias: "shorter", detail: "压缩得更精炼（Ask AI）", action: .run("请把以下内容压缩得更简洁，保留核心信息。")),
        SlashCommand(name: "变长", alias: "longer", detail: "扩写得更丰富（Ask AI）", action: .run("请把以下内容写得更丰富、有细节，保持原意。")),
        // ---- 格式化命令（官方清单：/title …/table）----
        SlashCommand(name: "标题样式", alias: "title", detail: "段落 → 标题（/h1 同）", action: .format(.title)),
        SlashCommand(name: "标题样式2", alias: "h1", detail: "同 /title", action: .format(.title)),
        SlashCommand(name: "小标题样式", alias: "heading", detail: "段落 → 小标题（/h2 同）", action: .format(.heading)),
        SlashCommand(name: "小标题样式2", alias: "h2", detail: "同 /heading", action: .format(.heading)),
        SlashCommand(name: "子标题样式", alias: "subheading", detail: "段落 → 子标题（/h3 同）", action: .format(.subheading)),
        SlashCommand(name: "子标题样式2", alias: "h3", detail: "同 /subheading", action: .format(.subheading)),
        SlashCommand(name: "正文样式", alias: "body", detail: "段落 → 正文", action: .format(.body)),
        SlashCommand(name: "等宽块", alias: "monostyled", detail: "段落 → 等宽（/code 同）", action: .format(.monostyled)),
        SlashCommand(name: "等宽块2", alias: "code", detail: "同 /monostyled", action: .format(.monostyled)),
        SlashCommand(name: "检查项", alias: "checklist", detail: "转为检查项列表", action: .format(.checklist)),
        SlashCommand(name: "项目符号列表", alias: "bulletedlist", detail: "转为项目符号列表", action: .format(.bulletedList)),
        SlashCommand(name: "虚线列表", alias: "dashedlist", detail: "转为虚线列表", action: .format(.dashedList)),
        SlashCommand(name: "编号列表", alias: "numberedlist", detail: "转为编号列表", action: .format(.numberedList)),
        SlashCommand(name: "引用块", alias: "quote", detail: "转为块引用（/blockquote 同）", action: .format(.blockQuote)),
        SlashCommand(name: "引用块2", alias: "blockquote", detail: "同 /quote", action: .format(.blockQuote)),
        SlashCommand(name: "表格", alias: "table", detail: "插入表格", action: .format(.table)),
// 字符样式（Inline Toolbar 证据：bold / italic / underline / strikethrough）
SlashCommand(name: "加粗", alias: "bold", detail: "加粗选中文本（⌘B）", action: .format(.bold)),
SlashCommand(name: "斜体", alias: "italic", detail: "选中文本变斜体（⌘I）", action: .format(.italic)),
SlashCommand(name: "下划线", alias: "underline", detail: "给选中文本加下划线（⌘U）", action: .format(.underline)),
SlashCommand(name: "删除线", alias: "strikethrough", detail: "给选中文本加删除线", action: .format(.strikethrough)),
        SlashCommand(name: "自定义", alias: "custom", detail: "填入提示词再编辑", action: .fill("")),
        SlashCommand(name: "清空上下文", alias: "clear", detail: "清除抓取的笔记选中内容", action: .clearContext),
        SlashCommand(name: "新会话", alias: "new", detail: "清空对话历史与结果", action: .newSession),
        SlashCommand(name: "插入笔记", alias: "insert", detail: "把当前结果插入 Notes 光标处", action: .insertOutput),
        SlashCommand(name: "存为新笔记", alias: "savenote", detail: "把当前结果保存为新笔记", action: .saveAsNote),
        SlashCommand(name: "停止", alias: "stop", detail: "停止当前生成", action: .stopGeneration),
        SlashCommand(name: "设置", alias: "set", detail: "打开设置", action: .openSettings),
    ]
    // 用户模板（ProNotes：模板经斜杠命令插入；NotesCopilot：变量引擎展开后插入）
    for t in TemplateStore.templates {
        let safe = t.name.replacingOccurrences(of: " ", with: "-")
        guard !safe.isEmpty else { continue }
        let vars = TemplateEngine.specs(in: t.content)
        let varSummary = vars.isEmpty ? "" : " · " + vars.map { "\($0.kind.badge)" }.joined(separator: "/")
        cmds.append(SlashCommand(name: safe,
                                  alias: safe.lowercased().alnum(),
                                  detail: "\(t.isBuiltin ? "内置模板" : "插入模板")\(varSummary)\(t.isBuiltin ? "" : "：\(t.content.replacingOccurrences(of: "\n", with: " ").prefix(24))" )",
                                  action: .insertTemplate(t)))
    }
    return cmds
}

extension String {
    /// 全局键入匹配用：仅保留字母数字（模板名可能含中文——在 IME 下无法逐键匹配，
    /// 英文名模板可正常工作）
    func alnum() -> String {
        String(self.map { c in
            (c.isLetter && c.isASCII) || c.isNumber ? Character(c.lowercased()) : "-"
        }.filter { $0 != "-" })
    }
}

// MARK: - 调试日志（诊断斜杠命令/权限问题用，写到 ~/Library/Logs/NotesCopilot-debug.log）

enum NCLog {
    static let path = NSHomeDirectory() + "/Library/Logs/NotesCopilot-debug.log"
    static func log(_ msg: String) {
        let line = "\(Date()) | \(msg)\n"
        let data = line.data(using: .utf8) ?? Data()
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

// MARK: - 文本扩展 KeywordListener（对应 ProNotes KeywordListener：
// 全局键盘监听 keywords / onMatch / maxSequenceLength，命中后展开片段）

struct KeywordRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

enum KeywordStore {
    private static let key = "nc.keywords"
    static var rules: [KeywordRule] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([KeywordRule].self, from: d) else { return [] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

final class KeywordListener {
    static let shared = KeywordListener()
    private let accessibilityTrusted: () -> Bool
    private let tapFactory: (CGEventTapOptions) -> CFMachPort?

    init(accessibilityTrusted: @escaping () -> Bool = { NotesBridge.shared.isTrusted },
         tapFactory: ((CGEventTapOptions) -> CFMachPort?)? = nil) {
        self.accessibilityTrusted = accessibilityTrusted
        self.tapFactory = tapFactory ?? Self.createTap
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = ""
    /// 对应 ProNotes 的 maxSequenceLength：缓冲区上限
    private let maxSequenceLength = 64
    /// 斜杠命令缓冲（如英文别名 "/polish"）：
    /// 只在监听启动后重新开始记录，避免旧缓冲误触发
    private var slashBuf = ""
    /// 授权重试定时器：用户在系统设置里授完权后自动拉起监听，无需重启应用
    private var retryTimer: Timer?
    /// 上次记录的辅助功能授权结果（日志去重）
    private var lastTrustLog: Bool?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "nc.kw.enabled") }

    /// 监听是否真正在跑（菜单栏状态展示用）
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// 键盘斜杠缓冲是否为空（AX 通道与 tap 通道互斥用）
    var slashBufIsEmpty: Bool { slashBuf.isEmpty }

    /// 全局斜杠命令开关（在 Notes 里直接键入 /命令 用 AI）——默认开启
    var slashGlobal: Bool {
        UserDefaults.standard.object(forKey: "nc.slash.global") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "nc.slash.global")
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    func startIfNeeded() {
        guard tap == nil else { return }
        guard enabled || slashGlobal else {
            cancelPermissionRetry()
            NCLog.log("startIfNeeded 跳过：关键词与全局斜杠均关闭")
            NotificationCenter.default.post(
                name: .init("nc.kwStatus"),
                object: "菜单键盘导航与关键词扩展已关闭。")
            return
        }
        // defaultTap 会拦截/修改事件，需要辅助功能；输入监控预检不能阻止此主动 tap。
        let trusted = accessibilityTrusted()
        if lastTrustLog != trusted {
            NCLog.log("菜单键盘导航与关键词监听：辅助功能授权 = \(trusted)，二进制 = \(Bundle.main.bundleURL.path)")
            lastTrustLog = trusted
        }
        guard trusted else {
            waitForAccessibility()
            return
        }
        guard let t = tapFactory(.defaultTap) else {
            NCLog.log("主动键盘监听未创建：tapCreate 返回空值")
            reportTapUnavailable()
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        guard isRunning else {
            NCLog.log("主动键盘监听已创建但未启用：tapIsEnabled 返回 false")
            stop()
            reportTapUnavailable()
            return
        }
        cancelPermissionRetry()
        NCLog.log("菜单键盘导航与关键词监听已启动（主动 tap 已启用）")
        NotificationCenter.default.post(
            name: .init("nc.kwStatus"),
            object: "菜单键盘导航与关键词监听已启动。")
    }

    private static func createTap(options: CGEventTapOptions) -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    KeywordListener.shared.handleTapDisabled()
                    return Unmanaged.passUnretained(event)
                }
                return KeywordListener.shared.handle(event)
            },
            userInfo: nil
        )
    }

    /// 撤销辅助功能后不能反复启用旧 tap；保留重试等待用户重新授权。
    func handleTapDisabled() {
        guard accessibilityTrusted() else {
            stop()
            waitForAccessibility()
            return
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if !isRunning {
            stop()
            reportTapUnavailable()
        }
    }

    private func waitForAccessibility() {
        NotificationCenter.default.post(
            name: .init("nc.kwStatus"),
            object: "菜单键盘导航与关键词扩展等待「辅助功能」授权：请在「系统设置 › 隐私与安全性 › 辅助功能」中允许 NotesCopilot，授权后自动重试。")
        schedulePermissionRetry()
    }

    private func reportTapUnavailable() {
        NCLog.log("菜单键盘导航与关键词监听创建或启用失败（当前会话 tap 不可用）")
        NotificationCenter.default.post(
            name: .init("nc.kwStatus"),
            object: "菜单键盘导航与关键词扩展暂不可用：当前会话无法创建键盘监听，已安排自动重试。")
        schedulePermissionRetry()
    }

    /// 每 3 秒重试一次：授权完成后自动启动监听（无须重启应用）
    private func schedulePermissionRetry() {
        if Thread.isMainThread {
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.startIfNeeded()
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.schedulePermissionRetry() }
        }
    }

    private func cancelPermissionRetry() {
        if Thread.isMainThread {
            retryTimer?.invalidate()
            retryTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in self?.cancelPermissionRetry() }
        }
    }

    func stop() {
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            source = nil
        }
        if let t = tap {
            CFMachPortInvalidate(t)
            tap = nil
        }
        buffer = ""
        slashBuf = ""
        cancelPermissionRetry()
    }

    /// keyDown 仅路由菜单导航与显式启用的关键词；正文命令统一交给 AX。
    fileprivate func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty {
            buffer = ""
            slashBuf = ""
            return Unmanaged.passUnretained(event)
        }
        // ---- 下拉面板键盘导航（面板可见时接管 ↑↓/⏎/esc，IME 激活时面板自行放行）----
        // tap 挂在主 runloop = 主线程，可安全进入 MainActor；测试构建（无 NC_APP）跳过
        #if NC_APP
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if kc == 125 || kc == 126 || kc == 36 || kc == 53,
           MainActor.assumeIsolated({
               SlashSuggestPanel.shared.routeKeyIfVisible(kc)
           }) {
            buffer = ""
            slashBuf = ""
            return nil
        }
        #endif
        var chars = [UniChar](repeating: 0, count: 4)
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actual, unicodeString: &chars)
        guard actual > 0 else {
            buffer = ""
            slashBuf = ""
            return Unmanaged.passUnretained(event)
        }
        let s = String(utf16CodeUnits: chars, count: Int(actual))
        guard let c = s.first, s.count == 1 else {
            buffer = ""
            slashBuf = ""
            return Unmanaged.passUnretained(event)
        }

        // 正文斜杠与 Markdown 统一由 AX 通道识别。tap 仅负责菜单导航和关键词，
        // 避免终止符落地前后两条通道同时删除同一段文字。
        slashBuf = ""

        // ---- 关键词文本扩展通道 ----
        guard enabled, c.isLetter || c.isNumber || ";._-".contains(c) else {
            buffer = ""
            return Unmanaged.passUnretained(event)
        }
        buffer.append(c)
        if buffer.count > maxSequenceLength {
            buffer.removeFirst(buffer.count - maxSequenceLength)
        }
        for rule in KeywordStore.rules where !rule.trigger.isEmpty && buffer.hasSuffix(rule.trigger) {
            buffer = ""
            let n = rule.trigger.count
            let text = rule.expansion
            let trigger = rule.trigger
            let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard self.enabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
                NotesBridge.shared.typeExpansion(deleteCount: n, insert: text, expectedTrigger: trigger)
            }
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// 斜杠命令匹配："/alias" 精确或前缀唯一匹配
    private func matchSlash(_ trigger: String) -> SlashCommand? {
        guard trigger.hasPrefix("/"), trigger.count > 1 else { return nil }
        let token = String(trigger.dropFirst()).lowercased()
        let cmds = buildSlashCommands().filter { !$0.alias.isEmpty }
        if let exact = cmds.first(where: { $0.alias.lowercased() == token }) { return exact }
        let prefix = cmds.filter { $0.alias.lowercased().hasPrefix(token) }
        return prefix.count == 1 ? prefix[0] : nil  // 前缀歧义则不触发
    }

    /// 在捕获的 Notes 目标执行斜杠；验证删除完成后再读取上下文和运行命令。
@MainActor
static func performGlobalSlash(_ cmd: SlashCommand, deleteCount: Int,
                               target: NotesBridge.SelectionSnapshot? = nil, expectedToken: String? = nil) {
    guard let target = target ?? NotesBridge.shared.readTextSnapshot(),
          NotesBridge.shared.isCurrent(target),
          let range = NotesBridge.suffixRange(in: target, characterCount: deleteCount) else { return }
    let token = (target.documentText as NSString).substring(with: NSRange(location: range.location, length: range.length))
    let normalized = token.replacingOccurrences(of: "／", with: "/")
    guard normalized.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
          expectedToken.map({ $0.replacingOccurrences(of: "／", with: "/") == normalized }) ?? true,
          NotesCommandExecution.shared.claim(target) else { return }
    SlashSuggestPanel.shared.hide()
    NotesBridge.shared.removeSuffix(in: target, characterCount: deleteCount) { current, error in
        MainActor.assumeIsolated {
            defer { NotesCommandExecution.shared.release() }
            guard let current, error == nil, NotesBridge.shared.isCurrent(current) else {
                NCLog.log("斜杠执行取消：\(error ?? "原目标已变化")")
                return
            }
            executeGlobalSlash(cmd, target: current)
        }
    }
}

@MainActor
private static func executeGlobalSlash(_ cmd: SlashCommand, target: NotesBridge.SelectionSnapshot) {
    switch cmd.action {
    case .run(let prompt):
        #if NC_APP
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let engine = delegate.engine
        let context = NotesBridge.shared.readContextAroundCursor()
        engine.setContext(context?.text ?? "", source: context?.source ?? "", noteID: target.noteID)
        engine.autoInsertNext = true
        delegate.revealPanel(captureContext: false)
        engine.run(prompt: prompt, writebackTarget: target)
        #endif
    case .insertTemplate(let template):
        #if NC_APP
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine else { return }
        engine.stop()
        let generation = engine.operationGeneration
        let context = NotesBridge.shared.readContextAroundCursor()?.text ?? ""
        TemplateRunner.runInNotes(template, selection: context,
                                  isOperationValid: { engine.operationGeneration == generation })
        #endif
    case .format(let style):
        _ = FormatBridge.trigger(style)
    case .openSettings:
        NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
    case .stopGeneration:
        #if NC_APP
        (NSApp.delegate as? AppDelegate)?.engine.stop()
        #endif
    case .newSession:
        #if NC_APP
        (NSApp.delegate as? AppDelegate)?.engine.beginSession()
        #endif
    case .clearContext:
        #if NC_APP
        (NSApp.delegate as? AppDelegate)?.engine.setContext("", source: "", noteID: target.noteID)
        #endif
    case .insertOutput:
        #if NC_APP
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine else { return }
        guard !engine.output.isEmpty else { return }
        engine.lastError = NotesBridge.shared.replaceSelection(in: target, with: engine.output,
                                                               html: MarkdownDocument.html(engine.output))
        #endif
    case .saveAsNote:
        #if NC_APP
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine, !engine.output.isEmpty else { return }
        engine.lastError = NotesBridge.shared.createNewNote(engine.output, html: MarkdownDocument.html(engine.output))
        #endif
    case .fill:
        #if NC_APP
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let context = NotesBridge.shared.readContextAroundCursor()
        delegate.engine.setContext(context?.text ?? "", source: context?.source ?? "", noteID: target.noteID)
        delegate.revealPanel(captureContext: false)
        #endif
    }
}

}

/// 所有 Notes 正文变更共用仲裁；键盘 tap 不再独立执行正文命令。
@MainActor
final class NotesCommandExecution {
    static let shared = NotesCommandExecution()
    private(set) var isBusy = false
    private var previous: NotesBridge.SelectionSnapshot?
    private var suppressedUntil = Date.distantPast

    func claim(_ target: NotesBridge.SelectionSnapshot) -> Bool {
        guard !isBusy, !(previous?.matches(target) == true && Date() < suppressedUntil) else { return false }
        isBusy = true
        previous = target
        suppressedUntil = Date().addingTimeInterval(1)
        return true
    }

    func release() { isBusy = false }
}

// MARK: - AX 通道斜杠命令（不依赖「输入监控」权限）
// 复刻 ProNotes 的证据链：cancelPollTextArea + KeywordListener latency ——
// ProNotes 本身就是轮询 AX 文本区实现的。本通道每 120ms 读一次 Notes 焦点元素
// 光标前的文本，看到 "/命令 "（或全角 ／）即触发，删除与执行走 AX（仅需辅助功能权限）。

@MainActor
final class AXSlashWatcher {
    static let shared = AXSlashWatcher()
    private var timer: Timer?
    /// 触发后冷却，防止轮询重复命中同一缓冲
    private var cooldown = false

    private var slashGlobal: Bool {
        UserDefaults.standard.object(forKey: "nc.slash.global") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.slash.global")
    }

    var isRunning: Bool { timer != nil }

    func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let trusted = NotesBridge.shared.isTrusted
        NCLog.log("AX 斜杠通道已启动：辅助功能权限 = \(trusted)，无需输入监控，仅需辅助功能")
        // 预热格式菜单缓存：后台把 15 个常用菜单项一次性找齐，
        // 之后 Markdown/斜杠格式化直接 AXPress，零遍历零延迟
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            FormatBridge.warmMenuCache(titles: ["标题", "小标题", "副标题", "正文", "等宽样式",
                                                "核对清单", "项目符号列表", "短划线列表", "编号列表",
                                                "块引用", "表格", "粗体", "斜体", "下划线", "删除线",
                                                "Title", "Heading", "Subheading", "Body", "Checklist"])
        }
        if !trusted {
            // 主动弹系统授权引导窗（带「打开系统设置」按钮），而不是静默等用户自己发现
            NotesBridge.shared.requestTrust()
            // 授权后自动激活：2 秒轮询检测，成功即打日志（poll 会自动开始工作）
            startTrustWatch()
        }
    }

    /// 辅助功能授权检测轮询：授权成功即写日志并通知用户可以开始用了
    private var trustTimer: Timer?
    private func startTrustWatch() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NotesBridge.shared.isTrusted {
                    NCLog.log("✅ 辅助功能授权成功！AX 斜杠通道已激活，可到 Notes 输入 /polish 测试")
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.lastAXOK = Date()
                }
            }
        }
    }

    private var lastAXOK: Date?

    private var pollDiagAt: Date?
    private func poll() {
        UrlTitleLinker.cancelIfTargetChanged()
        // AX 始终独立工作；斜杠、Markdown、URL 各自读取实时开关。
        guard NotesBridge.isFrontmostNotes() else {
            SlashSuggestPanel.shared.hide()
            return
        }
        guard !cooldown, !NotesCommandExecution.shared.isBusy else { return }
        guard !SlashSuggestPanel.isIMEComposing else { return }
        guard let tail = NotesBridge.shared.textBeforeCursor(maxLength: 8192) else {
            SlashSuggestPanel.shared.hide()
            return
        }

        // 通道 0：/ 建议下拉（ProNotes 同款：输入 / 即弹命令菜单，持续输入过滤、点选执行）
        if slashGlobal, let q = Self.activeSlashQuery(tail) {
            let items = Self.suggestCandidates(for: q)
            SlashSuggestPanel.shared.update(items: items, query: q,
                                            cursorRect: NotesBridge.shared.cursorScreenRect())
            pollDiagAt = nil
        } else if SlashSuggestPanel.shared.isVisible {
            SlashSuggestPanel.shared.hide()
        }

        // 低频诊断（≤1次/5s）：前台且 tail 尾是空格但三个通道均未命中——记录尾部码点，定位静默失败
        if let last = tail.last, last == " ",
           pollDiagAt.map({ Date().timeIntervalSince($0) > 5 }) ?? true {
            pollDiagAt = Date()
            let codes = tail.suffix(8).unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            NCLog.log("poll 诊断：tail 尾 8 码点 [\(codes)]")
        }

        // 通道 1：斜杠命令（含用户模板命令）
        // 唯一识别通道；与菜单点击通过 NotesCommandExecution 仲裁写入。
        if slashGlobal, let hit = Self.matchAXSlashTail(tail),
           let target = NotesBridge.shared.readTextSnapshot() {
            cooldown = true
            SlashSuggestPanel.shared.hide()
            pollDiagAt = nil
            NCLog.log("AX 通道命中斜杠：\(String(tail.suffix(24))) → \(hit.cmd.name)")
            KeywordListener.performGlobalSlash(hit.cmd, deleteCount: hit.deleteCount, target: target,
                                               expectedToken: String(tail.suffix(hit.deleteCount)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.cooldown = false
            }
            return
        }

        // 通道 2：行首 Markdown 扩展（# / ## / [] / > / ``` / - / * / 1. + 空格）
        if let hit = Self.matchAXMarkdownTail(tail) {
            cooldown = true
            SlashSuggestPanel.shared.hide()
            pollDiagAt = nil
            NCLog.log("AX 通道命中 Markdown：\(hit.style.rawValue)，删 \(hit.delete) 字符")
            if let target = NotesBridge.shared.readTextSnapshot(), target.range.length == 0,
               let before = Self.textBeforeCursor(in: target),
               let verified = Self.matchAXMarkdownTail(before), verified.style == hit.style,
               verified.delete == hit.delete, NotesCommandExecution.shared.claim(target) {
                NotesBridge.shared.removeSuffix(in: target, characterCount: hit.delete) { current, error in
                    MainActor.assumeIsolated {
                        defer { NotesCommandExecution.shared.release() }
                        guard let current, error == nil, NotesBridge.shared.isCurrent(current),
                              Self.markdownEnabled else { return }
                        _ = FormatBridge.trigger(hit.style)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.cooldown = false
            }
            return
        }

        // 通道 3：URL + 空格 → 自动取标题转超链（SSO 页/失败回退 URL 文字）
        if UrlTitleLinker.hit(tail) {
            cooldown = true
            pollDiagAt = nil
            NCLog.log("AX 通道命中 URL：原文保留，待标题返回后校验目标并替换")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.cooldown = false   // 标题抓取可能耗时数秒，冷却放宽
            }
            return
        }
    }

    nonisolated static var markdownEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "nc.md.enabled") == nil || defaults.bool(forKey: "nc.md.enabled")
    }

    nonisolated static func textBeforeCursor(in target: NotesBridge.SelectionSnapshot) -> String? {
        guard target.range.location >= 0, target.range.location <= target.documentText.utf16.count else { return nil }
        return (target.documentText as NSString).substring(to: target.range.location)
    }

    /// 检测光标前是否有一个「正在输入、尚未终止」的 / 命令段（用于建议下拉）。
    /// 返回形如 "/polish" 的查询串；与触发通道（matchAXSlashTail）语义一致：允许行中 /，
    /// 仅排除 URL 型斜杠（"https:" 后、连续 "//" 中）。
    nonisolated static func activeSlashQuery(_ tail: String) -> String? {
        let norm = tail.replacingOccurrences(of: "／", with: "/")
        guard let slashIdx = norm.lastIndex(of: "/") else { return nil }
        let before = norm[..<slashIdx]
        // URL 中的斜杠不弹："https:" 后的第一个 /、"//" 的第二个 /
        if before.hasSuffix(":") || before.hasSuffix("/") { return nil }
        if slashBelongsToURL(before: String(before)) { return nil }
        let after = String(norm[norm.index(after: slashIdx)...])
        // 段内出现空白/换行 = 已输入终止符，交给触发逻辑而非建议
        guard !after.contains(" "), !after.contains("\n"), !after.contains("\t") else { return nil }
        // 查询段过长大概率不是命令输入
        guard after.count <= 24 else { return nil }
        return "/" + after
    }

    /// URL 的路径名可能恰好是 /title、/body 等合法命令，必须留给 URL 通道。
    nonisolated private static func slashBelongsToURL(before: String) -> Bool {
        let token = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)?.lowercased() ?? ""
        return token.contains("://") || token.hasPrefix("www.")
    }

    /// 建议列表：前缀命中优先，其次包含命中；
    /// 空查询（刚键入 /）时按分组各取前 5 项，分组导航体验一致
    nonisolated static func suggestCandidates(for query: String, limit: Int = 8) -> [SlashCommand] {
        let token = String(query.dropFirst()).lowercased()
        let cmds = buildSlashCommands()
        guard !token.isEmpty else {
            var out: [SlashCommand] = []
            for g in SlashGroup.displayOrder {
                out += cmds.filter { $0.group == g }.prefix(5)
            }
            return out
        }
        // 英文别名与中文命令名/模板名均可匹配——中文 IME 直接打命令名可命中
        let pref = cmds.filter { cmd in
            (!cmd.alias.isEmpty && cmd.alias.lowercased().hasPrefix(token))
                || cmd.name.lowercased().hasPrefix(token)
        }
        let rest = cmds.filter { cmd in
            !pref.contains(where: { $0.id == cmd.id }) && (
                (!cmd.alias.isEmpty && cmd.alias.lowercased().contains(token))
                    || cmd.name.lowercased().contains(token)
            )
        }
        return Array((pref + rest).prefix(limit))
    }

    /// 从光标前文本尾部匹配 “/命令 + 终止符”（全角 ／ 归一为半角）
    nonisolated static func matchAXSlashTail(_ tail: String) -> (cmd: SlashCommand, deleteCount: Int)? {
        guard let last = tail.last, last == " " || last == "\n" || last == "\t" else { return nil }
        let body = String(tail.dropLast()).replacingOccurrences(of: "／", with: "/")
        guard let slashIdx = body.lastIndex(of: "/") else { return nil }
        let before = String(body[..<slashIdx])
        guard !before.hasSuffix(":"), !before.hasSuffix("/"), !slashBelongsToURL(before: before) else { return nil }
        let trigger = String(body[slashIdx...])
        guard trigger.count > 1, let cmd = matchSlashToken(trigger) else { return nil }
        return (cmd, trigger.count + 1)   // +1 = 终止符
    }

    /// 行首 Markdown 匹配：光标前文本 = [<行首>]# + 空格，且行内只有 token 本身
    /// 返回删除字符数（token+空格）与目标样式；开关关闭时返回 nil
    /// 全角标点/数字 → 半角（中文 IME 全角标点家族远比想象宽：真机取证
    /// shift+[ 输出〖(U+3015 家族)、shift+. 输出》(U+300B)，而非教科书全角 U+FF0B 段）
    /// 策略：先 NFKC（覆盖 ＃＊１２３０ 等兼容字符），再显式等价类覆盖 NFKC 不折叠的标点。
    nonisolated static func normalizeMdToken(_ s: String) -> String {
        let explicit: [Character: Character] = [
            "【": "[", "】": "]", "〖": "[", "〗": "]",
            "＞": ">", "》": ">", "·": "*",
            "－": "-", "—": "-", "–": "-",
        ]
        let nfkc = s.precomposedStringWithCompatibilityMapping  // 不改变字符数（一对一组合映射）
        return String(nfkc.map { explicit[$0] ?? $0 })
    }

    nonisolated static func matchAXMarkdownTail(_ tail: String) -> (style: FormatStyle, delete: Int)? {
        guard markdownEnabled, let last = tail.last, last == " " else { return nil }
        let body = String(tail.dropLast())
        // 取最后一行（光标所在行）
        let lineStart = body.lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let lineRaw = String(body[lineStart...])
        // 归一化全角 token（一对一映射，字符数不变，delete 仍按原始长度计）
        let line = normalizeMdToken(lineRaw)
        // 行内必须是纯 token（如 "##"），不能是 "##abc"
        guard !line.isEmpty, line.allSatisfy({ "#[]>*-`123456789.".contains($0) }) else { return nil }
        guard let style = FormatBridge.markdownToken(line) else { return nil }
        // 对应 ProNotes 的 expandMarkdown* 开关检查
        guard FormatBridge.expansionEnabled(style) else { return nil }
        return (style, lineRaw.count + 1)   // +1 = 空格
    }

    /// 与 KeywordListener.matchSlash 同逻辑（私有不可访问，此处静态化便于测试）
    nonisolated static func matchSlashToken(_ trigger: String) -> SlashCommand? {
        guard trigger.hasPrefix("/"), trigger.count > 1 else { return nil }
        let token = String(trigger.dropFirst()).lowercased()
        let cmds = buildSlashCommands()
        if let exact = cmds.first(where: { !$0.alias.isEmpty && $0.alias.lowercased() == token }) { return exact }
        // AX 正文支持直接键入中文命令名/模板名，例如 "/润色"。
        // 命令名匹配让 IME 用户无需切英文输入法；中文名模板（alias 为空）也在此命中。
        if let byName = cmds.first(where: { $0.name == token }) { return byName }
        let prefix = cmds.filter { !$0.alias.isEmpty && $0.alias.lowercased().hasPrefix(token) }
        return prefix.count == 1 ? prefix[0] : nil
    }
}
