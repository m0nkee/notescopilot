import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - 快捷动作（与斜杠命令同源的内置指令）

struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
}

let quickActions: [QuickAction] = [
    QuickAction(title: "续写", prompt: "请基于上文内容自然地续写下去，保持原文的风格与格式。"),
    QuickAction(title: "总结", prompt: "请用简洁的要点总结以下内容的核心信息。"),
    QuickAction(title: "翻译", prompt: "请将以下内容翻译成英文，保持原意与语气。"),
    QuickAction(title: "润色", prompt: "请润色以下文字，使其更通顺、专业，保持原意与格式。"),
    QuickAction(title: "解释", prompt: "请解释以下内容的关键概念与逻辑。"),
    QuickAction(title: "扩写", prompt: "请扩展以下内容，补充细节与论据，保持原有结构。"),
    QuickAction(title: "修拼写", prompt: "请修复以下文字的拼写与语法错误，只输出修正后的文本，不要解释。"),
    QuickAction(title: "变短", prompt: "请把以下内容压缩得更简洁，保留核心信息。"),
    QuickAction(title: "变长", prompt: "请把以下内容写得更丰富、有细节，保持原意。"),
]

// MARK: - 服务商预设（自配置模型的核心：任意 OpenAI 兼容端点）

struct ProviderPreset {
    let name: String
    let base: String
    let model: String
}

