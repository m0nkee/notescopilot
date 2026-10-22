import AppKit
import Accessibility

// MARK: - Apple Notes 桥接（复刻 ProNotes 的三通道思路：AX 读取 + AppleScript 写入）

final class NotesBridge {
    static let shared = NotesBridge()
    static let notesBundleID = "com.apple.Notes"

    // MARK: 辅助功能权限

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 当前前台应用是否为 Apple Notes（行首 Markdown 扩展只应往 Notes 里触发，与 ProNotes 一致）
    static func isFrontmostNotes() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == notesBundleID
    }

    // MARK: Deeplink（对应 ProNotes 的 copySelectedNoteLink / CopyDeeplinkButton / _openURL）

    /// 用 AppleScript 读 Notes 当前选中笔记的 identifier（证据：`set selectedNote to (get selection as record)`）
    func selectedNoteID() -> String? {
        let script = """
        tell application "Notes"
            set selectedNote to (get selection as record)
            return identifier of selectedNote
        end tell
        """
        guard let s = NSAppleScript(source: script) else { return nil }
        var err: NSDictionary?
        let out = s.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return out.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生成 notes:// deeplink 并复制到剪贴板；返回是否成功
    @discardableResult
    func copySelectedNoteLink() -> Bool {
        guard let id = selectedNoteID() else { return false }
        let link = Self.deeplink(forNoteID: id)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        return true
    }

    /// notes:// deeplink 构造（notes://show_note?paster=<identifier> 可直接打开对应笔记）
    static func deeplink(forNoteID id: String) -> String {
        "notes://show_note?paster=" + id
    }

    func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilityPrefs() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: 通过 AX API 读取 Notes 中的选中文本

    /// 复刻 ProNotes 的行为：读取「最近活跃的非本应用」（通常为 Notes）
    /// 的聚焦 UI 元素的 kAXSelectedTextAttribute。
    func readSelectedText() -> String? {
        guard let app = FrontmostTracker.shared.lastForeignApp else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let sel = selRef else { return nil }
        return sel as? String
    }

    /// AI 上下文自动带入：选中优先，无选中时光标所在段落。
    /// 解决「/命令弹面板没自动输入上下文」的体验问题：
    /// - 有选中 → 用选中（与 ProNotes selection 一致）
    /// - 无选中 → 光标前最近的非空段落（用户写在哪 AI 就看哪）
    func readContextAroundCursor() -> (text: String, source: String)? {
        // 1) 选中文本
        if let sel = readSelectedText(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (sel, "选中文本")
        }
        // 2) 光标前文本 → 取最后一个非空段
        guard let tail = textBeforeCursor(maxLength: 4000) else { return nil }
        let paras = tail.components(separatedBy: "\n").reversed().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let para = paras.first, !para.isEmpty else { return nil }
        return (para, "光标段落")
    }

    /// 读当前前台应用焦点文本区光标前的文本（AX 轮询通道用；只需辅助功能权限）
    /// 复刻 ProNotes 的 pollTextArea / cancelPollTextArea 证据：不依赖键盘监听
    func textBeforeCursor(maxLength: Int) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        // 光标 = 选区起点；无选区时该属性仍返回插入点位置
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeVal = rangeRef else { return nil }
        guard AXValueGetType(unsafeBitCast(rangeVal, to: AXValue.self)) == .cfRange else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeVal, to: AXValue.self), .cfRange, &sel), sel.location >= 0, sel.location > 0 else { return nil }

        let start = max(0, sel.location - maxLength)
        var cfRange = CFRange(location: start, length: sel.location - start)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var outRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &outRef
        ) == .success, let strRef = outRef else { return nil }
        return unsafeBitCast(strRef, to: CFString.self) as String
    }

    /// 光标所在行的屏幕矩形（Quartz 坐标：左上原点），用于 / 建议面板跟随光标定位。
    /// 实现：取光标前一字符的 AXBoundsForRange（长度为 0 的 range 部分实现不支持，故取 1 字符）。
    func cursorScreenRect() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeVal = rangeRef else { return nil }
        guard AXValueGetType(unsafeBitCast(rangeVal, to: AXValue.self)) == .cfRange else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeVal, to: AXValue.self), .cfRange, &sel), sel.location > 0 else { return nil }
        var cfRange = CFRange(location: sel.location - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var rectRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &rectRef
        ) == .success, let rectVal = rectRef,
            AXValueGetType(unsafeBitCast(rectVal, to: AXValue.self)) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(rectVal, to: AXValue.self), .cgRect, &rect),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    // MARK: AppleScript

    @discardableResult
    func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return "无法创建 AppleScript" }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        if let err, let msg = err[NSAppleScript.errorMessage] as? String { return msg }
        return nil
    }

    // MARK: 选中即 AI：选区快照 / 签名 / 替换 / 追加

    struct SelectionSnapshot {
        let element: AXUIElement   // 焦点文本元素引用（Notes 的文本区）
        let range: CFRange         // 选中区间
        let text: String           // 选中内容
        let bounds: CGRect         // 选中矩形（Quartz 全局坐标，左上原点）
    }

    /// 选区签名（仅位置+长度，轮询去抖用）：Notes 前台且有非空选区时返回，否则 nil
    func selectionSignature() -> String? {
        guard let focused = focusedNotesTextElement() else { return nil }
        guard let r = selectedRange(of: focused), r.length > 0 else { return nil }
        return "\(r.location):\(r.length)"
    }

    /// 完整选区快照（弹出加工面板时用）：文本 + AXBoundsForRange 矩形
    func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let focused = focusedNotesTextElement(),
              let r = selectedRange(of: focused), r.length > 0,
              let text = selectedText(of: focused) ?? stringForRange(focused, r) else { return nil }
        let bounds = boundsForRange(focused, r)
            ?? (cursorScreenRect() ?? CGRect(x: 0, y: 0, width: 200, height: 24))
        return SelectionSnapshot(element: focused, range: r, text: text, bounds: bounds)
    }

    private func focusedNotesTextElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.notesBundleID else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var fRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &fRef) == .success,
              let f = fRef else { return nil }
        return unsafeBitCast(f, to: AXUIElement.self)
    }

    private func selectedRange(of el: AXUIElement) -> CFRange? {
        var rRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rRef) == .success,
              let rv = rRef, AXValueGetType(unsafeBitCast(rv, to: AXValue.self)) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rv, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    private func selectedText(of el: AXUIElement) -> String? {
        var tRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &tRef) == .success,
              let t = tRef else { return nil }
        return t as? String
    }

    private func stringForRange(_ el: AXUIElement, _ r: CFRange) -> String? {
        var cfRange = r
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var outRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXStringForRangeParameterizedAttribute as CFString, param, &outRef
        ) == .success, let s = outRef else { return nil }
        return unsafeBitCast(s, to: CFString.self) as String
    }

    /// 区间的屏幕矩形（Quartz 左上原点）
    private func boundsForRange(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        var cfRange = r
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var rectRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &rectRef
        ) == .success, let rv = rectRef,
            AXValueGetType(unsafeBitCast(rv, to: AXValue.self)) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(rv, to: AXValue.self), .cgRect, &rect),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// AX 恢复选区（替换/追加前的关键一步：面板操作后选区可能丢失）
    @discardableResult
    private func setSelectionRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var range = r
        guard let v = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// 替换原选区：优先 AXSetSelectedText（不碰剪贴板）；不支持时恢复选区后 ⌘V 粘贴
    func replaceSelection(in snap: SelectionSnapshot, with text: String) -> String? {
        // 尝试 1：AX 直写选中（Notes 的 WebKit 文本区通常支持）
        if setSelectionRange(snap.element, snap.range) {
            var textRef: CFTypeRef = text as CFTypeRef
            if AXUIElementSetAttributeValue(snap.element, kAXSelectedTextAttribute as CFString, textRef) == .success {
                return nil
            }
        }
        // 尝试 2：恢复选区 + 粘贴（⌘V 天然覆盖选区）
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID })
        else { return "未找到正在运行的 Apple Notes。" }
        if !NotesBridge.isFrontmostNotes() { notes.activate(); Thread.sleep(forTimeInterval: 0.45) }
        guard setSelectionRange(snap.element, snap.range) else { return "无法恢复选区（文本可能已变动）" }
        typeExpansion(deleteCount: 0, insert: text)
        return nil
    }

    /// 追加到选区末尾：把光标移到选区结尾（零长区间）再粘贴
    func appendAfterSelection(in snap: SelectionSnapshot, with text: String) -> String? {
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID })
        else { return "未找到正在运行的 Apple Notes。" }
        if !NotesBridge.isFrontmostNotes() { notes.activate(); Thread.sleep(forTimeInterval: 0.45) }
        guard setSelectionRange(snap.element, CFRange(location: snap.range.location + snap.range.length, length: 0))
        else { return "无法定位选区末尾（文本可能已变动）" }
        typeExpansion(deleteCount: 0, insert: text)
        return nil
    }

    /// 把 AI 结果粘贴回 Notes 光标处（对应 ProNotes 的结果注入）
    func insertIntoNotes(_ text: String) -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID })
        else { return "未找到正在运行的 Apple Notes。" }
        notes.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            _ = self.runScript("""
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let s = saved {
                    pb.clearContents()
                    pb.setString(s, forType: .string)
                }
            }
        }
        return nil
    }

    /// 把 AI 结果替换 Notes 当前选中文本（无选中时等同插入光标处）。
    /// ⌘V 本身就会覆盖选区，但选区可能已被面板操作丢失——先 AX 恢复选区再粘贴。
    @discardableResult
    func replaceSelectionInNotes(_ text: String) -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID })
        else { return "未找到正在运行的 Apple Notes。" }
        notes.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            _ = self.runScript("""
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let s = saved {
                    pb.clearContents()
                    pb.setString(s, forType: .string)
                }
            }
        }
        return nil
    }

    /// 把 AI 结果存为一条新笔记（对应 ProNotes 的 create new note with body 脚本）
    @discardableResult
    func createNewNote(_ text: String) -> String? {
        let html = Self.appleScriptEscaped(Self.htmlEscaped(text))
        return runScript("""
        tell application "Notes"
            activate
            set newNote to make new note
            set body of newNote to "\(html)"
            show newNote
        end tell
        """)
    }

    /// 删除刚键入的 N 个字符（全局斜杠命令命中后，清掉已进入笔记的命令文字）。
    /// 用 CGEventPost 合成退格：AppleScript/System Events 首次执行耗时数秒且阻塞主线程，
    /// 是「慢半拍」主因；CGEventPost 纯内存投递、零阻塞（辅助功能权限下直达 Notes）。
    func deleteTyped(count: Int) {
        guard count > 0 else { return }
        let t0 = Date()
        for _ in 0..<count {
            guard let d = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let u = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { continue }
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)   // 退格节拍：过快会被 Notes web 视图吞掉
        }
        NCLog.log("deleteTyped \(count) 键耗时 \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    /// 文本扩展（对应 ProNotes KeywordListener 命中后的展开）：
    /// 删除刚输入的触发词字符，粘贴展开片段，最后恢复原剪贴板内容。
    func typeExpansion(deleteCount: Int, insert text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        var deletes = ""
        for _ in 0..<deleteCount {
            deletes += "keystroke (ASCII character 8)\n"
        }
        DispatchQueue.main.async {
            _ = self.runScript("""
            tell application "System Events"
            \(deletes)keystroke "v" using command down
            end tell
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let s = saved {
                    pb.clearContents()
                    pb.setString(s, forType: .string)
                }
            }
        }
    }

    /// 富文本粘贴（URL 转超链用）：剪贴板放 public.html + 纯文本兜底，
    /// Notes 粘贴 HTML 中的 <a href> 会生成真超链（蓝字可点）。
    /// 恢复剪贴板时同时还原 html 与纯文本。
    func typeExpansionRich(html: String, deleteCount: Int) {
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        let savedHTML = pb.data(forType: .html)
        pb.clearContents()
        pb.setData(html.data(using: .utf8), forType: .html)
        // 纯文本版 = 去 HTML 标签（Notes 不认 html 类型时的兜底）
        pb.setString(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                     forType: .string)
        var deletes = ""
        for _ in 0..<deleteCount {
            deletes += "keystroke (ASCII character 8)\n"
        }
        DispatchQueue.main.async {
            _ = self.runScript("""
            tell application "System Events"
            \(deletes)keystroke "v" using command down
            end tell
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                if let h = savedHTML { pb.setData(h, forType: .html) }
                if let s = savedString { pb.setString(s, forType: .string) }
            }
        }
    }

    // MARK: Notes 格式菜单（标题/小标题/列表/块引用…）—— 选中加工面板的格式按钮

    /// Notes 支持的段落/字体格式全集（菜单准确标题 + 按钮短标签），按「格式」菜单顺序。
    /// 枚举失败时以此兜底；注意 NotesBridge 会被不含 SelectionAI.swift 的测试套编译，勿引用 UI 类型。
    /// 斜体⌘I 下划线⌘U 删除线(无快捷键)在 字体 子菜单；「显示颜色」⌘⇧C 打开颜色面板选色。
    static let formatMenuItems: [(menu: String, label: String)] = [
        ("标题", "标题"), ("小标题", "小标题"), ("副标题", "副标题"), ("正文", "正文"),
        ("等宽样式", "等宽"),
        ("斜体", "斜体"), ("下划线", "下划线"), ("删除线", "删除线"), ("显示颜色", "颜色"),
        ("项目符号列表", "圆点列表"), ("短划线列表", "短划线"), ("编号列表", "编号列表"),
        ("块引用", "块引用"),
    ]

    private static func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// 取菜单栏项的菜单元素：Notes 不支持 AXMenu 属性(-25212)，但菜单是菜单栏项的首个子元素
    private static func menuOfMenuBarItem(_ mbItem: AXUIElement) -> AXUIElement? {
        guard let kidsRef = axAttr(mbItem, kAXChildrenAttribute as String),
              let kids = kidsRef as? [AXUIElement] else { return nil }
        return kids.first
    }

    /// 枚举 Notes 菜单栏里当前实际存在的段落格式项（AX 读取，无需打开菜单）。
    /// 动态枚举的意义：跟随 Notes 版本/本地化，「当前已支持」以菜单为准。
    func supportedFormatTitles() -> [String] {
        let fallback = Self.formatMenuItems.map(\.menu)
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID }),
              notes.isFinishedLaunching else { return fallback }
        let axApp = AXUIElementCreateApplication(notes.processIdentifier)
        guard let menuBar = Self.axAttr(axApp, kAXMenuBarAttribute) else { return fallback }
        var found: Set<String> = []
        let wanted = Set(fallback)
        // AXMenuBar 返回的是单个菜单栏元素，子元素才是菜单栏项
        let bar = unsafeBitCast(menuBar, to: AXUIElement.self)
        if let itemsRef = Self.axAttr(bar, kAXChildrenAttribute as String),
           let items = itemsRef as? [AXUIElement] {
            for mbItem in items {
                guard let menu = Self.menuOfMenuBarItem(mbItem) else { continue }
                Self.collectFormatTitles(menu, depth: 0, wanted: wanted, into: &found)
            }
        }
        guard !found.isEmpty else { return fallback }
        return fallback.filter { found.contains($0) }
    }

    private static func collectFormatTitles(_ el: AXUIElement, depth: Int, wanted: Set<String>, into out: inout Set<String>) {
        guard depth < 4 else { return }
        guard let roleRef = axAttr(el, kAXRoleAttribute), let role = roleRef as? String else { return }
        if role == "AXMenuItem", let tRef = axAttr(el, kAXTitleAttribute),
           let t = tRef as? String, wanted.contains(t) {
            out.insert(t)
        }
        if let kidsRef = axAttr(el, kAXChildrenAttribute),
           let kids = kidsRef as? [AXUIElement] {
            for k in kids { collectFormatTitles(k, depth: depth + 1, wanted: wanted, into: &out) }
        }
    }

    /// 对 Notes 当前选中文本应用段落格式：AX 按下「格式」菜单对应项（Notes 须前台且有选区）。
    /// AXPress 失败时兜底：读菜单项快捷键（AXMenuItemCmdChar/Modifiers）用 CGEvent 发送。
    @discardableResult
    func applyFormat(_ menuTitle: String) -> String? {
        guard let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID }) else {
            return "未找到正在运行的 Apple Notes"
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.notesBundleID else {
            return "Notes 不在前台，无法应用格式"
        }
        let axApp = AXUIElementCreateApplication(notes.processIdentifier)
        guard let item = Self.findMenuItem(axApp, titled: menuTitle) else {
            return "菜单项「\(menuTitle)」未找到"
        }
        let press = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if press == .success { return nil }
        NCLog.log("格式「\(menuTitle)」AXPress 失败(\(press.rawValue))，改走快捷键")
        return Self.pressViaShortcut(item, title: menuTitle)
    }

    /// 在应用菜单栏的所有菜单里递归找标题匹配的 AXMenuItem
    private static func findMenuItem(_ axApp: AXUIElement, titled title: String) -> AXUIElement? {
        guard let barEl = axAttr(axApp, kAXMenuBarAttribute) else { return nil }
        let bar = unsafeBitCast(barEl, to: AXUIElement.self)
        guard let itemsRef = axAttr(bar, kAXChildrenAttribute as String),
              let items = itemsRef as? [AXUIElement] else { return nil }
        for mbItem in items {
            guard let menu = Self.menuOfMenuBarItem(mbItem) else { continue }
            if let hit = findMenuItemRecurse(menu, titled: title, depth: 0) { return hit }
        }
        return nil
    }

    private static func findMenuItemRecurse(_ el: AXUIElement, titled title: String, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        if let roleRef = axAttr(el, kAXRoleAttribute), (roleRef as? String) == "AXMenuItem",
           let tRef = axAttr(el, kAXTitleAttribute), (tRef as? String) == title {
            return el
        }
        if let kidsRef = axAttr(el, kAXChildrenAttribute),
           let kids = kidsRef as? [AXUIElement] {
            for k in kids {
                if let hit = findMenuItemRecurse(k, titled: title, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    /// 快捷键兜底：AXMenuItemCmdChar + AXMenuItemCmdModifiers（bit0=Shift bit1=Option bit2=Control，Command 恒定）
    private static func pressViaShortcut(_ item: AXUIElement, title: String) -> String? {
        guard let chRef = axAttr(item, "AXMenuItemCmdChar"), let ch = chRef as? String, !ch.isEmpty else {
            return "「\(title)」无可用快捷键"
        }
        var mods = 0
        if let modRef = axAttr(item, "AXMenuItemCmdModifiers") {
            mods = (modRef as? NSNumber)?.intValue ?? 0
        }
        var flags: CGEventFlags = [.maskCommand]
        if mods & 1 != 0 { flags.insert(.maskShift) }
        if mods & 2 != 0 { flags.insert(.maskAlternate) }
        if mods & 4 != 0 { flags.insert(.maskControl) }
        guard let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return "无法创建键盘事件"
        }
        let chars = Array(ch.utf16)
        d.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        u.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        return nil
    }

    // MARK: 转义

    static func htmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
