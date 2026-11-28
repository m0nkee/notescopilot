import Foundation
import AppKit
import Carbon
import Carbon.HIToolbox

// MARK: - 模板系统（对应 ProNotes TemplateNote / TemplateNoteManager：
// "Templates allow you to insert repetitive snippets using slash commands"）

struct TemplateNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    /// 内置模板（Optional 兼容旧数据：缺 key 反序列化为 nil）
    var builtin: Bool?
    /// Notes 中的源笔记；这类模板只在内存中读取，不写入本地模板列表。
    var sourceNotesID: String?
    /// Notes 去掉首行模板名后的正文与样式，供展开后按富文本插入。
    var sourceDocument: TopotextDoc?

    init(id: UUID = UUID(), name: String, content: String, builtin: Bool? = nil, sourceNotesID: String? = nil,
         sourceDocument: TopotextDoc? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.builtin = builtin
        self.sourceNotesID = sourceNotesID
        self.sourceDocument = sourceDocument
    }

    var isBuiltin: Bool { builtin ?? false }
    var isFromNotes: Bool { sourceNotesID != nil }
    var commandName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
    }
}

enum TemplateStore {
    private static let key = "nc.templates"
    static let notesChangedNotification = Notification.Name("nc.notesTemplatesChanged")
    private static let notesLock = NSLock()
    private static var notesSnapshot: [TemplateNote] = []

    /// 本地模板独立保存；Notes 模板随源文件夹刷新，不持久化副本。
    static var templates: [TemplateNote] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([TemplateNote].self, from: d) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            SlashCommandCache.invalidate()
        }
    }

    static var notesTemplates: [TemplateNote] {
        notesLock.lock(); defer { notesLock.unlock() }
        return notesSnapshot
    }

    static func updateNotesTemplates(_ templates: [TemplateNote]) {
        notesLock.lock()
        notesSnapshot = templates
        notesLock.unlock()
        SlashCommandCache.invalidate()
        NotificationCenter.default.post(name: notesChangedNotification, object: nil)
    }

    static func commandKey(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-").lowercased()
    }

    /// Notes 中的同名命令优先，本地版本仍保留，源笔记移除后自动恢复。
    static var availableTemplates: [TemplateNote] {
        var names = Set<String>()
        return (notesTemplates + templates).filter {
            let key = commandKey(for: $0.name)
            return !key.isEmpty && names.insert(key).inserted
        }
    }
}

// MARK: - 斜杠命令（对应 ProNotes 的 slash 命令面板 + Ask AI 指令）

enum SlashAction {
    case run(WritingInstruction)  // 填入提示词并立即执行
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
        case .ai: return L10n.text("AI Writing")
        case .markdown: return L10n.text("Markdown Formatting")
        case .template: return L10n.text("Templates")
        case .tool: return L10n.text("Tools")
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

    var commandAlias: String {
        switch self {
        case .ai: return "ai"
        case .markdown: return "markdown"
        case .template: return "templates"
        case .tool: return "tools"
        }
    }

    /// 面板分组展示顺序
    static let displayOrder: [SlashGroup] = [.ai, .markdown, .template, .tool]
}

struct CustomAICommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var prompt = ""
    var enabled = true

    /// Command names are typed after `/`; reject whitespace, separators and
    /// duplicates so the suggestion menu remains deterministic.
    static func hasValidName(_ rawName: String, existing: [CustomAICommand] = [],
                             excludingID: UUID? = nil) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32,
              !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else { return false }
        return !existing.contains {
            $0.id != excludingID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

enum CustomAICommandStore {
    private static let key = "nc.customAICommands"

    static var commands: [CustomAICommand] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([CustomAICommand].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            SlashCommandCache.invalidate()
        }
    }
}

/// AX 轮询每 120ms 会查询命令；缓存避免重复反序列化模板和重建全量清单。
enum SlashCommandCache {
    private static let lock = NSLock()
    private static var cached: [SlashCommand]?

    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func commands() -> [SlashCommand] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let commands = buildUncachedSlashCommands()
        lock.lock()
        if cached == nil { cached = commands }
        lock.unlock()
        return commands
    }
}

struct SlashCommand: Identifiable {
    let id = UUID()
    let name: String      // 不带斜杠的命令名
    /// 英文命令别名；菜单筛选和 AX 正文执行也支持直接匹配中文 name。
    let alias: String
    let action: SlashAction
    private let titleKey: String?
    private let localizedDetail: () -> String

