import AppKit
import Accessibility
import SwiftUI

// MARK: 快捷动作定义

struct SelectionQuickAction: Equatable {
    enum Group: CaseIterable {
        case edit, read

        var title: String {
            switch self {
            case .edit: return L10n.text("Edit")
            case .read: return L10n.text("Read")
            }
        }
    }

    let name: String
    let titleKey: String
    let group: Group
    let shortcut: String?
    let instruction: WritingInstruction

    var displayName: String { L10n.text(titleKey) }
}

/// 快捷加工清单：指令要求「只输出加工后的文本」，保证替换动作可直接落笔
let selectionQuickActions: [SelectionQuickAction] = [
    .init(name: "校对", titleKey: "Proofread", group: .edit, shortcut: "p", instruction: "请只修正错别字、语法和标点，保留原意、段落与语气。输出完整校对稿，无需改动时返回原文。"),
    .init(name: "润色", titleKey: "Polish", group: .edit, shortcut: "r", instruction: "请润色以下文字，使其更通顺、专业，保持原意与格式。只输出润色后的文本，不要解释。"),
    .init(name: "精简", titleKey: "Shorten", group: .edit, shortcut: "c", instruction: "请把以下内容压缩得更简洁，保留核心信息。只输出精简后的文本。"),
    .init(name: "总结", titleKey: "Summarize", group: .read, shortcut: "s", instruction: "请用简洁的要点总结以下内容的核心信息。只输出总结内容。"),
    .init(name: "翻译", titleKey: "Translate", group: .read, shortcut: "t", instruction: .translate),
    .init(name: "解释", titleKey: "Explain", group: .read, shortcut: "e", instruction: "请简要解释以下内容的关键概念与逻辑。"),
]

enum SelectionReviewKey: String {
    case original = "o", copy = "c", back = "b", generate = "g", append = "a", replace = "r", insert = "i", followUp = "f"
}

enum WritingSelection {
    case notes(NotesBridge.SelectionSnapshot)
    case input(InputFieldSelection)
    case service(String)
    case instruction

    var text: String {
        switch self {
        case .notes(let snapshot): return snapshot.text
        case .input(let snapshot): return snapshot.text
        case .service(let text): return text
        case .instruction: return ""
        }
    }

    var notesSnapshot: NotesBridge.SelectionSnapshot? {
        if case .notes(let snapshot) = self { return snapshot }
        return nil
    }
}

// MARK: Notes 原生格式菜单

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

/// A stable signature still needs a matching control and range to place a launcher.
struct SelectionPollingState {
    private(set) var state: SelAIState = .idle
    private var failedSignature: String?
    private var nextSnapshotAttempt: Date?

    init(shownSignature: String? = nil) {
        if let shownSignature { state = .shown(sig: shownSignature) }
    }

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
                // Back off on transient AX failures while tracking the same range.
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
    private let panel: SelectionAIPanel
    private let defaults: UserDefaults
    private let frontmost: () -> NSRunningApplication?
    private let browserAccess = BrowserSelectionAccess()

    init(panel: SelectionAIPanel? = nil, defaults: UserDefaults = .standard,
         frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.panel = panel ?? .shared
        self.defaults = defaults
        self.frontmost = frontmost
    }

    var isRunning: Bool { timer != nil }

    func startIfNeeded() {
        guard timer == nil, SelectionScope.isEnabled(in: defaults) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NCLog.log("选区写作工具已启动")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        browserAccess.update(for: nil)
        polling = SelectionPollingState()
        if !panel.isServiceSession { panel.hide() }
    }

    func scopeDidChange() {
        polling = SelectionPollingState()
        if !SelectionScope.allowsGlobalSelection(in: defaults) { browserAccess.update(for: nil) }
        if !panel.isSourceAllowed { panel.hide() }
    }

