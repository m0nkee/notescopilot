import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - 快捷动作（与斜杠命令同源的内置指令）

struct QuickAction: Identifiable {
    let id = UUID()
    let titleKey: String
    let instruction: WritingInstruction

    var title: String { L10n.text(titleKey) }
}

let quickActions: [QuickAction] = [
    QuickAction(titleKey: "Continue Writing", instruction: "请基于上文内容自然地续写下去，保持原文的风格与格式。"),
    QuickAction(titleKey: "Summarize", instruction: "请用简洁的要点总结以下内容的核心信息。"),
    QuickAction(titleKey: "Translate", instruction: .translate),
    QuickAction(titleKey: "Polish", instruction: "请润色以下文字，使其更通顺、专业，保持原意与格式。"),
    QuickAction(titleKey: "Explain", instruction: "请解释以下内容的关键概念与逻辑。"),
    QuickAction(titleKey: "Expand", instruction: "请扩展以下内容，补充细节与论据，保持原有结构。"),
    QuickAction(titleKey: "Fix Spelling", instruction: "请修复以下文字的拼写与语法错误，只输出修正后的文本，不要解释。"),
    QuickAction(titleKey: "Make Shorter", instruction: "请把以下内容压缩得更简洁，保留核心信息。"),
    QuickAction(titleKey: "Make Longer", instruction: "请把以下内容写得更丰富、有细节，保持原意。"),
]

// MARK: - 服务商预设（自配置模型的核心：任意 OpenAI 兼容端点）

struct ProviderPreset {
    let name: String
    let base: String
    let model: String

    var displayName: String { L10n.text(name) }
}

