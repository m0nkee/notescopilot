import Foundation
import CoreServices
import SQLite3

/// Swift 中 SQLITE_TRANSIENT 的等价物（-1 也表示“交由 SQLite 拷贝管理”
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - LiberatorLite：Apple Notes SQLite 直读（复刻 ProNotes Liberator 通道 1）
// SQL 语句均来自逆向报告的 cstring 证据：
// ZICCLOUDSYNCINGOBJECT 统一实体表、Z_ENT 实体类型、ZTITLE1 笔记标题、
// 行内附件 UTI（hashtag/link）、ZMARKEDFORDELETION 软删除过滤、COLLATE NOCASE 标签匹配

struct NoteSummary: Identifiable, Hashable, Sendable {
    let pk: Int64
    var uuid: String
    var title: String
    var snippet: String
    var modified: Date?
    var created: Date?
    var folder: String
    var id: Int64 { pk }
}

struct NoteContent: Sendable {
    let markdown: String
    let plainText: String
    let warning: String?
    let isComplete: Bool
}

struct NoteAIContext: Sendable {
    let note: NoteSummary
    let content: NoteContent
}

/// Shared by mouse/keyboard selection and exercised without a running Notes app.
struct LibrarySelectionState {
    private(set) var selectedID: Int64?
    private(set) var content: NoteContent?
    private(set) var isLoading = false
    private var requestID: UUID?

    mutating func begin(noteID: Int64?) -> UUID? {
        selectedID = noteID
        content = nil
        isLoading = noteID != nil
        requestID = noteID.map { _ in UUID() }
        return requestID
    }

    @discardableResult
    mutating func complete(_ content: NoteContent, noteID: Int64, requestID: UUID) -> Bool {
        guard selectedID == noteID, self.requestID == requestID else { return false }
        self.content = content
        isLoading = false
        return true
    }
}

struct LibraryQuery {
    var searchText = ""
    var folderPK: Int64?
    var hashtag: String?
    var sort: SearchSort = .updatedDescending

    func execute(in store: NotesStore) -> [NoteSummary] {
        var list = hashtag.map { store.notes(hashtag: $0) } ?? store.notes(folderPK: folderPK)
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let matches = Set(store.search(searchText).map(\.pk))
            list = list.filter { matches.contains($0.pk) }
        }
        return sort.sorted(list)
    }
}

// MARK: 搜索排序（证据：updatedDescending / updatedAscending / createdDescending / createdAscending）

enum SearchSort: String, CaseIterable {
    case updatedDescending, updatedAscending, createdDescending, createdAscending

    var label: String {
        switch self {
        case .updatedDescending: return "修改时间 ↓"
        case .updatedAscending: return "修改时间 ↑"
        case .createdDescending: return "创建时间 ↓"
        case .createdAscending: return "创建时间 ↑"
        }
    }

    func sorted(_ list: [NoteSummary]) -> [NoteSummary] {
        let updated = { (n: NoteSummary) in n.modified ?? .distantPast }
        let created = { (n: NoteSummary) in n.created ?? .distantPast }
        switch self {
        case .updatedDescending: return list.sorted { updated($0) > updated($1) }
        case .updatedAscending: return list.sorted { updated($0) < updated($1) }
        case .createdDescending: return list.sorted { created($0) > created($1) }
        case .createdAscending: return list.sorted { created($0) < created($1) }
        }
    }
}

enum StoreError: LocalizedError {
    case permissionDenied(String)
    case corrupted(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let p): return "无法读取 \(p)——需要在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中授权 NotesCopilot。"
        case .corrupted(let m): return "数据库异常：\(m)"
        }
    }
}

