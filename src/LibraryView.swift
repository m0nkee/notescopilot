import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 笔记库窗口（对应 ProNotes 的笔记列表 / FTS 搜索 / Hashtag 标签页 / Backlinks 反链 / 复制 Markdown）

struct LibraryView: View {
    @State private var notesList: [NoteSummary] = []
    @State private var foldersList: [(pk: Int64, name: String)] = []
    @State private var tags: [String] = []
    @State private var searchText = ""
    @State private var selectedNote: NoteSummary?
    @State private var selection = LibrarySelectionState()
    @State private var backlinksList: [NoteSummary] = []
    @State private var storeError: String?
    @State private var busy = false
    @State private var sortOrder: SearchSort = .updatedDescending
    @State private var selectedFolder: Int64?
    @State private var selectedTag: String?
    @State private var listRequestID = UUID()
    @State private var exportError: String?

    private var bodyMarkdown: String { selection.content?.markdown ?? "" }
    private var canUseContent: Bool {
        selectedNote != nil && selectedNote?.pk == selection.selectedID
            && selection.content != nil && !selection.isLoading
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            noteList
            Divider()
            detail
        }
        .frame(minWidth: 880, minHeight: 560)
        .toolbar {
            ToolbarItem {
                Button {
                    reload()
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button {
                    copyMarkdown()
                } label: { Label("复制 Markdown", systemImage: "doc.on.doc") }
                .disabled(!canUseContent)
            }
            ToolbarItem {
                Button {
                    exportMarkdown()
                } label: { Label("导出 .md 文件", systemImage: "square.and.arrow.up") }
                .disabled(!canUseContent)
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeAvailable"))) { _ in reload() }
        // FSEvents 重索引完成后自动刷新（对应 ProNotes 的 Indexing completed → 刷新列表）
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeDidReindex"))) { _ in
            reload()
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    // MARK: 侧栏：文件夹 + 标签

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("文件夹", systemImage: "folder")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
            Button {
                searchText = ""
                selectedFolder = nil; selectedTag = nil
                reload()
            } label: {
                Label("全部笔记", systemImage: "tray.full").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).padding(.horizontal, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(foldersList, id: \.pk) { f in
                        Button {
                            selectedFolder = f.pk; selectedTag = nil
                            reload()
                        } label: {
                            Label(f.name, systemImage: "folder").lineLimit(1)
                                .foregroundStyle(selectedFolder == f.pk ? Color.accentColor : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 6)
            }
            Divider().padding(.vertical, 4)
            Label("Hashtag 标签", systemImage: "number")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if tags.isEmpty {
                        Text("暂无标签").font(.caption2).foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                    }
                    ForEach(tags, id: \.self) { t in
                        Button {
                            selectedTag = t; selectedFolder = nil
                            reload()
                        } label: {
                            Label("#" + t, systemImage: "tag").lineLimit(1)
                                .foregroundStyle(selectedTag == t ? Color.accentColor : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 中栏：搜索 + 列表

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索标题和正文", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reload() }
                Button("搜") { reload() }
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                // 排序菜单（证据：updatedDescending / updatedAscending / createdDescending / createdAscending）
                Menu {
                    ForEach(SearchSort.allCases, id: \.self) { s in
                        Button(s.label) { sortOrder = s; reload() }
                    }
                } label: {
                    Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon).controlSize(.small)
                }
                .fixedSize()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(8)
            Divider()
            List(selection: Binding<Int64?>(get: { selection.selectedID }, set: { id in
                select(id.flatMap { value in notesList.first { $0.pk == value } })
            })) {
                ForEach(notesList) { n in
                    NoteRow(note: n)
                        .tag(n.pk)
                        .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .overlay {
                if !busy && notesList.isEmpty && storeError == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("没有符合条件的笔记").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let err = storeError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err).font(.caption).foregroundColor(.orange)
                    if (NSApp.delegate as? AppDelegate)?.notesStoreLoading != true {
                        Button("打开完全磁盘访问设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("重新连接笔记库") {
                            NSApp.sendAction(#selector(AppDelegate.retryNotesStore), to: nil, from: nil)
                        }
                    }
                }.padding(8)
            } else {
                Text(busy ? "正在读取笔记…" : "\(notesList.count) 条笔记")
                    .font(.caption2).foregroundColor(.secondary).padding(4)
            }
        }
        .frame(width: 280)
    }

    // MARK: 右栏：正文 + 反链

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = selectedNote {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.title3.bold()).lineLimit(2)
                        Text([note.folder, note.modified.map { Self.df.string(from: $0) } ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Button {
                            // 用笔记上下文发起 AI 请求：桥接笔记库与 Ask AI
                            guard canUseContent, let content = selection.content, content.isComplete else { return }
                            NSApp.sendAction(#selector(AppDelegate.openPanelWithNote(_:)), to: nil,
                                             from: NoteAIContext(note: note, content: content))
                        } label: {
                            Label("问 AI", systemImage: "sparkles")
                        }
                        .disabled(!canUseContent || selection.content?.isComplete != true)
                        Button {
                            copyMarkdown()
                        } label: {
                            Label("复制 MD", systemImage: "doc.on.doc")
                        }
                        .disabled(!canUseContent)
                        // 复制 deeplink（对应 ProNotes 的 CopyDeeplinkButton / copySelectedNoteLink）
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(NotesBridge.deeplink(forNoteID: note.uuid), forType: .string)
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                Divider()
                if selection.isLoading {
                    ProgressView("正在读取正文…").padding(12)
                }
                if let warning = selection.content?.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(12)
                }
                ScrollView {
                    Text(bodyMarkdown)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                if !backlinksList.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Backlinks 反链（\(backlinksList.count)）", systemImage: "link")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(backlinksList) { b in
                                    Button(b.title.isEmpty ? "无标题" : b.title) {
                                        select(b)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.squares.right")
                        .font(.system(size: 36)).foregroundColor(.secondary)
                    Text("选择笔记查看正文")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 逻辑

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var store: NotesStore? {
        (NSApp.delegate as? AppDelegate)?.notesStore
    }

    private func reload() {
        let requestID = UUID()
        listRequestID = requestID
        busy = true
        storeError = nil
        // 后台线程读库，主线程更新
        let storeRef = store
        let query = LibraryQuery(searchText: searchText, folderPK: selectedFolder,
                                 hashtag: selectedTag, sort: sortOrder)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let storeRef else {
                DispatchQueue.main.async {
                    guard listRequestID == requestID else { return }
                    let delegate = NSApp.delegate as? AppDelegate
                    storeError = delegate?.notesStoreLoading == true ? "正在连接笔记库并建立全文索引…"
                        : (delegate?.notesStoreError ?? "无法读取笔记库。请授权完全磁盘访问后重新连接。")
                    busy = false
                }
                return
            }
            let list = query.execute(in: storeRef)
            let tagsAll = storeRef.hashtags()
            let folders = storeRef.folders()
            DispatchQueue.main.async {
                guard listRequestID == requestID else { return }
                notesList = list
                tags = tagsAll
                foldersList = folders
                busy = false
                if let id = selection.selectedID {
                    select(notesList.first { $0.pk == id })
                }
            }
        }
    }

    private func select(_ note: NoteSummary?) {
        selectedNote = note
        backlinksList = []
        guard let requestID = selection.begin(noteID: note?.pk), let note, let store else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let content = store.content(for: note)
            let bl = store.backlinks(toNoteUUID: note.uuid)
            DispatchQueue.main.async {
                guard selection.complete(content, noteID: note.pk, requestID: requestID) else { return }
                backlinksList = bl
            }
        }
    }

    private func copyMarkdown() {
        guard canUseContent else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(bodyMarkdown, forType: .string)
    }

    private func exportMarkdown() {
        guard canUseContent, !bodyMarkdown.isEmpty else { return }
        let markdown = bodyMarkdown
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (selectedNote?.title.replacingOccurrences(
            of: "/", with: "-").prefix(60) ?? "note") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try Data(markdown.utf8).write(to: url, options: .atomic) }
            catch { exportError = error.localizedDescription }
        }
    }
}

struct NoteRow: View {
    let note: NoteSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(note.snippet.replacingOccurrences(of: "\u{FFFC}", with: ""))
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
