import AppKit
import Accessibility

// MARK: - Apple Notes 桥接（复刻 ProNotes 的三通道思路：AX 读取 + AppleScript 写入）

enum NotesAccessIssue: Equatable {
    case accessibilityRequired, automationDenied, identityUnavailable

    var message: String {
        switch self {
        case .accessibilityRequired:
            return "Notes 访问需要辅助功能权限。请在系统设置的“隐私与安全性 → 辅助功能”中允许 NotesCopilot，然后回到 Notes 正文重试。"
        case .automationDenied:
            return "Notes 自动化访问被拒绝。请在系统设置的“隐私与安全性 → 自动化”中允许 NotesCopilot 控制 Notes。"
        case .identityUnavailable:
            return "无法确认当前笔记。请在 Notes 中只选中一条笔记，点击正文后重试。"
        }
    }

    var needsAutomationSettings: Bool { self == .automationDenied }
}

final class NotesBridge {
    static let shared = NotesBridge()
    static let notesBundleID = "com.apple.Notes"
    static let accessChangedNotification = Notification.Name("nc.notesAccessChanged")

    private let snapshotReader: (() -> SelectionSnapshot?)?
    private let replacementWriter: ((SelectionSnapshot, CFRange, String, String?) -> String?)?
    private let activationScheduler: ((@escaping () -> Void) -> Void)?
    private let trustChecker: () -> Bool
    private let identityReader: (() -> (id: String?, errorNumber: Int?))?
    private var identityIssue: NotesAccessIssue?
    private var publishedAccessIssue: NotesAccessIssue?

    init(snapshotReader: (() -> SelectionSnapshot?)? = nil,
         replacementWriter: ((SelectionSnapshot, CFRange, String, String?) -> String?)? = nil,
         activationScheduler: ((@escaping () -> Void) -> Void)? = nil,
         trustChecker: @escaping () -> Bool = { AXIsProcessTrusted() },
         identityReader: (() -> (id: String?, errorNumber: Int?))? = nil) {
        self.snapshotReader = snapshotReader
        self.replacementWriter = replacementWriter
        self.activationScheduler = activationScheduler
        self.trustChecker = trustChecker
        self.identityReader = identityReader
    }

    // MARK: 辅助功能权限

    var isTrusted: Bool { trustChecker() }

    var accessIssue: NotesAccessIssue? { isTrusted ? identityIssue : .accessibilityRequired }

    /// 只刷新辅助功能状态；不会发送 AppleEvent 或触发 Notes 自动化授权。
    @discardableResult
    func refreshAccessIssue() -> NotesAccessIssue? {
        let issue = accessIssue
        if issue != publishedAccessIssue {
            publishedAccessIssue = issue
            NotificationCenter.default.post(name: Self.accessChangedNotification, object: self)
        }
        return issue
    }