let presets: [ProviderPreset] = [
    ProviderPreset(name: "DeepSeek", base: "https://api.deepseek.com", model: "deepseek-chat"),
    ProviderPreset(name: "Kimi", base: "https://api.moonshot.cn/v1", model: "kimi-k2-turbo-preview"),
    ProviderPreset(name: "通义千问", base: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
    ProviderPreset(name: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    ProviderPreset(name: "OpenRouter", base: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
    ProviderPreset(name: "硅基流动", base: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-72B-Instruct"),
    ProviderPreset(name: "Ollama 本地", base: "http://localhost:11434/v1", model: ""),
    ProviderPreset(name: "LM Studio 本地", base: "http://localhost:1234/v1", model: ""),
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
    var onSuggestions: ([SlashCommand]) -> Void
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
            context.coordinator.refreshSuggestions(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var textView: NSTextView?
        var suggestions: [SlashCommand] = []
        var active = false

        init(_ p: PromptTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
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
            guard !token.contains(where: { $0.isWhitespace }) else { close(); return }
            let all = parent.commands()
            let filtered = token.isEmpty ? all
                : all.filter { $0.name.localizedCaseInsensitiveContains(token) }
            suggestions = filtered
            active = !filtered.isEmpty
            parent.onSuggestions(filtered)
        }

        private func close() {
            active = false
            suggestions = []
            parent.onSuggestions([])
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
            active = false
            suggestions = []
            parent.onAccept(cmd)
        }
    }
}

// MARK: - 主面板

struct PanelView: View {
    @ObservedObject var engine: ChatEngine
    @State private var prompt = ""
    @State private var axTrusted = true
    @State private var suggestions: [SlashCommand] = []
    @State private var selectedIdx = 0
    /// 当前生效模型配置（设置页切换后经通知实时刷新）
    @State private var activeProfileLabel = ""

    var body: some View {
        VStack(spacing: 12) {
            header
            if !engine.pendingResult.isEmpty { reviewBanner }
            contextSection
            if !suggestions.isEmpty { suggestionsMenu }
            promptSection
            quickActionsRow
            outputSection
            footerBar
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 680)
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: engine.pendingResult.isEmpty)
        .onAppear {
            axTrusted = NotesBridge.shared.isTrusted
            activeProfileLabel = Self.profileLabel()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileStore.changedNotification)) { _ in
            activeProfileLabel = Self.profileLabel()
        }
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            var got = false
            for p in providers {
                p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage, let att = ImageAttachment.make(img) {
                        DispatchQueue.main.async { engine.images.append(att) }
                    }
                }
                got = true
            }
            return got
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("NotesCopilot").font(.headline)
            if !activeProfileLabel.isEmpty {
                Text(activeProfileLabel)
                    .font(.caption2).foregroundColor(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 110)
                    .help("当前生效模型配置（设置中可切换）")
            }
            Text("⇧⌘Space")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            Toggle("连续对话", isOn: $engine.continuous)
                .toggleStyle(.switch).controlSize(.mini)
            if engine.continuous && !engine.history.isEmpty {
                Text("已 \(engine.history.count / 2) 轮")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                if let sel = NotesBridge.shared.readSelectedText(), !sel.isEmpty {
                    engine.noteContext = sel
                }
            } label: {
                Label("抓取选中", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.link)
            Button {
                engine.noteContext = ""
            } label: {
                Label("清空", systemImage: "xmark.circle")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: 笔记上下文

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("笔记上下文")
                    .font(.caption).foregroundColor(.secondary)
                if !engine.noteContext.isEmpty, !engine.contextSource.isEmpty {
                    Text(engine.contextSource)
                        .font(.caption2).foregroundColor(.purple)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.12)))
                }
                Spacer()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $engine.noteContext)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .opacity(engine.noteContext.isEmpty ? 0.6 : 1)
                if engine.noteContext.isEmpty {
                    Text("在 Notes 中选中文字或用 / 命令会自动带入；无需选中，光标所在段落也会作为上下文。")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: 斜杠命令建议菜单

    private var suggestionsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, cmd in
                HStack(spacing: 8) {
                    Text(cmd.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("/" + cmd.alias)
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
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                PromptTextView(text: $prompt,
                               commands: { buildSlashCommands() },
                               onSuggestions: { list in
                                   suggestions = list
                                   selectedIdx = 0
                               },
                               onMove: { delta in
                                   guard !suggestions.isEmpty else { return }
                                   selectedIdx = (selectedIdx + delta + suggestions.count) % suggestions.count
                               },
                               onAccept: { cmd in perform(cmd) },
                               onRun: {
                                   suggestions = []
                                   engine.run(prompt: prompt)
                               },
                               onCancelSuggestions: { suggestions = [] },
                               selectedIndex: { selectedIdx })
                    .frame(height: 64)
                VStack(spacing: 6) {
                    Button {
                        suggestions = []
                        engine.run(prompt: prompt)
                    } label: {
                        Label(engine.busy ? "生成中…" : "生成", systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(engine.busy ||
                              prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if engine.busy {
                        Button("停止") { engine.stop() }
                            .controlSize(.small)
                    } else {
                        Button {
                            addImage()
                        } label: {
                            Image(systemName: "photo")
                        }
                        .controlSize(.small)
                        .help("添加图片（也可直接拖入面板）；发送时作为多模态 image part")
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
                if let img = NSImage(contentsOf: u), let att = ImageAttachment.make(img) {
                    engine.images.append(att)
                }
            }
        }
    }

    // MARK: 快捷动作

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickActions) { qa in
                    Button(qa.title) {
                        prompt = qa.prompt
                        suggestions = []
                        engine.run(prompt: qa.prompt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: AI 结果 review 横幅（斜杠命令完成后确认再写回，防误写）

    /// review 期间是否有选中可替换：进入 review 时读一次（面板夺焦点前）
    @State private var reviewHasSelection = false

    private var reviewBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.purple)
                Text("AI 已完成，确认后写回笔记")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    engine.pendingResult = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("丢弃结果")
            }
            // 结果预览（截断）
            Text(engine.pendingResult)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button {
                    _ = NotesBridge.shared.replaceSelectionInNotes(engine.pendingResult)
                    engine.pendingResult = ""
                } label: {
                    Label(reviewHasSelection ? "替换选中" : "插入光标处",
                          systemImage: reviewHasSelection ? "arrow.triangle.2.circlepath" : "square.and.arrow.down.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(engine.pendingResult, forType: .string)
                    engine.pendingResult = ""
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
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
        .onAppear {
            reviewHasSelection = !(NotesBridge.shared.readSelectedText() ?? "").isEmpty
        }
    }

    // MARK: 输出区

    private var outputSection: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            ScrollView {
                Text(engine.output.isEmpty ? "AI 结果会显示在这里…（输入 / 查看斜杠命令）" : engine.output)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if engine.busy { ProgressView().padding(8) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 底栏（结果操作 + token 用量）

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if let err = NotesBridge.shared.insertIntoNotes(engine.output) {
                        engine.lastError = err
                    }
                } label: {
                    Label("插入笔记", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(engine.output.isEmpty)
                Button("复制") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(engine.output, forType: .string)
                }
                .disabled(engine.output.isEmpty)
                Button {
                    if let err = NotesBridge.shared.createNewNote(engine.output) {
                        engine.lastError = err
                    }
                } label: {
                    Label("存为新笔记", systemImage: "doc.badge.plus")
                }
                .disabled(engine.output.isEmpty)
                Spacer()
                if !axTrusted {
                    Button("授权辅助功能") { NotesBridge.shared.requestTrust() }
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
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
                if engine.promptTokens > 0 || engine.totalPromptTokens > 0 {
                    Text("输入 \(engine.promptTokens)\(engine.tokensEstimated ? "≈" : "") · 输出 \(engine.completionTokens)\(engine.tokensEstimated ? "≈" : "") tokens" +
                        " ｜ 累计 \(engine.totalPromptTokens)/\(engine.totalCompletionTokens)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 斜杠命令执行

    /// 生效配置标签："名称 · 模型"（无配置时为空）
    fileprivate static func profileLabel() -> String {
        guard let p = Config.activeProfile else { return "" }
        let name = p.name.isEmpty ? "未命名" : p.name
        let model = p.model.isEmpty ? "未配置模型" : p.model
        return name + " · " + model
    }

    private func perform(_ cmd: SlashCommand) {
        suggestions = []
        switch cmd.action {
        case .run(let p):
            prompt = p
            engine.run(prompt: p)
        case .fill(let p):
            prompt = p
        case .clearContext:
            engine.noteContext = ""
        case .newSession:
            engine.resetSession()
        case .insertOutput:
            if let err = NotesBridge.shared.insertIntoNotes(engine.output) {
                engine.lastError = err
            }
        case .saveAsNote:
            if let err = NotesBridge.shared.createNewNote(engine.output) {
                engine.lastError = err
            }
        case .openSettings:
            NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
        case .format(let style):
            _ = FormatBridge.trigger(style)
        case .stopGeneration:
            engine.stop()
        case .insertTemplate(let tpl):
            // 模板：变量引擎展开（{{selection}} 取面板笔记上下文）后插入 Notes
            TemplateRunner.run(tpl, selection: engine.noteContext) { text in
                if let err = NotesBridge.shared.insertIntoNotes(text) {
                    engine.lastError = err
                }
            } onError: { msg in
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
        case .model: return "模型配置"
        case .generation: return "生成参数"
        case .prompt: return "系统提示词"
        case .markdown: return "行首 Markdown"
        case .templates: return "模板"
        case .expansion: return "斜杠与文本扩展"
        case .general: return "通用与诊断"
        }
    }

    var subtitle: String {
        switch self {
        case .model: return "可保存多份服务商/本地模型配置，点卡片左侧圆圈切换生效"
        case .generation: return "采样温度与输出长度"
        case .prompt: return "AI 的角色设定，随每次请求发送"
        case .markdown: return "在 Notes 里键入 # / ## / [] / > / ``` / - / * / 1. + 空格 自动套格式"
        case .templates: return "在提示词输入框键入 / 即可通过斜杠命令插入"
        case .expansion: return "在任意应用（含 Notes）键入 /命令 直接用 AI；需「输入监控」授权"
        case .general: return "登录启动、权限检查与连接诊断"
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
    // 多配置模型：可保存多份（不同服务商/本地），点选其一作为生效配置
    @State private var profiles: [ModelProfile] = ProfileStore.load()
    @State private var activeID: UUID? = ProfileStore.activeID
    /// 每份配置拉取到的模型列表（id → models）
    @State private var modelsByProfile: [UUID: [String]] = [:]
    @State private var fetchingID: UUID?
    /// 展开编辑中的配置卡
    @State private var expandedIDs: Set<UUID> = []
    /// 本地推理服务探测结果（服务名 → 模型列表）
    @State private var localServices: [(name: String, port: Int, models: [String])] = []
    @AppStorage("nc.sys") private var systemPrompt = Config.defaultSystem
    @AppStorage("nc.temp") private var temperature = 0.7
    @AppStorage("nc.maxTokens") private var maxTokens = 2048
    @State private var statusText = ""

    // 模板与文本扩展
    @State private var templates: [TemplateNote] = TemplateStore.templates
    @State private var rules: [KeywordRule] = KeywordStore.rules
    @State private var kwEnabled = UserDefaults.standard.bool(forKey: "nc.kw.enabled")
    @State private var slashGlobal = UserDefaults.standard.object(forKey: "nc.slash.global") == nil
        ? true : UserDefaults.standard.bool(forKey: "nc.slash.global")
    @State private var selAIEnabled = UserDefaults.standard.object(forKey: "nc.selai.enabled") == nil
        ? true : UserDefaults.standard.bool(forKey: "nc.selai.enabled")
    @State private var newTplName = ""
    @State private var newTplContent = ""
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var kwStatus: String?
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
    /// 当前导航页（Magpie 左侧导航）
    @State private var page: SettingsPage = .model

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(Color.primary.opacity(0.08))
            settingsDetail
        }
        .frame(minWidth: 900, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.kwStatus"))) { n in
            kwStatus = n.object as? String
        }
        .onChange(of: profiles) { ProfileStore.save($0) }
        .onChange(of: activeID) { id in
            ProfileStore.activeID = id
            updateActiveStatus()
        }
        .onChange(of: templates) { TemplateStore.templates = $0 }
        .onChange(of: rules) { KeywordStore.rules = $0 }
        .onChange(of: kwEnabled) { on in
            UserDefaults.standard.set(on, forKey: "nc.kw.enabled")
            if on { KeywordListener.shared.restart() } else { KeywordListener.shared.stop() }
        }
        .onChange(of: slashGlobal) { on in
            UserDefaults.standard.set(on, forKey: "nc.slash.global")
            KeywordListener.shared.restart()
        }
        .onChange(of: selAIEnabled) { on in
            UserDefaults.standard.set(on, forKey: "nc.selai.enabled")
            if on {
                SelectionWatcher.shared.startIfNeeded()
            } else {
                SelectionWatcher.shared.stop()
            }
        }
    }

    /// ── 左侧导航（Magpie NavigationView 自绘：选中项 accent 胶囊高亮）──
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text("NotesCopilot 设置")
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
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader
                if !statusText.isEmpty { infoBar }
                pageContent
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
            card("checkmark.seal", "生效状态") {
                activeStatusRow
            }
            ForEach($profiles) { $p in
                profileCard($p)
            }
            if profiles.isEmpty {
                Label("还没有配置，点下方“快速添加”或手动新建一份。", systemImage: "tray")
                    .font(.callout).foregroundColor(.orange)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            }
            card("plus.circle", "快速添加", note: "云端预设 / 本地推理服务 / 手动新建") {
                quickAddRow
            }
        }
        .onAppear {
            guard localServices.isEmpty else { return }
            LocalAIProbe.discover { name, port, ids in
                if !localServices.contains(where: { $0.port == port }) {
                    localServices.append((name, port, ids))
                }
            }
        }
    }

    /// 快速添加：云端预设 + 本地探测到的推理服务 + 手动新建
    private var quickAddRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.name) { p in
                    Button {
                        let prof = ModelProfile(name: p.name, baseURL: p.base,
                                                apiKey: "", model: p.model)
                        appendProfile(prof, active: profiles.isEmpty)
                        page = .model
                        statusText = "已添加 \(p.name) 预设，点击卡片右侧 › 展开填入 API Key。"
                    } label: {
                        Label(p.name, systemImage: "plus")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                ForEach(localServices, id: \.port) { svc in
                    if !profiles.contains(where: { $0.baseURL.contains("localhost:\(svc.port)") }) {
                        Button {
                            let prof = ModelProfile(name: svc.name + "（本地）",
                                                    baseURL: "http://localhost:\(svc.port)/v1",
                                                    apiKey: "",
                                                    model: svc.models.first ?? "")
                            appendProfile(prof, active: true)
                            modelsByProfile[prof.id] = svc.models
                            statusText = "已添加 \(svc.name) 并设为生效（免 API Key）"
                                + (svc.models.isEmpty ? "。" : "，共 \(svc.models.count) 个模型可选。")
                        } label: {
                            Label(svc.name, systemImage: "cpu")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(.green)
                    }
                }
                Button {
                    appendProfile(ModelProfile(name: "新配置"), active: profiles.isEmpty)
                    if let id = profiles.last?.id { expandedIDs.insert(id) }
                    statusText = "已新建空白配置，展开后填写端点与模型。"
                } label: {
                    Label("手动新建", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    /// 生效状态行：一眼看出当前用的是哪份配置
    @ViewBuilder private var activeStatusRow: some View {
        if let active = profiles.first(where: { $0.id == activeID }) ?? profiles.first {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text("当前生效：\(active.name.isEmpty ? "未命名" : active.name) ｜ \(active.baseURL) ｜ \(active.model.isEmpty ? "未填模型名" : active.model)")
                    .font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else {
            Text("尚无生效配置，AI 功能不可用。")
                .font(.caption).foregroundColor(.orange)
        }
    }

    /// 单份配置卡：头部＝圆圈单选 + 名称 + 摘要 + 展开箭头；
    /// 展开区＝带标签的字段栅格（Base URL / API Key / 模型），编辑体验优先
    private func profileCard(_ binding: Binding<ModelProfile>) -> some View {
        let p = binding.wrappedValue
        let isActive = p.id == activeID
        let isExpanded = expandedIDs.contains(p.id)
        return VStack(alignment: .leading, spacing: 10) {
            // ── 头部（常显）：单选 + 名称 + 摘要 + 操作 ──
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { activeID = p.id }
                } label: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("设为生效配置")

                TextField("配置名称", text: binding.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .frame(minWidth: 80, maxWidth: 140)

                Text(profileSummary(p))
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                Spacer()

                if isActive {
                    Text("生效中")
                        .font(.caption2).foregroundColor(.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
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
                .help(isExpanded ? "收起编辑" : "展开编辑")
                Button {
                    deleteProfile(p.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除这份配置")
            }

            // ── 展开区：带标签的字段栅格 ──
            if isExpanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Base URL")
                            .font(.caption).foregroundColor(.secondary)
                            .gridColumnAlignment(.leading)
                            .frame(width: 58, alignment: .leading)
                        TextField("https://api.deepseek.com（可自动补 /v1）", text: binding.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .contextMenu { pasteMenuItems(for: binding.baseURL) }
                    }
                    GridRow {
                        Text("API Key")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 58, alignment: .leading)
                        HStack(spacing: 4) {
                            SecureField("仅保存在本机，本地服务可留空", text: binding.apiKey)
                                .contextMenu { pasteMenuItems(for: binding.apiKey) }
                            Button {
                                if let s = NSPasteboard.general.string(forType: .string) {
                                    binding.apiKey.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help("从剪贴板粘贴 API Key")
                        }
                    }
                    GridRow {
                        Text("模型")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 58, alignment: .leading)
                        HStack(spacing: 6) {
                            TextField("如 deepseek-chat / gemma4:latest", text: binding.model)
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
                                        Text("拉取列表").font(.caption)
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
            .fill(isActive ? Color.green.opacity(0.06) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isActive ? Color.green.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// 卡片摘要：host:port · 模型名
    private func profileSummary(_ p: ModelProfile) -> String {
        var host = p.baseURL
        if let url = URL(string: p.baseURL), let h = url.host {
            host = h + (url.port.map { ":\($0)" } ?? "")
        }
        let model = p.model.isEmpty ? "未选模型" : p.model
        return host.isEmpty ? model : host + " · " + model
    }

    private func toggleExpand(_ id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        }
    }

    private func deleteProfile(_ id: UUID) {
        if activeID == id { activeID = nil }
        expandedIDs.remove(id)
        profiles.removeAll { $0.id == id }
        statusText = "已删除该配置。"
    }

    private func appendProfile(_ prof: ModelProfile, active: Bool) {
        profiles.append(prof)
        if active || profiles.count == 1 { activeID = prof.id }
    }

    private func updateActiveStatus() {
        if let p = Config.activeProfile, !p.baseURL.isEmpty {
            statusText = "已切换生效配置：\(p.name.isEmpty ? "未命名" : p.name)（\(p.model.isEmpty ? "未填模型名" : p.model)）"
        }
    }

    // MARK: 生成参数页

    private var generationPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("thermometer.medium", "采样温度", note: "越高越有创造性，越低越稳定") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperature：\(String(format: "%.1f", temperature))")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("0.0 – 2.0").font(.caption).foregroundColor(.secondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                }
            }
            card("text.quote", "最大输出 tokens") {
                Stepper("\(maxTokens)", value: $maxTokens, in: 512...32768, step: 512)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: 行首 Markdown 页

    private var markdownPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("number", "总开关") {
                Toggle("启用行首 Markdown 展开", isOn: $mdEnabled).toggleStyle(.switch)
            }
            card("link", "URL 转标题超链") {
                Toggle("在 Notes 键入 URL 后敲空格，自动替换为网页标题超链", isOn: $urlTitleEnabled)
                    .toggleStyle(.switch)
                if urlTitleEnabled {
                    Text("例：键入 https://www.apple.com 后敲空格，自动变成「Apple」蓝字标题超链。登录页/抓取失败时回退为「URL 本身做链接文字」，仍是可点超链。30 秒内同一 URL 不重复触发。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            card("list.bullet.rectangle", "展开规则", note: "主开关关闭时以下规则均不生效") {
                VStack(spacing: 10) {
                    Toggle("标题（# ## ###）", isOn: $mdHeaders).toggleStyle(.switch)
                    Divider()
                    Toggle("检查项（[]）", isOn: $mdChecklists).toggleStyle(.switch)
                    Divider()
                    Toggle("块引用（>）", isOn: $mdQuote).toggleStyle(.switch)
                    Divider()
                    Toggle("等宽块（```）", isOn: $mdMonostyled).toggleStyle(.switch)
                    Divider()
                    Toggle("虚线列表（-）", isOn: $mdDashed).toggleStyle(.switch)
                    Divider()
                    Toggle("项目符号列表（*）", isOn: $mdBulleted).toggleStyle(.switch)
                    Divider()
                    Toggle("编号列表（1.）", isOn: $mdNumbered).toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: 系统提示词页

    private var promptPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("text.bubble", "系统提示词", note: "留空则使用内置默认") {
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 11))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                HStack {
                    Spacer()
                    Button("恢复默认") { systemPrompt = Config.defaultSystem }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: 模板管理页（斜杠命令插入）

    private var templatesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 内置模板（对齐 ProNotes _defaultTemplates）
            let builtin = templates.filter(\.isBuiltin)
            if !builtin.isEmpty {
                card("seal", "内置模板",
                     note: "开箱即用；删除后重新安装不会自动恢复（可在下面重建同名的自定义版）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(builtin) { t in
                            templateRow(t, deletable: true)
                        }
                    }
                }
            }

            // 自定义模板
            let custom = templates.filter { !$0.isBuiltin }
            card("square.and.pencil", "自定义模板",
                 note: custom.isEmpty ? "还没有自定义模板" : "斜杠命令：/模板名") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(custom) { t in
                        templateRow(t, deletable: true)
                    }
                    if custom.isEmpty {
                        Text("用下方「新建模板」创建，或在 Notes 里键入 /命令 即可展开。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            // 新建模板
            card("plus.square.on.square", "新建模板") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名称（即斜杠命令名，建议用拼音/英文）", text: $newTplName)
                        .textFieldStyle(.roundedBorder)
                    TextField("模板内容（支持 {{date}} {{selection}} {{ask:问题}} {{ai:指令}} 等变量）",
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
                            Label("添加", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newTplName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newTplContent.isEmpty)
                    }
                }
            }

            // 变量速查（模板变量引擎说明）
            card("curlybraces", "模板变量速查",
                 note: "在模板内容里用 {{变量}} 引用；ProNotes 只有静态插入，这里是动态模板") {
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
                    Text("提示：\\{{ 可输出字面 {{；未知变量原样保留；{{ai:}} 走当前生效配置，需笔记上下文时先在 Notes 选中文字再触发。")
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
                TextField("模板内容", text: $templates[idx].content, axis: .vertical)
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

    // MARK: 文本扩展页（KeywordListener）

    private var expansionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("textformat.abc", "选中即 AI（悬浮快捷加工）") {
                Toggle("在 Notes 选中文字后自动弹出快捷加工条", isOn: $selAIEnabled)
                    .toggleStyle(.switch)
                if selAIEnabled {
                    Text("选中文字并保持约 0.4 秒，选区下方弹出悬浮条：〔润色 · 总结 · 翻译 · 解释 · 精简〕或输入自定义指令回车。AI 完成后弹出结果卡，可「替换选区」（直接覆盖原文字）、「追加到后」（插到选区末尾之后）、「复制」或关闭。仅辅助功能权限，无剪贴板污染优先 AX 直写。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("切换选区会自动重新弹出；取消选区面板自动消失。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            card("slash.circle", "全局斜杠命令") {
                Toggle("在任意应用（含 Notes）中键入 /命令 直接用 AI", isOn: $slashGlobal)
                    .toggleStyle(.switch)
                if slashGlobal {
                    Text("在 Notes 里选中文字，键入命令+空格即可：/runse 润色 · /zongjie 总结 · /fanyi 翻译 · /xuxie 续写 · /jieshi 解释 · /kuoxie 扩写 · /yaodian 要点 · /biaoti 标题 · 英文命名模板也可直接键入。命中后自动抓取选中作上下文。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("注：中文命令名经输入法组合后无法逐键捕获，请使用拼音别名；建议英文输入模式。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            card("keyboard", "关键词文本扩展") {
                Toggle("启用关键词文本扩展", isOn: $kwEnabled).toggleStyle(.switch)
                if kwEnabled {
                    Text("需在「系统设置 › 隐私与安全性 › 输入监控」授权本应用；触发词不能含空格。")
                        .font(.caption).foregroundColor(.secondary)
                    ForEach($rules) { $r in
                        HStack(spacing: 6) {
                            TextField("触发词（如 ;;hello）", text: $r.trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            TextField("展开为", text: $r.expansion, axis: .vertical)
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
                        TextField("触发词", text: $newTrigger)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        TextField("展开为", text: $newExpansion, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let t = newTrigger.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty, !t.contains(" "), !newExpansion.isEmpty else { return }
                            rules.append(KeywordRule(trigger: t, expansion: newExpansion))
                            newTrigger = ""
                            newExpansion = ""
                        } label: {
                            Label("添加", systemImage: "plus")
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
            card("power", "登录启动") {
                Toggle("登录时启动 NotesCopilot", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onAppear {
                        launchAtLogin = Self.isLaunchAtLogin()
                    }
                    .onChange(of: launchAtLogin) { on in
                        Task { await Self.setLaunchAtLogin(on) }
                    }
            }
            card("lock.shield", "权限说明") {
                Text("· 快捷键与读取选中文本需要「辅助功能」权限\n· 插入/新建笔记需要「自动化」权限（Apple Notes、系统事件）")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("打开辅助功能设置") {
                        NotesBridge.shared.openAccessibilityPrefs()
                    }
                    .controlSize(.small)
                }
            }
            card("antenna.radiowaves.left.and.right", "连接诊断") {
                HStack {
                    Button {
                        if let id = activeID ?? profiles.first?.id { fetchModels(for: id) }
                    } label: {
                        Label("测试当前生效配置", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                    if let p = Config.activeProfile {
                        Text("\(p.name.isEmpty ? "未命名" : p.name) · \(p.model.isEmpty ? "未填模型" : p.model)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if let st = kwStatus {
                    Text(st).font(.caption).foregroundColor(.orange)
                }
            }
        }
    }

    private func pasteMenuItems(for binding: Binding<String>) -> some View {
        Group {
            Button("粘贴") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    binding.wrappedValue = s
                }
            }
            Button("粘贴并去除空白") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    binding.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            Divider()
            Button("清空") { binding.wrappedValue = "" }
        }
    }

    // MARK: 登录启动（SMAppService，对应 ProNotes 的 _launchAtLogin / LaunchAtLogin 证据）

    static func isLaunchAtLogin() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ on: Bool) async {
        do {
            if on {
                try await SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            print("launchAtLogin 失败：\(error.localizedDescription)")
        }
    }

    /// 拉取指定配置的模型列表（GET /models），写入该配置的模型菜单；
    /// 模型名为空时自动填第一个
    private func fetchModels(for id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let raw = profiles[idx].baseURL
        let key = profiles[idx].apiKey
        let name = profiles[idx].name.isEmpty ? "未命名" : profiles[idx].name
        fetchingID = id
        statusText = "正在请求 \(name) 的模型列表…"
        Task {
            do {
                guard let base = Config.apiBase(raw) else {
                    throw APIError(status: -1, message: "Base URL 为空")
                }
                let list = try await AIService.fetchModels(base: base, key: key)
                await MainActor.run {
                    modelsByProfile[id] = list
                    if let i = profiles.firstIndex(where: { $0.id == id }),
                       profiles[i].model.isEmpty {
                        profiles[i].model = list.first ?? ""
                    }
                    statusText = list.isEmpty
                        ? "\(name)：连接成功，但未返回模型列表，请手动填写模型名。"
                        : "\(name)：连接成功，发现 \(list.count) 个模型。"
                    fetchingID = nil
                }
            } catch {
                await MainActor.run {
                    statusText = "\(name)：失败：\(error.localizedDescription)"
                    fetchingID = nil
                }
            }
        }
    }
}
