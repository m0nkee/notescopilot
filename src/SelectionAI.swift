import AppKit
import Accessibility
import ObjectiveC

// MARK: - 选中即 AI：悬浮快捷加工（hover 风格）
//
// 复刻 ProNotes Inline Toolbar 的「贴在 Notes 编辑区上的悬浮条」思路，但触发条件改为
// 「文本选中且稳定」：AX 轮询读 kAXSelectedTextRange，选区稳定 2 拍（≈0.4s）即视为
// 用户完成选择，在选区矩形下方弹出非激活面板（不抢 Notes 焦点，选区不丢）：
//
//   [润色] [总结] [翻译] [解释] [精简]  [自定义指令…]
//     → AIService.complete 非流式加工 → 结果卡展示：
//   [替换选区] [追加到后] [复制] [×]
//
// 写入通道（替换/追加）：优先 AXSetSelectedText（零剪贴板污染），
// 不支持时退回「AXSetSelectedTextRange 恢复选区 + ⌘V 粘贴」。

// MARK: 快捷动作定义

struct SelectionQuickAction: Equatable {
    let name: String
    let instruction: String
}

/// 快捷加工清单：指令要求「只输出加工后的文本」，保证替换动作可直接落笔
let selectionQuickActions: [SelectionQuickAction] = [
    .init(name: "润色", instruction: "请润色以下文字，使其更通顺、专业，保持原意与格式。只输出润色后的文本，不要解释。"),
    .init(name: "总结", instruction: "请用简洁的要点总结以下内容的核心信息。只输出总结内容。"),
    .init(name: "翻译", instruction: "请将以下内容翻译成英文，保持原意与语气。只输出译文。"),
    .init(name: "解释", instruction: "请简要解释以下内容的关键概念与逻辑。"),
    .init(name: "精简", instruction: "请把以下内容压缩得更简洁，保留核心信息。只输出精简后的文本。"),
]

// MARK: Notes 原生格式按钮（选中面板第二排，纯逻辑可单测）

struct NotesFormatItem: Equatable {
    let menuTitle: String   // Notes「格式」菜单的准确标题（AXPress 用）
    let label: String       // 按钮短标签
}

enum NotesFormatButton {
    /// 从 Notes 菜单枚举结果构造按钮清单：仅保留实际存在的项，按 canonical 顺序
    nonisolated static func items(presenting titles: [String]) -> [NotesFormatItem] {
        let set = Set(titles)
        return NotesBridge.formatMenuItems
            .filter { set.contains($0.menu) }
            .map { NotesFormatItem(menuTitle: $0.menu, label: $0.label) }
    }

    /// 拆行（面板宽度有限，每行最多 5 个）
    nonisolated static func splitRows(_ items: [NotesFormatItem], maxPerRow: Int = 5) -> [[NotesFormatItem]] {
        guard maxPerRow > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: maxPerRow)
            .map { Array(items[$0..<min($0 + maxPerRow, items.count)]) }
    }
}

// MARK: 状态机（纯逻辑，可单测）

enum SelAIState: Equatable {
    case idle
    case watching(sig: String, stable: Int)
    case shown(sig: String)

    enum StepAction: Equatable { case none, hide, show }

    /// 轮询步进 reducer：
    /// - currentSig == nil（非 Notes / 无选中 / 选区塌陷）→ 隐藏并回 idle
    /// - idle → 开始观察新选区
    /// - watching 同选区 → 稳定计数 +1，达阈值（2）→ show
    /// - watching 换选区 → 重开计数
    /// - shown 选区变化 → 隐藏 + 重新观察（用户换选了别处，重新去抖弹出）
    static func step(_ s: SelAIState, currentSig: String?) -> (state: SelAIState, action: StepAction) {
        guard let sig = currentSig else {
            return s == .idle ? (.idle, .none) : (.idle, .hide)
        }
        switch s {
        case .idle:
            return (.watching(sig: sig, stable: 1), .none)
        case .watching(let old, let n):
            if old == sig {
                let n2 = n + 1
                return n2 >= 2 ? (.shown(sig: sig), .show) : (.watching(sig: sig, stable: n2), .none)
            }
            return (.watching(sig: sig, stable: 1), .none)
        case .shown(let shown):
            if shown == sig { return (s, .none) }
            return (.watching(sig: sig, stable: 1), .hide)
        }
    }
}

// MARK: - 轮询 watcher

