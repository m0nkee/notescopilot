import Foundation
import CoreServices
import SQLite3

/// Swift 中 SQLITE_TRANSIENT 的等价物（-1 也表示“交由 SQLite 拷贝管理”
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - LiberatorLite：Apple Notes SQLite 直读（复刻 ProNotes Liberator 通道 1）
// SQL 语句均来自逆向报告的 cstring 证据：
// ZICCLOUDSYNCINGOBJECT 统一实体表、Z_ENT 实体类型、ZTITLE1 笔记标题、
// 行内附件 UTI（hashtag/link）、ZMARKEDFORDELETION 软删除过滤、COLLATE NOCASE 标签匹配

struct NoteSummary: Identifiable, Hashable {
    let pk: Int64
    var uuid: String
    var title: String
    var snippet: String
    var modified: Date?
    var created: Date?
    var folder: String
    var id: Int64 { pk }
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

final class NotesStore {
    private var db: OpaquePointer?
    private var fts: OpaquePointer?
    let path: String
    private var noteEnt: Int64 = 12
    private var folderEnt: Int64 = 11
    private var dataEnt: Int64 = 13
    private var noteRefCol = "ZNOTEDATA"   // 笔记行指向数据实体的列
    private var noteTitleCol = "ZTITLE1"
    private var noteCreatedCol = "ZCREATIONDATE1"  // 创建时间列（缺列时回退修改时间）
    private var folderTitleCol = "ZTITLE2"
    private var blobCol = "ZDATA"
    private(set) var indexedCount = 0

    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    init(path: String = NotesStore.defaultPath) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if sqlite3_open_v2(path, nil, flags, nil) != SQLITE_OK {
                let lower = msg.lowercased()
                if lower.contains("authorization") || lower.contains("denied") || lower.contains("unable to open") {
                    throw StoreError.permissionDenied(path)
                }
            }
            throw StoreError.corrupted(msg)
        }
        db = handle
        try detectSchema()
        try buildFTS()
    }

    deinit {
        sqlite3_close(db)
        sqlite3_close(fts)
    }

    // MARK: 运行时 schema 探测（Z_PRIMARYKEY 映射 Z_ENT→实体名 + 列名自适应）

    private func detectSchema() throws {
        // 实体码：Z_PRIMARYKEY(Z_ENT, ZNAME) —— ICFolder / ICNote / ICNoteData
        if let rows = query("SELECT Z_ENT, ZNAME FROM Z_PRIMARYKEY") {
            for r in rows {
                let ent = (r[0] as? Int64) ?? -1
                let name = (r[1] as? String) ?? ""
                let n = name.lowercased()
                if n.contains("folder") { folderEnt = ent }
                if n.contains("notedata") { dataEnt = ent }
                else if n.contains("note") { noteEnt = ent }
            }
        }
        // 列名自适应（不同 macOS 版本列名有差异）
        guard let cols = tableColumns("ZICCLOUDSYNCINGOBJECT") else {
            throw StoreError.corrupted("未找到 ZICCLOUDSYNCINGOBJECT 表")
        }
        if !cols.contains(noteTitleCol) { noteTitleCol = cols.first { $0.hasPrefix("ZTITLE") } ?? "ZTITLE1" }
        noteCreatedCol = cols.first { $0.hasPrefix("ZCREATIONDATE") } ?? "ZMODIFICATIONDATE1"
        folderTitleCol = cols.contains("ZTITLE2") ? "ZTITLE2" : noteTitleCol
        noteRefCol = cols.contains("ZNOTEDATA") ? "ZNOTEDATA" : (cols.contains("ZDATA") ? "ZDATA" : noteRefCol)
        blobCol = cols.contains("ZDATA") ? "ZDATA" : "ZNSData"
    }

    private func tableColumns(_ table: String) -> [String]? {
        guard let rows = query("PRAGMA table_info(\(table))") else { return nil }
        return rows.compactMap { $0[1] as? String }
    }

    // MARK: 底层查询

    @discardableResult
    private func query(_ sql: String, _ args: [Any] = [], on handle: OpaquePointer? = nil) -> [[Any?]]? {
        let h = handle ?? db
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(args, to: stmt)
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
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
        }
        return out
    }

    private func bind(_ args: [Any], to stmt: OpaquePointer?) {
        for (i, a) in args.enumerated() {
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let v as Int: sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
            case let v as String:
                let arr = [UInt8](v.utf8)
                arr.withUnsafeBufferPointer { buf in
                    if let p = buf.baseAddress {
                        sqlite3_bind_text(stmt, Int32(i + 1), p, Int32(buf.count), SQLITE_TRANSIENT)
                    }
                }
            case let v as Double: sqlite3_bind_double(stmt, Int32(i + 1), v)
            default: break
            }
        }
    }

    // MARK: 笔记列表（证据 SQL：ZMARKEDFORDELETION != 1 过滤 + 置顶优先 + 修改时间倒序）

    func notes(limit: Int = 500, folderPK: Int64? = nil) -> [NoteSummary] {
        var sql = """
        SELECT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1,
               COALESCE(NULLIF(f.\(folderTitleCol), ''), f.\(noteTitleCol), ''), n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
        WHERE n.Z_ENT = ? AND n.ZMARKEDFORDELETION != 1
        """
        var args: [Any] = [noteEnt]
        if let fp = folderPK {
            sql += " AND n.ZFOLDER = ?"
            args.append(fp)
        }
        sql += " ORDER BY n.ZISPINNED DESC, n.ZMODIFICATIONDATE1 DESC LIMIT ?"
        args.append(limit)
        return (query(sql, args) ?? []).compactMap(Self.makeSummary)
    }

    func folders() -> [(pk: Int64, name: String)] {
        let sql = "SELECT Z_PK, COALESCE(NULLIF(\(folderTitleCol), ''), \(noteTitleCol)), ZFOLDERTYPE FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND ZMARKEDFORDELETION != 1 ORDER BY 2 ASC"
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
            // Core Data 时间戳（2001 纪元）或 Unix 纪元自适应
            date = ts > 600_000_000 ? Date(timeIntervalSince1970: ts) : Date(timeIntervalSinceReferenceDate: ts)
        }
        let ts2 = (row[6] as? Double) ?? 0
        var created: Date?
        if ts2 > 0 {
            created = ts2 > 600_000_000 ? Date(timeIntervalSince1970: ts2) : Date(timeIntervalSinceReferenceDate: ts2)
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
          AND h.ZMARKEDFORDELETION != 1
        ORDER BY 1
        """
        return (query(sql) ?? []).compactMap { $0[0] as? String }.filter { !$0.isEmpty }
    }

    func notes(hashtag: String) -> [NoteSummary] {
        let sql = """
        SELECT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1, '', n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT h
        JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = h.ZNOTE1
        WHERE h.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag'
          AND h.ZTOKENCONTENTIDENTIFIER = ? COLLATE NOCASE
          AND h.ZMARKEDFORDELETION != 1
        ORDER BY n.ZMODIFICATIONDATE1 DESC
        """
        return (query(sql, [hashtag]) ?? []).compactMap(Self.makeSummary)
    }

    // MARK: 反链（证据：行内 link 附件指向目标笔记 ZIDENTIFIER）

    func backlinks(toNoteUUID: String) -> [NoteSummary] {
        let sql = """
        SELECT n.Z_PK, n.ZIDENTIFIER, n.\(noteTitleCol), n.ZSNIPPET, n.ZMODIFICATIONDATE1, '', n.\(noteCreatedCol)
        FROM ZICCLOUDSYNCINGOBJECT h
        JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = h.ZNOTE1
        WHERE h.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.link'
          AND h.ZTOKENCONTENTIDENTIFIER = ? COLLATE NOCASE
          AND h.ZMARKEDFORDELETION != 1
        """
        return (query(sql, [toNoteUUID]) ?? []).compactMap(Self.makeSummary)
    }

    // MARK: 笔记正文数据（ZNOTEDATA/ZDATA → 数据实体行 → ZDATA blob → topotext）

    func noteBodyData(pk: Int64) -> Data? {
        let sql = "SELECT \(noteRefCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?"
        guard let ref = (query(sql, [pk])?.first?.first as? Int64) else { return nil }
        let blobSQL = "SELECT \(blobCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? AND Z_ENT = ?"
        if let d = query(blobSQL, [ref, dataEnt])?.first?.first as? Data { return d }
        return query("SELECT \(blobCol) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", [ref])?
            .first?.first as? Data
    }

    // MARK: 全文检索（复刻 Liberator.sqlite 的 FTS documents 表 + remove_diacritics=2）

    private func buildFTS() throws {
        var mem: OpaquePointer?
        guard sqlite3_open(":memory:", &mem) == SQLITE_OK, let mem else {
            throw StoreError.corrupted("无法创建内存索引")
        }
        fts = mem
        // 先尝试 fts5（系统 SQLite 支持），失败退回 fts3（与 ProNotes 相同）
        if sqlite3_exec(fts, "CREATE VIRTUAL TABLE documents USING fts5(title, snippet, tokenize='unicode61 remove_diacritics 2')", nil, nil, nil) != SQLITE_OK {
            guard sqlite3_exec(fts, "CREATE VIRTUAL TABLE documents USING fts3(title, snippet, tokenize=? )", nil, nil, nil) != SQLITE_OK else {
                throw StoreError.corrupted("FTS 不可用")
            }
        }
        indexAll()
    }

    func indexAll() {
        _ = query("DELETE FROM documents", on: fts)
        indexedCount = 0
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(fts, "INSERT INTO documents(rowid, title, snippet) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        indexedCount = 0
        for n in notes(limit: 5000) {
            let t2 = [UInt8](n.title.utf8)
            let s2 = [UInt8](n.snippet.utf8)
            t2.withUnsafeBufferPointer { tb2 in
                s2.withUnsafeBufferPointer { sb2 in
                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, n.pk)
                    if let tp = tb2.baseAddress {
                        sqlite3_bind_text(stmt, 2, tp, Int32(tb2.count), SQLITE_TRANSIENT)
                    }
                    if let sp = sb2.baseAddress {
                        sqlite3_bind_text(stmt, 3, sp, Int32(sb2.count), SQLITE_TRANSIENT)
                    }
                    if sqlite3_step(stmt) == SQLITE_DONE { indexedCount += 1 }
                }
            }
        }
    }

    func search(_ text: String) -> [NoteSummary] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var terms = q.split(separator: " ").map { String($0).replacingOccurrences(of: "\"", with: "") }
        terms = terms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        // 逐词前缀查询后取交集（CJK 无分词时多词 AND 更可靠）
        var sets: [Set<Int64>] = []
        for t in terms {
            guard let rows = query("SELECT rowid FROM documents WHERE documents MATCH ? ORDER BY rank",
                                   ["\"\(t)\"*"], on: fts) else { return [] }
            sets.append(Set(rows.compactMap { $0[0] as? Int64 }))
        }
        var pks = sets.first ?? []
        for s in sets.dropFirst() { pks.formIntersection(s) }
        let all = notes(limit: 5000)
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.pk, $0) })
        return pks.sorted().compactMap { map[$0] }
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