    private func poll() {
        guard SelectionScope.isEnabled(in: defaults) else { return }
        if !panel.isSourceAllowed { scopeDidChange() }
        if panel.writing { return }
        if panel.isStandaloneSession || panel.isServiceSession
            || (panel.hasOpenedSelection && !panel.isInputSession && panel.panelIsKey) {
            polling = SelectionPollingState()
            return
        }
        let front = frontmost()
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier && panel.hasOpenedSelection { return }
        let inNotes = front?.bundleIdentifier == NotesBridge.notesBundleID
        var anchor: TextSelectionAnchor?
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            browserAccess.update(for: SelectionScope.allowsApplication(front, in: defaults) && !inNotes && AXIsProcessTrusted() ? front : nil)
        }
        if let front, !inNotes, SelectionScope.allowsApplication(front, in: defaults) {
            // A pause halfway through a drag is not a finished selection.
            if NSEvent.pressedMouseButtons & 1 != 0 { return }
            // Hit-testing an app directly looks through other windows. Once the
            // tool has keyboard focus, Chromium can expose the same document
            // selection on a different AX node behind our menu.
            anchor = InputFieldBridge.anchor(in: front, allowPointerLookup: !panel.containsPointer)
        }
        let sig = inNotes ? NotesBridge.shared.selectionSignature() : anchor?.signature
        if panel.isWaitingAfterDismissal(in: front, candidate: anchor) {
            polling = SelectionPollingState()
            return
        }
        if let excerpt = panel.launcherExcerpt {
            if sig == excerpt.anchor.signature {
                polling = SelectionPollingState(shownSignature: excerpt.anchor.signature)
                return
            }
            if InputFieldBridge.isInSourceContext(excerpt, front: front) {
                if sig == nil || panel.containsPointer {
                    // Ignore an empty AX sample and discard any half-observed replacement.
                    polling = SelectionPollingState(shownSignature: excerpt.anchor.signature)
                    return
                }
            } else {
                panel.hide()
                polling = SelectionPollingState()
            }
        }
        // A renderer may lose focus as the tool opens. Keep its captured excerpt until
        // the user closes it or another nonempty selection survives the debounce.
        if panel.hasOpenedSelection && !panel.isObservingNewSelection(sig, candidate: anchor) {
            polling = SelectionPollingState()
            return
        }
        let action = polling.poll(currentSig: sig, now: Date()) {
            if inNotes {
                anchor = NotesBridge.shared.selectionAnchor()
            } else if var input = anchor {
                input.bounds = input.extent.bounds(in: input.element)
                anchor = input
            }
            guard let anchor, sig == anchor.signature else { return false }
            return true
        }
        switch action {
        case .show:
            if let anchor {
                panel.showLauncher(at: anchor) { [weak self] in self?.polling = SelectionPollingState() }
            }
        case .hide:
            if !panel.hasOpenedSelection && panel.launcherExcerpt == nil { panel.hide() }
        case .none:
            break
        }
    }
}

struct SelectionDiffLine: Identifiable, Equatable {
    enum Kind { case same, removed, added }
    let id = UUID()
    let kind: Kind
    let text: String
}

enum SelectionDiff {
    static func lines(original: String, result: String, limit: Int = 1000) -> [SelectionDiffLine] {
        let left = original.isEmpty ? [] : original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let right = result.isEmpty ? [] : result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard left.count <= limit, right.count <= limit else {
            return right.map { SelectionDiffLine(kind: .added, text: $0) }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lines: [SelectionDiffLine] = []
        var i = 0, j = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] {
                lines.append(SelectionDiffLine(kind: .same, text: left[i]))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(SelectionDiffLine(kind: .removed, text: left[i]))
                i += 1
            } else {
                lines.append(SelectionDiffLine(kind: .added, text: right[j]))
                j += 1
            }
        }
        while i < left.count { lines.append(SelectionDiffLine(kind: .removed, text: left[i])); i += 1 }
        while j < right.count { lines.append(SelectionDiffLine(kind: .added, text: right[j])); j += 1 }
        return lines
    }
}

// MARK: - 悬浮面板（非激活，hover 风格）

/// 请求状态与选区一起失效；迟到的完成和错误均不能更新新选区。
@MainActor
final class SelectionAIRequest {
    typealias Completion = (String, String) async throws -> String
    typealias ConversationCompletion = (String, String, [ChatMessageRecord]) async throws -> String

    private struct Prompt {
        let instruction: String
        let history: [ChatMessageRecord]
    }

    private let complete: ConversationCompletion?
    private var submittedPrompt: Prompt?
    private var answeredPrompt: Prompt?
    private var requestID: UUID?
    private var writeOperationID: UUID?
    private(set) var selection: WritingSelection?
    var snapshot: NotesBridge.SelectionSnapshot? { selection?.notesSnapshot }
    private(set) var resultText = ""
    private(set) var generatedText = ""
    private(set) var busy = false
    private(set) var lastError: String?
    private(set) var needsConfiguration = false
    private(set) var task: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(conversationCompletion: ConversationCompletion? = nil) { complete = conversationCompletion }