let presets: [ProviderPreset] = [
    ProviderPreset(name: "DeepSeek", base: "https://api.deepseek.com", model: "deepseek-chat"),
    ProviderPreset(name: "Kimi", base: "https://api.moonshot.cn/v1", model: "kimi-k2-turbo-preview"),
    ProviderPreset(name: "Qwen", base: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
    ProviderPreset(name: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    ProviderPreset(name: "OpenRouter", base: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
    ProviderPreset(name: "SiliconFlow", base: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-72B-Instruct"),
    ProviderPreset(name: "Ollama (Local)", base: "http://localhost:11434/v1", model: ""),
    ProviderPreset(name: "LM Studio (Local)", base: "http://localhost:1234/v1", model: ""),
]

/// 常见本地推理服务的探测点（OpenAI 兼容端点；启动时后台探测，发现后在设置页亮起）
enum LocalAIProbe {
    static let candidates: [(name: String, port: Int)] = [
        ("Ollama", 11434), ("LM Studio", 1234), ("llama.cpp", 8080), ("vLLM", 8000),
    ]

    /// 探测本机端口：连接成功且 /v1/models 返回 JSON 即视为可用（0.8s 超时，后台线程）
    static func discover(completion: @escaping (String, Int, [String]) -> Void) {
        for (name, port) in candidates {
            DispatchQueue.global(qos: .utility).async {
                guard let url = URL(string: "http://localhost:\(port)/v1/models") else { return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 1.5
                let sem = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: req) { data, resp, _ in
                    defer { sem.signal() }
                    guard (resp as? HTTPURLResponse)?.statusCode == 200,
                          let d = data,
                          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
                    let ids = (o["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                    DispatchQueue.main.async { completion(name, port, ids) }
                }.resume()
                _ = sem.wait(timeout: .now() + 2)
            }
        }
    }
}

// MARK: - 提示词输入框（NSTextView 封装，支持斜杠命令键盘导航 / ⌘⏎ 运行）

struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    var commands: () -> [SlashCommand]
    var onSuggestions: ([SlashCommand], Int?) -> Void
    var onMove: (Int) -> Void
    var onAccept: (SlashCommand) -> Void
    var onRun: () -> Void
    var onCancelSuggestions: () -> Void
    var selectedIndex: () -> Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            tv.window?.makeFirstResponder(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            context.coordinator.suggestionsDismissed = false
            context.coordinator.refreshSuggestions(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var textView: NSTextView?
        var suggestions: [SlashCommand] = []
        var active = false
        var suggestionsDismissed = false
        private var currentQuery: String?

        init(_ p: PromptTextView) {
            parent = p
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(templatesDidChange),
                                                  name: TemplateStore.notesChangedNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func templatesDidChange() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.templatesDidChange() }
                return
            }
            guard !suggestionsDismissed, let tv = textView else { return }
            refreshSuggestions(tv)
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            suggestionsDismissed = false
            refreshSuggestions(tv)
        }

        /// 检测光标处的 "/命令" token（要求斜杠前是空白或行首，避免误触 URL）
        func refreshSuggestions(_ tv: NSTextView) {
            guard let r = tv.selectedRanges.first as? NSRange?, let range = r, range.length == 0 else {
                close(); return
            }
            let s = tv.string as NSString
            let before = s.substring(to: range.location)
            guard let slashIdx = before.lastIndex(of: "/") else { close(); return }
            if slashIdx != before.startIndex {
                let prev = before[before.index(before: slashIdx)]
                guard prev == " " || prev == "\n" || prev == "\t" else { close(); return }
            }
            let token = String(before[before.index(after: slashIdx)...])
            let query = "/" + token
            let category = SlashQuery.isCategory(query)
            guard !token.contains("\n"), !token.contains("\t"),
                  category || !token.contains(where: { $0.isWhitespace }) else { close(); return }
            let filtered = SlashQuery.candidates(for: query, commands: parent.commands())
            let sameRows = suggestions.count == filtered.count && zip(suggestions, filtered).allSatisfy {
                $0.name == $1.name && $0.alias == $1.alias && $0.group == $1.group
            }
            let reset: Int? = currentQuery != query || !sameRows ? (category ? -1 : 0) : nil
            currentQuery = query
            suggestions = filtered
            active = !filtered.isEmpty
            parent.onSuggestions(filtered, reset)
        }

        private func close() {
            active = false
            currentQuery = nil
            suggestions = []
            parent.onSuggestions([], nil)
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if active && !suggestions.isEmpty {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMove(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMove(1)
                    return true
                case #selector(NSResponder.insertTab(_:)):
                    acceptCurrent()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCancelSuggestions()
                    suggestionsDismissed = true
                    active = false
                    suggestions = []
                    return true
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let e = NSApp.currentEvent, e.modifierFlags.contains(.command) {
                    parent.onRun()
                    return true
                }
                if active && !suggestions.isEmpty {
                    acceptCurrent()
                    return true
                }
            }
            return false
        }

        private func acceptCurrent() {
            let idx = parent.selectedIndex()
            guard suggestions.indices.contains(idx) else { return }
            let cmd = suggestions[idx]
            suggestionsDismissed = true
            active = false
            suggestions = []
            parent.onAccept(cmd)
        }
    }
}

// MARK: - 主面板

/// Notes diagnostics stay separate from AI errors so manual input remains usable.
struct NotesAccessNoticeView: View {
    let issue: NotesAccessIssue
    var allowsManualInput = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.message).font(.caption).textSelection(.enabled)
                if issue == .accessibilityRequired {
                    Text(L10n.text("Slash commands and selection tools in Notes are temporarily unavailable."))
                        .font(.caption2).foregroundColor(.secondary)
                }
                if allowsManualInput {
                    Text(L10n.text("You can still enter context and a task here to use AI."))
                        .font(.caption2).foregroundColor(.secondary)
                }
                if issue == .accessibilityRequired {
                    Button(L10n.text("Open Accessibility Settings")) { NotesBridge.shared.openAccessibilityPrefs() }
                        .buttonStyle(.link).font(.caption)
                } else if issue.needsAutomationSettings {
                    Button(L10n.text("Open Automation Settings")) { NotesBridge.shared.openAutomationPrefs() }
                        .buttonStyle(.link).font(.caption)
                } else {
                    Button(L10n.text("Open Notes")) {
                        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NotesBridge.notesBundleID) else { return }
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.accessIssue")
    }
}

struct PanelView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject private var localization = L10n.shared
    private let notesAccessIssueProvider: () -> NotesAccessIssue?

    init(engine: ChatEngine,
         notesAccessIssueProvider: @escaping () -> NotesAccessIssue? = { NotesBridge.shared.refreshAccessIssue() }) {
        self.engine = engine
        self.notesAccessIssueProvider = notesAccessIssueProvider
    }

    @State private var prompt = ""
    @State private var axTrusted = true
    @State private var notesAccessIssue: NotesAccessIssue?
    @State private var suggestions: [SlashCommand] = []
    @State private var selectedIdx = 0
    /// 当前生效模型配置（设置页切换后经通知实时刷新）
    @State private var activeProfileLabel = ""
    @State private var showHistory = false
    @State private var showRawOutput = false
    @State private var followOutput = true
    @State private var writingReview = false

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    contextSection
                    if showHistory { historySection }
                    promptSection
                    if suggestions.isEmpty { quickActionsRow }
                }
            }.frame(maxHeight: .infinity)
            if !suggestions.isEmpty { suggestionsMenu }
            outputSection
            if !engine.pendingResult.isEmpty { reviewBanner }
            footerBar
        }
        .padding(14)
        .environment(\.locale, localization.locale)
        .frame(minWidth: 520, minHeight: 640)
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: engine.pendingResult.isEmpty)
        .onAppear {
            refreshNotesAccess()
            activeProfileLabel = Self.profileLabel()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileStore.changedNotification).receive(on: DispatchQueue.main)) { _ in
            activeProfileLabel = Self.profileLabel()
        }
        .onChange(of: localization.language) { _ in
            activeProfileLabel = Self.profileLabel()
        }
        .onReceive(engine.$submittedPrompt.receive(on: DispatchQueue.main)) { submitted in
            prompt = submitted
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesBridge.accessChangedNotification, object: NotesBridge.shared).receive(on: DispatchQueue.main)) { _ in
            refreshNotesAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: DispatchQueue.main)) { _ in
            refreshNotesAccess()
        }
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            var got = false
            for p in providers {
                p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { engine.addImage(img) }
                    }
                }
                got = true
            }
            return got
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("NotesCopilot").font(.headline)
                Spacer()
                Button { engine.beginSession() } label: { Label(L10n.text("New Chat"), systemImage: "square.and.pencil") }
                    .controlSize(.small)
                Button { showHistory.toggle() } label: {
                    Label(L10n.format("History (%lld)", engine.history.count / 2), systemImage: "clock")
                }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(activeProfileLabel.isEmpty ? L10n.text("No model configured") : activeProfileLabel)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Toggle(L10n.text("Keep chat context"), isOn: $engine.continuous).toggleStyle(.switch).controlSize(.mini)
            }
            if let notice = engine.sessionNotice {
                Text(notice).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Continued chats include the last 6 turns. Changing the note source or model profile starts a new chat."))
                .font(.caption2).foregroundColor(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(engine.history.enumerated()), id: \.offset) { _, message in
                        let assistant = message["role"] as? String == "assistant"
                        let content = ChatEngine.historyDisplayContent(message)
                        DisclosureGroup(assistant ? L10n.text("AI response") : L10n.text("My task")) {
                            if assistant { MarkdownPreview(text: content) }
                            else { Text(content).font(.caption).textSelection(.enabled) }
                        }.font(.caption)
                    }
                    if engine.history.isEmpty { Text(L10n.text("No completed exchanges in this chat")).font(.caption).foregroundColor(.secondary) }
                }
            }.frame(maxHeight: 160)
        }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refreshContext() {
        let target = NotesBridge.shared.readNotesSnapshot()
        let context = target.flatMap { NotesBridge.context(in: $0) }
        engine.setContext(context?.text ?? "", source: context?.source ?? "", noteID: target?.noteID)
        refreshNotesAccess()
    }

    private func refreshNotesAccess() {
        notesAccessIssue = notesAccessIssueProvider()
        axTrusted = notesAccessIssue != .accessibilityRequired
    }
    // MARK: 笔记上下文

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L10n.text("Note context"))
                    .font(.caption).foregroundColor(.secondary)
                if !engine.noteContext.isEmpty, !engine.contextSource.isEmpty {
                    Text(engine.contextSourceLabel)
                        .font(.caption2).foregroundColor(.purple)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.12)))
                }
                Spacer()
                Button(L10n.text("Refresh"), action: refreshContext).buttonStyle(.link).font(.caption)
                Button(L10n.text("Clear")) { engine.setContext("", source: "") }.buttonStyle(.link).font(.caption)
            }
            if let issue = notesAccessIssue {
                NotesAccessNoticeView(issue: issue, allowsManualInput: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { engine.noteContext }, set: { engine.setContext($0, source: "手动输入") }))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .opacity(engine.noteContext.isEmpty ? 0.6 : 1)
                if engine.noteContext.isEmpty {
                    Text(L10n.text("Select text or place the cursor in Notes, then press ⇧⌘Space to capture context. You can also type it here."))
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: 斜杠命令建议菜单

    private var suggestionsMenu: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, cmd in
                        HStack(spacing: 8) {
                            Text(cmd.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(cmd.alias.isEmpty ? L10n.text("Templates") : "/" + cmd.alias)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.purple)
                                .frame(minWidth: 70, alignment: .leading)
                            Text(cmd.detail)
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(i == selectedIdx ? Color.accentColor.opacity(0.25) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { perform(cmd) }
                        .id(i)
                    }
                }
            }
            .frame(height: min(140, CGFloat(suggestions.count) * 28))
            .onChange(of: selectedIdx) { index in
                guard suggestions.indices.contains(index) else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    // MARK: 提示词输入 + 图片

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Task · ⌘↩ Generate")).font(.caption).foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                PromptTextView(text: $prompt,
                               commands: { buildSlashCommands() },
                               onSuggestions: { list, reset in
                                   suggestions = list
                                   if let reset { selectedIdx = reset }
                               },
                               onMove: { delta in
                                   guard !suggestions.isEmpty else { return }
                                   selectedIdx = selectedIdx < 0 ? (delta > 0 ? 0 : suggestions.count - 1)
                                       : (selectedIdx + delta + suggestions.count) % suggestions.count
                               },
                               onAccept: { cmd in perform(cmd) },
                               onRun: {
                                   suggestions = []
                                   engine.run(prompt: prompt)
                               },
                               onCancelSuggestions: { suggestions = [] },
                               selectedIndex: { selectedIdx })
                    .frame(height: 64)
                    .accessibilityLabel(L10n.text("Writing task"))
                    if prompt.isEmpty {
                        Text(L10n.text("Enter a task or type / to see commands"))
                            .font(.caption).foregroundColor(.secondary).padding(8).allowsHitTesting(false)
                    }
                }.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                VStack(spacing: 6) {
                    Button {
                        suggestions = []
                        engine.run(prompt: prompt)
                    } label: {
                        Label(engine.busy ? L10n.text("Generating…") : L10n.text("Generate"), systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(engine.busy ||
                              prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if engine.busy {
                        Button(L10n.text("Stop")) { engine.stop() }
                            .controlSize(.small)
                    } else {
                        Button {
                            addImage()
                        } label: {
                            Image(systemName: "photo")
                        }
                        .controlSize(.small)
                        .help(L10n.text("Attach an image or drag it into the panel to include it in the request."))
                    }
                }
            }
            if !engine.images.isEmpty { imagesStrip }
        }
    }

    private var imagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(engine.images) { img in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button {
                            engine.images.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(2)
        }
        .frame(height: 50)
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for u in panel.urls {
                if let img = NSImage(contentsOf: u) { engine.addImage(img) }
            }
        }
    }

    // MARK: 快捷动作

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickActions) { qa in
                    Button(qa.title) {
                        suggestions = []
                        run(qa.instruction)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(engine.busy)
                }
            }
        }
    }

    // MARK: AI 结果 review 横幅（斜杠命令完成后确认再写回，防误写）

    private var reviewHasSelection: Bool { (engine.pendingTarget?.range.length ?? 0) > 0 }

    private var reviewBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.purple)
                Text(L10n.text("Review the AI result before writing it to Notes"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    engine.dismissReview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Discard Result"))
            }
            HStack(spacing: 8) {
                Button {
                    guard let target = engine.pendingTarget, let reviewID = engine.pendingReviewID else { return }
                    let result = engine.pendingResult
                    writingReview = true
                    NotesBridge.shared.writeWhenNotesActive(in: target, text: result, html: MarkdownDocument.html(result),
                                                           isOperationValid: { engine.pendingReviewID == reviewID }) { error in
                        writingReview = false
                        guard engine.pendingReviewID == reviewID else { return }
                        if let error {
                            engine.lastError = error
                        } else if engine.pendingResult == result,
                                  engine.pendingTarget?.matches(target) == true {
                            engine.dismissReview()
                        }
                    }
                } label: {
                    Label(reviewHasSelection ? L10n.text("Replace Selection") : L10n.text("Insert at Cursor"),
                          systemImage: reviewHasSelection ? "arrow.triangle.2.circlepath" : "square.and.arrow.down.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .disabled(engine.pendingTarget == nil || writingReview)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(engine.pendingResult, forType: .string)
                    engine.dismissReview()
                } label: {
                    Label(L10n.text("Copy"), systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.purple.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1))
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 输出区

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(engine.responseStatus.isEmpty ? L10n.text("Result") : engine.responseStatus)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle(L10n.text("Follow Output"), isOn: $followOutput).toggleStyle(.checkbox).font(.caption2)
                Picker(L10n.text("Display Mode"), selection: $showRawOutput) {
                    Text(L10n.text("Preview")).tag(false)
                    Text(L10n.text("Raw")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if engine.output.isEmpty {
                            Text(L10n.text("Enter a task to start writing, or type / to choose a command."))
                                .font(.callout).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if showRawOutput {
                            Text(engine.output).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownPreview(text: engine.output)
                        }
                        Color.clear.frame(height: 1).id("outputBottom")
                    }.padding(12)
                }
                .onChange(of: engine.output) { _ in
                    if followOutput && engine.busy { proxy.scrollTo("outputBottom", anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            .overlay(alignment: .topTrailing) { if engine.busy { ProgressView().controlSize(.small).padding(8) } }
            .frame(minHeight: 120, maxHeight: .infinity)
            if !engine.busy && (engine.canRetry || engine.canContinue) {
                HStack {
                    if engine.canRetry { Button(L10n.text("Regenerate")) { engine.retryLastRequest() } }
                    if engine.canContinue { Button(L10n.text("Continue Generating")) { engine.continueLastResponse() } }
                }.controlSize(.small)
            }
        }.frame(maxHeight: .infinity)
    }

    // MARK: 底栏（结果操作 + token 用量）

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    let generation = engine.operationGeneration
                    NotesBridge.shared.insertIntoNotes(engine.output, html: MarkdownDocument.html(engine.output),
                                                       isOperationValid: { engine.operationGeneration == generation }) { error in
                        guard engine.operationGeneration == generation else { return }
                        engine.lastError = error
                    }
                } label: {
                    Label(L10n.text("Insert into Notes"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(engine.output.isEmpty || engine.busy)
                Button(L10n.text("Copy")) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(engine.output, forType: .string)
                }
                .disabled(engine.output.isEmpty || engine.busy)
                Button {
                    if let err = NotesBridge.shared.createNewNote(engine.output, html: MarkdownDocument.html(engine.output)) {
                        engine.lastError = err
                    }
                } label: {
                    Label(L10n.text("Save as New Note"), systemImage: "doc.badge.plus")
                }
                .disabled(engine.output.isEmpty || engine.busy)
                Spacer()
                if !axTrusted {
                    Button(L10n.text("Grant Accessibility Access")) { NotesBridge.shared.requestTrust() }
                        .buttonStyle(.link)
                        .foregroundColor(.orange)
                }
                Button {
                    NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.link)
            }
            HStack {
                if let err = engine.lastError {
                    ScrollView {
                        Text(err).font(.caption).foregroundColor(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 56)
                }
                Spacer()
                if engine.promptTokens > 0 || engine.totalPromptTokens > 0 {
                    let estimated = engine.tokensEstimated ? "≈" : ""
                    Text(L10n.format("Input %lld%@ · Output %lld%@ tokens | Total %lld/%lld",
                                     engine.promptTokens, estimated, engine.completionTokens, estimated,
                                     engine.totalPromptTokens, engine.totalCompletionTokens))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 斜杠命令执行

    /// 生效配置标签："名称 · 模型"（无配置时为空）
    fileprivate static func profileLabel() -> String {
        guard let p = Config.activeProfile else { return "" }
        let name = p.name.isEmpty ? L10n.text("Untitled") : p.name
        let model = p.model.isEmpty ? L10n.text("No model configured") : p.model
        return name + " · " + model
    }

    private func run(_ instruction: WritingInstruction) {
        prompt = instruction.prompt(for: engine.noteContext)
        engine.run(prompt: prompt)
    }

    private func perform(_ cmd: SlashCommand) {
        suggestions = []
        switch cmd.action {
        case .run(let instruction):
            run(instruction)
        case .fill(let p):
            prompt = p
        case .clearContext:
            engine.setContext("", source: "")
        case .newSession:
            engine.beginSession()
        case .insertOutput:
            let generation = engine.operationGeneration
            NotesBridge.shared.insertIntoNotes(engine.output, html: MarkdownDocument.html(engine.output),
                                               isOperationValid: { engine.operationGeneration == generation }) { error in
                guard engine.operationGeneration == generation else { return }
                engine.lastError = error
            }
        case .saveAsNote:
            if let err = NotesBridge.shared.createNewNote(engine.output, html: MarkdownDocument.html(engine.output)) {
                engine.lastError = err
            }
        case .openSettings:
            NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
        case .format(let style):
            guard let target = NotesBridge.shared.readNotesSnapshot() else {
                engine.lastError = L10n.text("Return to Notes and select the text you want to format.")
                return
            }
            NotesBridge.shared.withNotesTargetActive(in: target) { error in
                if let error { engine.lastError = error }
                else if !FormatBridge.trigger(style) { engine.lastError = L10n.text("This format is unavailable in the current Notes menu.") }
            }
        case .stopGeneration:
            engine.stop()
        case .insertTemplate(let tpl):
            // 模板：变量引擎展开（{{selection}} 取面板笔记上下文）后插入 Notes
            guard let target = NotesBridge.shared.readNotesSnapshot() else {
                engine.lastError = L10n.text("The original cursor position could not be found. Return to the note and try again.")
                return
            }
            engine.stop()
            let generation = engine.operationGeneration
            TemplateRunner.runRich(tpl, selection: engine.noteContext,
                               isOperationValid: { engine.operationGeneration == generation }) { text, html in
                NotesBridge.shared.writeWhenNotesActive(in: target, text: text, html: html,
                                                       isOperationValid: { engine.operationGeneration == generation }) { error in
                    guard engine.operationGeneration == generation else { return }
                    if let error { engine.lastError = error }
                }
            } onError: { msg in
                guard engine.operationGeneration == generation else { return }
                engine.lastError = msg
            }
        }
    }
}

// MARK: - 设置视图

// MARK: - 设置页（Magpie/WinUI 风格：左侧导航 + 右侧圆角卡片内容区）

/// 设置页导航项（同 Magpie 的 NavigationView 左侧栏）
enum SettingsPage: String, CaseIterable, Identifiable {
    case model, generation, prompt, markdown, templates, expansion, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: return L10n.text("Model Profiles")
        case .generation: return L10n.text("Generation")
        case .prompt: return L10n.text("System Prompt")
        case .markdown: return L10n.text("Markdown Shortcuts")
        case .templates: return L10n.text("Templates")
        case .expansion: return L10n.text("Commands & Expansion")
        case .general: return L10n.text("General & Diagnostics")
        }
    }

    var subtitle: String {
        switch self {
        case .model: return L10n.text("Save cloud and local model profiles. Select the circle on a profile card to make it active.")
        case .generation: return L10n.text("Sampling temperature, reasoning effort, and output length")
        case .prompt: return L10n.text("Define the AI's role for each request")
        case .markdown: return L10n.text("In Notes, type #, ##, [], >, ```, -, *, or 1. followed by a space to apply formatting.")
        case .templates: return L10n.text("Type / in the prompt field to insert a template.")
        case .expansion: return L10n.text("Choose where writing tools appear and manage slash commands and keyword expansion.")
        case .general: return L10n.text("Interface language, updates, launch at login, permissions, and connection checks")
        }
    }

    var icon: String {
        switch self {
        case .model: return "cpu"
        case .generation: return "slider.horizontal.3"
        case .prompt: return "text.bubble"
        case .markdown: return "number"
        case .templates: return "doc.on.doc"
        case .expansion: return "keyboard"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var updater: AppUpdater
    @ObservedObject private var localization = L10n.shared
    private let discoverLocalModels: Bool
    private let notesAccessIssueProvider: () -> NotesAccessIssue?
    init(discoverLocalModels: Bool = true,
         notesAccessIssueProvider: @escaping () -> NotesAccessIssue? = { NotesBridge.shared.refreshAccessIssue() },
         initialPage: SettingsPage = .model,
         updater: AppUpdater? = nil) {
        self.updater = updater ?? .shared
        self.discoverLocalModels = discoverLocalModels
        self.notesAccessIssueProvider = notesAccessIssueProvider
        _page = State(initialValue: initialPage)
    }
    // 多配置模型：可保存多份（不同服务商/本地），点选其一作为生效配置
    @State private var profiles: [ModelProfile] = ProfileStore.load()
    @State private var activeID: UUID? = ProfileStore.activeID
    /// 每份配置拉取到的模型列表（id → models）
    @State private var modelsByProfile: [UUID: [String]] = [:]
    @State private var fetchingID: UUID?
    @State private var modelFetchGeneration = UUID()
    /// 展开编辑中的配置卡
    @State private var expandedIDs: Set<UUID> = []
    /// 本地推理服务探测结果（服务名 → 模型列表）
    @State private var localServices: [(name: String, port: Int, models: [String])] = []
    @AppStorage("nc.sys") private var systemPrompt = Config.defaultSystem
    @AppStorage("nc.temp") private var temperature = 0.7
    @AppStorage("nc.maxTokens") private var maxTokens = 2048
    @State private var statusText = ""
    @State private var lastSavedProfiles: [ModelProfile]?
    @State private var profileSaveTask: Task<Void, Never>?
    @State private var pendingDeleteID: UUID?

    // 模板与文本扩展
    @State private var templates: [TemplateNote] = TemplateStore.templates
    @State private var notesTemplates: [TemplateNote] = TemplateStore.notesTemplates
    @State private var notesTemplatesLoading = false
    @State private var notesTemplatesReady = false
    @State private var notesTemplatesError: String?
    @State private var rules: [KeywordRule] = KeywordStore.rules
    @State private var kwEnabled = UserDefaults.standard.bool(forKey: "nc.kw.enabled")
    @State private var slashGlobal = UserDefaults.standard.object(forKey: "nc.slash.global") == nil
        ? true : UserDefaults.standard.bool(forKey: "nc.slash.global")
    @State private var selAIEnabled = SelectionScope.isEnabled()
    @AppStorage(SelectionScope.defaultsKey) private var selectionScope = SelectionScope.notes
    @AppStorage(SelectionScope.pausedKey) private var selectionPaused = false
    @AppStorage(SelectionScope.PrivacyMode.defaultsKey) private var selectionPrivacyMode = SelectionScope.PrivacyMode.blocklist
    @State private var selectionPrivacyApps: [String] = SelectionScope.privacyApps()
    @State private var privacyAppChoices: [String] = []
    @State private var selectedPrivacyApp = ""
    @State private var manualPrivacyApp = ""
    @State private var newTplName = ""
    @State private var newTplContent = ""
    @State private var customAICommands: [CustomAICommand] = CustomAICommandStore.commands
    @State private var newAICommandName = ""
    @State private var newAICommandPrompt = ""
    @State private var newAICommandError: String?
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var kwStatus: KeywordListener.Status?
    // 行首 Markdown 开关（对应 ProNotes 的 expandMarkdown* 证据）
    @AppStorage("nc.md.enabled") private var mdEnabled = true
    @AppStorage("nc.md.headers") private var mdHeaders = true
    @AppStorage("nc.md.checklists") private var mdChecklists = true
    @AppStorage("nc.md.quote") private var mdQuote = true
    @AppStorage("nc.md.monostyled") private var mdMonostyled = true
    @AppStorage("nc.md.dashed") private var mdDashed = true
    @AppStorage("nc.md.bulleted") private var mdBulleted = true
    @AppStorage("nc.md.numbered") private var mdNumbered = true
    @AppStorage("nc.urltitle.enabled") private var urlTitleEnabled = true
    @State private var launchAtLogin = false
    @State private var changingLaunchAtLogin = false
    @State private var testingModel = false
    @State private var axAuthorized = false
    @State private var keyboardRunning = false
    @State private var notesAccessIssue: NotesAccessIssue?
    /// 当前导航页（Magpie 左侧导航）
    @State private var page: SettingsPage = .model

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(Color.primary.opacity(0.08))
            settingsDetail
        }
        .frame(minWidth: 900, minHeight: 620)
        .environment(\.locale, localization.locale)
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.kwStatus")).receive(on: DispatchQueue.main)) { n in
            kwStatus = n.object as? KeywordListener.Status
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileStore.errorNotification).receive(on: DispatchQueue.main)) { note in
            statusText = note.object as? String ?? L10n.text("Could not save the profile. Check its settings.")
        }
        .onReceive(NotificationCenter.default.publisher(for: TemplateStore.notesChangedNotification).receive(on: DispatchQueue.main)) { _ in
            refreshNotesTemplatesStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeAvailable")).receive(on: DispatchQueue.main)) { _ in
            refreshNotesTemplatesStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesBridge.accessChangedNotification, object: NotesBridge.shared).receive(on: DispatchQueue.main)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: DispatchQueue.main)) { _ in
            refreshPrivacyAppChoices()
            refreshPermissionStatus()
        }
        .onDisappear {
            profileSaveTask?.cancel()
            saveProfilesNow()
        }
        .onAppear {
            lastSavedProfiles = profiles
            refreshPrivacyAppChoices()
            refreshPermissionStatus()
            refreshNotesTemplatesStatus()
            if let error = ProfileStore.lastError { statusText = error }
        }
        .onChange(of: profiles) { _ in
            scheduleProfileSave()
        }
        .onChange(of: activeID) { id in
            ProfileStore.activeID = id
            updateActiveStatus()
        }
        .onChange(of: templates) { TemplateStore.templates = $0 }
        .onChange(of: customAICommands) { CustomAICommandStore.commands = $0 }
        .onChange(of: rules) { KeywordStore.rules = $0 }
        .onChange(of: kwEnabled) { on in
            UserDefaults.standard.set(on, forKey: "nc.kw.enabled")
            KeywordListener.shared.restart()
        }
        .onChange(of: slashGlobal) { on in
            UserDefaults.standard.set(on, forKey: "nc.slash.global")
            KeywordListener.shared.restart()
        }
        .onChange(of: selAIEnabled) { on in
            UserDefaults.standard.set(on, forKey: SelectionScope.enabledKey)
            KeywordListener.shared.restart()
            if on {
                SelectionWatcher.shared.startIfNeeded()
            } else {
                SelectionWatcher.shared.stop()
            }
        }
        .onChange(of: selectionScope) { _ in SelectionWatcher.shared.scopeDidChange() }
        .onChange(of: selectionPaused) { _ in
            UserDefaults.standard.set(selectionPaused, forKey: SelectionScope.pausedKey)
            SelectionWatcher.shared.scopeDidChange()
        }
        .onChange(of: selectionPrivacyMode) { mode in
            UserDefaults.standard.set(mode.rawValue, forKey: SelectionScope.PrivacyMode.defaultsKey)
            SelectionWatcher.shared.scopeDidChange()
        }
        .onChange(of: selectionPrivacyApps) { apps in
            UserDefaults.standard.set(apps, forKey: SelectionScope.privacyAppsKey)
            SelectionWatcher.shared.scopeDidChange()
        }
    }

    /// ── 左侧导航（Magpie NavigationView 自绘：选中项 accent 胶囊高亮）──
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.text("NotesCopilot Settings"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ForEach(SettingsPage.allCases) { p in
                Button {
                    page = p
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                            .foregroundStyle(page == p ? Color.accentColor : Color.secondary)
                        Text(p.title)
                            .font(.system(size: 13, weight: page == p ? .semibold : .regular))
                            .foregroundColor(.primary.opacity(0.9))
                        Spacer(minLength: 0)
                        if page == p {
                            Capsule().fill(Color.accentColor).frame(width: 3, height: 14)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(page == p ? Color.accentColor.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Divider().padding(.bottom, 2)
                Button {
                    (NSApp.delegate as? AppDelegate)?.showPanel()
                } label: {
                    Label(L10n.text("Open AI Panel"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("settings.openAIPanel")
                Button {
                    (NSApp.delegate as? AppDelegate)?.showLibrary()
                } label: {
                    Label(L10n.text("Note Library"), systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settings.openLibrary")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            Button {
                page = .general
                Task { await updater.check() }
            } label: {
                Label(updater.isChecking ? L10n.text("Checking…") : L10n.text("Check for Updates"),
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(updater.isChecking)
            .accessibilityIdentifier("settings.checkForUpdates")
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            if let release = updater.availableRelease {
                if updater.isDownloading {
                    Button(L10n.text("Cancel Download")) { updater.cancelDownload() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                    if let progress = updater.downloadProgress {
                        ProgressView(value: progress)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                    }
                } else {
                    Button(L10n.format("Download v%@", release.version)) {
                        Task { @MainActor in
                            guard let fileURL = await updater.download() else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                if let notes = release.alertNotes {
                    Text(notes)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
                if !updater.downloadStatusMessage.isEmpty {
                    Text(updater.downloadStatusMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            Text("v\(updater.currentVersion.isEmpty ? "-" : updater.currentVersion)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 196, alignment: .topLeading)
    }

    /// ── 右侧内容区：页头 + InfoBar 状态条 + 分页卡片 ──
    private var settingsDetail: some View {
        VStack(spacing: 0) {
            if page == .model {
                profileSaveBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    pageHeader
                    if !statusText.isEmpty { infoBar }
                    pageContent
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var profileSaveStatus: (text: String, icon: String, color: Color) {
        guard let saved = lastSavedProfiles else { return (L10n.text("Loading profiles…"), "ellipsis.circle", .secondary) }
        if profiles != saved { return (L10n.text("Unsaved changes"), "circle.fill", .orange) }
        if profiles.isEmpty { return (L10n.text("No model profiles"), "tray", .secondary) }
        return (L10n.text("Saved"), "checkmark.circle.fill", .green)
    }

    /// Keep the explicit save action reachable while the model list scrolls.
    private var profileSaveBar: some View {
        let status = profileSaveStatus
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Label(status.text, systemImage: status.icon)
                    .font(.callout)
                    .foregroundColor(status.color)
                    .accessibilityIdentifier("settings.profileSaveStatus")
                Text(L10n.text("Changes are saved automatically. You can also save them manually."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button { saveProfilesNow() } label: {
                Label(L10n.text("Save Profiles"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("settings.saveProfiles")
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(page.title).font(.system(size: 20, weight: .bold))
            Text(page.subtitle).font(.callout).foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// Magpie InfoBar 样式状态条
    private var infoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(statusText).font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                statusText = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .model: modelPage
        case .generation: generationPage
        case .prompt: promptPage
        case .markdown: markdownPage
        case .templates: templatesPage
        case .expansion: expansionPage
        case .general: generalPage
        }
    }

    /// Magpie 风格卡片：图标 + 标题 + 说明 + 内容，圆角 8、细描边、白色底
    private func card<Content: View>(_ icon: String, _ title: String,
                                     note: String = "",
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if !note.isEmpty {
                        Text(note).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    // MARK: 模型配置页（多份，点左侧圆圈切换生效）

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profiles.isEmpty {
                onboardingCard
            }
            card("checkmark.seal", L10n.text("Active Profile")) {
                activeStatusRow
            }
            ForEach($profiles) { $p in
                profileCard($p)
            }
            if profiles.isEmpty {
                Label(L10n.text("Use Quick Add below or create a profile manually."), systemImage: "tray")
                    .font(.callout).foregroundColor(.orange)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            }
            card("plus.circle", L10n.text("Quick Add"), note: L10n.text("Cloud presets, local servers, and manual setup")) {
                quickAddRow
            }
        }
        .confirmationDialog(L10n.text("Delete this model profile?"), isPresented: pendingDeleteBinding, titleVisibility: .visible) {
            Button(L10n.text("Delete Model Profile"), role: .destructive) {
                if let id = pendingDeleteID { performDelete(id) }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text(L10n.text("This permanently removes the base URL, model, and parameters, including unsaved changes."))
        }
        .onAppear {
            guard discoverLocalModels, localServices.isEmpty else { return }
            LocalAIProbe.discover { name, port, ids in
                if !localServices.contains(where: { $0.port == port }) {
                    localServices.append((name, port, ids))
                }
            }
        }
    }

    private var onboardingCard: some View {
        card("sparkles", L10n.text("Getting Started"), note: L10n.text("You can skip any step. Grant access for the features you use.")) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("1. Add a cloud preset or local server, or enter a base URL and model name."), systemImage: "1.circle")
                Label(L10n.text("2. Enter your cloud API key or confirm your local server address. Profiles are saved on this Mac."), systemImage: "2.circle")
                HStack {
                    Label(L10n.text("3. Test generation with a short request to verify your endpoint, credentials, and parameters."), systemImage: "3.circle")
                    Spacer()
                    Button(testingModel ? L10n.text("Testing…") : L10n.text("Test Now")) { testActiveModel() }
                        .controlSize(.small)
                        .disabled(testingModel)
                }
                HStack {
                    Label(L10n.text("4. Grant Accessibility and Automation access for Notes. Enable global selection tools to use them in other apps."), systemImage: "4.circle")
                    Spacer()
                    Button(L10n.text("View Permissions")) { page = .general }
                        .controlSize(.small)
                }
                Text(L10n.text("Slash commands and the selection button require Accessibility access. Notes Automation access lets you write results back to Notes. The note library and Notes templates require Full Disk Access."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// 快速添加：云端预设 + 本地探测到的推理服务 + 手动新建
    private var quickAddRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.name) { p in
                    Button {
                        let prof = ModelProfile(name: p.displayName, baseURL: p.base,
                                                apiKey: "", model: p.model)
                        appendProfile(prof, active: profiles.isEmpty)
                        page = .model
                        statusText = L10n.format("%@ preset added. Expand the card to enter an API key.", p.displayName)
                    } label: {
                        Label(p.displayName, systemImage: "plus")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                ForEach(localServices, id: \.port) { svc in
                    if !profiles.contains(where: { $0.baseURL.contains("localhost:\(svc.port)") }) {
                        Button {
                            let prof = ModelProfile(name: L10n.format("%@ (Local)", svc.name),
                                                    baseURL: "http://localhost:\(svc.port)/v1",
                                                    apiKey: "",
                                                    model: svc.models.first ?? "")
                            appendProfile(prof, active: true)
                            modelsByProfile[prof.id] = svc.models
                            let added = L10n.format("%@ is now active and requires no API key.", svc.name)
                            statusText = svc.models.isEmpty ? added : added + " " + L10n.format(
                                "Models available: %lld", svc.models.count)
                        } label: {
                            Label(svc.name, systemImage: "cpu")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(.green)
                    }
                }
                Button {
                    appendProfile(ModelProfile(name: L10n.text("New Profile")), active: profiles.isEmpty)
                    if let id = profiles.last?.id { expandedIDs.insert(id) }
                    statusText = L10n.text("Profile created. Expand it to enter your endpoint and model.")
                } label: {
                    Label(L10n.text("Create Manually"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// 生效状态行：一眼看出当前用的是哪份配置
    @ViewBuilder private var activeStatusRow: some View {
        if let active = profiles.first(where: { $0.id == activeID }) ?? profiles.first {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green).font(.caption)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("Active: %@ | %@ | %@",
                                     active.name.isEmpty ? L10n.text("Untitled") : active.name,
                                     active.baseURL,
                                     active.model.isEmpty ? L10n.text("No model name") : active.model))
                        .font(.caption).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } else {
            Text(L10n.text("Select a model profile to use AI features."))
                .font(.caption).foregroundColor(.orange)
        }
    }

    /// 单份配置卡：头部＝圆圈单选 + 名称 + 摘要 + 展开箭头；
    /// 展开区＝带标签的字段栅格（Base URL / API Key / 模型），编辑体验优先
    private func profileCard(_ binding: Binding<ModelProfile>) -> some View {
        let p = binding.wrappedValue
        let isActive = p.id == (activeID ?? profiles.first?.id)
        let isExpanded = expandedIDs.contains(p.id)
        let activeColor: Color = .green
        return VStack(alignment: .leading, spacing: 10) {
            // ── 头部（常显）：单选 + 名称 + 摘要 + 操作 ──
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { activeID = p.id }
                } label: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isActive ? activeColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Make Active"))

                TextField(L10n.text("Profile Name"), text: binding.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .frame(minWidth: 80, maxWidth: 140)

                Text(profileSummary(p))
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                Spacer()

                if isActive {
                    Text(L10n.text("Active"))
                        .font(.caption2).foregroundColor(activeColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(activeColor.opacity(0.12)))
                }
                Button {
                    toggleExpand(p.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L10n.text("Collapse Editor") : L10n.text("Expand Editor"))
                Button {
                    deleteProfile(p.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Delete Profile"))
            }

            // ── 展开区：带标签的字段栅格 ──
            if isExpanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Base URL")
                            .font(.caption).foregroundColor(.secondary)
                            .gridColumnAlignment(.leading)
                            .frame(width: 58, alignment: .leading)
                        TextField(L10n.text("https://api.deepseek.com (/v1 is added if needed)"), text: binding.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .contextMenu { pasteMenuItems(for: binding.baseURL) }
                    }
                    GridRow {
                        Text("API Key")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 58, alignment: .leading)
                        HStack(spacing: 4) {
                            SecureField(L10n.text("Stored on this Mac. Optional for local servers."), text: binding.apiKey)
                                .contextMenu { pasteMenuItems(for: binding.apiKey) }
                            Button {
                                if let s = NSPasteboard.general.string(forType: .string) {
                                    binding.apiKey.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.text("Paste API Key from Clipboard"))
                        }
                    }
                    GridRow {
                        Text(L10n.text("Model"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 58, alignment: .leading)
                        HStack(spacing: 6) {
                            TextField(L10n.text("e.g. deepseek-chat or gemma4:latest"), text: binding.model)
                                .textFieldStyle(.roundedBorder)
                                .contextMenu { pasteMenuItems(for: binding.model) }
                            if let list = modelsByProfile[p.id], !list.isEmpty {
                                Menu {
                                    ForEach(list, id: \.self) { m in
                                        Button(m) { binding.model.wrappedValue = m }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10))
                                }
                                .frame(width: 26)
                            }
                            Button {
                                fetchModels(for: p.id)
                            } label: {
                                Group {
                                    if fetchingID == p.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text(L10n.text("Fetch Models")).font(.caption)
                                    }
                                }
                                .frame(width: 56)
                            }
                            .disabled(fetchingID == p.id)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isActive ? activeColor.opacity(0.06) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isActive ? activeColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// 卡片摘要：host:port · 模型名
    private func profileSummary(_ p: ModelProfile) -> String {
        var host = p.baseURL
        if let url = URL(string: p.baseURL), let h = url.host {
            host = h + (url.port.map { ":\($0)" } ?? "")
        }
        let model = p.model.isEmpty ? L10n.text("No model selected") : p.model
        return host.isEmpty ? model : host + " · " + model
    }

    private func toggleExpand(_ id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        }
    }

    private func deleteProfile(_ id: UUID) {
        pendingDeleteID = id
    }

    private func performDelete(_ id: UUID) {
        pendingDeleteID = nil
        expandedIDs.remove(id)
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles.first?.id }
        profileSaveTask?.cancel()
        saveProfilesNow()
        statusText = L10n.text("Profile deleted.")
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    private func scheduleProfileSave() {
        profileSaveTask?.cancel()
        profileSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveProfilesNow()
        }
    }

    private func saveProfilesNow() {
        guard profiles != lastSavedProfiles else { return }
        let previousError = ProfileStore.lastError
        if ProfileStore.save(profiles) {
            lastSavedProfiles = profiles
            if let error = ProfileStore.lastError { statusText = error }
            else if let previousError, statusText == previousError {
                statusText = L10n.text("Profiles saved.")
            }
        } else {
            statusText = ProfileStore.lastError ?? L10n.text("Could not save profiles")
        }
    }

    private func appendProfile(_ prof: ModelProfile, active: Bool) {
        profiles.append(prof)
        if active || profiles.count == 1 { activeID = prof.id }
    }

    private func updateActiveStatus() {
        if let p = Config.activeProfile, !p.baseURL.isEmpty {
            statusText = L10n.format("Active profile switched to %@ (%@).",
                                     p.name.isEmpty ? L10n.text("Untitled") : p.name,
                                     p.model.isEmpty ? L10n.text("No model name") : p.model)
        }
    }

    private var activeProfileIndex: Int? {
        profiles.firstIndex { $0.id == (activeID ?? profiles.first?.id) }
    }

    private var activeTemperatureBinding: Binding<Double> {
        Binding(
            get: { activeProfileIndex.flatMap { profiles[$0].temperature } ?? temperature },
            set: { value in
                if let index = activeProfileIndex { profiles[index].temperature = value }
                else { temperature = value }
            }
        )
    }

    private var activeMaxTokensBinding: Binding<Int> {
        Binding(
            get: { activeProfileIndex.flatMap { profiles[$0].maxTokens } ?? maxTokens },
            set: { value in
                if let index = activeProfileIndex { profiles[index].maxTokens = value }
                else { maxTokens = value }
            }
        )
    }

    private var activeMaxTokens: Int { activeMaxTokensBinding.wrappedValue }

    private var activeReasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                activeProfileIndex.flatMap { profiles[$0].reasoningEffort?.rawValue } ?? ""
            },
            set: { value in
                if let index = activeProfileIndex {
                    profiles[index].reasoningEffort = ReasoningEffort.parse(value)
                }
            }
        )
    }

    private var activeModelSupportsTemperature: Bool {
        let model = activeProfileIndex.map { profiles[$0].model } ?? ""
        return AIRequestConfiguration.temperatureIsSupported(for: model)
    }

    // MARK: 生成参数页

    private var generationPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("thermometer.medium", L10n.text("Temperature"), note: L10n.text("Higher values are more creative. Lower values are more consistent.")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(activeModelSupportsTemperature
                             ? L10n.format("Temperature: %.1f", activeTemperatureBinding.wrappedValue)
                             : L10n.text("Temperature: 1.0 (model default)"))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(activeModelSupportsTemperature ? "0.0 – 2.0" : L10n.text("Default only"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if activeModelSupportsTemperature {
                        Slider(value: activeTemperatureBinding, in: 0...2, step: 0.1)
                    } else {
                        Text(L10n.text("This model uses the server's default temperature. Requests omit the temperature parameter."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            card("text.quote", L10n.text("Maximum Output Tokens")) {
                Stepper("\(activeMaxTokens)", value: activeMaxTokensBinding, in: 512...32768, step: 512)
                    .font(.system(size: 12, weight: .medium))
            }
            card("brain.head.profile", L10n.text("Reasoning Effort"), note: L10n.text("Set how much effort a reasoning model spends on a response.")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.format("Reasoning Effort: %@",
                                         activeReasoningEffortBinding.wrappedValue.isEmpty
                                             ? L10n.text("Default") : activeReasoningEffortBinding.wrappedValue))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(activeReasoningEffortBinding.wrappedValue.isEmpty ? L10n.text("Parameter omitted") : "reasoning_effort")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Picker(L10n.text("Reasoning Effort"), selection: activeReasoningEffortBinding) {
                        Text(L10n.text("Default")).tag("")
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.label).tag(effort.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(activeProfileIndex == nil)
                    Text(L10n.text("The default omits reasoning_effort. Choosing Minimal, Low, Medium, or High sends that value with each request. Availability depends on the model and provider."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 行首 Markdown 页

    private var markdownPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("number", L10n.text("Markdown Expansion")) {
                Toggle(L10n.text("Expand Markdown at the start of a line"), isOn: $mdEnabled).toggleStyle(.switch)
            }
            card("link", L10n.text("Link Titles")) {
                Toggle(L10n.text("Convert a URL to a titled link when you type a space after it in Notes"), isOn: $urlTitleEnabled)
                    .toggleStyle(.switch)
                if urlTitleEnabled {
                    Text(L10n.text("For example, type https://www.apple.com and press Space to create a link labeled Apple. If the page requires sign-in or the title cannot be fetched, the URL remains the link text. Each URL triggers at most once every 30 seconds."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            card("list.bullet.rectangle", L10n.text("Expansion Rules"), note: L10n.text("Turn on Markdown expansion to use these rules.")) {
                VStack(spacing: 10) {
                    Toggle(L10n.text("Headings (# ## ###)"), isOn: $mdHeaders).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Checklists ([])"), isOn: $mdChecklists).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Block quotes (>)"), isOn: $mdQuote).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Monospaced blocks (```)"), isOn: $mdMonostyled).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Dashed lists (-)"), isOn: $mdDashed).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Bulleted lists (*)"), isOn: $mdBulleted).toggleStyle(.switch)
                    Divider()
                    Toggle(L10n.text("Numbered lists (1.)"), isOn: $mdNumbered).toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: 系统提示词页

    private var promptPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("text.bubble", L10n.text("System Prompt"), note: L10n.text("Leave blank to use the built-in prompt.")) {
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 11))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                HStack {
                    Spacer()
                    Button(L10n.text("Restore Default")) { systemPrompt = Config.defaultSystem }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: 模板管理页（斜杠命令插入）

    private var templatesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("folder", L10n.text("Apple Notes Templates"), note: L10n.text("Enabled by default and refreshed automatically")) {
                Text(L10n.text("Templates load from the Templates folder in Notes. Use the first line as the template name and start the content on the next line. The first paragraph of the content becomes the new note's title. Changes refresh automatically. When names match, Notes templates take precedence and local copies are kept."))
                    .font(.caption).foregroundColor(.secondary)
                if notesTemplatesLoading {
                    Label(L10n.text("Loading Notes templates…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundColor(.secondary)
                } else if let error = notesTemplatesError {
                    Text(error).font(.caption).foregroundColor(.orange)
                } else if !notesTemplatesReady {
                    Text(L10n.text("Grant Full Disk Access to read Notes templates, then click Reload."))
                        .font(.caption).foregroundColor(.secondary)
                } else if notesTemplates.isEmpty {
                    Text(L10n.text("Create a Templates folder in Notes and move your notes there. Only fully readable notes with content appear here."))
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(notesTemplates) { template in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("/\(template.commandName)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            varBadges(TemplateEngine.specs(in: template.content))
                        }
                        Text(template.content).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    }.textSelection(.enabled)
                }
                HStack {
                    Button(L10n.text("Reload")) { (NSApp.delegate as? AppDelegate)?.refreshNotesTemplates() }
                        .disabled(notesTemplatesLoading)
                    if !notesTemplatesReady || notesTemplatesError != nil {
                        Button(L10n.text("Open Full Disk Access Settings")) { openPrivacy("Privacy_AllFiles") }
                    }
                }.controlSize(.small)
            }
            // 内置模板（对齐 ProNotes _defaultTemplates）
            let builtin = templates.filter(\.isBuiltin)
            if !builtin.isEmpty {
                card("seal", L10n.text("Built-in Templates"),
                     note: L10n.text("Ready to use. You can recreate deleted templates below. Reinstalling the app leaves them deleted.")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(builtin) { t in
                            templateRow(t, deletable: true)
                        }
                    }
                }
            }

            // 自定义模板
            let custom = templates.filter { !$0.isBuiltin }
            card("square.and.pencil", L10n.text("Custom Templates"),
                 note: custom.isEmpty ? L10n.text("No custom templates") : L10n.text("Slash command: /template-name")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(custom) { t in
                        templateRow(t, deletable: true)
                    }
                    if custom.isEmpty {
                        Text(L10n.text("Create templates below and expand them in Notes with /template-name."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            // 自定义 AI 命令
            card("wand.and.stars", L10n.text("Custom AI Commands"),
                 note: customAICommands.isEmpty ? L10n.text("No custom commands") : L10n.text("Slash command: /command-name")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($customAICommands) { $command in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("/\(command.name.isEmpty ? L10n.text("Untitled") : command.name)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                                Toggle(L10n.text("Enabled"), isOn: $command.enabled)
                                    .toggleStyle(.checkbox)
                                    .controlSize(.mini)
                                Button(role: .destructive) {
                                    customAICommands.removeAll { $0.id == command.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                            TextField(L10n.text("Command Name"), text: $command.name)
                                .textFieldStyle(.roundedBorder)
                            if !CustomAICommand.hasValidName(command.name, existing: customAICommands, excludingID: command.id) {
                                Text(L10n.text("Use a unique name of 1–32 characters without spaces, slashes, or backslashes."))
                                    .font(.caption2).foregroundColor(.red)
                            }
                            TextField(L10n.text("Prompt"), text: $command.prompt, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if customAICommands.isEmpty {
                        Text(L10n.text("Type /command-name in Notes or the command panel to run its saved prompt."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    TextField(L10n.text("New command name, e.g. weekly"), text: $newAICommandName)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text("New prompt, e.g. Turn this week's notes into a weekly report"), text: $newAICommandPrompt, axis: .vertical)
                        .lineLimit(2...3)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button(L10n.text("Add AI Command")) {
                            let name = newAICommandName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let prompt = newAICommandPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard CustomAICommand.hasValidName(name, existing: customAICommands) else {
                                newAICommandError = L10n.text("Use a unique name of 1–32 characters without spaces, slashes, or backslashes.")
                                return
                            }
                            guard !prompt.isEmpty else {
                                newAICommandError = L10n.text("Enter a prompt.")
                                return
                            }
                            customAICommands.append(CustomAICommand(name: name, prompt: prompt))
                            newAICommandName = ""
                            newAICommandPrompt = ""
                            newAICommandError = nil
                        }
                        .disabled(newAICommandName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newAICommandPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let error = newAICommandError {
                            Text(error).font(.caption2).foregroundColor(.red)
                        }
                    }
                }
            }

            // 新建模板
            card("plus.square.on.square", L10n.text("New Template")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.text("Name (used as the slash command)"), text: $newTplName)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text("Template content, e.g. {{date}}, {{selection}}, {{ask:question}}, or {{ai:instruction}}"),
                              text: $newTplContent, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    if !TemplateEngine.specs(in: newTplContent).isEmpty {
                        varBadges(TemplateEngine.specs(in: newTplContent))
                    }
                    HStack {
                        Spacer()
                        Button {
                            let n = newTplName.trimmingCharacters(in: .whitespaces)
                            let c = newTplContent
                            guard !n.isEmpty, !c.isEmpty else { return }
                            templates.append(TemplateNote(name: n, content: c))
                            newTplName = ""
                            newTplContent = ""
                        } label: {
                            Label(L10n.text("Add"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newTplName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newTplContent.isEmpty)
                    }
                }
            }

            // 变量速查（模板变量引擎说明）
            card("curlybraces", L10n.text("Template Variables"),
                 note: L10n.text("Use {{variable}} in template content.")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(TemplateCheatRow.all, id: \.syntax) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.syntax)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 150, alignment: .leading)
                            Text(row.desc)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Text(L10n.text("Use \\{{ for literal braces. Unknown variables are preserved. {{ai:}} uses your active model profile. Select text in Notes first if the template needs context."))
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// 模板行：命令名 + 变量徽章 + 内容编辑 + 删除
    private func templateRow(_ t: TemplateNote, deletable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("/\(t.name)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                varBadges(TemplateEngine.specs(in: t.content))
                Spacer()
                Button(role: .destructive) {
                    templates.removeAll { $0.id == t.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if let idx = templates.firstIndex(where: { $0.id == t.id }) {
                TextField(L10n.text("Template Content"), text: $templates[idx].content, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private func varBadges(_ specs: [TemplateVarSpec]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                Text(s.kind.badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func refreshPrivacyAppChoices() {
        privacyAppChoices = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier ?? app.localizedName }
            .filter { $0 != Bundle.main.bundleIdentifier }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        if selectedPrivacyApp.isEmpty || !privacyAppChoices.contains(selectedPrivacyApp) {
            selectedPrivacyApp = privacyAppChoices.first ?? ""
        }
    }

    private func addPrivacyApp(_ rawIdentity: String) {
        let identity = rawIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty, !selectionPrivacyApps.contains(identity) else { return }
        selectionPrivacyApps.append(identity)
        manualPrivacyApp = ""
    }

    // MARK: 文本扩展页（KeywordListener）

    private var expansionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("textformat.abc", L10n.text("Selection Writing Tools")) {
                Toggle(L10n.text("Show writing tools when text is selected"), isOn: $selAIEnabled)
                    .toggleStyle(.switch)
                if selAIEnabled {
                    Picker(L10n.text("Scope"), selection: $selectionScope) {
                        Text(L10n.text("Notes Only")).tag(SelectionScope.notes)
                        Text(L10n.text("All Apps")).tag(SelectionScope.global)
                    }
                    .pickerStyle(.segmented)
                    if selectionScope == .global {
                        Toggle(L10n.text("Pause selection detection in other apps"), isOn: $selectionPaused)
                            .toggleStyle(.switch)
                        Picker(L10n.text("App Access"), selection: $selectionPrivacyMode) {
                            Text(L10n.text("Blocklist")).tag(SelectionScope.PrivacyMode.blocklist)
                            Text(L10n.text("Allowlist")).tag(SelectionScope.PrivacyMode.allowlist)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Picker(L10n.text("Running Apps"), selection: $selectedPrivacyApp) {
                                ForEach(privacyAppChoices, id: \.self) { app in
                                    Text(verbatim: app).tag(app)
                                }
                            }
                            .labelsHidden()
                            Button(L10n.text("Add Selected App")) { addPrivacyApp(selectedPrivacyApp) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(selectedPrivacyApp.isEmpty || selectionPrivacyApps.contains(selectedPrivacyApp))
                            Spacer()
                            Text(L10n.format("Apps in list: %lld", selectionPrivacyApps.count))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            TextField(L10n.text("Enter a bundle ID or app name"), text: $manualPrivacyApp)
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.text("Add")) { addPrivacyApp(manualPrivacyApp) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(manualPrivacyApp.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(selectionPrivacyApps, id: \.self) { app in
                            HStack {
                                Text(verbatim: app)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    selectionPrivacyApps.removeAll { $0 == app }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                        Text(L10n.text("An allowlist restricts selection tools to listed apps. A blocklist excludes listed apps. Running an AI action sends the selected text to the active model. These settings store app identifiers only."))
                            .font(.caption).foregroundColor(.orange)
                    } else {
                        Text(L10n.text("Select text in a note to proofread, polish, or enter an instruction. Review the result before replacing the selection or appending it."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(L10n.text("The automatic button requires Accessibility access. Writing back to Notes also requires Notes Automation access. You can open the tools manually from the macOS Services menu."))
                    .font(.caption).foregroundColor(.secondary)
            }
            card("slash.circle", L10n.text("Notes Slash Commands")) {
                Toggle(L10n.text("Show the command menu when you type / in a note"), isOn: $slashGlobal)
                    .toggleStyle(.switch)
                if slashGlobal {
                    Text(L10n.text("Type / to click a command, or type an alias such as /polish, /summarize, or /translate followed by a space. Commands use the selection or current paragraph. Review AI results before writing them back. Accessibility and Notes Automation access are required to identify the note and write to it."))
                        .font(.caption).foregroundColor(.secondary)
                    Text(L10n.text("Filter by command name or alias. With Accessibility access, use ↑↓ to select, Return to run, and Esc to close. You can also click a command."))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            card("keyboard", L10n.text("Keyword Expansion")) {
                Toggle(L10n.text("Enable keyword expansion"), isOn: $kwEnabled).toggleStyle(.switch)
                if kwEnabled {
                    Text(L10n.text("Requires Accessibility access. Triggers cannot contain spaces."))
                        .font(.caption).foregroundColor(.secondary)
                    ForEach($rules) { $r in
                        HStack(spacing: 6) {
                            TextField(L10n.text("Trigger, e.g. ;;hello"), text: $r.trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            TextField(L10n.text("Expand To"), text: $r.expansion, axis: .vertical)
                                .lineLimit(1...3)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                rules.removeAll { $0.id == r.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField(L10n.text("Trigger"), text: $newTrigger)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        TextField(L10n.text("Expand To"), text: $newExpansion, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let t = newTrigger.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty, !t.contains(" "), !newExpansion.isEmpty else { return }
                            rules.append(KeywordRule(trigger: t, expansion: newExpansion))
                            newTrigger = ""
                            newExpansion = ""
                        } label: {
                            Label(L10n.text("Add"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newTrigger.contains(" ") || newExpansion.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: 通用与诊断页

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("globe", L10n.text("Interface Language")) {
                Picker(L10n.text("Interface Language"), selection: Binding(
                    get: { localization.language }, set: { localization.select($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.interfaceLanguage")
            }
            card("arrow.down.circle", L10n.text("Updates")) {
                HStack {
                    Text(L10n.format("Current version: v%@",
                                     updater.currentVersion.isEmpty ? "-" : updater.currentVersion))
                        .font(.callout)
                    Spacer()
                    Button(updater.isChecking ? L10n.text("Checking…") : L10n.text("Check for Updates")) {
                        Task { await updater.check() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(updater.isChecking)
                    .accessibilityIdentifier("settings.updates.check")
                }
                Text(updater.statusMessage)
                    .font(.caption)
                    .foregroundColor(updater.availableRelease == nil ? .secondary : .orange)
                    .accessibilityIdentifier("settings.updates.status")
                if let release = updater.availableRelease {
                    if updater.isDownloading {
                        HStack {
                            Button(L10n.text("Cancel Download")) { updater.cancelDownload() }
                                .controlSize(.small)
                                .accessibilityIdentifier("settings.updates.cancelDownload")
                            if let progress = updater.downloadProgress {
                                ProgressView(value: progress)
                                    .frame(maxWidth: 180)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        Button(L10n.format("Download v%@", release.version)) {
                            Task { @MainActor in
                                guard let fileURL = await updater.download() else { return }
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            }
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.updates.download")
                    }
                    if let notes = release.alertNotes {
                        ScrollView {
                            Text(notes)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(L10n.text("The DMG is verified with SHA-256, saved to Downloads, and revealed in Finder. Drag the app into Applications to replace the previous version. If macOS cannot verify the app, click Done, then Open Anyway in System Settings → Privacy & Security."))
                        .font(.caption2).foregroundColor(.secondary)
                    if !updater.downloadStatusMessage.isEmpty {
                        Text(updater.downloadStatusMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle(L10n.text("Check for updates automatically"), isOn: $updater.automaticallyChecks)
                    .toggleStyle(.switch)
                    .onChange(of: updater.automaticallyChecks) { enabled in
                        if enabled { Task { await updater.checkIfNeeded() } }
                    }
                Text(L10n.text("Checks for updates at most once a day. Remind Later postpones the next reminder by at least one day."))
                    .font(.caption2).foregroundColor(.secondary)
                HStack {
                    if let date = updater.lastChecked {
                        Text(L10n.format("Last checked: %@",
                                         date.formatted(.dateTime.year().month().day().hour().minute().locale(localization.locale))))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Open Releases")) { NSWorkspace.shared.open(AppUpdater.releasesURL) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            card("power", L10n.text("Launch at Login")) {
                Toggle(L10n.text("Open NotesCopilot when you log in"), isOn: Binding(get: { launchAtLogin }, set: { on in
                    changingLaunchAtLogin = true
                    Task { @MainActor in
                        defer { changingLaunchAtLogin = false }
                        do {
                            try await Self.setLaunchAtLogin(on)
                            launchAtLogin = Self.isLaunchAtLogin()
                            statusText = launchAtLogin == on ? L10n.text("Launch at login updated.") : L10n.text("Allow NotesCopilot to launch at login in System Settings.")
                        } catch {
                            launchAtLogin = Self.isLaunchAtLogin()
                            statusText = L10n.format("Could not update launch at login: %@", error.localizedDescription)
                        }
                    }
                }))
                    .toggleStyle(.switch)
                    .disabled(changingLaunchAtLogin)
                    .onAppear { launchAtLogin = Self.isLaunchAtLogin() }
            }
            card("lock.shield", L10n.text("Features & Permissions")) {
                Label(axAuthorized ? L10n.text("Accessibility: Granted. Notes Automation is a separate permission.") : L10n.text("Accessibility: Grant access to use slash commands and selection tools in Notes."),
                      systemImage: axAuthorized ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundColor(axAuthorized ? .secondary : .orange)
                if let issue = notesAccessIssue { NotesAccessNoticeView(issue: issue) }
                Label(keyboardRunning ? L10n.text("Keyboard navigation and keyword expansion: Listening") : L10n.text("Keyboard navigation and keyword expansion: Inactive. You can still click commands."),
                      systemImage: keyboardRunning ? "checkmark.circle" : "info.circle").font(.caption).foregroundColor(.secondary)
                Text(L10n.text("Keyboard navigation uses Accessibility access."))
                    .font(.caption).foregroundColor(.secondary)
                Text(L10n.text("The note library and Notes templates require Full Disk Access. macOS requests Automation access the first time you create a note or read a note's identity or browser title."))
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button(L10n.text("Open Accessibility Settings")) {
                        NotesBridge.shared.openAccessibilityPrefs()
                    }
                    Button(L10n.text("Automation Settings")) { NotesBridge.shared.openAutomationPrefs() }
                    Button(L10n.text("Full Disk Access")) { openPrivacy("Privacy_AllFiles") }
                    Button(L10n.text("Check Again")) { refreshPermissionStatus() }
                }.controlSize(.small)
            }
            card("antenna.radiowaves.left.and.right", L10n.text("Connection Diagnostics")) {
                HStack {
                    Button {
                        testActiveModel()
                    } label: {
                        Label(testingModel ? L10n.text("Testing generation…") : L10n.text("Test Active Model"), systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(testingModel || profiles.isEmpty)
                    Spacer()
                    if let p = Config.activeProfile {
                        Text("\(p.name.isEmpty ? L10n.text("Untitled") : p.name) · \(p.model.isEmpty ? L10n.text("No model name") : p.model)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(L10n.text("A short generation request verifies your model, credentials, and parameters. Fetch Models checks the model list endpoint."))
                    .font(.caption2).foregroundColor(.secondary)
                if let st = kwStatus {
                    Text(st.message).font(.caption).foregroundColor(.orange)
                }
            }
        }
    }

    private func pasteMenuItems(for binding: Binding<String>) -> some View {
        Group {
            Button(L10n.text("Paste")) {
                if let s = NSPasteboard.general.string(forType: .string) {
                    binding.wrappedValue = s
                }
            }
            Button(L10n.text("Paste and Trim Whitespace")) {
                if let s = NSPasteboard.general.string(forType: .string) {
                    binding.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            Divider()
            Button(L10n.text("Clear")) { binding.wrappedValue = "" }
        }
    }

    // MARK: 登录启动（SMAppService，对应 ProNotes 的 _launchAtLogin / LaunchAtLogin 证据）

    static func isLaunchAtLogin() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ on: Bool) async throws {
        if on { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }

    private func refreshPermissionStatus() {
        notesAccessIssue = notesAccessIssueProvider()
        axAuthorized = notesAccessIssue != .accessibilityRequired
        keyboardRunning = KeywordListener.shared.isRunning
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func testActiveModel() {
        testingModel = true
        statusText = L10n.text("Testing whether the active model can generate a response…")
        Task { @MainActor in
            defer { testingModel = false }
            do {
                let configuration = try AIRequestConfiguration.current()
                _ = try await AIService.complete(instruction: "请只回复 OK。", context: "", configuration: configuration)
                statusText = L10n.format("%@ generated a response with the current settings.", configuration.model)
            } catch {
                statusText = L10n.format("Generation test failed: %@", error.localizedDescription)
            }
        }
    }

    private func refreshNotesTemplatesStatus() {
        notesTemplates = TemplateStore.notesTemplates
        let delegate = NSApp.delegate as? AppDelegate
        notesTemplatesLoading = delegate?.notesStoreLoading == true || delegate?.notesTemplatesLoading == true
        notesTemplatesReady = delegate?.notesStore != nil
        notesTemplatesError = delegate?.notesStoreError
    }

    /// 拉取指定配置的模型列表（GET /models），写入该配置的模型菜单；
    /// 模型名为空时自动填第一个
    private func fetchModels(for id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let raw = profiles[idx].baseURL
        let key = profiles[idx].apiKey
        let name = profiles[idx].name.isEmpty ? L10n.text("Untitled") : profiles[idx].name
        modelFetchGeneration = UUID()
        let generation = modelFetchGeneration
        fetchingID = id
        statusText = L10n.format("Fetching models for %@…", name)
        Task {
            do {
                guard let base = Config.apiBase(raw) else {
                    throw APIError(status: -1, message: L10n.text("Base URL is empty"))
                }
                let list = try await AIService.fetchModels(base: base, key: key)
                await MainActor.run {
                    guard modelFetchGeneration == generation else { return }
                    guard let current = profiles.first(where: { $0.id == id }),
                          current.baseURL == raw, current.apiKey == key else {
                        fetchingID = nil
                        return
                    }
                    modelsByProfile[id] = list
                    if let i = profiles.firstIndex(where: { $0.id == id }),
                       profiles[i].model.isEmpty {
                        profiles[i].model = list.first ?? ""
                    }
                    statusText = list.isEmpty
                        ? L10n.format("%@ connected and returned an empty list. Enter a model name manually.", name)
                        : L10n.format("%@ connected. Models found: %lld.", name, list.count)
                    fetchingID = nil
                }
            } catch {
                await MainActor.run {
                    guard modelFetchGeneration == generation else { return }
                    statusText = L10n.format("%@ failed: %@", name, error.localizedDescription)
                    fetchingID = nil
                }
            }
        }
    }
}
