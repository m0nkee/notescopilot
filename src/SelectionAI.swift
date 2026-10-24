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
            .filter { NotesBridge.formatMenuTitles(for: $0.menu).contains { set.contains($0) } }
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

/// Coordinates the real poll's cheap selection signature and fallible full
/// snapshot preparation. A show is observable only after preparation succeeds.
struct SelectionPollingState {
    private(set) var state: SelAIState = .idle
    private var failedSignature: String?
    private var nextSnapshotAttempt: Date?

    mutating func poll(currentSig: String?, now: Date, prepareShow: () -> Bool) -> SelAIState.StepAction {
        if currentSig != failedSignature {
            failedSignature = nil
            nextSnapshotAttempt = nil
        }
        if let deadline = nextSnapshotAttempt, now < deadline { return .none }
        let (next, action) = SelAIState.step(state, currentSig: currentSig)
        if action == .show, !prepareShow() {
            if let currentSig {
                state = .watching(sig: currentSig, stable: 1)
                failedSignature = currentSig
                // Permission failures must stay recoverable without retrying
                // an Apple Event on every 0.2-second selection poll.
                nextSnapshotAttempt = now.addingTimeInterval(1)
            }
            return .none
        }
        state = next
        if action == .show {
            failedSignature = nil
            nextSnapshotAttempt = nil
        }
        return action
    }
}

// MARK: - 轮询 watcher