    init(name: String, titleKey: String? = nil, alias: String,
         detail: @autoclosure @escaping () -> String, action: SlashAction) {
        self.name = name
        self.titleKey = titleKey
        self.alias = alias
        self.localizedDetail = detail
        self.action = action
    }

    var displayName: String {
        guard let titleKey else { return name }
        return L10n.text(titleKey)
    }

    var detail: String { localizedDetail() }

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

/// 面板与 Notes 正文共用的分组查询和筛选；分组查询始终展示完整结果。
enum SlashQuery {
    private static func parse(_ query: String) -> (group: SlashGroup?, token: String) {
        let normalized = query.replacingOccurrences(of: "／", with: "/")
        let body = normalized.hasPrefix("/") ? String(normalized.dropFirst()) : normalized
        let head = body.prefix { $0 != " " }.lowercased()
        let group: SlashGroup?
        switch head {
        case "templates", "template", "模板", "模版": group = .template
        case "ai", "智能": group = .ai
        case "markdown", "格式": group = .markdown
        case "tools", "tool", "工具": group = .tool
        default: group = nil
        }
        let token = group == nil ? body : String(body.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        return (group, token.lowercased())
    }

    static func isCategory(_ query: String) -> Bool { parse(query).group != nil }

    static func candidates(for query: String, commands: [SlashCommand], limit: Int? = nil) -> [SlashCommand] {
        let parsed = parse(query)
        let commands = parsed.group.map { group in commands.filter { $0.group == group } } ?? commands
        guard !parsed.token.isEmpty else {
            if parsed.group != nil || limit == nil { return commands }
            return SlashGroup.displayOrder.flatMap { group in commands.filter { $0.group == group }.prefix(5) }
        }
        let tokens = parsed.group == nil ? [parsed.token]
            : parsed.token.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let firstToken = tokens.first else { return [] }
        let matching = commands.filter { command in
            tokens.allSatisfy { token in
                command.name.lowercased().contains(token) || command.alias.lowercased().contains(token)
            }
        }
        let prefix = matching.filter {
            (!$0.alias.isEmpty && $0.alias.lowercased().hasPrefix(firstToken)) || $0.name.lowercased().hasPrefix(firstToken)
        }
        let rest = matching.filter { command in
            !prefix.contains(where: { $0.id == command.id })
        }
        let matches = prefix + rest
        guard parsed.group == nil, let limit else { return matches }
        return Array(matches.prefix(max(0, limit)))
    }
}

func buildUncachedSlashCommands() -> [SlashCommand] {
    var cmds: [SlashCommand] = [
        SlashCommand(name: "续写", titleKey: "Continue Writing", alias: "continue",
                     detail: L10n.text("Continue from the note context"),
                     action: .run("请基于上文内容自然地续写下去，保持原文的风格与格式。")),
        SlashCommand(name: "总结", titleKey: "Summarize", alias: "summarize",
                     detail: L10n.text("Summarize the note’s key points"),
                     action: .run("请用简洁的要点总结以下内容的核心信息。")),
        SlashCommand(name: "翻译", titleKey: "Translate", alias: "translate",
                     detail: WritingInstruction.translationHint, action: .run(.translate)),
        SlashCommand(name: "润色", titleKey: "Polish", alias: "polish",
                     detail: L10n.text("Make the text clearer and more professional"),
                     action: .run("请润色以下文字，使其更通顺、专业，保持原意与格式。")),
        SlashCommand(name: "解释", titleKey: "Explain", alias: "explain",
                     detail: L10n.text("Explain key concepts and reasoning"),
                     action: .run("请解释以下内容的关键概念与逻辑。")),
        SlashCommand(name: "扩写", titleKey: "Expand", alias: "expand",
                     detail: L10n.text("Add detail and supporting arguments"),
                     action: .run("请扩展以下内容，补充细节与论据，保持原有结构。")),
        SlashCommand(name: "要点", titleKey: "Key Points", alias: "keypoints",
                     detail: L10n.text("Rewrite as a list of key points"),
                     action: .run("请把以下内容改写成结构清晰的要点清单（Markdown 列表）。")),
        SlashCommand(name: "标题", titleKey: "Suggest Titles", alias: "titles",
                     detail: L10n.text("Suggest three titles for the note"),
                     action: .run("请为以下笔记拟 3 个候选标题，每行一个。")),
        SlashCommand(name: "修拼写", titleKey: "Fix Spelling and Grammar", alias: "fixgrammar",
                     detail: L10n.text("Correct spelling and grammar with AI"),
                     action: .run("请修复以下文字的拼写与语法错误，只输出修正后的文本，不要解释。")),
        SlashCommand(name: "格式检查", titleKey: "Check Formatting", alias: "format",
                     detail: L10n.text("Find formatting issues and suggest fixes"),
                     action: .run("请检查以下内容的格式问题（标点符号、多余空格、标题层级、列表结构、错别字），逐条列出：问题位置、问题描述、修改建议。不要直接改写原文，只输出问题清单。")),
        SlashCommand(name: "变短", titleKey: "Make Shorter", alias: "shorter",
                     detail: L10n.text("Make the text more concise"),
                     action: .run("请把以下内容压缩得更简洁，保留核心信息。")),
        SlashCommand(name: "变长", titleKey: "Make Longer", alias: "longer",
                     detail: L10n.text("Add more detail to the text"),
                     action: .run("请把以下内容写得更丰富、有细节，保持原意。")),
        // ---- 格式化命令（官方清单：/title …/table）----
        SlashCommand(name: "标题样式", titleKey: "Title Style", alias: "title",
                     detail: L10n.text("Format the paragraph as a title (/h1)"), action: .format(.title)),
        SlashCommand(name: "标题样式2", titleKey: "Title Style", alias: "h1",
                     detail: L10n.text("Same as /title"), action: .format(.title)),
        SlashCommand(name: "小标题样式", titleKey: "Heading Style", alias: "heading",
                     detail: L10n.text("Format the paragraph as a heading (/h2)"), action: .format(.heading)),
        SlashCommand(name: "小标题样式2", titleKey: "Heading Style", alias: "h2",
                     detail: L10n.text("Same as /heading"), action: .format(.heading)),
        SlashCommand(name: "子标题样式", titleKey: "Subheading Style", alias: "subheading",
                     detail: L10n.text("Format the paragraph as a subheading (/h3)"), action: .format(.subheading)),
        SlashCommand(name: "子标题样式2", titleKey: "Subheading Style", alias: "h3",
                     detail: L10n.text("Same as /subheading"), action: .format(.subheading)),
        SlashCommand(name: "正文样式", titleKey: "Body Style", alias: "body",
                     detail: L10n.text("Format the paragraph as body text"), action: .format(.body)),
        SlashCommand(name: "等宽块", titleKey: "Monospaced Block", alias: "monostyled",
                     detail: L10n.text("Format the paragraph as monospaced text (/code)"), action: .format(.monostyled)),
        SlashCommand(name: "等宽块2", titleKey: "Monospaced Block", alias: "code",
                     detail: L10n.text("Same as /monostyled"), action: .format(.monostyled)),
        SlashCommand(name: "检查项", titleKey: "Checklist", alias: "checklist",
                     detail: L10n.text("Convert to a checklist"), action: .format(.checklist)),
        SlashCommand(name: "项目符号列表", titleKey: "Bulleted List", alias: "bulletedlist",
                     detail: L10n.text("Convert to a bulleted list"), action: .format(.bulletedList)),
        SlashCommand(name: "虚线列表", titleKey: "Dashed List", alias: "dashedlist",
                     detail: L10n.text("Convert to a dashed list"), action: .format(.dashedList)),
        SlashCommand(name: "编号列表", titleKey: "Numbered List", alias: "numberedlist",
                     detail: L10n.text("Convert to a numbered list"), action: .format(.numberedList)),
        SlashCommand(name: "引用块", titleKey: "Block Quote", alias: "quote",
                     detail: L10n.text("Convert to a block quote (/blockquote)"), action: .format(.blockQuote)),
        SlashCommand(name: "引用块2", titleKey: "Block Quote", alias: "blockquote",
                     detail: L10n.text("Same as /quote"), action: .format(.blockQuote)),
        SlashCommand(name: "表格", titleKey: "Table", alias: "table",
                     detail: L10n.text("Insert a table"), action: .format(.table)),
        SlashCommand(name: "加粗", titleKey: "Bold", alias: "bold",
                     detail: L10n.text("Bold the selected text (⌘B)"), action: .format(.bold)),
        SlashCommand(name: "斜体", titleKey: "Italic", alias: "italic",
                     detail: L10n.text("Italicize the selected text (⌘I)"), action: .format(.italic)),
        SlashCommand(name: "下划线", titleKey: "Underline", alias: "underline",
                     detail: L10n.text("Underline the selected text (⌘U)"), action: .format(.underline)),
        SlashCommand(name: "删除线", titleKey: "Strikethrough", alias: "strikethrough",
                     detail: L10n.text("Strike through the selected text"), action: .format(.strikethrough)),
        SlashCommand(name: "自定义", titleKey: "Custom Prompt", alias: "custom",
                     detail: L10n.text("Enter a prompt to edit"), action: .fill("")),
        SlashCommand(name: "清空上下文", titleKey: "Clear Context", alias: "clear",
                     detail: L10n.text("Clear the captured note selection"), action: .clearContext),
        SlashCommand(name: "新会话", titleKey: "New Chat", alias: "new",
                     detail: L10n.text("Clear the chat history and result"), action: .newSession),
        SlashCommand(name: "插入笔记", titleKey: "Insert into Note", alias: "insert",
                     detail: L10n.text("Insert the current result at the Notes cursor"), action: .insertOutput),
        SlashCommand(name: "存为新笔记", titleKey: "Save as New Note", alias: "savenote",
                     detail: L10n.text("Save the current result as a new note"), action: .saveAsNote),
        SlashCommand(name: "停止", titleKey: "Stop", alias: "stop",
                     detail: L10n.text("Stop generating the current result"), action: .stopGeneration),
        SlashCommand(name: "设置", titleKey: "Settings", alias: "set",
                     detail: L10n.text("Open Settings"), action: .openSettings),
    ]
    // 用户自定义 AI 命令：与内置 /polish 等同级，可直接输入中文名或英文别名。
    let allCustomCommands = CustomAICommandStore.commands
    for custom in allCustomCommands where custom.enabled {
        let name = custom.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = custom.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CustomAICommand.hasValidName(custom.name, existing: allCustomCommands, excludingID: custom.id),
              !prompt.isEmpty,
              !cmds.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame
                                      || $0.alias.caseInsensitiveCompare(name.lowercased().alnum()) == .orderedSame })
        else { continue }
        let preview = String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(48))
        cmds.append(SlashCommand(name: name, alias: name.lowercased().alnum(),
                                 detail: L10n.format("Custom AI · %@", preview),
                                 action: .run(.text(prompt))))
    }
    // 用户模板（ProNotes：模板经斜杠命令插入；NotesCopilot：变量引擎展开后插入）
    for t in TemplateStore.availableTemplates {
        let safe = t.commandName
        guard !safe.isEmpty else { continue }
        let variables = TemplateEngine.specs(in: t.content)
        let preview = String(t.content.replacingOccurrences(of: "\n", with: " ").prefix(24))
        cmds.append(SlashCommand(name: safe, alias: safe.lowercased().alnum(),
                                 detail: slashTemplateDetail(t, variables: variables, preview: preview),
                                 action: .insertTemplate(t)))
    }
    return cmds
}