@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()
    private var timer: Timer?
    private var state: SelAIState = .idle

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "nc.selai.enabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.selai.enabled")
    }

    var isRunning: Bool { timer != nil }

    func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NCLog.log("选中加工通道已启动（AX 轮询 0.2s，开关 = \(enabled)）")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        state = .idle
        SelectionAIPanel.shared.hide()
    }

    private func poll() {
        guard enabled else { return }
        // 用户正在面板输入框里打字（面板持 key、Notes 不在前台）：挂起轮询，避免面板被误收起
        if SelectionAIPanel.shared.panelIsKey { return }
        // 上下文里的选中区间签名：仅选区起止，不读全文（省一次 AX 取值）
        let sig: String? = NotesBridge.shared.selectionSignature()
        let (next, action) = SelAIState.step(state, currentSig: sig)
        state = next
        switch action {
        case .show:
            // 弹出时才做完整快照（文本 + 边界矩形 + 元素引用）
            guard NotesBridge.isFrontmostNotes(),
                  let snap = NotesBridge.shared.readSelectionSnapshot() else { break }
            SelectionAIPanel.shared.showMenu(for: snap)
            NCLog.log("选中加工面板弹出：选中 \(snap.text.count) 字 @\(snap.range.location)")
        case .hide:
            SelectionAIPanel.shared.hide()
        case .none:
            break
        }
    }
}

// MARK: - 悬浮面板（非激活，hover 风格）

/// 可成为 key window 的 borderless 面板：否则自定义指令输入框拿不到键盘焦点（默认 borderless canBecomeKey=false）
/// .nonactivatingPanel 保证弹出时不抢 Notes 焦点；但要输入时需应用内激活（见 ActivatingTextField）
final class SelectionKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 自定义指令输入框：非激活应用的 borderless 面板点击无法成为 key window，
/// 点击时应用内激活本应用 + makeKey + firstResponder 才能接收键盘输入
final class ActivatingTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

@MainActor
final class SelectionAIPanel: NSObject {
    static let shared = SelectionAIPanel()

    private enum Mode { case hidden, menu, working, result }

    private var panel: NSPanel?
    private var mode: Mode = .hidden
    private var snapshot: NotesBridge.SelectionSnapshot?
    private var resultText: String = ""
    private var pendingInstruction: String = ""

    // 菜单态控件
    private var actionsRow: NSStackView?
    private var customRow: NSStackView?
    private var formatRows: [NSStackView] = []
    private var customField: NSTextField?

    // 结果态控件
    private var resultView: NSTextView?
    private var resultButtons: NSStackView?
    private var statusLabel: NSTextField?
    private var spinner: NSProgressIndicator?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 面板持有键盘焦点（用户正在输入指令）：轮询暂时挂起，避免因 Notes 不在前台而收起面板
    var panelIsKey: Bool { panel?.isKeyWindow ?? false }

    func hide() {
        panel?.orderOut(nil)
        mode = .hidden
        yieldToNotes {}
    }

