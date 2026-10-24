import Foundation
import AppKit
import SQLite3
import Compression
import zlib

// notescopilot v3 端到端验证：合成 NoteStore fixture → NotesStore 查询 → topotext 解码 → Markdown

let SQLITE_TRANSIENT_FIX = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : "  \(detail)")")
    if !ok { failures += 1 }
}

// ---------- 1. 造 protobuf 数据 ----------

func varint(_ v: UInt64) -> [UInt8] {
    var out: [UInt8] = []
    var x = v
    repeat {
        var b = UInt8(x & 0x7F)
        x >>= 7
        if x != 0 { b |= 0x80 }
        out.append(b)
    } while x != 0
    return out
}
func tag(_ n: Int, _ wt: Int) -> [UInt8] { varint(UInt64(n << 3 | wt)) }
func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { tag(n, 2) + varint(UInt64(bytes.count)) + bytes }
func fieldStr(_ n: Int, _ s: String) -> [UInt8] { field(n, Array(s.utf8)) }
func fieldVar(_ n: Int, _ v: UInt64) -> [UInt8] { tag(n, 0) + varint(v) }

// NoteData 包装：字段2 = Document
// Document: 字段1 = repeated AttributeRun；同时嵌一个文本字段（模拟 CRDT 树中的字符串）
// AttributeRun: 字段4 = length(varint), 字段2 = paragraphStyle 嵌套消息
let run1 = fieldVar(4, 5) + field(2, fieldVar(1, 1))                       // 标题段 5 字符
let run2 = fieldVar(4, 12) + field(2, fieldVar(1, 0))                      // 正文段 12 字符
let docBody = field(1, run1) + field(1, run2) + fieldStr(3, "会议纪要标题正文内容")
let noteData = field(2, docBody)

// zlib 压缩版（0x78 头）验证 zlibInflate 通道
let plain = Data(docBody)
var compressed = Data([0x78, 0x9C])
do {
    let src = [UInt8](plain)
    var dst = [UInt8](repeating: 0, count: plain.count + 1024)
    let n: Int = src.withUnsafeBufferPointer { sp in
        dst.withUnsafeMutableBufferPointer { dp in
            compression_encode_buffer(dp.baseAddress!, dp.count, sp.baseAddress!, sp.count, nil, COMPRESSION_ZLIB)
        }
    }
    check("zlib 压缩成功", n > 0)
    // compression_encode_buffer 产出 raw DEFLATE，手工加 zlib 容器：0x78 0x9C + deflate + adler32(BE)
    var a1: UInt32 = 1, a2: UInt32 = 0
    for b in src { a1 = (a1 + UInt32(b)) % 65521; a2 = (a2 + a1) % 65521 }
    let adler = (a2 << 16) | a1
    compressed.append(Data(dst.prefix(n)))
    compressed.append(Data([UInt8((adler >> 24) & 0xFF), UInt8((adler >> 16) & 0xFF),
                            UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]))
}

// ---------- 2. 造 fixture SQLite ----------

let fixturePath = NSTemporaryDirectory() + "nc-fixture-\(UUID().uuidString).sqlite"
var db: OpaquePointer?
sqlite3_open(fixturePath, &db)
func exec(_ sql: String) {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        print("SQL FAIL: \(sql) -> \(String(cString: sqlite3_errmsg(db)))")
        exit(2)
    }
}
exec("""
CREATE TABLE ZICCLOUDSYNCINGOBJECT (
  Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZTITLE1 TEXT,
  ZTITLE2 TEXT, ZSNIPPET TEXT, ZISPINNED INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER,
  ZMODIFICATIONDATE1 REAL, ZCREATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER DEFAULT 0,
  ZTYPEUTI1 TEXT, ZTOKENCONTENTIDENTIFIER TEXT, ZNOTE1 INTEGER, ZNOTEDATA INTEGER, ZDATA BLOB
);
CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, ZNAME TEXT);
""")
// 实体注册：11=ICFolder 12=ICNote 13=ICNoteData
var ins: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO Z_PRIMARYKEY VALUES (?,?)", -1, &ins, nil)
func bindEnt(_ ent: Int32, _ name: String) {
    sqlite3_reset(ins)
    sqlite3_bind_int(ins, 1, ent)
    sqlite3_bind_text(ins, 2, name, -1, SQLITE_TRANSIENT_FIX)
    sqlite3_step(ins)
}
bindEnt(11, "ICFolder"); bindEnt(12, "ICNote"); bindEnt(13, "ICNoteData")
sqlite3_finalize(ins)