private func slashTemplateDetail(_ template: TemplateNote, variables: [TemplateVarSpec], preview: String) -> String {
    let title = template.isFromNotes ? L10n.text("Notes Template")
        : template.isBuiltin ? L10n.text("Built-in Template")
        : L10n.text("Insert Template")
    let summary = variables.isEmpty ? "" : " · " + variables.map(\.kind.badge).joined(separator: "/")
    return title + summary + (template.isBuiltin ? "" : L10n.format(": %@", preview))
}

func buildSlashCommands() -> [SlashCommand] { SlashCommandCache.commands() }

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

struct DoubleMShortcut {
    static let interval: TimeInterval = 0.35

    enum Key { case down, up, other }
    enum Decision { case pass, hold, replayThenPass, match }

    private enum Stage { case firstDown, firstUp, secondDown }

    private struct Pending {
        let pid: pid_t
        let started: TimeInterval
        var stage: Stage
    }

    private var pending: Pending?
    var pendingPID: pid_t? { pending?.pid }

    mutating func reset() { pending = nil }

    mutating func handle(_ key: Key, at time: TimeInterval, eligiblePID: pid_t?) -> Decision {
        guard var current = pending else {
            guard key == .down, let eligiblePID else { return .pass }
            pending = Pending(pid: eligiblePID, started: time, stage: .firstDown)
            return .hold
        }

        guard eligiblePID == current.pid, time >= current.started, time - current.started <= Self.interval else {
            reset()
            return .replayThenPass
        }
        switch (current.stage, key) {
        case (.firstDown, .up):
            current.stage = .firstUp
        case (.firstUp, .down):
            current.stage = .secondDown
        case (.secondDown, .up):
            reset()
            return .match
        default:
            reset()
            return .replayThenPass
        }

        pending = current
        return .hold
    }

