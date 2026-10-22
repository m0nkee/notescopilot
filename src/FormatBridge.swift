import AppKit
import Accessibility

// MARK: - 格式化桥（复刻 ProNotes 的 AX 菜单触发通道）
// 证据：AXMenuItemCmdChar / "%ld matching menu items found for %s in %s. Picked the first one."
// / cannotFindMenuItem —— 按标题在整个菜单树中递归搜索并 AXPress 第一个命中项

enum FormatStyle: String, CaseIterable {
    case title, heading, subheading, body, monostyled
    case checklist, bulletedList, dashedList, numberedList
    case blockQuote, table
    case bold, italic, underline, strikethrough

    /// Notes 菜单项标题（英文/简体中文双语候选，ProNotes 有 languageCode 设置同理）
    var menuTitles: [String] {
        switch self {
        case .title:        return ["Title", "标题"]
        case .heading:      return ["Heading", "小标题"]
        case .subheading:   return ["Subheading", "副标题", "子标题"]
        case .body:         return ["Body", "正文"]
        case .monostyled:   return ["Monostyled", "等宽样式", "Monospaced", "等宽"]
        case .checklist:    return ["Checklist", "核对清单", "添加检查项目"]
        case .bulletedList: return ["Bulleted List", "项目符号列表"]
        case .dashedList:   return ["Dashed List", "短划线列表", "虚线列表"]
        case .numberedList: return ["Numbered List", "编号列表"]
        case .blockQuote:   return ["Block Quote", "块引用"]
        case .table:        return ["Table…", "表格…", "Table", "表格"]
        case .bold:         return ["Bold", "粗体"]
        case .italic:       return ["Italic", "斜体"]
        case .underline:    return ["Underline", "下划线"]
        case .strikethrough: return ["Strikethrough", "删除线"]
        }
    }

    /// 标准菜单快捷键（有则用 keystroke，比 AX 遍历更快更稳）
    var shortcut: String? {
        switch self {
        case .bold: return "b using command down"
        case .italic: return "i using command down"
        case .underline: return "u using command down"
        case .checklist: return "l using shift and command down"
        case .table: return nil
        default: return nil
        }
    }
}

enum FormatBridge {
    /// 菜单元素缓存：首次全树搜索后缓存 AXUIElement，后续直接 AXPress。
    /// 全树遍历是每次几十上百毫秒的 AX IPC 开销——格式化「慢半拍」的主因。
    /// press 失败 = 元素失效（Notes 重启/菜单重建），清缓存重找。
    /// 缓存只在 Notes 前台且 AX 可用时有意义，故预热放在 poll 首次命中前。
    nonisolated(unsafe) private static var menuCache: [String: AXUIElement] = [:]

