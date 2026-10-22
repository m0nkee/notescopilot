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
    @State private var bodyMarkdown = ""
    @State private var backlinksList: [NoteSummary] = []
    @State private var storeError: String?
    @State private var busy = false
    @State private var sortOrder: SearchSort = .updatedDescending

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
                .disabled(selectedNote == nil)
            }
            ToolbarItem {
                Button {
                    exportMarkdown()
                } label: { Label("导出 .md 文件", systemImage: "square.and.arrow.up") }
                .disabled(selectedNote == nil)
            }
        }
        .onAppear { reload() }
        // FSEvents 重索引完成后自动刷新（对应 ProNotes 的 Indexing completed → 刷新列表）
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeDidReindex"))) { _ in
            reload()
        }
    }

    // MARK: 侧栏：文件夹 + 标签

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("文件夹", systemImage: "folder")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
            Button {
                searchText = ""
                reload(folder: nil)
            } label: {
                Label("全部笔记", systemImage: "tray.full").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).padding(.horizontal, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(foldersList, id: \.pk) { f in
                        Button {
                            reload(folder: f.pk)
                        } label: {
                            Label(f.name, systemImage: "folder").lineLimit(1)
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
                            reload(hashtag: t)
                        } label: {
                            Label("#" + t, systemImage: "tag").lineLimit(1)
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
                TextField("全文搜索（FTS，支持音调折叠）", text: $searchText)
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
            List(selection: $selectedNote) {
                ForEach(notesList) { n in
                    NoteRow(note: n)
                        .tag(n)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            select(n)
                        }
                }
            }
            .listStyle(.plain)
            if let err = storeError {
                Text(err).font(.caption).foregroundColor(.orange).padding(8)
            } else {
                Text("\(notesList.count) 条笔记")
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
                            NSApp.sendAction(#selector(AppDelegate.openPanelWithNote(_:)), to: nil, from: note)
                        } label: {
                            Label("问 AI", systemImage: "sparkles")
                        }
                        Button {
                            copyMarkdown()
                        } label: {
                            Label("复制 MD", systemImage: "doc.on.doc")
                        }
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
                    Text("选择左侧笔记查看正文（topotext → Markdown）")
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

    private func reload(folder: Int64? = nil, hashtag: String? = nil) {
        busy = true
        storeError = nil
        selectedNote = nil
        bodyMarkdown = ""
        backlinksList = []
        // 后台线程读库，主线程更新
        let storeRef = store
        let q = searchText.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let storeRef else {
                DispatchQueue.main.async {
                    storeError = "数据库未打开（可能无权限）。"
                    busy = false
                }
                return
            }
            var list: [NoteSummary] = []
            if !q.isEmpty {
                list = storeRef.search(q)
            } else if let tag = hashtag {
                list = storeRef.notes(hashtag: tag)
            } else {
                list = storeRef.notes(folderPK: folder)
            }
            let tagsAll = storeRef.hashtags()
            let folders = storeRef.folders()
            DispatchQueue.main.async {
                notesList = sortOrder.sorted(list)
                tags = tagsAll
                foldersList = folders
                busy = false
            }
        }
    }

    private func select(_ note: NoteSummary) {
        selectedNote = note
        guard let store else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var md = ""
            if let blob = store.noteBodyData(pk: note.pk),
               let doc = TopotextDecoder.decode(blob) {
                md = MarkdownConverter.convert(note: note, doc: doc)
            } else {
                md = MarkdownConverter.convert(note: note, doc: nil)
            }
            let bl = store.backlinks(toNoteUUID: note.uuid)
            DispatchQueue.main.async {
                bodyMarkdown = md
                backlinksList = bl
            }
        }
    }

    private func copyMarkdown() {
        guard let note = selectedNote else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(bodyMarkdown.isEmpty ? note.snippet : bodyMarkdown, forType: .string)
    }

    private func exportMarkdown() {
        guard !bodyMarkdown.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (selectedNote?.title.replacingOccurrences(
            of: "/", with: "-").prefix(60) ?? "note") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? bodyMarkdown.data(using: .utf8)?.write(to: url)
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