    static func key(for event: CGEvent, isUntranslatedM: (CGKeyCode) -> Bool = { _ in false }) -> Key {
        guard event.type == .keyDown || event.type == .keyUp,
              event.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate,
                                        .maskSecondaryFn, .maskAlphaShift, .maskHelp]).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .other }
        let isM = withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 2) { chars in
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count,
                                           unicodeString: chars.baseAddress)
            return count == 1 && chars[0] == 109
                || count == 0 && isUntranslatedM(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
        }
        return isM ? (event.type == .keyDown ? .down : .up) : .other
    }
}

#if NC_APP
private enum HostShortcutInputSource {
    case layout, chineseIME, unsupported

    static var current: Self {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = property(kTISPropertyInputSourceType, of: input) else { return .unsupported }
        if type == kTISTypeKeyboardLayout as String { return .layout }
        guard type == kTISTypeKeyboardInputMode as String,
              let bundle = property(kTISPropertyBundleID, of: input) else { return .unsupported }
        return ["com.apple.inputmethod.SCIM", "com.apple.inputmethod.TCIM"].contains(bundle) ? .chineseIME : .unsupported
    }

    static var currentID: String? {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(kTISPropertyInputSourceID, of: input)
    }

    private static func property(_ key: CFString, of input: TISInputSource) -> String? {
        TISGetInputSourceProperty(input, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    static func isMInCurrentLayout(_ keyCode: CGKeyCode, keyboardType: UInt32) -> Bool {
        guard let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { return false }
        let data = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return false }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var state: UInt32 = 0
        var count = 0
        var char: UniChar = 0
        let type = keyboardType == 0 ? UInt32(LMGetKbdType()) : keyboardType
        let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, type,
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &state, 1, &count, &char)
        return result == noErr && count == 1 && char == 109
    }
}
#endif