    /// 当前前台应用是否为 Apple Notes（行首 Markdown 扩展只应往 Notes 里触发，与 ProNotes 一致）
    static func isFrontmostNotes() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == notesBundleID
    }

    // MARK: Deeplink（对应 ProNotes 的 copySelectedNoteLink / CopyDeeplinkButton / _openURL）

    /// 用 AppleScript 读 Notes 当前选中笔记的 identifier（证据：`set selectedNote to (get selection as record)`）
    func selectedNoteID() -> String? {
        let result = identityReader?() ?? Self.readSelectedNoteIdentity()
        if result.errorNumber == nil,
           let id = result.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            identityIssue = nil
            refreshAccessIssue()
            return id
        }
        identityIssue = result.errorNumber == -1743 ? .automationDenied : .identityUnavailable
        refreshAccessIssue()
        return nil
    }

    /// 只保留身份及错误码用于诊断，不记录笔记、脚本或系统返回的原始错误描述。
    private static func readSelectedNoteIdentity() -> (id: String?, errorNumber: Int?) {
        let script = """
        tell application "Notes"
            set selectedNotes to selection
            if (count of selectedNotes) is not 1 then return ""
            return id of item 1 of selectedNotes
        end tell
        """
        guard let s = NSAppleScript(source: script) else { return (nil, nil) }
        var err: NSDictionary?
        let out = s.executeAndReturnError(&err)
        if let err { return (nil, (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0) }
        return (out.stringValue, nil)
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

    func openAutomationPrefs() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
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
        guard Self.isFrontmostNotes() else { return nil }
        if let snapshot = readTextSnapshot() { return Self.context(in: snapshot) }
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

    /// 只解析已绑定的 Notes 快照，面板持焦点时不会误读自己的输入框。
    static func context(in snapshot: SelectionSnapshot) -> (text: String, source: String)? {
        let document = snapshot.documentText as NSString
        let cursor = snapshot.range.location
        guard cursor >= 0, cursor <= document.length, snapshot.range.length >= 0,
              snapshot.range.length <= document.length - cursor else { return nil }
        if snapshot.range.length > 0 {
            let selection = document.substring(with: NSRange(location: cursor, length: snapshot.range.length))
            if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (selection, "选中文本")
            }
        }
        guard document.length > 0 else { return nil }
        let line = document.substring(with: document.lineRange(for: NSRange(location: cursor, length: 0)))
            .trimmingCharacters(in: .newlines)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { return (line, "光标段落") }
        let before = document.substring(to: cursor)
        if let previous = before.components(separatedBy: .newlines).reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return (previous, "光标段落")
        }
        return nil
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
        let noteID: String
        let documentText: String

        func matches(_ other: SelectionSnapshot) -> Bool {
            !noteID.isEmpty && noteID == other.noteID && CFEqual(element, other.element)
                && range.location == other.range.location && range.length == other.range.length
                && text == other.text && documentText == other.documentText
        }
    }

    /// 选区签名（仅位置+长度，轮询去抖用）：Notes 前台且有非空选区时返回，否则 nil
    func selectionSignature() -> String? {
        guard let focused = focusedNotesTextElement() else { return nil }
        guard let r = selectedRange(of: focused), r.length > 0 else { return nil }
        return "\(r.location):\(r.length)"
    }

    /// 完整选区快照；也保存笔记身份与正文，写回时拒绝失效的目标。
    func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let snap = readTextSnapshot(), snap.range.length > 0 else { return nil }
        return snap
    }

    /// 包含零长光标的快照，用于异步 URL/模板写回。
    func readTextSnapshot(allowInactiveNotes: Bool = false) -> SelectionSnapshot? {
        if let snapshotReader { return snapshotReader() }
        guard let focused = focusedNotesTextElement(allowInactiveNotes: allowInactiveNotes),
              let role = Self.axAttr(focused, kAXRoleAttribute) as? String,
              role == kAXTextAreaRole,
              let r = selectedRange(of: focused), r.location >= 0, r.length >= 0,
              let documentText = Self.axAttr(focused, kAXValueAttribute) as? String,
              r.location <= (documentText as NSString).length,
              r.length <= (documentText as NSString).length - r.location,
              let noteID = selectedNoteID() else { return nil }
        let text = (documentText as NSString).substring(with: NSRange(location: r.location, length: r.length))
        let bounds = boundsForRange(focused, r)
            ?? (cursorScreenRect() ?? CGRect(x: 0, y: 0, width: 200, height: 24))
        guard let current = focusedNotesTextElement(allowInactiveNotes: allowInactiveNotes), CFEqual(current, focused),
              let currentRange = selectedRange(of: current),
              currentRange.location == r.location, currentRange.length == r.length,
              Self.axAttr(current, kAXValueAttribute) as? String == documentText else { return nil }
        return SelectionSnapshot(element: focused, range: r, text: text, bounds: bounds,
                                 noteID: noteID, documentText: documentText)
    }

    func isCurrent(_ snap: SelectionSnapshot) -> Bool {
        guard let current = readTextSnapshot() else { return false }
        return snap.matches(current)
    }

    func readNotesSnapshot() -> SelectionSnapshot? {
        readTextSnapshot(allowInactiveNotes: true)
    }

    private func focusedNotesTextElement(allowInactiveNotes: Bool = false) -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app: NSRunningApplication
        if front.bundleIdentifier == Self.notesBundleID {
            app = front
        } else {
            guard allowInactiveNotes, front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  FrontmostTracker.shared.lastForeignApp?.bundleIdentifier == Self.notesBundleID,
                  let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID })
            else { return nil }
            app = notes
        }
        guard refreshAccessIssue() != .accessibilityRequired else { return nil }
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

    /// 替换原选区：目标身份、范围、原文均未变化才执行。
    func replaceSelection(in snap: SelectionSnapshot, with text: String, html: String? = nil,
                          isOperationValid: () -> Bool = { true }) -> String? {
        replaceText(in: snap, range: snap.range, with: text, html: html, isOperationValid: isOperationValid)
    }

    /// 追加到选区末尾：把光标移到选区结尾（零长区间）再粘贴
    func appendAfterSelection(in snap: SelectionSnapshot, with text: String) -> String? {
        replaceText(in: snap, range: CFRange(location: snap.range.location + snap.range.length, length: 0), with: text)
    }

    /// 仅从本应用的确认面板归还焦点；其他应用持焦点时取消。
    func withNotesTargetActive(in snap: SelectionSnapshot,
                               isOperationValid: @escaping () -> Bool = { true },
                               completion: @escaping (String?) -> Void) {
        guard isOperationValid() else { completion("操作已取消。"); return }
        let validate = {
            guard isOperationValid() else { completion("操作已取消。"); return }
            let current = self.isCurrent(snap)
            completion(isOperationValid() && current ? nil : "操作已取消或原笔记已变化。")
        }
        if let activationScheduler { activationScheduler(validate); return }
        if snapshotReader != nil || Self.isFrontmostNotes() {
            validate()
            return
        }
        guard let current = readNotesSnapshot(), snap.matches(current),
              let notes = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.notesBundleID }) else {
            completion("原笔记、光标或文本已变化，已取消写入。")
            return
        }
        guard isOperationValid() else { completion("操作已取消。"); return }
        notes.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { validate() }
    }

    func writeWhenNotesActive(in snap: SelectionSnapshot, text: String, range: CFRange? = nil,
                             html: String? = nil, isOperationValid: @escaping () -> Bool = { true },
                             completion: @escaping (String?) -> Void) {
        withNotesTargetActive(in: snap, isOperationValid: isOperationValid) { error in
            if let error { completion(error); return }
            completion(self.replaceText(in: snap, range: range ?? snap.range, with: text, html: html,
                                        isOperationValid: isOperationValid))
        }
    }

    @discardableResult
    func replaceText(in snap: SelectionSnapshot, range: CFRange, with text: String, html: String? = nil,
                     isOperationValid: () -> Bool = { true }) -> String? {
        guard isOperationValid() else { return "操作已取消。" }
        guard isCurrent(snap) else { return "原笔记、光标或文本已变化，已取消写入。" }
        let size = (snap.documentText as NSString).length
        guard range.location >= 0, range.length >= 0, range.location <= size,
              range.length <= size - range.location else { return "写入范围无效，已取消写入。" }
        guard isOperationValid() else { return "操作已取消。" }
        if let replacementWriter { return replacementWriter(snap, range, text, html) }
        guard setSelectionRange(snap.element, range) else { return "无法定位原选区，已取消写入。" }
        let selected = (snap.documentText as NSString).substring(with: NSRange(location: range.location, length: range.length))
        let target = SelectionSnapshot(element: snap.element, range: range, text: selected, bounds: snap.bounds,
                                       noteID: snap.noteID, documentText: snap.documentText)
        guard isCurrent(target) else { return "原笔记已变化，已取消写入。" }
        guard isOperationValid() else { return "操作已取消。" }
        if html == nil,
           AXUIElementSetAttributeValue(snap.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return nil
        }

        return validatedPaste(in: target, prepareClipboard: {
            self.preparePasteboard(text: text, html: html)
        }, postPaste: {
            guard isOperationValid(),
                  let notes = NSWorkspace.shared.frontmostApplication, notes.bundleIdentifier == Self.notesBundleID else {
                return "Notes 不在前台，已取消粘贴。"
            }
            return Self.dispatchPreparedPaste(preservingStyle: html != nil,
                isOperationValid: { isOperationValid() && self.isCurrent(target) },
                triggerMenu: { FormatBridge.triggerMenu(item: $0) },
                postStandardPaste: {
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
                        return "无法发送粘贴操作。"
                    }
                    down.flags = .maskCommand; up.flags = .maskCommand
                    guard isOperationValid() else { return "操作已取消。" }
                    down.postToPid(notes.processIdentifier); up.postToPid(notes.processIdentifier)
                    return nil
                })
        }, isOperationValid: isOperationValid)
    }

    /// Notes 的普通“粘贴”可能沿用目标段落样式；模板和其他富文本必须明确保留源样式。
    /// 不把保留样式菜单失败降级为普通粘贴，避免静默丢失用户选择的模板格式。
    static func dispatchPreparedPaste(preservingStyle: Bool,
                                      isOperationValid: () -> Bool,
                                      triggerMenu: (String) -> Bool,
                                      postStandardPaste: () -> String?) -> String? {
        guard isOperationValid() else { return "操作已取消。" }
        guard preservingStyle else { return postStandardPaste() }
        for title in ["Paste and Retain Style", "粘贴并保留样式", "粘贴并保留格式", "貼上並保留樣式"] {
            guard isOperationValid() else { return "操作已取消。" }
            if triggerMenu(title) { return nil }
        }
        return "无法执行 Notes 的“粘贴并保留样式”，已取消写入。"
    }

    /// 剪贴板读取可能阻塞；所有准备工作之后再校验，失效时不发送按键。
    func validatedPaste(in target: SelectionSnapshot,
                        prepareClipboard: () -> (() -> Void), postPaste: () -> String?,
                        isOperationValid: () -> Bool = { true }) -> String? {
        guard isOperationValid() else { return "操作已取消。" }
        let restore = prepareClipboard()
        guard isOperationValid(), isCurrent(target), isOperationValid() else {
            restore()
            return "原笔记、光标或文本已变化，已取消粘贴。"
        }
        guard isOperationValid() else { restore(); return "操作已取消。" }
        if let error = postPaste() {
            restore()
            return error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { restore() }
        return nil
    }

    /// public.html 接收方可能按单字节默认编码读取片段；编码声明必须随字节一起交付。
    static func htmlPasteboardData(_ html: String) -> Data {
        let document = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" + html + "</body></html>"
        return Data(document.utf8)
    }

    /// Notes 使用标准 RTFD/RTF 富文本；两种格式由同一次 HTML 导入生成。
    /// 输入仅为本应用渲染的 HTML；AppKit HTML 导入必须在主线程运行。
    private static func richPasteboardData(_ html: String) -> (rtf: Data, rtfd: Data?)? {
        guard Thread.isMainThread else { return nil }
        do {
            let richText = try NSAttributedString(data: htmlPasteboardData(html), options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ], documentAttributes: nil)
            let rtf = try richText.data(from: NSRange(location: 0, length: richText.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let rtfd = try? richText.data(from: NSRange(location: 0, length: richText.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            return (rtf, rtfd)
        } catch {
            return nil
        }
    }

    func preparePasteboard(text: String, html: String?, pasteboard pb: NSPasteboard = .general) -> () -> Void {
        let rich = html.flatMap(Self.richPasteboardData)
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pb.clearContents()
        if let rtfd = rich?.rtfd { pb.setData(rtfd, forType: .rtfd) }
        if let rtf = rich?.rtf { pb.setData(rtf, forType: .rtf) }
        if let html { pb.setData(Self.htmlPasteboardData(html), forType: .html) }
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount
        return {
            guard pb.changeCount == changeCount else { return }
            pb.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(items)
        }
    }

    /// 显式插入也绑定点击时的 Notes 光标，等待焦点归还时再次校验。
    func insertIntoNotes(_ text: String, html: String? = nil,
                         isOperationValid: @escaping () -> Bool = { true },
                         completion: @escaping (String?) -> Void) {
        guard let target = readNotesSnapshot() else {
            completion("无法定位 Notes 原光标，请回到笔记正文后重试。")
            return
        }
        writeWhenNotesActive(in: target, text: text, html: html,
                             isOperationValid: isOperationValid, completion: completion)
    }

    /// 把 AI 结果替换 Notes 当前选中文本（无选中时等同插入光标处）。
    /// ⌘V 本身就会覆盖选区，但选区可能已被面板操作丢失——先 AX 恢复选区再粘贴。
    func replaceSelectionInNotes(_ text: String, html: String? = nil,
                                 isOperationValid: @escaping () -> Bool = { true },
                                 completion: @escaping (String?) -> Void) {
        insertIntoNotes(text, html: html, isOperationValid: isOperationValid, completion: completion)
    }

    /// 把 AI 结果存为一条新笔记（对应 ProNotes 的 create new note with body 脚本）
    @discardableResult
    func createNewNote(_ text: String, html: String? = nil) -> String? {
        let html = Self.appleScriptEscaped(html ?? Self.htmlEscaped(text))
        return runScript("""
        tell application "Notes"
            activate
            set newNote to make new note
            set body of newNote to "\(html)"
            show newNote
        end tell
        """)
    }

    /// 删除 Notes 光标前的 N 个字符；精确绑定原范围，不向当前应用发送全局退格。
    @discardableResult
    func deleteTyped(count: Int) -> String? {
        guard let target = readTextSnapshot(),
              let range = Self.suffixRange(in: target, characterCount: count) else {
            return "无法定位 Notes 中待删除的文字，已取消。"
        }
        return replaceText(in: target, range: range, with: "")
    }

    /// 以实际 UTF-16 长度定位后缀，不把中文/emoji 的字符数当作 AX 偏移。
    static func suffixRange(in target: SelectionSnapshot, characterCount: Int) -> CFRange? {
        guard characterCount > 0, target.range.length == 0, target.range.location >= 0,
              target.range.location <= target.documentText.utf16.count else { return nil }
        let before = (target.documentText as NSString).substring(to: target.range.location)
        guard before.count >= characterCount else { return nil }
        let length = String(before.suffix(characterCount)).utf16.count
        return CFRange(location: target.range.location - length, length: length)
    }

    /// 删除完成后确认同一笔记的全文与光标；粘贴兜底未落地时异步等待，不阻塞事件监听。
    func removeSuffix(in target: SelectionSnapshot, characterCount: Int,
                      completion: @escaping (SelectionSnapshot?, String?) -> Void) {
        guard let range = Self.suffixRange(in: target, characterCount: characterCount) else {
            completion(nil, "原命令范围无效，已取消执行。")
            return
        }
        let document = (target.documentText as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: "")
        let expected = SelectionSnapshot(element: target.element,
                                         range: CFRange(location: range.location, length: 0), text: "",
                                         bounds: target.bounds, noteID: target.noteID, documentText: document)
        if let error = replaceText(in: target, range: range, with: "") {
            completion(nil, error)
            return
        }
        let deadline = Date().addingTimeInterval(0.8)
        func verify() {
            guard let current = self.readTextSnapshot() else {
                completion(nil, "Notes 焦点已变化，已取消执行。")
                return
            }
            if expected.matches(current) { completion(current, nil); return }
            // 仅允许等待仍未落地的原文；其他编辑、换笔记和移动光标立即取消。
            let awaitingPaste = target.noteID == current.noteID && CFEqual(target.element, current.element)
                && current.documentText == target.documentText
                && current.range.location == range.location && current.range.length == range.length
            guard awaitingPaste, Date() < deadline else {
                completion(nil, "命令删除未完成或原笔记已变化，已取消执行。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { verify() }
        }
        verify()
    }

    /// 文本扩展（对应 ProNotes KeywordListener 命中后的展开）：
    /// 删除刚输入的触发词字符，粘贴展开片段，最后恢复原剪贴板内容。
    func typeExpansion(deleteCount: Int, insert text: String, expectedTrigger: String? = nil) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = Self.axAttr(axApp, kAXFocusedUIElementAttribute) else { return }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard let cursor = selectedRange(of: element), cursor.length == 0,
              let document = Self.axAttr(element, kAXValueAttribute) as? String,
              cursor.location >= 0, cursor.location <= document.utf16.count else { return }
        let before = (document as NSString).substring(to: cursor.location)
        guard deleteCount > 0, before.count >= deleteCount else { return }
        let trigger = String(before.suffix(deleteCount))
        guard expectedTrigger.map({ $0 == trigger }) ?? true else { return }
        let replacementRange = CFRange(location: cursor.location - trigger.utf16.count, length: trigger.utf16.count)
        // 关键词也必须精确替换捕获的原文；不再向任意当前应用发送一串全局退格。
        guard setSelectionRange(element, replacementRange) else { return }
        func stillCurrent() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let currentFocused = Self.axAttr(axApp, kAXFocusedUIElementAttribute),
                  CFEqual(currentFocused, element),
                  Self.axAttr(element, kAXValueAttribute) as? String == document,
                  let currentRange = self.selectedRange(of: element) else { return false }
            return currentRange.location == replacementRange.location && currentRange.length == replacementRange.length
        }
        guard stillCurrent() else { return }
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success { return }
        let restore = preparePasteboard(text: text, html: nil)
        guard stillCurrent(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { restore(); return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { restore() }
    }

    /// 富文本粘贴（URL 转超链用）：剪贴板放 public.html + 纯文本兜底，
    /// Notes 粘贴 HTML 中的 <a href> 会生成真超链（蓝字可点）。
    /// 恢复剪贴板时同时还原 html 与纯文本。
    func typeExpansionRich(html: String, deleteCount: Int) {
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        let savedHTML = pb.data(forType: .html)
        pb.clearContents()
        pb.setData(Self.htmlPasteboardData(html), forType: .html)
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

    static func formatMenuTitles(for title: String) -> [String] {
        if title == "显示颜色" { return ["显示颜色", "Show Colors", "Show Colours"] }
        return FormatStyle.allCases.first(where: { $0.menuTitles.contains(title) })?.menuTitles ?? [title]
    }

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
        let wanted = Set(fallback.flatMap { Self.formatMenuTitles(for: $0) })
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
        return fallback.filter { title in Self.formatMenuTitles(for: title).contains { found.contains($0) } }
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
        guard let item = Self.formatMenuTitles(for: menuTitle).compactMap({ Self.findMenuItem(axApp, titled: $0) }).first else {
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