let now = Date().timeIntervalSinceReferenceDate
func insObj(_ pk: Int64, _ ent: Int64, _ cols: [String: Any]) {
    var sql = "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT"
    var vals: [Any] = [pk, ent]
    var ph = "?,?"
    for (k, v) in cols {
        sql += ", \(k)"
        ph += ", ?"
        vals.append(v)
    }
    sql += ") VALUES (\(ph))"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    for (i, a) in vals.enumerated() {
        switch a {
        case let v as Int64: sqlite3_bind_int64(stmt, Int32(i + 1), v)
        case let v as Int: sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
        case let v as String: sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_FIX)
        case let v as Double: sqlite3_bind_double(stmt, Int32(i + 1), v)
        case let v as Data:
            _ = v.withUnsafeBytes { p in
                sqlite3_bind_blob(stmt, Int32(i + 1), p.baseAddress, Int32(v.count), SQLITE_TRANSIENT_FIX)
            }
        default: break
        }
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        print("INSERT FAIL pk=\(pk): \(String(cString: sqlite3_errmsg(db)))")
        exit(2)
    }
    sqlite3_finalize(stmt)
}

// 文件夹
insObj(1, 11, ["ZTITLE1": "工作", "ZFOLDERTYPE": 0])
insObj(2, 11, ["ZTITLE1": "生活", "ZFOLDERTYPE": 0])
// NoteData：明文 + zlib 压缩各一个
insObj(101, 13, ["ZDATA": Data(noteData)])
insObj(102, 13, ["ZDATA": compressed])
// 笔记：N1（标题blob=明文 101）、N2（102）、已删除 N3
insObj(11, 12, ["ZIDENTIFIER": "uuid-n1", "ZTITLE1": "会议纪要", "ZSNIPPET": "讨论了版本发布",
                "ZISPINNED": 1, "ZFOLDER": 1, "ZMODIFICATIONDATE1": now, "ZCREATIONDATE1": now - 5000, "ZNOTEDATA": 101])
insObj(12, 12, ["ZIDENTIFIER": "uuid-n2", "ZTITLE1": "购物清单", "ZSNIPPET": "牛奶鸡蛋 #生活",
                "ZFOLDER": 2, "ZMODIFICATIONDATE1": now - 100, "ZCREATIONDATE1": now - 10, "ZNOTEDATA": 102])
insObj(13, 12, ["ZIDENTIFIER": "uuid-n3", "ZTITLE1": "已删除笔记", "ZMARKEDFORDELETION": 1])
// hashtag 附件：note12 有 #生活
insObj(201, 14, ["ZTYPEUTI1": "com.apple.notes.inlinetextattachment.hashtag",
                 "ZTOKENCONTENTIDENTIFIER": "生活", "ZNOTE1": 12])
// link 附件：note11 内链指向 uuid-n2 → n2 有来自 n1 的反链
insObj(202, 14, ["ZTYPEUTI1": "com.apple.notes.inlinetextattachment.link",
                 "ZTOKENCONTENTIDENTIFIER": "uuid-n2", "ZNOTE1": 11])
sqlite3_close(db)

// ---------- 3. NotesStore 查询验证 ----------

let store: NotesStore
do {
    store = try NotesStore(path: fixturePath)
} catch {
    print("FAIL 打开 fixture: \(error.localizedDescription)")
    exit(1)
}

let list = store.notes()
check("笔记列表软删除过滤（2条）", list.count == 2, "got \(list.count)")
check("置顶优先排序", list.first?.pk == 11, "first=\(list.first?.pk ?? -1)")
check("标题读取", list.first?.title == "会议纪要")
check("文件夹 JOIN", list.first?.folder == "工作")
check("CoreData 时间戳保持2001纪元", abs((list.first?.modified?.timeIntervalSinceReferenceDate ?? 0) - now) < 0.01)
check("创建时间列读取", list.first?.created != nil, "created=\(String(describing: list.first?.created))")

let folders = store.folders()
check("文件夹列表（2个）", folders.count == 2)

let tags = store.hashtags()
check("Hashtag 提取", tags == ["生活"], "got \(tags)")

let tagNotes = store.notes(hashtag: "生活")
check("Hashtag 笔记查询", tagNotes.count == 1 && tagNotes.first?.pk == 12)
let tagNotesCI = store.notes(hashtag: "生 活".replacingOccurrences(of: " ", with: ""))
_ = tagNotesCI