@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()
    private var timer: Timer?
    private var polling = SelectionPollingState()

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
        polling = SelectionPollingState()
        SelectionAIPanel.shared.hide()
    }

    private func poll() {
        guard enabled else { return }
        // 用户正在面板输入框里打字（面板持 key、Notes 不在前台）：挂起轮询，避免面板被误收起
        if SelectionAIPanel.shared.panelIsKey { return }
        if SelectionAIPanel.shared.isRetainingResult { return }
        if SelectionAIPanel.shared.cancelIfTargetChanged() { polling = SelectionPollingState() }
        // 上下文里的选中区间签名：仅选区起止，不读全文（省一次 AX 取值）
        let sig: String? = NotesBridge.shared.selectionSignature()
        var preparedSnapshot: NotesBridge.SelectionSnapshot?
        let action = polling.poll(currentSig: sig, now: Date()) {
            guard NotesBridge.isFrontmostNotes(),
                  let snapshot = NotesBridge.shared.readSelectionSnapshot(),
                  sig == "\(snapshot.range.location):\(snapshot.range.length)" else { return false }
            preparedSnapshot = snapshot
            return true
        }
        switch action {
        case .show:
            // 弹出时才做完整快照（文本 + 边界矩形 + 元素引用）
            guard let snap = preparedSnapshot else { break }
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

/// 请求状态与选区一起失效；迟到的完成和错误均不能更新新选区。
@MainActor
final class SelectionAIRequest {
    typealias Completion = (String, String) async throws -> String
    private let complete: Completion?
    private var requestID: UUID?
    private var writeOperationID: UUID?
    private(set) var snapshot: NotesBridge.SelectionSnapshot?
    private(set) var resultText = ""
    private(set) var busy = false
    private(set) var lastError: String?
    private(set) var task: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(complete: Completion? = nil) { self.complete = complete }

    func select(_ snapshot: NotesBridge.SelectionSnapshot) {
        cancel()
        self.snapshot = snapshot
    }

    func cancel() {
        writeOperationID = nil
        requestID = nil
        task?.cancel()
        task = nil
        snapshot = nil
        resultText = ""
        lastError = nil
        busy = false
    }

    func run(instruction: String) {
        guard let snapshot else { return }
        writeOperationID = nil
        requestID = nil
        task?.cancel()
        task = nil
        resultText = ""
        lastError = nil
        let operation: Completion
        do {
            if let complete {
                operation = complete
            } else {
                let configuration = try AIRequestConfiguration.current()
                operation = { instruction, context in
                    try await AIService.complete(instruction: instruction, context: context, configuration: configuration)
                }
            }
        } catch {
            busy = false
            lastError = error.localizedDescription
            onChange?()
            return
        }
        let id = UUID()
        requestID = id
        busy = true
        onChange?()
        task = Task { @MainActor [weak self] in
            do {
                let text = try await operation(instruction, snapshot.text)
                guard let self, !Task.isCancelled, self.requestID == id,
                      self.snapshot?.matches(snapshot) == true else { return }
                self.resultText = text
                self.busy = false
                self.task = nil
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.lastError = error.localizedDescription
                self.busy = false
                self.task = nil
                self.onChange?()
            }
        }
    }

    /// 写入失败不消费结果；关闭面板或切换请求后，迟到的写入回调不影响新结果。
    func writeResult(using writer: (NotesBridge.SelectionSnapshot, String, @escaping () -> Bool, @escaping (String?) -> Void) -> Void,
                     completion: @escaping (String?) -> Void) {
        guard let snapshot, !resultText.isEmpty else { return }
        let result = resultText
        let id = UUID()
        writeOperationID = id
        let valid: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.writeOperationID == id && self.snapshot?.matches(snapshot) == true
                && self.resultText == result && !self.busy
        }
        writer(snapshot, result, valid) { [weak self] error in
            guard let self, valid() else { return }
            self.writeOperationID = nil
            self.lastError = error
            completion(error)
        }
    }
}

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
    private let request = SelectionAIRequest()
    private var snapshot: NotesBridge.SelectionSnapshot? { request.snapshot }
    private var resultText: String { request.resultText }

    override init() {
        super.init()
        request.onChange = { [weak self] in self?.requestDidChange() }
    }

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
    private var replaceButton: NSButton?
    private var appendButton: NSButton?
    private var copyButton: NSButton?
    private var retryButton: NSButton?
    private var closeButton: NSButton?
    private var lastInstruction: (text: String, name: String)?
    private(set) var isRetainingResult = false
    private var writing = false
    private var expandedFormats = false
    private var moreFormatsButton: NSButton?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 面板持有键盘焦点（用户正在输入指令）：轮询暂时挂起，避免因 Notes 不在前台而收起面板
    var panelIsKey: Bool { panel?.isKeyWindow ?? false }

    func hide() {
        let heldFocus = panelIsKey
        request.cancel()
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
        mode = .hidden
        isRetainingResult = false
        writing = false
        if heldFocus { yieldToNotes {} }
    }

    @discardableResult
    func cancelIfTargetChanged() -> Bool {
        if isRetainingResult { return false }
        guard let snapshot, !panelIsKey else { return false }
        guard !NotesBridge.shared.isCurrent(snapshot) else { return false }
        hide()
        return true
    }

    /// 面板输入期间本应用是前台；交给 Notes 的动作前先把前台还给 Notes
    private func yieldToNotes(then action: @escaping @MainActor () -> Void = {}) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == NotesBridge.notesBundleID {
            action()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            return
        }
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == NotesBridge.notesBundleID })?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }

    // MARK: 弹出菜单

    func showMenu(for snap: NotesBridge.SelectionSnapshot) {
        isRetainingResult = false
        writing = false
        request.select(snap)
        let p = ensurePanel()
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
        122 + CGFloat(expandedFormats ? formatRows.count : min(1, formatRows.count)) * 27
    }

    // MARK: 加工执行

    private func run(instruction: String, actionName: String) {
        guard let snap = snapshot else { return }
        lastInstruction = (instruction, actionName)
        isRetainingResult = false
        switchTo(.working)
        statusLabel?.stringValue = "「\(actionName)」加工中…（选中 \(snap.text.count) 字）"
        spinner?.startAnimation(nil)
        request.run(instruction: instruction)
    }

    private func requestDidChange() {
        guard !request.busy, let snapshot else { return }
        guard panelIsKey || NotesBridge.shared.isCurrent(snapshot) else { hide(); return }
        spinner?.stopAnimation(nil)
        switchTo(.result)
        layout(size: NSSize(width: 440, height: 236))
        place(below: snapshot.bounds, size: NSSize(width: 440, height: 236))
        if let error = request.lastError { statusLabel?.stringValue = "❌ \(error)" }
    }

    // MARK: 结果动作

    private func replaceSelection() {
        writeResult(append: false)
    }

    private func appendAfter() {
        writeResult(append: true)
    }

    private func writeResult(append: Bool) {
        guard let snap = snapshot, !resultText.isEmpty, !writing else { return }
        writing = true
        isRetainingResult = true
        updateResultButtons()
        let range = append ? CFRange(location: snap.range.location + snap.range.length, length: 0) : snap.range
        request.writeResult(using: { target, text, valid, completed in
            NotesBridge.shared.writeWhenNotesActive(in: target, text: text, range: range,
                                                    html: MarkdownDocument.html(text),
                                                    isOperationValid: valid, completion: completed)
        }) { [weak self] error in
            guard let self else { return }
            self.writing = false
            if let error {
                self.statusLabel?.stringValue = "❌ \(error) 结果已保留，可重试或复制。"
                self.updateResultButtons()
                self.panel?.orderFront(nil)
            } else {
                self.hide()
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
        for (i, rowItems) in NotesFormatButton.splitRows(fmtItems, maxPerRow: 4).enumerated() {
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
        if formatRows.count > 1, let firstRow = formatRows.first {
            let more = NSButton(title: "更多格式 ▾", target: nil, action: nil)
            more.controlSize = .small
            more.onAction = { [weak self] _ in
                guard let self else { return }
                self.expandedFormats.toggle()
                self.moreFormatsButton?.title = self.expandedFormats ? "收起 ▴" : "更多格式 ▾"
                self.switchTo(.menu)
                self.layout(size: NSSize(width: 380, height: self.menuHeight()))
            }
            firstRow.addArrangedSubview(more)
            moreFormatsButton = more
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
        replaceButton = replace
        let append = NSButton(title: "追加到后", target: nil, action: nil)
        append.onAction = { [weak self] _ in self?.appendAfter() }
        appendButton = append
        let copy = NSButton(title: "复制", target: nil, action: nil)
        copy.onAction = { [weak self] _ in self?.copyResult() }
        copyButton = copy
        let retry = NSButton(title: "重试", target: nil, action: nil)
        retry.controlSize = .small
        retry.onAction = { [weak self] _ in
            guard let self, let instruction = self.lastInstruction else { return }
            self.run(instruction: instruction.text, actionName: instruction.name)
        }
        retryButton = retry
        let close = NSButton(title: "✕", target: nil, action: nil)
        close.bezelStyle = .texturedRounded
        close.controlSize = .small
        close.onAction = { [weak self] _ in self?.hide() }
        close.keyEquivalent = "\u{1b}"
        close.toolTip = "关闭并取消当前加工"
        closeButton = close
        [replace, append, copy, retry, NSView()].forEach { btns.addArrangedSubview($0) }
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
        guard let snapshot else { return }
        yieldToNotes {
            guard NotesBridge.shared.isCurrent(snapshot) else { self.hide(); return }
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
        for (i, frow) in formatRows.enumerated() { frow.isHidden = !menuMode || (!expandedFormats && i > 0) }
        statusLabel?.isHidden = (m == .menu)
        spinner?.isHidden = (m != .working)
        resultView?.enclosingScrollView?.isHidden = (m != .result)
        resultButtons?.isHidden = (m != .result && m != .working)
        closeButton?.title = m == .working ? "取消" : "✕"
        updateResultButtons()
        if m == .menu {
            statusLabel?.stringValue = ""
        }
        if m == .result {
            resultView?.string = resultText
            statusLabel?.stringValue = "AI 已加工 \(resultText.count) 字，可替换原选区、追加到选区后，或复制："
        }
    }

    private func updateResultButtons() {
        let available = mode == .result && !resultText.isEmpty && !writing
        replaceButton?.isEnabled = available
        appendButton?.isEnabled = available
        copyButton?.isEnabled = available
        retryButton?.isHidden = mode != .result
        retryButton?.isEnabled = !writing && lastInstruction != nil
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
        return CGRect(x: f.minX, y: qy, width: f.width, height: f.height)
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