final class NotesStore: @unchecked Sendable {
    // One connection and one index are shared by UI reads and file-event indexing.
    // Recursive locking also keeps a search from observing a half-rebuilt index.
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var fts: OpaquePointer?
    private var hasFTS = false
    private let enableFTS: Bool
    private var separateDataColumns: Set<String> = []
    private var hasInlineTextMetadata = false
    let path: String
    private var noteEnt: Int64 = 12
    private var folderEnt: Int64 = 11
    private var dataEnt: Int64 = 13
    private var noteRefCol = "ZNOTEDATA"   // 笔记行指向数据实体的列
    private var noteTitleCol = "ZTITLE1"
    private var noteCreatedCol = "ZCREATIONDATE1"  // 创建时间列（缺列时回退修改时间）
    private var folderTitleCol = "ZTITLE2"
    private var blobCol = "ZDATA"
    private var indexCount = 0
    var indexedCount: Int { lock.lock(); defer { lock.unlock() }; return indexCount }

    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    init(path: String = NotesStore.defaultPath, enableFTS: Bool = true) throws {
        self.path = path
        self.enableFTS = enableFTS
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            let lower = msg.lowercased()
            if lower.contains("authorization") || lower.contains("denied") || lower.contains("unable to open") {
                throw StoreError.permissionDenied(path)
            }
            throw StoreError.corrupted(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try detectSchema()
        try buildFTS()
    }

    deinit {
        sqlite3_close(db)
        sqlite3_close(fts)
    }

    // MARK: 运行时 schema 探测（Z_PRIMARYKEY 映射 Z_ENT→实体名 + 列名自适应）

    private func detectSchema() throws {
        // Core Data 使用 Z_NAME；兼容早期导出数据库中的 ZNAME。
        let registryColumns = tableColumns("Z_PRIMARYKEY") ?? []
        guard let entityNameCol = ["Z_NAME", "ZNAME"].first(where: { registryColumns.contains($0) }),
              let rows = query("SELECT Z_ENT, \(entityNameCol) FROM Z_PRIMARYKEY") else {
            throw StoreError.corrupted("无法读取 Notes 实体映射表 Z_PRIMARYKEY")
        }
        for r in rows {
            let ent = (r[0] as? Int64) ?? -1
            let name = (r[1] as? String) ?? ""
            let n = name.lowercased()
            if n == "icfolder" || n == "folder" { folderEnt = ent }
            if n == "icnotedata" || n == "notedata" { dataEnt = ent }
            if n == "icnote" || n == "note" { noteEnt = ent }
        }
        // 列名自适应（不同 macOS 版本列名有差异）
        guard let cols = tableColumns("ZICCLOUDSYNCINGOBJECT"), !cols.isEmpty else {
            throw StoreError.corrupted("未找到 ZICCLOUDSYNCINGOBJECT 表")
        }
        if !cols.contains(noteTitleCol) { noteTitleCol = cols.first { $0.hasPrefix("ZTITLE") } ?? "ZTITLE1" }
        noteCreatedCol = cols.contains("ZCREATIONDATE1") ? "ZCREATIONDATE1"
            : (cols.first { $0.hasPrefix("ZCREATIONDATE") } ?? "ZMODIFICATIONDATE1")
        folderTitleCol = cols.contains("ZTITLE2") ? "ZTITLE2" : noteTitleCol
        noteRefCol = cols.contains("ZNOTEDATA") ? "ZNOTEDATA" : (cols.contains("ZDATA") ? "ZDATA" : noteRefCol)
        blobCol = cols.contains("ZDATA") ? "ZDATA" : "ZNSData"
        separateDataColumns = Set(tableColumns("ZICNOTEDATA") ?? [])
        hasInlineTextMetadata = ["ZIDENTIFIER", "ZTYPEUTI1", "ZALTTEXT", "ZNOTE1"].allSatisfy { cols.contains($0) }
    }

    private func tableColumns(_ table: String) -> [String]? {
        guard let rows = query("PRAGMA table_info(\(table))") else { return nil }
        return rows.compactMap { $0[1] as? String }
    }

    // MARK: 底层查询

    @discardableResult
    private func query(_ sql: String, _ args: [Any] = [], on handle: OpaquePointer? = nil) -> [[Any?]]? {
        lock.lock(); defer { lock.unlock() }
        let h = handle ?? db
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(args, to: stmt)
        var out: [[Any?]] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            var row: [Any?] = []
            let n = sqlite3_column_count(stmt)
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(Int64(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row.append(Double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) {
                        row.append(Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i))))
                    } else { row.append(nil) }
                default: row.append(nil)
                }
            }
            out.append(row)
            result = sqlite3_step(stmt)
        }
        return result == SQLITE_DONE ? out : nil
    }

    private func bind(_ args: [Any], to stmt: OpaquePointer?) {
        for (i, a) in args.enumerated() {
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let v as Int: sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
            case let v as String:
                _ = v.withCString { p in
                    sqlite3_bind_text(stmt, Int32(i + 1), p, Int32(v.utf8.count), SQLITE_TRANSIENT)
                }
            case let v as Double: sqlite3_bind_double(stmt, Int32(i + 1), v)
            default: break
            }
        }
    }

    // MARK: 笔记列表（证据 SQL：ZMARKEDFORDELETION != 1 过滤 + 置顶优先 + 修改时间倒序）

    func notes(limit: Int? = nil, folderPK: Int64? = nil) -> [NoteSummary] {
        lock.lock(); defer { lock.unlock() }
        var sql = """
        SELECT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1,
               COALESCE(NULLIF(f.\(folderTitleCol), ''), f.\(noteTitleCol), ''), n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
        WHERE n.Z_ENT = ? AND COALESCE(n.ZMARKEDFORDELETION, 0) != 1
        """
        var args: [Any] = [noteEnt]
        if let fp = folderPK {
            sql += " AND n.ZFOLDER = ?"
            args.append(fp)
        }
        sql += " ORDER BY n.ZISPINNED DESC, n.ZMODIFICATIONDATE1 DESC"
        if let limit { sql += " LIMIT ?"; args.append(max(0, limit)) }
        return (query(sql, args) ?? []).compactMap(Self.makeSummary)
    }

    func folders() -> [(pk: Int64, name: String)] {
        let sql = "SELECT Z_PK, COALESCE(NULLIF(\(folderTitleCol), ''), \(noteTitleCol)), ZFOLDERTYPE FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND COALESCE(ZMARKEDFORDELETION, 0) != 1 ORDER BY 2 ASC"
        return (query(sql, [folderEnt]) ?? []).compactMap { r in
            guard let pk = r[0] as? Int64, let name = r[1] as? String else { return nil }
            let t = (r[2] as? Int64) ?? 0
            return (pk, t == 0 ? name : (name.isEmpty ? "智能文件夹" : name))
        }
    }


    private static func makeSummary(_ row: [Any?]) -> NoteSummary? {
        guard let pk = row[0] as? Int64 else { return nil }
        let ts = (row[4] as? Double) ?? 0
        var date: Date?
        if ts > 0 {
            // NoteStore's Core Data date columns always use the 2001 epoch.
            date = Date(timeIntervalSinceReferenceDate: ts)
        }
        let ts2 = (row[6] as? Double) ?? 0
        var created: Date?
        if ts2 > 0 {
            created = Date(timeIntervalSinceReferenceDate: ts2)
        }
        return NoteSummary(pk: pk,
                           uuid: (row[1] as? String) ?? "",
                           title: (row[2] as? String) ?? "无标题",
                           snippet: (row[3] as? String) ?? "",
                           modified: date,
                           created: created,
                           folder: (row[5] as? String) ?? "")
    }

    // MARK: 话题标签（证据：行内附件 UTI + ZTOKENCONTENTIDENTIFIER COLLATE NOCASE + JOIN ZNOTE1）

    func hashtags() -> [String] {
        let sql = """
        SELECT DISTINCT h.ZTOKENCONTENTIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT h
        WHERE h.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag'
          AND COALESCE(h.ZMARKEDFORDELETION, 0) != 1
        ORDER BY 1
        """
        return (query(sql) ?? []).compactMap { $0[0] as? String }.filter { !$0.isEmpty }
    }

    func notes(hashtag: String) -> [NoteSummary] {
        let sql = """
        SELECT DISTINCT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1, '', n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT h
        JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = h.ZNOTE1
        WHERE h.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag'
          AND h.ZTOKENCONTENTIDENTIFIER = ? COLLATE NOCASE
          AND COALESCE(h.ZMARKEDFORDELETION, 0) != 1
          AND COALESCE(n.ZMARKEDFORDELETION, 0) != 1
        ORDER BY n.ZMODIFICATIONDATE1 DESC
        """
        return (query(sql, [hashtag]) ?? []).compactMap(Self.makeSummary)
    }

    // MARK: 反链（证据：行内 link 附件指向目标笔记 ZIDENTIFIER）

    func backlinks(toNoteUUID: String) -> [NoteSummary] {
        let sql = """
        SELECT DISTINCT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1, '', n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT h
        JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = h.ZNOTE1
        WHERE h.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.link'
          AND h.ZTOKENCONTENTIDENTIFIER = ? COLLATE NOCASE
          AND COALESCE(h.ZMARKEDFORDELETION, 0) != 1
          AND COALESCE(n.ZMARKEDFORDELETION, 0) != 1
        """
        return (query(sql, [toNoteUUID]) ?? []).compactMap(Self.makeSummary)
    }

    // MARK: 笔记正文数据（ZNOTEDATA/ZDATA → 数据实体行 → ZDATA blob → topotext）

    func noteBodyData(pk: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        // Modern Notes stores gzip protobuf bodies in a separate Core Data table.
        if separateDataColumns.contains("ZDATA") {
            if separateDataColumns.contains("ZNOTE"),
               let data = query("SELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE = ?", [pk])?.first?.first as? Data {
                return data
            }
            if separateDataColumns.contains("Z_PK"),
               let ref = query("SELECT \(noteRefCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", [pk])?.first?.first as? Int64,
               let data = query("SELECT ZDATA FROM ZICNOTEDATA WHERE Z_PK = ?", [ref])?.first?.first as? Data {
                return data
            }
        }
        let sql = "SELECT \(noteRefCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?"
        guard let ref = (query(sql, [pk])?.first?.first as? Int64) else { return nil }
        let blobSQL = "SELECT \(blobCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? AND Z_ENT = ?"
        if let d = query(blobSQL, [ref, dataEnt])?.first?.first as? Data { return d }
        return query("SELECT \(blobCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", [ref])?
            .first?.first as? Data
    }

    func document(for notePK: Int64) -> TopotextDoc? {
        guard let blob = noteBodyData(pk: notePK), let decoded = TopotextDecoder.decode(blob) else { return nil }
        guard !decoded.isComplete, hasInlineTextMetadata else { return decoded }
        let rows = query("""
            SELECT ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT FROM ZICCLOUDSYNCINGOBJECT
            WHERE ZNOTE1 = ? AND COALESCE(ZMARKEDFORDELETION, 0) != 1
              AND ZTYPEUTI1 IN ('com.apple.notes.inlinetextattachment.hashtag',
                               'com.apple.notes.inlinetextattachment.link')
            ORDER BY Z_PK
            """, [notePK]) ?? []
        var attachments: [String: TopotextInlineAttachment] = [:]
        for row in rows {
            guard let id = row[0] as? String, !id.isEmpty,
                  let type = row[1] as? String, let text = row[2] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            attachments[id] = TopotextInlineAttachment(typeUTI: type, text: text)
        }
        return attachments.isEmpty ? decoded : TopotextDecoder.decode(blob, inlineAttachments: attachments)
    }

    func content(for note: NoteSummary) -> NoteContent {
        if let doc = document(for: note.pk) {
            let warning = doc.warnings.isEmpty ? nil : doc.warnings.joined(separator: "；")
            let markdown = MarkdownConverter.convert(note: note, doc: doc)
            return NoteContent(markdown: markdown, plainText: doc.text,
                               warning: warning, isComplete: doc.isComplete)
        }
        let warning = "无法读取完整正文（可能为加密笔记或不支持的数据格式），当前仅显示摘要。"
        return NoteContent(markdown: MarkdownConverter.convert(note: note, doc: nil),
                           plainText: note.snippet, warning: warning, isComplete: false)
    }

    // MARK: 全文检索（复刻 Liberator.sqlite 的 FTS documents 表 + remove_diacritics=2）

    private func buildFTS() throws {
        var mem: OpaquePointer?
        guard sqlite3_open(":memory:", &mem) == SQLITE_OK, let mem else {
            throw StoreError.corrupted("无法创建内存索引")
        }
        fts = mem
        // Keep a plain, folded-text index as well: unicode61 cannot find CJK
        // substrings, and older system SQLite builds may not provide FTS5.
        guard sqlite3_exec(fts, "CREATE TABLE search_documents (id INTEGER PRIMARY KEY, text TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.corrupted("无法创建搜索索引")
        }
        hasFTS = enableFTS && sqlite3_exec(fts, "CREATE VIRTUAL TABLE documents USING fts5(title, snippet, body, tokenize='unicode61 remove_diacritics 2')", nil, nil, nil) == SQLITE_OK
        if enableFTS && !hasFTS {
            hasFTS = sqlite3_exec(fts, "CREATE VIRTUAL TABLE documents USING fts3(title, snippet, body, tokenize=unicode61)", nil, nil, nil) == SQLITE_OK
        }
        indexAll()
    }

    func indexAll() {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(fts, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        defer { sqlite3_exec(fts, "COMMIT", nil, nil, nil) }
        if hasFTS { _ = query("DELETE FROM documents", on: fts) }
        _ = query("DELETE FROM search_documents", on: fts)
        indexCount = 0
        for n in notes() {
            let body = document(for: n.pk)?.text ?? n.snippet
            let folded = Self.fold(n.title + "\n" + n.snippet + "\n" + body)
            if query("INSERT INTO search_documents(id, text) VALUES (?,?)", [n.pk, folded], on: fts) != nil {
                indexCount += 1
            }
            if hasFTS {
                _ = query("INSERT INTO documents(rowid,title,snippet,body) VALUES (?,?,?,?)",
                          [n.pk, n.title, n.snippet, body], on: fts)
            }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func search(_ text: String) -> [NoteSummary] {
        lock.lock(); defer { lock.unlock() }
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let terms = q.split(whereSeparator: { $0.isWhitespace }).map { Self.fold(String($0)) }
        guard !terms.isEmpty else { return [] }
        // Literal AND substrings work for Chinese and punctuation-heavy text,
        // never interpret user input as an FTS query or LIKE pattern.
        let clauses = Array(repeating: "instr(text, ?) > 0", count: terms.count).joined(separator: " AND ")
        let rows = query("SELECT id FROM search_documents WHERE \(clauses)", terms, on: fts) ?? []
        let pks = Set(rows.compactMap { $0[0] as? Int64 })
        return notes().filter { pks.contains($0.pk) }
    }
}

// MARK: - FSEvents 监听重索引（复刻 ProNotes 的 FSEventStreamDelegate / notesDb 证据）

/// 监听 NoteStore.sqlite 所在目录的文件事件，去抖后在后台重跑 FTS 索引。
/// 完成后广播 nc.storeDidReindex（object = 已索引条数），笔记库窗口据此自动刷新。
final class StoreWatcher {
    private let store: NotesStore
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "nc.storewatcher", qos: .utility)

    init(store: NotesStore) { self.store = store }

    func start() {
        let dir = (store.path as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passRetained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<StoreWatcher>.fromOpaque(info).takeUnretainedValue().scheduleReindex()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [dir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
    }

    /// 去抖：Notes 落盘（WAL 切换）会产生连续事件，合并为一次重索引
    fileprivate func scheduleReindex() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.store.indexAll()
                let count = self.store.indexedCount
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .init("nc.storeDidReindex"), object: count)
                }
            }
            self.pending = item
            self.queue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }
}