let bl = store.backlinks(toNoteUUID: "uuid-n2")
check("Backlinks 反链", bl.count == 1 && bl.first?.pk == 11, "got \(bl.count)")

// ---------- 4. FTS 全文搜索 ----------
let hit = store.search("会议")
check("中文搜索同时命中标题和正文", Set(hit.map(\.pk)) == [11, 12], "got \(hit.map(\.pk))")
let hit2 = store.search("牛奶")
check("FTS snippet 命中", hit2.count == 1 && hit2.first?.pk == 12)
let miss = store.search("不存在的词")
check("FTS 无命中", miss.isEmpty)
let multi = store.search("购物清单")
check("FTS 多词合并后前缀命中", multi.count == 1 && multi.first?.pk == 12, "got \(multi.map(\.pk))")
let multiAND = store.search("牛奶 鸡蛋")
check("中文连写中段多词搜索", multiAND.map(\.pk) == [12], "got \(multiAND.map(\.pk))")

// ---------- 5. topotext 解码 + Markdown ----------
let blob1 = store.noteBodyData(pk: 11)
check("读取明文 blob", blob1 != nil && blob1!.count == noteData.count)
if let b = blob1, let doc = TopotextDecoder.decode(b) {
    check("明文解码: 文本收割", doc.text.contains("会议纪要") || doc.text.contains("标题"), "text=\(doc.text.prefix(40))")
    check("明文解码: runs 提取", doc.runs.count >= 2, "runs=\(doc.runs.count)")
    if doc.runs.count >= 2 {
        check("run length 解析", doc.runs[0].length == 5 && doc.runs[1].length == 12,
              "len=\(doc.runs.map(\.length))")
        check("段落样式解析", doc.runs[0].paragraphType == 1, "type=\(doc.runs[0].paragraphType)")
    }
    let note = list.first!
    let md = MarkdownConverter.convert(note: note, doc: doc)
    check("Markdown 生成", md.hasPrefix("# 会议纪要"), String(md.prefix(30)))
    print("---- Markdown 预览 ----")
    print(md)
    print("---------------------")
} else {
    check("明文解码", false)
}

let blob2 = store.noteBodyData(pk: 12)
check("读取 zlib blob", blob2 != nil && blob2!.first == 0x78)
if let b = blob2, let inflated = ProtoWire.zlibInflate(b) {
    check("zlib 解压 round-trip", inflated == plain,
          "inflated=\(inflated.count) vs plain=\(plain.count)")
    if let doc = TopotextDecoder.decode(b) {
        check("压缩 blob 解码", doc.text.contains("会议纪要") || doc.runs.count >= 2,
              "text=\(doc.text.prefix(20)) runs=\(doc.runs.count)")
    } else {
        check("压缩 blob 解码", false)
    }
} else {
    check("zlib 解压", false, "inflated==nil")
}

// ---------- 6. 权限错误路径 ----------
do {
    _ = try NotesStore(path: "/nonexistent/NoteStore.sqlite")
    check("不存在路径应抛错", false)
} catch {
    check("不存在路径应抛错", true)
}

// ---------- 7. 正文检索、中文子串与真实 Notes 存储格式 ----------
check("正文独有文本参与全文索引", store.search("正文内容").map(\.pk) == [11, 12])
check("中文标题和正文中段可以搜索", Set(store.search("议纪").map(\.pk)) == [11, 12])
let folderQuery = LibraryQuery(searchText: "纪要", folderPK: 1, sort: .createdAscending)
check("文件夹搜索与排序组合不丢筛选", folderQuery.execute(in: store).map(\.pk) == [11])
check("标签搜索只返回该标签笔记", LibraryQuery(searchText: "牛奶", hashtag: "生活").execute(in: store).map(\.pk) == [12])
check("搜索结果不会穿透文件夹筛选", LibraryQuery(searchText: "牛奶", folderPK: 1).execute(in: store).isEmpty)
check("刷新重用相同条件仍保留筛选", folderQuery.execute(in: store).map(\.pk) == [11])
check("兼容恢复结果明确标记不完整", !store.content(for: list[0]).isComplete
      && store.content(for: list[0]).warning != nil)

