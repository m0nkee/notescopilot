import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 笔记库窗口（对应 ProNotes 的笔记列表 / FTS 搜索 / Hashtag 标签页 / Backlinks 反链 / 复制 Markdown）

struct LibraryView: View {
    @ObservedObject private var localization = L10n.shared
    @State private var notesList: [NoteSummary] = []
    @State private var foldersList: [(pk: Int64, name: String)] = []
    @State private var tags: [String] = []
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "nc.library.recentSearches") ?? []
    @State private var showMarkdownPreview = false
    @State private var selectedNote: NoteSummary?
    @State private var selection = LibrarySelectionState()
    @State private var backlinksList: [NoteSummary] = []
    @State private var storeUnavailable = false
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
    private var storeError: String? {
        guard storeUnavailable else { return nil }
        let delegate = NSApp.delegate as? AppDelegate
        if delegate?.notesStoreLoading == true {
            return L10n.text("Connecting to the notes library and building the search index…")
        }
        return delegate?.notesStoreError ?? L10n.text("Could not read the notes library. Grant Full Disk Access and reconnect.")
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
        .environment(\.locale, localization.locale)
        .toolbar {
            ToolbarItem {
                Button {
                    reload()
                } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button {
                    copyMarkdown()
                } label: { Label(L10n.text("Copy Markdown"), systemImage: "doc.on.doc") }
                .disabled(!canUseContent)
            }
            ToolbarItem {
                Button {
                    exportMarkdown()
                } label: { Label(L10n.text("Export .md File"), systemImage: "square.and.arrow.up") }
                .disabled(!canUseContent)
            }
        }
        .onAppear { reload() }
        .onChange(of: searchText) { _ in
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeAvailable"))) { _ in reload() }
        // FSEvents 重索引完成后自动刷新（对应 ProNotes 的 Indexing completed → 刷新列表）
        .onReceive(NotificationCenter.default.publisher(for: .init("nc.storeDidReindex"))) { _ in
            reload()
        }
        .alert(L10n.text("Export Failed"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    // MARK: 侧栏：文件夹 + 标签

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("Folders"), systemImage: "folder")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
            Button {
                searchText = ""
                selectedFolder = nil; selectedTag = nil
                reload()
            } label: {
                Label(L10n.text("All Notes"), systemImage: "tray.full").frame(maxWidth: .infinity, alignment: .leading)
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
            Label(L10n.text("Tags"), systemImage: "number")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if tags.isEmpty {
                        Text(L10n.text("No tags")).font(.caption2).foregroundColor(.secondary)
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
            searchControls
            Divider()
            List(selection: Binding<Int64?>(get: { selection.selectedID }, set: { id in
                select(id.flatMap { value in notesList.first { $0.pk == value } })
            })) {
                ForEach(notesList) { n in
                    NoteRow(note: n, query: searchText.trimmingCharacters(in: .whitespaces))
                        .tag(n.pk)
                        .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .overlay {
                if !busy && notesList.isEmpty && storeError == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text(L10n.text("No matching notes")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let err = storeError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err).font(.caption).foregroundColor(.orange)
                    if (NSApp.delegate as? AppDelegate)?.notesStoreLoading != true {
                        Button(L10n.text("Open Full Disk Access Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button(L10n.text("Reconnect Notes Library")) {
                            NSApp.sendAction(#selector(AppDelegate.retryNotesStore), to: nil, from: nil)
                        }
                    }
                }.padding(8)
            } else {
                Text(busy ? L10n.text("Reading notes…") : noteCount)
                    .font(.caption2).foregroundColor(.secondary).padding(4)
            }
        }
        .frame(width: 280)
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L10n.text("Search notes"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Search note titles and contents"))
                    .onSubmit { rememberSearch(); reload() }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        reload()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Clear Search"))
                }
                Button(L10n.text("Search")) { rememberSearch(); reload() }
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack {
                if !recentSearches.isEmpty {
                    Menu {
                        ForEach(recentSearches, id: \.self) { query in
                            Button(query) {
                                searchText = query
                                rememberSearch(query)
                                reload()
                            }
                        }
                        Button(L10n.text("Clear Recent Searches")) {
                            recentSearches = []
                            UserDefaults.standard.set([String](), forKey: "nc.library.recentSearches")
                        }
                    } label: {
                        Label(L10n.text("Recent"), systemImage: "clock.arrow.circlepath")
                    }
                    .fixedSize()
                }
                Menu {
                    ForEach(SearchSort.allCases, id: \.self) { sort in
                        Button(sort.label) { sortOrder = sort; reload() }
                    }
                } label: {
                    Label(sortOrder.label, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    // MARK: 右栏：正文 + 反链

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = selectedNote {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.displayTitle).font(.title3.bold()).lineLimit(2)
                        Text([note.folder, note.modified.map { dateFormat.format($0) } ?? ""]
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
                            Label(L10n.text("Ask AI"), systemImage: "sparkles")
                        }
                        .disabled(!canUseContent || selection.content?.isComplete != true)
                        Button {
                            copyMarkdown()
                        } label: {
                            Label(L10n.text("Copy MD"), systemImage: "doc.on.doc")
                        }
                        .disabled(!canUseContent)
                        // 复制 deeplink（对应 ProNotes 的 CopyDeeplinkButton / copySelectedNoteLink）
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(NotesBridge.deeplink(forNoteID: note.uuid), forType: .string)
                        } label: {
                            Label(L10n.text("Copy Link"), systemImage: "link")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                Divider()
                if selection.isLoading {
                    ProgressView(L10n.text("Reading note…")).padding(12)
                }
                if let warning = selection.content?.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(12)
                }
                HStack {
                    Picker(L10n.text("Format"), selection: $showMarkdownPreview) {
                        Text("Markdown").tag(false)
                        Text(L10n.text("Preview")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer()
                }
                .padding(.horizontal, 12)
                ScrollView {
                    if showMarkdownPreview {
                        MarkdownPreview(text: bodyMarkdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        Text(bodyMarkdown)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                if !backlinksList.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L10n.format("Backlinks (%lld)", Int64(backlinksList.count)), systemImage: "link")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(backlinksList) { b in
                                    Button(b.displayTitle) {
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
                    Text(L10n.text("Select a note to view its contents"))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 逻辑

    private var dateFormat: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localization.locale)
    }

    private var noteCount: String {
        L10n.format(notesList.count == 1 ? "%lld note" : "%lld notes", Int64(notesList.count))
    }

    private var store: NotesStore? {
        (NSApp.delegate as? AppDelegate)?.notesStore
    }

    private func rememberSearch(_ rawQuery: String? = nil) {
        let query = (rawQuery ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0 == query }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "nc.library.recentSearches")
    }

    private func reload() {
        let requestID = UUID()
        listRequestID = requestID
        busy = true
        storeUnavailable = false
        // 后台线程读库，主线程更新
        let storeRef = store
        let query = LibraryQuery(searchText: searchText, folderPK: selectedFolder,
                                 hashtag: selectedTag, sort: sortOrder)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let storeRef else {
                DispatchQueue.main.async {
                    guard listRequestID == requestID else { return }
                    storeUnavailable = true
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
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Self.highlighted(note.displayTitle, query: query).font(.callout.weight(.medium)).lineLimit(1)
            Self.highlighted(note.snippet.replacingOccurrences(of: "\u{FFFC}", with: ""), query: query)
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    static func highlighted(_ text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Text(verbatim: text) }
        var result = Text("")
        var start = text.startIndex
        while let range = text.range(of: trimmed,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex) {
            result = result + Text(verbatim: String(text[start..<range.lowerBound]))
                + Text(verbatim: String(text[range])).foregroundColor(.orange).bold()
            start = range.upperBound
        }
        return result + Text(verbatim: String(text[start...]))
    }
}