final class KeywordListener {
    static let shared = KeywordListener()
    enum Status {
        case disabled, running, waitingForAccessibility, unavailable

        var message: String {
            switch self {
            case .disabled:
                return L10n.text("Keyboard navigation and keyword expansion are off.")
            case .running:
                return L10n.text("Keyboard navigation and keyword expansion are active.")
            case .waitingForAccessibility:
                return L10n.text(
                    "Allow NotesCopilot in System Settings › Privacy & Security › Accessibility to enable keyboard navigation and keyword expansion. The app will retry automatically.")
            case .unavailable:
                return L10n.text(
                    "Keyboard navigation and keyword expansion are temporarily unavailable. The app will retry automatically.")
            }
        }
    }

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
    #if NC_APP
    private static let replayTag: Int64 = 0x4E_43_4D_52
    private var hostShortcut = DoubleMShortcut()
    private var hostShortcutApp: NSRunningApplication?
    private var hostShortcutInputSource: HostShortcutInputSource?
    private var hostShortcutInputID: String?
    private var heldKeys: [CGEvent] = []
    private var hostShortcutTimeout: Timer?
    private var applicationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?

    #if NC_APP_TEST
    var hostShortcutTestPanel: SelectionAIPanel?
    #endif

    @MainActor
    private var hostShortcutPanel: SelectionAIPanel {
        #if NC_APP_TEST
        if let hostShortcutTestPanel { return hostShortcutTestPanel }
        #endif
        return .shared
    }
    #endif
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
        guard enabled || slashGlobal || SelectionScope.isEnabled() else {
            cancelPermissionRetry()
            NCLog.log("startIfNeeded 跳过：选区快捷键、关键词与斜杠均关闭")
            NotificationCenter.default.post(
                name: .init("nc.kwStatus"),
                object: Status.disabled)
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
        #if NC_APP
        observeHostShortcutChanges()
        #endif
        cancelPermissionRetry()
        NCLog.log("菜单键盘导航与关键词监听已启动（主动 tap 已启用）")
        NotificationCenter.default.post(
            name: .init("nc.kwStatus"),
            object: Status.running)
    }