    convenience init(complete: @escaping Completion) {
        self.init(conversationCompletion: { instruction, context, _ in try await complete(instruction, context) })
    }

    func select(_ selection: WritingSelection) {
        cancel()
        self.selection = selection
    }

    func cancel() {
        writeOperationID = nil
        requestID = nil
        task?.cancel()
        task = nil
        selection = nil
        submittedPrompt = nil
        answeredPrompt = nil
        resultText = ""
        generatedText = ""
        lastError = nil
        needsConfiguration = false
        busy = false
    }

    func run(instruction: String, followUp: Bool = false) {
        var history: [ChatMessageRecord] = []
        if followUp, case .instruction = selection, let answeredPrompt {
            // A follow-up refers to the version the user last saw or edited.
            history = answeredPrompt.history
            history.append(ChatMessageRecord(role: "user", content: answeredPrompt.instruction))
            history.append(ChatMessageRecord(role: "assistant", content: resultText))
            history = Array(history.suffix(ChatEngine.historyMessageLimit))
        }
        submit(Prompt(instruction: instruction, history: history))
    }

    func regenerate() {
        if let submittedPrompt { submit(submittedPrompt) }
    }

    private func submit(_ prompt: Prompt) {
        guard let selection else { return }
        submittedPrompt = prompt
        writeOperationID = nil
        requestID = nil
        task?.cancel()
        task = nil
        lastError = nil
        needsConfiguration = false
        let operation: ConversationCompletion
        do {
            if let complete {
                operation = complete
            } else {
                let configuration = try AIRequestConfiguration.current()
                operation = { instruction, context, history in
                    try await AIService.complete(instruction: instruction, context: context,
                                                 contextKind: .selection, configuration: configuration, history: history)
                }
            }
        } catch {
            busy = false
            lastError = error.localizedDescription
            needsConfiguration = true
            onChange?()
            return
        }
        let id = UUID()
        requestID = id
        busy = true
        onChange?()
        task = Task { @MainActor [weak self] in
            do {
                let text = try await operation(prompt.instruction, selection.text, prompt.history)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw APIError(status: -2, message: L10n.text("The model returned no text. Try again."))
                }
                self.answeredPrompt = prompt
                self.resultText = text
                self.generatedText = text
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

    /// 手动编辑会立即使旧的写入操作失效，写入前仍会校验选区未变化。
    func editResult(_ text: String) {
        guard !busy, resultText != text else { return }
        writeOperationID = nil
        resultText = text
        onChange?()
    }

    var resultEdited: Bool { !generatedText.isEmpty && resultText != generatedText }

    /// 写入失败不消耗结果；关闭面板或切换请求后，迟到的写入回调不影响新结果。
    func writeResult(using writer: (NotesBridge.SelectionSnapshot, String, @escaping () -> Bool, @escaping (String?) -> Void) -> Void,
                     completion: @escaping (String?) -> Void) {
        guard let snapshot, !busy, !resultText.isEmpty else { return }
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

@MainActor
final class SelectionAIPanel: NSObject, ObservableObject {
    enum Phase { case launcher, menu, working, review, unavailable }

    static let shared = SelectionAIPanel()
    private let notes: NotesBridge
    private let request: SelectionAIRequest
    private let formatTitles: () -> [String]
    private let defaults: UserDefaults
    private var panel: SelectionKeyPanel?
    private var anchor: TextSelectionAnchor?
    private(set) var launcherExcerpt: InputFieldSelection?
    private var hostInputMonitor: Any?
    private var waitingForSourceGesture = false
    private var dismissedSource: (pid: pid_t, window: AXUIElement?, inputCount: UInt64)?
    private var placement = NSRect.zero
    private var returnApplication: NSRunningApplication?
    private var instructionSource: NSRunningApplication?
    private var insertionTarget: InstructionInsertionTarget?
    private var sessionID = UUID()
    private(set) var action: SelectionQuickAction?
    private(set) var formats: [NotesFormatItem] = []
    @Published private(set) var phase: Phase = .launcher
    @Published private(set) var status = ""
    @Published private(set) var writing = false
    @Published private(set) var staleSelection = false
    @Published var showingOriginal = false
    @Published var showingDiff = false
    @Published private(set) var isComposingFollowUp = false
    @Published var customInstruction = ""

    init(request: SelectionAIRequest? = nil, notes: NotesBridge = .shared, defaults: UserDefaults = .standard,
         formatTitles: (() -> [String])? = nil) {
        self.request = request ?? SelectionAIRequest()
        self.notes = notes
        self.defaults = defaults
        self.formatTitles = formatTitles ?? notes.supportedFormatTitles
        super.init()
        self.request.onChange = { [weak self] in self?.requestDidChange() }
    }

    var panelIsKey: Bool { panel?.isKeyWindow == true }
    var isServiceSession: Bool {
        if case .service = request.selection { return true }
        return false
    }
    var isInputSession: Bool {
        if case .input = anchor?.source { return true }
        return false
    }
    var isStandaloneSession: Bool {
        if case .instruction = request.selection { return true }
        return false
    }
    var isSourceAllowed: Bool {
        if let instructionSource { return allowsHost(instructionSource) }
        if case .input(let host) = anchor?.source { return allowsHost(host.application) }
        return true
    }

    private func allowsHost(_ app: NSRunningApplication) -> Bool {
        guard SelectionScope.isEnabled(in: defaults), !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        return app.bundleIdentifier == NotesBridge.notesBundleID || SelectionScope.allowsApplication(app, in: defaults)
    }

    var sourceName: String? {
        switch request.selection {
        case .notes: return "Notes"
        case .input(let field): return field.host.application.localizedName ?? L10n.text("Text Field")
        case .service: return L10n.text("Services Selection")
        case .instruction, nil: return nil
        }
    }
    var hasOpenedSelection: Bool { anchor != nil && phase != .launcher }
    var containsPointer: Bool { panel?.isVisible == true && panel?.frame.contains(NSEvent.mouseLocation) == true }
    func isObservingNewSelection(_ signature: String?, candidate: TextSelectionAnchor?) -> Bool {
        guard let signature, signature != anchor?.signature else { return false }
        // Chromium can republish a selection on a read-only ancestor when
        // the menu takes focus, including selections made in a chat composer.
        if waitingForSourceGesture, case .input(let original) = request.selection,
           case .input(let next) = candidate?.source,
           next.application.processIdentifier == original.host.application.processIdentifier,
           CFEqual(next.window, original.host.window),
           original.fieldValue == nil || !next.editable { return false }
        return true
    }
    var original: String { request.selection?.text ?? "" }
    var result: String { request.resultText }
    var resultEdited: Bool { request.resultEdited }
    var diffLines: [SelectionDiffLine] { SelectionDiff.lines(original: original, result: result) }
    var needsConfiguration: Bool { request.needsConfiguration }
    var hasNotesTarget: Bool { request.snapshot != nil }
    var hasReplacementTarget: Bool {
        if case .input(let selection) = request.selection { return selection.fieldValue != nil && isSourceAllowed }
        return hasNotesTarget
    }
    var canWrite: Bool {
        phase == .review && hasReplacementTarget && !staleSelection
            && !showingOriginal && !showingDiff && !writing && !result.isEmpty
    }

    func showLauncher(at anchor: TextSelectionAnchor, onNewDrag: @escaping () -> Void = {}) {
        if case .input(let host) = anchor.source, !allowsHost(host.application) { return }
        prepareLauncher(at: anchor, onNewDrag: onNewDrag)
        present(.launcher)
    }

    private func prepareLauncher(at anchor: TextSelectionAnchor, onNewDrag: @escaping () -> Void = {}) {
        resetSession()
        self.anchor = anchor
        placement = Self.screenRect(for: anchor.bounds)
        if case .input = anchor.source {
            launcherExcerpt = InputFieldBridge.launcherExcerpt(anchor)
            // AppKit delivers the panel's own click locally. Only a new host
            // interaction ends the pending excerpt; pointer travel and mouse-up do not.
            hostInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                guard let self else { return }
                if event.type == .leftMouseDown && self.containsPointer { return }
                if self.phase != .launcher {
                    if self.waitingForSourceGesture,
                       event.type == .leftMouseDown || event.type == .keyDown,
                       case .input(let original) = self.request.selection,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == original.host.application.processIdentifier {
                        self.waitingForSourceGesture = false
                    }
                    return
                }
                if event.type == .scrollWheel && !event.momentumPhase.isEmpty { return }
                self.hide()
                if event.type == .leftMouseDown { onNewDrag() }
            }
        }
    }

    @objc func openTools() {
        guard let anchor else { return }
        let selection: WritingSelection
        switch anchor.source {
        case .notes:
            guard let snapshot = notes.readSelectionSnapshot(allowInactiveNotes: true),
                  anchor.matches(snapshot.element, snapshot.range) else {
                status = notes.accessIssue?.message ?? L10n.text("Couldn’t verify this selection. Select the text again in Notes.")
                present(.unavailable, focus: true)
                return
            }
            selection = .notes(snapshot)
        case .input:
            guard isSourceAllowed else { hide(); return }
            guard let field = InputFieldBridge.openSelection(anchor, excerpt: launcherExcerpt) else {
                status = L10n.text("Couldn’t read the selection. Select the text again in the original app.")
                present(.unavailable, focus: true)
                return
            }
            selection = .input(field)
        }
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = L10n.text("The selection is blank. Select the text you want to work with.")
            present(.unavailable, focus: true)
            return
        }
        showMenu(for: selection)
    }

    private func showMenu(for selection: WritingSelection) {
        request.select(selection)
        if case .input = selection { waitingForSourceGesture = true }
        if case .notes = selection { formats = NotesFormatButton.items(presenting: formatTitles()) }
        status = ""
        present(.menu, focus: true)
    }

    func openStandaloneInstruction(returningTo app: NSRunningApplication? = nil) {
        resetSession()
        instructionSource = app
        insertionTarget = app.flatMap { allowsHost($0) ? InstructionInsertionTarget.capture(in: $0) : nil }
        request.select(.instruction)
        placement = Self.screenRect(for: nil)
        present(.menu, focus: true)
    }

    /// A Services request can reuse a verified live launcher. A pasteboard alone has no write target.
    @objc(openSelectionWritingTools:userData:error:)
    func openSelectionWritingTools(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = L10n.text("Select the text you want to work with first.") as NSString
            return
        }
        error?.pointee = nil
        // Bind only the selection already observed in the frontmost source. Never
        // search another document for text that happens to match the pasteboard.
        if phase == .launcher, let anchor, let front = NSWorkspace.shared.frontmostApplication {
            let target: WritingSelection?
            switch anchor.source {
            case .input(let host):
                if front.processIdentifier == host.application.processIdentifier,
                   SelectionScope.allowsApplication(front, in: defaults),
                   let field = InputFieldBridge.capture(anchor), field.fieldValue != nil {
                    target = .input(field)
                } else { target = nil }
            case .notes:
                if front.bundleIdentifier == NotesBridge.notesBundleID,
                   let snap = notes.readSelectionSnapshot(), anchor.matches(snap.element, snap.range) {
                    target = .notes(snap)
                } else { target = nil }
            }
            if let target, target.text.utf16.elementsEqual(text.utf16) {
                showMenu(for: target)
                return
            }
        }
        resetSession()
        request.select(.service(text))
        placement = Self.screenRect(for: nil)
        present(.menu, focus: true)
    }

    private func resetSession() {
        if let hostInputMonitor { NSEvent.removeMonitor(hostInputMonitor) }
        hostInputMonitor = nil
        launcherExcerpt = nil
        waitingForSourceGesture = false
        sessionID = UUID()
        request.cancel()
        anchor = nil
        returnApplication = nil
        instructionSource = nil
        insertionTarget = nil
        formats = []
        action = nil
        status = ""
        writing = false
        staleSelection = false
        showingOriginal = false
        showingDiff = false
        isComposingFollowUp = false
        customInstruction = ""
    }

    func canReceiveHostShortcut(in app: NSRunningApplication, requiresCompositionCheck: Bool = false) -> Bool {
        guard !writing, phase == .launcher || panel?.isVisible != true, allowsHost(app),
              AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        if requiresCompositionCheck && Self.chineseCandidateWindowIsAbsent() != true { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.03)
        var value: CFTypeRef?
        let focus = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        guard focus == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return focus == .noValue || (!requiresCompositionCheck && focus == .attributeUnsupported)
        }
        let field = value as! AXUIElement
        guard !AXText.isProtected(field) else { return false }
        if !requiresCompositionCheck { return !AXText.isComposing(field) }

        var marked: CFTypeRef?
        let markedStatus = AXUIElementCopyAttributeValue(field, "AXMarkedTextRange" as CFString, &marked)
        switch markedStatus {
        case .success:
            guard let marked, CFGetTypeID(marked) == AXValueGetTypeID() else { return false }
            var range = CFRange()
            return AXValueGetValue(marked as! AXValue, .cfRange, &range) && range.length == 0
        case .noValue:
            return true
        case .attributeUnsupported, .notImplemented:
            // Built-in Chinese input methods show candidates while composing in
            // standard controls, which often omit the marked-range attribute.
            // A custom or unidentified editor may have invisible composition.
            let role = AXText.attribute(field, kAXRoleAttribute) as? String
            return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXStaticTextRole,
                    kAXButtonRole, kAXWindowRole, kAXApplicationRole].contains(role ?? "")
        default:
            return false
        }
    }

    private static func chineseCandidateWindowIsAbsent() -> Bool? {
        // Inspect only WindowServer metadata. No window title, pixels, or
        // screen recording permission is needed.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let inputPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard let id = app.bundleIdentifier,
                  id == "com.apple.inputmethod.SCIM" || id == "com.apple.inputmethod.TCIM" else { return nil }
            return app.processIdentifier
        })
        return !windows.contains { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return inputPIDs.contains(owner)
        }
    }

    func openFromHostShortcut(in app: NSRunningApplication, requiresCompositionCheck: Bool = false) -> Bool {
        guard canReceiveHostShortcut(in: app, requiresCompositionCheck: requiresCompositionCheck) else { return false }
        // Resolve the live selection and focus the panel outside the event tap.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canReceiveHostShortcut(in: app, requiresCompositionCheck: requiresCompositionCheck) else { return }
            var current: TextSelectionAnchor?
            if app.bundleIdentifier == NotesBridge.notesBundleID {
                current = self.notes.selectionAnchor()
            } else if var input = InputFieldBridge.anchor(in: app) {
                input.bounds = input.extent.bounds(in: input.element)
                current = input
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            if let current {
                self.prepareLauncher(at: current)
                self.openTools()
            } else {
                self.openStandaloneInstruction(returningTo: app)
            }
        }
        return true
    }

    private static var hostInputCount: UInt64 {
        [.leftMouseDown, .rightMouseDown, .keyDown].reduce(UInt64(0)) {
            $0 + UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1))
        }
    }

    // Closing a tool leaves the source selection intact. Wait for the next
    // gesture before offering it again; retain no excerpt while dismissed.
    func dismiss() {
        var source: (pid_t, AXUIElement?, UInt64)?
        if let anchor {
            switch anchor.source {
            case .input(let host): source = (host.application.processIdentifier, host.window, Self.hostInputCount)
            case .notes:
                var pid: pid_t = 0
                if AXUIElementGetPid(anchor.element, &pid) == .success { source = (pid, nil, Self.hostInputCount) }
            }
        }
        hide()
        dismissedSource = source
    }

    func isWaitingAfterDismissal(in front: NSRunningApplication?, candidate: TextSelectionAnchor?) -> Bool {
        guard let dismissed = dismissedSource else { return false }
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        let sameWindow: Bool
        if case .input(let host) = candidate?.source, let window = dismissed.window {
            sameWindow = CFEqual(host.window, window)
        } else { sameWindow = true }
        if sameWindow && front?.processIdentifier == dismissed.pid && Self.hostInputCount == dismissed.inputCount { return true }
        dismissedSource = nil
        return false
    }

    func hide() {
        dismissedSource = nil
        let restore = panelIsKey ? returnApplication : nil
        resetSession()
        panel?.orderOut(nil)
        panel?.contentView = nil
        if let restore, !restore.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            restore.activate()
        }
    }

    private func markStale() {
        staleSelection = true
        status = L10n.text("The original selection changed. You can still copy the result.")
    }

    func run(_ action: SelectionQuickAction) {
        guard !writing, request.selection != nil else { return }
        guard isSourceAllowed else { hide(); return }
        self.action = action
        status = ""
        showingOriginal = false
        showingDiff = false
        present(.working)
        request.run(instruction: action.instruction.prompt(for: original), followUp: isComposingFollowUp)
        isComposingFollowUp = false
    }

    func runCustom() {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        run(.init(name: "自定义", titleKey: "Custom Prompt", group: .edit, shortcut: nil, instruction: .text(instruction)))
    }

    private func performToolKey(_ key: String) -> Bool {
        switch phase {
        case .menu:
            if key == SelectionKeyPanel.instructionKey { return panel?.focusInstruction() == true }
            guard !isStandaloneSession,
                  let action = selectionQuickActions.first(where: { $0.shortcut == key }) else { return false }
            run(action)
        case .review:
            guard !writing, let key = SelectionReviewKey(rawValue: key) else { return false }
            switch key {
            case .back: chooseAnotherTool()
            case .generate:
                guard action != nil else { return false }
                regenerate()
            case .followUp:
                guard isStandaloneSession, !result.isEmpty else { return false }
                beginFollowUp()
            case .insert:
                guard canInsert else { return false }
                insertResult()
            case .original, .copy:
                guard !result.isEmpty else { return false }
                if key == .original {
                    guard !isStandaloneSession else { return false }
                    showingOriginal.toggle()
                    if showingOriginal { showingDiff = false }
                } else { copyPreview() }
            case .append, .replace:
                guard canWrite else { return false }
                writeResult(append: key == .append)
            }
        default: return false
        }
        return true
    }

    func chooseAnotherTool() {
        guard !writing, let selection = request.selection else { return }
        request.select(selection)
        action = nil
        status = ""
        showingOriginal = false
        showingDiff = false
        isComposingFollowUp = false
        present(.menu)
    }

    private func requestDidChange() {
        guard !request.busy, request.selection != nil else { return }
        guard isSourceAllowed else { hide(); return }
        status = request.lastError.map {
            result.isEmpty ? $0 : L10n.format("The previous result is still available. %@", $0)
        } ?? ""
        if hasReplacementTarget && !result.isEmpty && request.lastError == nil {
            switch request.selection {
            case .notes(let target): staleSelection = notes.readNotesSnapshot().map(target.matches) != true
            case .input(let target):
                staleSelection = !InputFieldBridge.isCurrent(target)
                    && !(panelIsKey && InputFieldBridge.selectionSurvivesFocusHandoff(target))
            default: break
            }
            if staleSelection { markStale() }
        }
        present(.review)
    }

    func updateResult(_ text: String) {
        request.editResult(text)
        if request.resultEdited {
            status = L10n.text("Your edits will be used when writing the result.")
        }
        present(.review)
    }

    func showDiff() {
        showingDiff = true
        showingOriginal = false
        present(.review)
    }

    func beginFollowUp() {
        guard phase == .review, isStandaloneSession, !writing, !result.isEmpty else { return }
        customInstruction = ""
        status = ""
        isComposingFollowUp = true
        present(.menu, focus: true)
    }

    func regenerate() {
        guard phase == .review, !writing, action != nil else { return }
        guard isSourceAllowed else { hide(); return }
        status = ""
        showingOriginal = false
        showingDiff = false
        present(.working)
        request.regenerate()
    }

    var hasInsertionTarget: Bool { isStandaloneSession && insertionTarget != nil }
    var canInsert: Bool {
        hasInsertionTarget && phase == .review && !writing && !result.isEmpty && isSourceAllowed
    }

    func insertResult() {
        guard canInsert, let target = insertionTarget else { return }
        let session = sessionID
        let text = result
        writing = true
        status = ""
        panel?.orderOut(nil)
        Task { @MainActor in
            let error = await target.insert(text) {
                self.sessionID == session && self.writing && self.isSourceAllowed
            }
            guard self.sessionID == session else { return }
            self.writing = false
            if let error {
                self.insertionTarget = nil
                self.status = L10n.format("%@ You can still copy the result.", error)
                self.present(.review, focus: true)
            } else {
                self.hide()
            }
        }
    }

    func copyPreview(to pb: NSPasteboard = .general) {
        let text = showingOriginal ? original : result
        guard phase == .review, !writing, !text.isEmpty else { return }
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            status = showingOriginal ? L10n.text("Original copied") : L10n.text("Result copied")
        } else {
            status = L10n.text("Couldn’t copy. Try again.")
        }
        present(.review)
    }

    func writeResult(append: Bool) {
        guard canWrite else { return }
        writing = true
        status = ""
        if case .input(let target) = request.selection {
            let session = sessionID
            let text = result
            panel?.orderOut(nil)
            Task { @MainActor in
                let error = await InputFieldBridge.write(target, text: text, append: append) {
                    self.sessionID == session && self.writing && self.isSourceAllowed
                }
                guard self.sessionID == session else { return }
                self.writing = false
                guard let error else { self.hide(); return }
                self.staleSelection = true
                self.status = L10n.format("%@ You can still copy the result.", error)
                self.present(.review)
            }
            return
        }
        request.writeResult(using: { target, text, valid, completed in
            let end = target.range.location + target.range.length
            let range = append ? CFRange(location: end, length: 0) : target.range
            self.notes.writeWhenNotesActive(in: target, text: text, range: range, html: MarkdownDocument.html(text),
                                            isOperationValid: valid, completion: completed)
        }) { [weak self] error in
            guard let self else { return }
            self.writing = false
            guard let error else { self.hide(); return }
            if let snapshot = self.request.snapshot, self.notes.readNotesSnapshot().map(snapshot.matches) != true {
                self.markStale()
            } else {
                self.status = L10n.format("%@ Try writing again or copy the result.", error)
            }
            self.present(.review)
        }
    }

    func applyFormat(_ item: NotesFormatItem) {
        guard let target = request.snapshot, phase == .menu else { return }
        let session = sessionID
        notes.withNotesTargetActive(in: target, isOperationValid: {
            self.sessionID == session && self.phase == .menu && self.request.snapshot?.matches(target) == true
        }) { error in
            guard self.sessionID == session, self.phase == .menu, self.request.snapshot?.matches(target) == true else { return }
            self.status = error ?? self.notes.applyFormat(item.menuTitle) ?? ""
            self.present(.menu)
        }
    }

    // A key panel can receive Escape directly. For the passive chip in Notes the
    // existing Notes keyboard listener can dismiss it without activating the app.
    func dismissFromHost() -> Bool {
        guard panel?.isVisible == true, let anchor, !SlashSuggestPanel.isIMEComposing else { return false }
        switch anchor.source {
        case .notes: guard NotesBridge.isFrontmostNotes() else { return false }
        case .input(let host):
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == host.application.processIdentifier else { return false }
        }
        dismiss()
        return true
    }

    private func present(_ phase: Phase, focus: Bool = false) {
        let pendingSize = phase == .working && panel?.isVisible == true ? panel?.frame.size : nil
        if phase != .launcher { launcherExcerpt = nil }
        self.phase = phase
        let window: SelectionKeyPanel
        if let panel {
            window = panel
        } else {
            window = SelectionKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.dismiss = { [weak self] in self?.dismiss() }
            window.performToolKey = { [weak self] key in self?.performToolKey(key) == true }
            panel = window
        }

        window.title = SelectionLauncherButton.displayName
        window.acceptsKeyboard = phase != .launcher
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: placement.midX, y: placement.midY)) } ?? NSScreen.main
        let content: NSView
        let size: NSSize
        if phase == .launcher {
            content = SelectionLauncherButton(target: self, action: #selector(openTools))
            size = SelectionLauncherButton.size
        } else {
            let host = NSHostingView(rootView: SelectionToolsView(model: self, pendingSize: pendingSize, maxWidth: screen?.visibleFrame.width ?? 600))
            content = host
            size = host.fittingSize
        }
        window.setContentSize(size)
        window.contentView = content
        if let screen {
            window.setFrameOrigin(Self.origin(for: size, near: placement, within: screen.visibleFrame))
        }
        if focus {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                returnApplication = front
            }
            // Keep the host's field editor and selection active while reviewing external text.
            if !isInputSession && insertionTarget == nil { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        if phase == .menu {
            if isStandaloneSession {
                if !window.focusInstruction() {
                    let session = sessionID
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionID == session, self.phase == .menu else { return }
                        _ = self.panel?.focusInstruction()
                    }
                }
            } else {
                // Start in command mode even if AppKit initially chose the text field.
                window.makeFirstResponder(nil)
            }
        }
    }

    private static func screenRect(for quartz: CGRect?) -> NSRect {
        if let quartz, !quartz.isEmpty, let primary = NSScreen.screens.first {
            return CGRect(x: quartz.minX, y: primary.frame.maxY - quartz.maxY, width: quartz.width, height: quartz.height)
        }
        return CGRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    static func origin(for size: CGSize, near anchor: CGRect, within visible: CGRect) -> CGPoint {
        let bounds = visible.insetBy(dx: 4, dy: 4)
        let below = anchor.minY - size.height - 4
        let y = below >= bounds.minY ? below : anchor.maxY + 4
        return CGPoint(x: max(bounds.minX, min(anchor.minX, bounds.maxX - size.width)),
                       y: max(bounds.minY, min(y, bounds.maxY - size.height)))
    }
}