func gzip(_ data: Data) -> Data {
    let src = [UInt8](data)
    var dst = [UInt8](repeating: 0, count: data.count + 1024)
    let count = src.withUnsafeBufferPointer { input in
        dst.withUnsafeMutableBufferPointer { output in
            compression_encode_buffer(output.baseAddress!, output.count,
                                      input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
    }
    precondition(count > 0)
    var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
    result.append(contentsOf: dst.prefix(count))
    let checksum = UInt32(src.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
    for value in [checksum, UInt32(data.count)] {
        result.append(contentsOf: (0..<4).map { UInt8((value >> (8 * $0)) & 255) })
    }
    return result
}

let nativeText = "😀粗体正常\n待办事项\n尾段正文深处 café 100%"
let boldRun = fieldVar(1, 4) + fieldVar(5, 1)
let normalRun = fieldVar(1, 3)
let checklistStyle = fieldVar(1, 103) + fieldVar(4, 1) + field(5, field(1, [0, 1, 2, 3]) + fieldVar(2, 1))
let todoRun = fieldVar(1, 5) + field(2, checklistStyle)
let tailRun = fieldVar(1, UInt64("尾段正文深处 café 100%".utf16.count))
let nativeNote = fieldStr(2, nativeText) + field(5, boldRun) + field(5, normalRun)
    + field(5, todoRun) + field(5, tailRun)
let nativeProto = Data(field(2, fieldVar(2, 1) + field(3, nativeNote)))
let nativeGzip = gzip(nativeProto)
check("gzip容器校验与解压", ProtoWire.gzipInflate(nativeGzip) == nativeProto)
let nativeDoc = TopotextDecoder.decode(nativeGzip)
check("真实Notes protobuf字段映射", nativeDoc?.text == nativeText && nativeDoc?.isComplete == true)
check("真实Notes样式/核对清单", nativeDoc?.runs[0].bold == true
      && nativeDoc?.runs[2].isTodo == true && nativeDoc?.runs[2].todoDone == true
      && nativeDoc?.runs[2].listLevel == 1)
let nativeMarkdown = nativeDoc.map(MarkdownConverter.applyRuns) ?? ""
check("UTF16表情与加粗结束边界", nativeMarkdown.hasPrefix("**😀粗体**正常\n"), nativeMarkdown)
check("核对清单缩进与完成状态", nativeMarkdown.contains("  - [x] 待办事项"), nativeMarkdown)
check("正文尾段不会丢失", nativeMarkdown.hasSuffix("尾段正文深处 café 100%"))
let attachmentProto = Data(field(2, fieldVar(2, 1) + field(3,
    fieldStr(2, "\u{FFFC}") + field(5, fieldVar(1, 1) + field(12, fieldStr(2, "public.image"))))))
let attachmentDoc = TopotextDecoder.decode(gzip(attachmentProto))
check("无法导出的附件明确警告", attachmentDoc?.isComplete == false
      && attachmentDoc?.warnings.first?.contains("附件") == true)
let signedStyleProto = Data(field(2, fieldVar(2, 1) + field(3,
    fieldStr(2, "a") + field(5, fieldVar(1, 1) + field(2, fieldVar(1, UInt64.max) + fieldVar(4, UInt64.max))))))
check("负数protobuf样式值不会溢出崩溃", TopotextDecoder.decode(signedStyleProto)?.text == "a")
var corruptGzip = nativeGzip
corruptGzip[corruptGzip.count - 8] ^= 0xff
check("gzip校验失败拒绝返回截断正文", ProtoWire.gzipInflate(corruptGzip) == nil)

sqlite3_open(fixturePath, &db)
exec("CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)")
exec("BEGIN")
for index in 0..<5005 {
    insObj(Int64(10000 + index), 12, ["ZIDENTIFIER": "bulk-\(index)", "ZTITLE1": "批量笔记\(index)",
                                     "ZSNIPPET": index == 5004 ? "beyond_index_limit" : "",
                                     "ZMODIFICATIONDATE1": now - Double(index + 1000),
                                     "ZCREATIONDATE1": now - Double(index + 1000)])
}
insObj(30004, 12, ["ZIDENTIFIER": "native-1", "ZTITLE1": "原生正文", "ZSNIPPET": "很短的摘要",
                   "ZMODIFICATIONDATE1": now + 1, "ZCREATIONDATE1": now + 1])
insObj(30005, 12, ["ZIDENTIFIER": "native-2", "ZTITLE1": "通过外键读取", "ZSNIPPET": "",
                   "ZNOTEDATA": 701, "ZMODIFICATIONDATE1": now + 2, "ZCREATIONDATE1": now + 2])
for (pk, notePK) in [(700, 30004), (701, 0)] {
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO ZICNOTEDATA (Z_PK,ZNOTE,ZDATA) VALUES (?,?,?)", -1, &statement, nil)
    sqlite3_bind_int(statement, 1, Int32(pk))
    if notePK != 0 { sqlite3_bind_int(statement, 2, Int32(notePK)) }
    _ = nativeGzip.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_FIX) }
    check("写入真实格式fixture", sqlite3_step(statement) == SQLITE_DONE)
    sqlite3_finalize(statement)
}
exec("COMMIT")
sqlite3_close(db)
let nativeStore = try NotesStore(path: fixturePath)
check("超过500条的全库列表无截断", nativeStore.notes().count == 5009)
check("超过5000条的索引无截断", nativeStore.indexedCount == 5009
      && nativeStore.search("beyond_index_limit").count == 1)
check("ZICNOTEDATA通过ZNOTE读正文", nativeStore.noteBodyData(pk: 30004) == nativeGzip)
check("ZICNOTEDATA通过ZNOTEDATA外键读正文", nativeStore.noteBodyData(pk: 30005) == nativeGzip)
let nativeSummary = nativeStore.notes().first { $0.pk == 30004 }!
check("完整正文与导出状态", nativeStore.content(for: nativeSummary).isComplete
      && nativeStore.content(for: nativeSummary).warning == nil)
check("原生正文中段被索引", Set(nativeStore.search("段正文深").map(\.pk)) == [30004, 30005])
check("音调折叠和字面百分号", nativeStore.search("CAFE 100%").count == 2)
let plainStore = try NotesStore(path: fixturePath, enableFTS: false)
check("FTS不可用时仍可搜索正文", plainStore.search("段正文深").count == 2)
let readsLock = NSLock()
var concurrentReadsValid = true
DispatchQueue.concurrentPerform(iterations: 8) { index in
    if index % 2 == 0 { nativeStore.indexAll() }
    else if nativeStore.search("段正文深").count != 2 {
        readsLock.lock(); concurrentReadsValid = false; readsLock.unlock()
    }
}
check("并发重索引不会暴露半成品搜索结果", concurrentReadsValid)

// ---------- 8. 选择状态：鼠标键盘共用同一入口，旧请求不可覆盖 ----------
var state = LibrarySelectionState()
let requestA = state.begin(noteID: 1)!
check("开始加载立即清除旧正文并进入loading", state.isLoading && state.content == nil)
let requestB = state.begin(noteID: 2)!
let content = NoteContent(markdown: "B", plainText: "B", warning: nil, isComplete: true)
check("旧请求不能覆盖新笔记", !state.complete(content, noteID: 1, requestID: requestA) && state.content == nil)
check("新请求可以提交正文", state.complete(content, noteID: 2, requestID: requestB)
      && state.content?.markdown == "B" && !state.isLoading)
let requestB2 = state.begin(noteID: 2)!
check("同一笔记重新加载也清空旧正文", state.content == nil && state.isLoading)
check("同一笔记旧代请求也不能提交", !state.complete(content, noteID: 2, requestID: requestB))
_ = state.begin(noteID: nil)
check("取消选择后请求不可写回", !state.complete(content, noteID: 2, requestID: requestB2)
      && state.selectedID == nil && state.content == nil && !state.isLoading)

var bold = TopotextRun(); bold.length = 4; bold.bold = true
var normal = TopotextRun(); normal.length = 3
check("加粗关闭发生在下一run之前", MarkdownConverter.applyRuns(TopotextDoc(runs: [bold, normal], text: "boldend", totalLength: 7)) == "**bold**end")
var bold2 = bold; bold2.length = 3
check("相邻相同格式合并不产生四星边界", MarkdownConverter.applyRuns(TopotextDoc(runs: [bold, bold2], text: "boldend", totalLength: 7)) == "**boldend**")
bold.length = 5
normal.length = 3
check("行内格式不包裹尾空格", MarkdownConverter.applyRuns(TopotextDoc(runs: [bold, normal], text: "bold end", totalLength: 8)) == "**bold** end")
normal.length = 1
check("样式范围不足也保留所有尾文", MarkdownConverter.applyRuns(TopotextDoc(runs: [normal], text: "abcd", totalLength: 1)) == "abcd")
let failedContent = nativeStore.content(for: nativeStore.notes().first { $0.pk == 10000 }!)
check("读取失败不得伪装为完整正文", !failedContent.isComplete && failedContent.warning != nil
      && failedContent.markdown.contains("仅为摘要"))

try? FileManager.default.removeItem(atPath: fixturePath)
print(failures == 0 ? "\nALL LIBRARY TESTS PASSED" : "\n\(failures) LIBRARY FAILURES")
exit(failures == 0 ? 0 : 1)