    private static func createTap(options: CGEventTapOptions) -> CFMachPort? {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    KeywordListener.shared.handleTapDisabled()
                    return Unmanaged.passUnretained(event)
                }
                return KeywordListener.shared.handle(event, proxy: proxy)
            },
            userInfo: nil
        )
    }

    /// 撤销辅助功能后不能反复启用旧 tap；保留重试等待用户重新授权。
    func handleTapDisabled() {
        #if NC_APP
        replayHostShortcut()
        #endif
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
            object: Status.waitingForAccessibility)
        schedulePermissionRetry()
    }

    private func reportTapUnavailable() {
        NCLog.log("菜单键盘导航与关键词监听创建或启用失败（当前会话 tap 不可用）")
        NotificationCenter.default.post(
            name: .init("nc.kwStatus"),
            object: Status.unavailable)
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
        #if NC_APP
        replayHostShortcut()
        if let applicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver)
            self.applicationObserver = nil
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        #endif
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

    #if NC_APP
    private func observeHostShortcutChanges() {
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let pending = self.hostShortcutApp,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != pending.processIdentifier {
                self.replayHostShortcut()
            }
            self.buffer = ""
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            // macOS can announce the same input source again when a field gains focus.
            guard let self, self.hostShortcutApp != nil,
                  self.hostShortcutInputID != HostShortcutInputSource.currentID else { return }
            self.replayHostShortcut()
        }
    }

    private func clearHostShortcut() {
        hostShortcut.reset()
        hostShortcutApp = nil
        hostShortcutInputSource = nil
        hostShortcutInputID = nil
        heldKeys.removeAll(keepingCapacity: true)
        hostShortcutTimeout?.invalidate()
        hostShortcutTimeout = nil
    }

    private func replayHostShortcut(before proxy: CGEventTapProxy? = nil, targetPID: Int64? = nil) {
        let app = hostShortcutApp
        let events = heldKeys
        clearHostShortcut()
        guard let app, !app.isTerminated, !events.isEmpty else { return }
        let isFrontmost = NSWorkspace.shared.frontmostApplication == app
        // Never inject a key buffered in ordinary input into a newly secured field.
        guard !isFrontmost || !IsSecureEventInputEnabled() else { return }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
            if let proxy, isFrontmost, targetPID == 0 || targetPID == Int64(app.processIdentifier) {
                // Quartz queues this before the currently intercepted key or click.
                event.tapPostEvent(proxy)
            } else {
                // A timeout or app change cannot send the pending M to a different app.
                event.postToPid(app.processIdentifier)
            }
            if isFrontmost, event.type == .keyDown { appendKeywordInput(from: event) }
        }
    }

    private func routeHostShortcut(_ event: CGEvent, proxy: CGEventTapProxy?) -> Bool {
        var source: HostShortcutInputSource?
        let key = DoubleMShortcut.key(for: event) { keyCode in
            source = .current
            guard source == .chineseIME else { return false }
            return HostShortcutInputSource.isMInCurrentLayout(
                keyCode, keyboardType: UInt32(clamping: event.getIntegerValueField(.keyboardEventKeyboardType)))
        }
        guard key == .down || hostShortcut.pendingPID != nil else { return false }
        let time = ProcessInfo.processInfo.systemUptime
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        let app = key == .other ? nil : NSWorkspace.shared.frontmostApplication
        let inputSource: HostShortcutInputSource = app == nil ? .unsupported : source ?? .current
        let requiresCompositionCheck = inputSource == .chineseIME
        var eligiblePID: pid_t?
        if let app, target == 0 || target == Int64(app.processIdentifier),
           !IsSecureEventInputEnabled(), inputSource != .unsupported,
           hostShortcutInputSource == nil || hostShortcutInputSource == inputSource,
           hostShortcut.pendingPID != nil || MainActor.assumeIsolated({
               hostShortcutPanel.canReceiveHostShortcut(in: app, requiresCompositionCheck: requiresCompositionCheck)
           }) {
            eligiblePID = app.processIdentifier
        }

        switch hostShortcut.handle(key, at: time, eligiblePID: eligiblePID) {
        case .pass:
            return false
        case .hold:
            guard let saved = event.copy() else { replayHostShortcut(before: proxy, targetPID: target); return false }
            heldKeys.append(saved)
            if hostShortcutApp == nil {
                hostShortcutApp = app
                hostShortcutInputSource = inputSource
                hostShortcutInputID = HostShortcutInputSource.currentID
                let timer = Timer(timeInterval: DoubleMShortcut.interval, repeats: false) { [weak self] _ in
                    self?.replayHostShortcut()
                }
                hostShortcutTimeout = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return true
        case .replayThenPass:
            replayHostShortcut(before: proxy, targetPID: target)
            return false
        case .match:
            if let app, MainActor.assumeIsolated({
                hostShortcutPanel.openFromHostShortcut(in: app, requiresCompositionCheck: requiresCompositionCheck)
            }) {
                clearHostShortcut()
                buffer = ""
                slashBuf = ""
                return true
            }
            replayHostShortcut(before: proxy, targetPID: target)
            return false
        }
    }
    #endif

    /// 正文命令统一交给 AX，键盘 tap 处理显式快捷键、菜单和关键词。
    fileprivate func handle(_ event: CGEvent, proxy: CGEventTapProxy? = nil) -> Unmanaged<CGEvent>? {
        #if NC_APP
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag {
            return Unmanaged.passUnretained(event)
        }
        if routeHostShortcut(event, proxy: proxy) { return nil }
        #endif
        guard event.type == .keyDown else { return Unmanaged.passUnretained(event) }
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
        if MainActor.assumeIsolated({ hostShortcutPanel.panelIsKey }) {
            // The nonactivating tools panel can own the keyboard while the
            // source app remains frontmost. Let its window and its IME route input.
            buffer = ""
            slashBuf = ""
            return Unmanaged.passUnretained(event)
        }
        if kc == 125 || kc == 126 || kc == 36 || kc == 53,
           MainActor.assumeIsolated({
               SlashSuggestPanel.shared.routeKeyIfVisible(kc)
                   || (kc == 53 && hostShortcutPanel.dismissFromHost())
           }) {
            buffer = ""
            slashBuf = ""
            return nil
        }
        #endif
        appendKeywordInput(from: event)
        return Unmanaged.passUnretained(event)
    }

    private func appendKeywordInput(from event: CGEvent) {
        var chars = [UniChar](repeating: 0, count: 4)
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actual, unicodeString: &chars)
        guard actual > 0, actual <= chars.count else {
            buffer = ""
            slashBuf = ""
            return
        }
        let s = String(utf16CodeUnits: chars, count: Int(actual))
        guard let c = s.first, s.count == 1 else {
            buffer = ""
            slashBuf = ""
            return
        }

        // 正文斜杠与 Markdown 统一由 AX 通道识别。tap 仅负责菜单导航和关键词，
        // 避免终止符落地前后两条通道同时删除同一段文字。
        slashBuf = ""

        // ---- 关键词文本扩展通道 ----
        guard enabled, c.isLetter || c.isNumber || ";._-".contains(c) else {
            buffer = ""
            return
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
                               target: NotesBridge.SelectionSnapshot? = nil, expectedToken: String? = nil,
                               isExplicitSelection: Bool = false) {
    guard let target = target ?? NotesBridge.shared.readTextSnapshot(),
          NotesBridge.shared.isCurrent(target),
          let range = NotesBridge.suffixRange(in: target, characterCount: deleteCount) else { return }
    let token = (target.documentText as NSString).substring(with: NSRange(location: range.location, length: range.length))
    let normalized = token.replacingOccurrences(of: "／", with: "/")
    guard normalized.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
          expectedToken.map({ $0.replacingOccurrences(of: "／", with: "/") == normalized }) ?? true,
          NotesCommandExecution.shared.claim(target, allowRepeat: isExplicitSelection) else { return }
    SlashSuggestPanel.shared.hide()
    if case .insertTemplate(let template) = cmd.action {
        // 一次替换命令与内容，避免清空新笔记标题时 Notes 暂时撤掉空草稿的身份。
        defer { NotesCommandExecution.shared.release(suppressUnchangedTarget: true, commandRange: range) }
        #if NC_APP
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine else { return }
        engine.stop()
        let generation = engine.operationGeneration
        let contextDocument = (target.documentText as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: "")
        let contextTarget = NotesBridge.SelectionSnapshot(element: target.element,
            range: CFRange(location: range.location, length: 0), text: "", bounds: target.bounds,
            noteID: target.noteID, documentText: contextDocument)
        let context = NotesBridge.context(in: contextTarget)?.text ?? ""
        TemplateRunner.runInNotes(template, selection: context, target: target, replacementRange: range,
                                 isOperationValid: { engine.operationGeneration == generation }) { error in
            guard engine.operationGeneration == generation else { return }
            engine.lastError = error
        }
        #endif
        return
    }
    if case .stopGeneration = cmd.action {
        #if NC_APP
        // 即使删除唯一标题后 Notes 暂时不可读，停止操作也必须立即生效。
        (NSApp.delegate as? AppDelegate)?.engine.stop()
        #endif
    }
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
    case .run(let instruction):
        #if NC_APP
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let engine = delegate.engine
        let context = NotesBridge.shared.readContextAroundCursor()
        engine.setContext(context?.text ?? "", source: context?.source ?? "", noteID: target.noteID)
        engine.autoInsertNext = true
        delegate.revealPanel(captureContext: false)
        engine.run(prompt: instruction.prompt(for: engine.noteContext), writebackTarget: target)
        #endif
    case .insertTemplate:
        break // 模板已在删除命令之前绑定原始目标并执行。
    case .format(let style):
        _ = FormatBridge.trigger(style)
    case .openSettings:
        NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
    case .stopGeneration:
        break // 已在删除命令之前停止任务。
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
    private struct TemplateSuppression {
        let target: NotesBridge.SelectionSnapshot
        let range: CFRange
        let token: String
    }
    private var templateSuppressions: [TemplateSuppression] = []
    var hasSuppressedTemplates: Bool { !templateSuppressions.isEmpty }

    func claim(_ target: NotesBridge.SelectionSnapshot, allowRepeat: Bool = false) -> Bool {
        guard !isBusy else { return false }
        observe(target)
        guard allowRepeat || (!templateSuppressions.contains { $0.target.matches(target) }
            && !(previous?.matches(target) == true && Date() < suppressedUntil)) else { return false }
        if allowRepeat { templateSuppressions.removeAll { $0.target.matches(target) } }
        isBusy = true
        previous = target
        suppressedUntil = Date().addingTimeInterval(1)
        return true
    }

    func observe(_ target: NotesBridge.SelectionSnapshot) {
        let document = target.documentText as NSString
        templateSuppressions.removeAll { entry in
            guard entry.target.noteID == target.noteID, CFEqual(entry.target.element, target.element) else { return false }
            guard entry.range.location >= 0, entry.range.length > 0,
                  entry.range.location <= document.length,
                  entry.range.length <= document.length - entry.range.location else { return true }
            return document.substring(with: NSRange(location: entry.range.location, length: entry.range.length)) != entry.token
        }
    }

    func release(suppressUnchangedTarget: Bool = false, commandRange: CFRange? = nil) {
        isBusy = false
        guard suppressUnchangedTarget, let previous else { return }
        let range = commandRange ?? CFRange(location: 0, length: previous.range.location)
        let document = previous.documentText as NSString
        guard range.location >= 0, range.length > 0, range.location <= document.length,
              range.length <= document.length - range.location else { return }
        suppressedUntil = .distantPast // 模板由独立记录抑制，编辑命令后可立即重新输入。
        templateSuppressions.removeAll { $0.target.matches(previous) }
        templateSuppressions.append(TemplateSuppression(target: previous, range: range,
            token: document.substring(with: NSRange(location: range.location, length: range.length))))
        if templateSuppressions.count > 32 { templateSuppressions.removeFirst(templateSuppressions.count - 32) }
    }
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
        if NotesCommandExecution.shared.hasSuppressedTemplates, let target = NotesBridge.shared.readTextSnapshot() {
            NotesCommandExecution.shared.observe(target)
        }
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
        let query = "/" + after
        if SlashQuery.isCategory(query) {
            guard !after.contains("\n"), !after.contains("\t"), after.count <= 256 else { return nil }
            return query
        }
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
        SlashQuery.candidates(for: query, commands: buildSlashCommands(), limit: limit)
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
        guard !SlashQuery.isCategory(trigger) else { return nil }
        let token = String(trigger.dropFirst()).lowercased()
        let cmds = buildSlashCommands()
        if let exact = cmds.first(where: { !$0.alias.isEmpty && $0.alias.lowercased() == token }) { return exact }
        // AX 正文支持直接键入中文命令名/模板名，例如 "/润色"。
        // 命令名匹配让 IME 用户无需切英文输入法；中文名模板（alias 为空）也在此命中。
        if let byName = cmds.first(where: { $0.name.lowercased() == token }) { return byName }
        let prefix = cmds.filter { !$0.alias.isEmpty && $0.alias.lowercased().hasPrefix(token) }
        return prefix.count == 1 ? prefix[0] : nil
    }
}