    /// 在 Notes 菜单树中按标题搜索菜单项并触发（缓存命中时直接 AXPress，无遍历）。
    /// 复刻证据行为："N matching menu items found for X in Y. Picked the first one."
    /// 真机取证：从应用根遍历整棵 AX 树（含全部窗口内容）可耗时 10s+；
    /// 限定在菜单栏子树内搜索只需 3ms。
    @discardableResult
    static func triggerMenu(item titled: String) -> Bool {
        if let cached = menuCache[titled] {
            if AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success { return true }
            menuCache.removeValue(forKey: titled)   // 失效：丢弃重找
        }
        guard let menuBar = Self.notesMenuBar() else { return false }
        guard let el = findItem(menuBar, target: titled) else { return false }
        menuCache[titled] = el
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// 预热菜单缓存（后台线程）：Notes 前台且 AX 通道已启动后调用一次，
    /// 把常用格式菜单项一次性找齐，首次真触发零遍历。
    /// 注意：只查找不按下（triggerMenu 会真触发菜单，不能用于预热）。
    static func warmMenuCache(titles: [String]) {
        DispatchQueue.global(qos: .utility).async {
            guard let menuBar = Self.notesMenuBar() else { return }
            for t in titles where menuCache[t] == nil {
                if let el = findItem(menuBar, target: t) { menuCache[t] = el }
            }
        }
    }

    /// Notes 菜单栏元素（找不到返回 nil）
    private static func notesMenuBar() -> AXUIElement? {
        guard let notes = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Notes"
        }) else { return nil }
        let axApp = AXUIElementCreateApplication(notes.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &ref) == .success,
              let bar = ref else { return nil }
        return unsafeBitCast(bar, to: AXUIElement.self)
    }

    /// 触发格式化：菜单 AXPress 优先（真机验证唯一可靠通道——
    /// ⌘T 同时绑在「标题」与「表格」、⌘B 同时绑在「正文」与「粗体」上，keystroke 有歧义），
    /// 快捷键仅作菜单未命中的兜底。
    static func trigger(_ style: FormatStyle) -> Bool {
        for t in style.menuTitles {
            if triggerMenu(item: t) { return true }
        }
        return triggerShortcut(style)
    }

    /// 标准菜单快捷键兜底（真机 dump：核对清单=⇧⌘L、粗体=⌘B、斜体=⌘I、下划线=⌘U）。
    /// CGEventPost 合成击键：NSAppleScript/System Events 同步执行耗时数百 ms 且阻塞主线程。
    static func triggerShortcut(_ style: FormatStyle) -> Bool {
        guard let sc = style.shortcut, let key = sc.split(separator: " ").first else { return false }
        // 解析 "b using command down" → (virtualKey, flags)
        guard let vk = Self.virtualKey(for: String(key).lowercased()) else { return false }
        var flags = CGEventFlags()
        for w in sc.split(separator: " ") {
            switch w {
            case "command": flags.insert(.maskCommand)
            case "shift":   flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        guard let d = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let u = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else { return false }
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        return true
    }

    /// 字母/数字 → macOS virtual key code
    private static func virtualKey(for ch: String) -> CGKeyCode? {
        let letters: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return letters[ch]
    }

    /// 返回找到的菜单元素（不按下）：供缓存层使用
    private static func findItem(_ root: AXUIElement, target: String) -> AXUIElement? {
        let titles = [target, target + "…", target + "..."]
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        var matches: [AXUIElement] = []
        var submenus: [AXUIElement] = []
        for item in children {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String {
                if titles.contains(title) { matches.append(item) }
            }
            // 顺带收集带子菜单的项
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subRef) == .success,
               let sub = subRef as? [AXUIElement], !sub.isEmpty {
                submenus.append(item)
            }
        }
        if let first = matches.first { return first }
        // 深入子菜单（菜单栏 → 菜单 → 子菜单…）
        for item in submenus {
            if let found = findItem(item, target: target) { return found }
        }
        return nil
    }

    // MARK: 行首 Markdown token → FormatStyle（官方清单：# ## ### [] ``` > 内建；- * 1. Built-In）

    static func markdownToken(_ token: String) -> FormatStyle? {
        switch token {
        case "#":    return .title
        case "##":   return .heading
        case "###":  return .subheading
        case "[]":   return .checklist
        case "```":  return .monostyled
        case ">":    return .blockQuote
        case "-":    return .dashedList
        case "*":    return .bulletedList
        case "1.":   return .numberedList
        default:     return nil
        }
    }

    /// 对应 ProNotes 的 expandMarkdown* 设置项
    static func expansionEnabled(_ style: FormatStyle) -> Bool {
        let d = UserDefaults.standard
        func on(_ key: String, _ defaultValue: Bool = true) -> Bool {
            d.object(forKey: key) == nil ? defaultValue : d.bool(forKey: key)
        }
        switch style {
        case .title, .heading, .subheading: return on("nc.md.headers")
        case .checklist:    return on("nc.md.checklists")
        case .dashedList:   return on("nc.md.dashed")
        case .bulletedList: return on("nc.md.bulleted")
        case .numberedList: return on("nc.md.numbered")
        case .blockQuote:   return on("nc.md.quote")
        case .monostyled:   return on("nc.md.monostyled")
        default: return true
        }
    }
}

// MARK: - 行首 Markdown 监听状态机（并入 KeywordListener 的第三个通道）

/// 记录当前行的起始状态：换行后处于“行首”；非行首输入重置。
/// 命中 token + 空格 → 删除 token+空格 → 触发 Notes 菜单格式化。
final class MarkdownLineTracker {
    static let shared = MarkdownLineTracker()
    private(set) var pendingToken = ""
    private var atLineStart = true

    var enabled: Bool {
        UserDefaults.standard.object(forKey: "nc.md.enabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.md.enabled")
    }

    /// 输入一个字符，返回（应删除的字符数, 应触发的格式）或 nil
    func feed(_ c: Character) -> (delete: Int, style: FormatStyle)? {
        guard enabled else { pendingToken = ""; return nil }
        if c == "\n" || c == "\r" {
            pendingToken = ""
            atLineStart = true
            return nil
        }
        if atLineStart {
            // token 构造区：ASCII 标记字符
            let tokenChars: Set<Character> = ["#", "[", "]", "`", ">", "-", "*", "1", "."]
            if tokenChars.contains(c) {
                pendingToken.append(c)
                if pendingToken.count > 3 { pendingToken = "" }
                return nil
            }
            if c == " " {
                // 空格 → 尝试触发
                if let style = FormatBridge.markdownToken(pendingToken),
                   FormatBridge.expansionEnabled(style) {
                    let n = pendingToken.count + 1
                    pendingToken = ""
                    atLineStart = false
                    return (n, style)
                }
                pendingToken = ""
                atLineStart = false
                return nil
            }
            atLineStart = false
            pendingToken = ""
            return nil
        }
        return nil
    }

    /// 重置状态（离开 Notes 前台时调用，避免残留半截 token）
    func reset() {
        pendingToken = ""
        atLineStart = true
    }

    /// 退格：回退 token（不精确匹配也无碍，只用于清理）
    func backspace() {
        if !pendingToken.isEmpty { pendingToken.removeLast() }
        else { atLineStart = true }
    }
}