    /// 面板输入期间本应用是前台；交给 Notes 的动作前先把前台还给 Notes
    private func yieldToNotes(then action: @escaping () -> Void = {}) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == NotesBridge.notesBundleID {
            action()
            return
        }
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == NotesBridge.notesBundleID })?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    // MARK: 弹出菜单

    func showMenu(for snap: NotesBridge.SelectionSnapshot) {
        snapshot = snap
        resultText = ""
        let p = ensurePanel()
        guard mode == .hidden else {
            // 面板已在：选区变了，更新快照即可
            return
        }
        switchTo(.menu)
        let h = menuHeight()
        layout(size: NSSize(width: 380, height: h))
        place(below: snap.bounds, size: NSSize(width: 380, height: h))
        p.orderFront(nil)
    }

    /// 分组小标签（左列，与「格式」标签同款式）
    private static func sectionTag(_ text: String) -> NSTextField {
        let tag = NSTextField(labelWithString: text)
        tag.font = .systemFont(ofSize: 10, weight: .semibold)
        tag.textColor = .tertiaryLabelColor
        tag.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return tag
    }

    /// 菜单态面板高度：AI 行 + 自定义行 + 格式行数 × 27 + 底部余量
    private func menuHeight() -> CGFloat {
        122 + CGFloat(formatRows.count) * 27
    }

    // MARK: 加工执行

    private func run(instruction: String, actionName: String) {
        guard let snap = snapshot ?? NotesBridge.shared.readSelectionSnapshot() else { return }
        snapshot = snap
        pendingInstruction = instruction
        switchTo(.working)
        statusLabel?.stringValue = "「\(actionName)」加工中…（选中 \(snap.text.count) 字）"
        spinner?.startAnimation(nil)
        Task { @MainActor in
            do {
                let out = try await AIService.complete(instruction: instruction, context: snap.text)
                self.spinner?.stopAnimation(nil)
                self.resultText = out
                self.switchTo(.result)
                self.layout(size: NSSize(width: 440, height: 236))
                if let snap2 = self.snapshot {
                    self.place(below: snap2.bounds, size: NSSize(width: 440, height: 236))
                }
                NCLog.log("选中加工完成：「\(actionName)」→ \(out.count) 字")
            } catch {
                self.spinner?.stopAnimation(nil)
                self.resultText = ""
                self.switchTo(.result)
                self.statusLabel?.stringValue = "❌ \(error.localizedDescription)"
                NCLog.log("选中加工失败：「\(actionName)」\(error.localizedDescription)")
            }
        }
    }

    // MARK: 结果动作

    private func replaceSelection() {
        guard var snap = snapshot else { return }
        hide()
        yieldToNotes {
            // 快照可能滞后：替换前重读一次选区，若签名一致用最新引用
            if let fresh = NotesBridge.shared.readSelectionSnapshot(),
               fresh.range.location == snap.range.location, fresh.range.length == snap.range.length {
                snap = fresh
            }
            if let err = NotesBridge.shared.replaceSelection(in: snap, with: self.resultText) {
                NCLog.log("选中替换失败：\(err)")
            } else {
                NCLog.log("选中替换成功：\(self.resultText.count) 字")
            }
        }
    }

    private func appendAfter() {
        guard var snap = snapshot else { return }
        hide()
        yieldToNotes {
            if let fresh = NotesBridge.shared.readSelectionSnapshot(),
               fresh.range.location == snap.range.location, fresh.range.length == snap.range.length {
                snap = fresh
            }
            if let err = NotesBridge.shared.appendAfterSelection(in: snap, with: self.resultText) {
                NCLog.log("选中追加失败：\(err)")
            } else {
                NCLog.log("选中追加成功：\(self.resultText.count) 字")
            }
        }
    }

    private func copyResult() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resultText, forType: .string)
        statusLabel?.stringValue = "✅ 已复制到剪贴板"
    }

    // MARK: 面板构建

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = SelectionKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.canHide = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        p.contentView = effect

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        container.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            container.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -4),
            container.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])

        // 菜单态：分组行（Magpie 风格，左侧分类小标签 + 内容）
        // 行 1「AI」：快捷加工动作
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.addArrangedSubview(Self.sectionTag("AI"))
        for a in selectionQuickActions {
            let b = NSButton(title: a.name, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.onAction = { [weak self] _ in
                self?.run(instruction: a.instruction, actionName: a.name)
            }
            row.addArrangedSubview(b)
        }
        row.addArrangedSubview(NSView()) // 弹性占位
        container.addArrangedSubview(row)
        actionsRow = row

        // 行 2「自定义」：输入任意指令，⏎ 用 AI 处理选中文本
        let crow = NSStackView()
        crow.orientation = .horizontal
        crow.spacing = 6
        crow.addArrangedSubview(Self.sectionTag("自定义"))
        let field = ActivatingTextField()
        field.placeholderString = "输入指令，⏎ 执行（如：改写成邮件语气）"
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(customFieldEnter)
        field.widthAnchor.constraint(equalToConstant: 286).isActive = true
        crow.addArrangedSubview(field)
        container.addArrangedSubview(crow)
        customRow = crow
        customField = field

        // 菜单态：Notes 原生格式按钮（标题/列表/块引用…，动态枚举「格式」菜单，仅显示当前已支持的项）
        let fmtItems = NotesFormatButton.items(presenting: NotesBridge.shared.supportedFormatTitles())
        for (i, rowItems) in NotesFormatButton.splitRows(fmtItems).enumerated() {
            let frow = NSStackView()
            frow.orientation = .horizontal
            frow.spacing = 5
            if i == 0 {
                let tag = NSTextField(labelWithString: "格式")
                tag.font = .systemFont(ofSize: 10, weight: .semibold)
                tag.textColor = .tertiaryLabelColor
                frow.addArrangedSubview(tag)
            }
            for it in rowItems {
                let b = NSButton(title: it.label, target: nil, action: nil)
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.font = .systemFont(ofSize: 11, weight: .regular)
                b.onAction = { [weak self] _ in self?.applyFormat(it.menuTitle) }
                frow.addArrangedSubview(b)
            }
            container.addArrangedSubview(frow)
            formatRows.append(frow)
        }

        // 结果/加载态：状态行 + 结果文本 + 按钮行
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        container.addArrangedSubview(status)
        statusLabel = status

        let spin = NSProgressIndicator()
        spin.controlSize = .small
        spin.style = .spinning
        spin.isDisplayedWhenStopped = false
        container.addArrangedSubview(spin)
        spinner = spin

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 12)
        tv.isRichText = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(scroll)
        resultView = tv

        let btns = NSStackView()
        btns.orientation = .horizontal
        btns.spacing = 8
        let replace = NSButton(title: "替换选区", target: nil, action: nil)
        replace.keyEquivalent = "\r"
        replace.onAction = { [weak self] _ in self?.replaceSelection() }
        let append = NSButton(title: "追加到后", target: nil, action: nil)
        append.onAction = { [weak self] _ in self?.appendAfter() }
        let copy = NSButton(title: "复制", target: nil, action: nil)
        copy.onAction = { [weak self] _ in self?.copyResult() }
        let close = NSButton(title: "✕", target: nil, action: nil)
        close.bezelStyle = .texturedRounded
        close.controlSize = .small
        close.onAction = { [weak self] _ in self?.hide() }
        [replace, append, copy, NSView()].forEach { btns.addArrangedSubview($0) }
        btns.addArrangedSubview(close)
        container.addArrangedSubview(btns)
        resultButtons = btns

        panel = p
        switchTo(.menu)
        return p
    }

    @objc private func customFieldEnter() {
        let text = (customField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        customField?.stringValue = ""
        run(instruction: text, actionName: "自定义")
    }

    /// 应用 Notes 原生段落格式到当前选区：面板保持展开，方便连续叠加格式
    private func applyFormat(_ menuTitle: String) {
        yieldToNotes {
            if let err = NotesBridge.shared.applyFormat(menuTitle) {
                NCLog.log("格式「\(menuTitle)」失败：\(err)")
                self.statusLabel?.stringValue = "❌ 格式「\(menuTitle)」：\(err)"
                self.statusLabel?.isHidden = false
            } else {
                NCLog.log("格式「\(menuTitle)」已应用到选区")
            }
        }
    }

    /// 状态切换：显示/隐藏对应控件组
    private func switchTo(_ m: Mode) {
        mode = m
        let menuMode = m == .menu
        actionsRow?.isHidden = !menuMode
        customRow?.isHidden = !menuMode
        for frow in formatRows { frow.isHidden = !menuMode }
        statusLabel?.isHidden = (m == .menu)
        spinner?.isHidden = (m != .working)
        resultView?.enclosingScrollView?.isHidden = (m != .result)
        resultButtons?.isHidden = (m != .result)
        if m == .menu {
            statusLabel?.stringValue = ""
        }
        if m == .result {
            resultView?.string = resultText
            statusLabel?.stringValue = "AI 已加工 \(resultText.count) 字，可替换原选区、追加到选区后，或复制："
        }
    }

    private func layout(size: NSSize) {
        panel?.setContentSize(size)
        // 让 stack 自适应新尺寸
        if let effect = panel?.contentView,
           let container = effect.subviews.first as? NSStackView {
            container.setFrameSize(size)
        }
    }

    /// 选区矩形（Quartz 坐标）下方放置；参考 SlashSuggestPanel.place 的换算与夹取
    private func place(below qRect: CGRect, size: CGSize) {
        guard let panel else { return }
        var targetScreen = NSScreen.main ?? NSScreen.screens[0]
        if let matched = NSScreen.screens.first(where: { quartzFrame(of: $0).contains(CGPoint(x: qRect.midX, y: qRect.minY)) }) {
            targetScreen = matched
        }
        let screenQ = quartzFrame(of: targetScreen)
        let screenA = targetScreen.frame
        let localX = qRect.minX - screenQ.minX
        let localYTop = qRect.maxY - screenQ.minY
        var x = screenA.minX + localX
        var y = screenA.minY + (screenA.height - localYTop) - size.height
        // 屏幕内夹取
        if x < screenA.minX + 4 { x = screenA.minX + 4 }
        if x + size.width > screenA.maxX - 4 { x = screenA.maxX - size.width - 4 }
        if y < screenA.minY + 4 {
            // 下方放不下：选区上方
            y = screenA.minY + (screenA.height - localYTop) + qRect.height
        }
        if y + size.height > screenA.maxY - 4 { y = screenA.maxY - size.height - 4 }
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    /// NSScreen Quartz 全局 frame（左上原点），同 SlashSuggestPanel.quartzFrame
    private func quartzFrame(of s: NSScreen) -> CGRect {
        let f = s.frame
        let mainH = NSScreen.screens.first { $0.frame.minX == 0 && $0.frame.minY == 0 }?.frame.height
            ?? NSScreen.screens.map { $0.frame.height }.max() ?? f.height
        let qy = -(f.minY + f.height - mainH)
        return CGRect(x: f.minX, y: min(0, qy), width: f.width, height: f.height)
    }
}

// MARK: - NSButton 闭包 action（AppKit 无 onAction 原生支持，做一个小扩展）

private var onActionKey: UInt8 = 0
extension NSButton {
    var onAction: ((NSButton) -> Void)? {
        get { objc_getAssociatedObject(self, &onActionKey) as? (NSButton) -> Void }
        set {
            objc_setAssociatedObject(self, &onActionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            target = self
            action = newValue == nil ? nil : #selector(handleOnAction)
        }
    }
    @objc private func handleOnAction() { onAction?(self) }
}
