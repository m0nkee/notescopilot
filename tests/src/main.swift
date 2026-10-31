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

// Inline text attachments use the same object placeholder as images and tables.
// Only matching metadata may turn those placeholders back into complete text.
let hashtagUTI = "com.apple.notes.inlinetextattachment.hashtag"
let noteLinkUTI = "com.apple.notes.inlinetextattachment.link"
func inlineRun(_ length: Int, id: String, type: String, style: [UInt8] = []) -> [UInt8] {
    fieldVar(1, UInt64(length)) + style + field(12, fieldStr(1, id) + fieldStr(2, type))
}
func inlineProto(_ text: String, runs: [[UInt8]]) -> Data {
    gzip(Data(field(2, fieldVar(2, 1) + field(3,
        fieldStr(2, text) + runs.flatMap { field(5, $0) }))))
}
let inlineText = "😀前\u{FFFC} 与 \u{FFFC}尾🙂文"
let inlineGzip = inlineProto(inlineText, runs: [
    fieldVar(1, UInt64("😀前".utf16.count)),
    inlineRun(1, id: "tag-id", type: hashtagUTI),
    fieldVar(1, UInt64(" 与 ".utf16.count)) + fieldVar(5, 1),
    inlineRun(1, id: "link-id", type: noteLinkUTI, style: fieldVar(5, 2)),
    fieldVar(1, UInt64("尾🙂文".utf16.count)) + fieldVar(6, 1),
])
let inlineMetadata = [
    "tag-id": TopotextInlineAttachment(typeUTI: hashtagUTI, text: "#项目🚀"),
    "link-id": TopotextInlineAttachment(typeUTI: noteLinkUTI, text: "计划📘"),
]
let inlineDoc = TopotextDecoder.decode(inlineGzip, inlineAttachments: inlineMetadata)
let expandedInlineText = "😀前#项目🚀 与 计划📘尾🙂文"
check("元数据还原标签和笔记链接后正文完整", inlineDoc?.text == expandedInlineText
      && inlineDoc?.isComplete == true && inlineDoc?.warnings.isEmpty == true,
      "text=\(inlineDoc?.text ?? "nil")")
check("内联文字替换按UTF16调整run及总长度", inlineDoc?.runs.map(\.length) == [3, 5, 3, 4, 4]
      && inlineDoc?.totalLength == expandedInlineText.utf16.count)
let inlineMarkdown = inlineDoc.map(MarkdownConverter.applyRuns) ?? ""
check("内联文字替换保留相邻加粗斜体下划线边界", inlineMarkdown == "😀前#项目🚀 **与** _计划📘_<u>尾🙂文</u>", inlineMarkdown)
check("笔记链接仅保留显示文字不编造URL", !inlineMarkdown.contains("](")
      && inlineDoc?.runs.allSatisfy { $0.link == nil } == true)

let loneTag = inlineProto("\u{FFFC}", runs: [inlineRun(1, id: "tag-id", type: hashtagUTI)])
let missingInline = TopotextDecoder.decode(loneTag)
check("缺少内联附件元数据保留占位并标记不完整", missingInline?.text == "\u{FFFC}"
      && missingInline?.isComplete == false)
let emptyInline = TopotextDecoder.decode(loneTag, inlineAttachments: [
    "tag-id": TopotextInlineAttachment(typeUTI: hashtagUTI, text: ""),
])
check("空显示文字不能冒充完整内联正文", emptyInline?.text == "\u{FFFC}" && emptyInline?.isComplete == false)
let mismatchedInline = TopotextDecoder.decode(loneTag, inlineAttachments: [
    "tag-id": TopotextInlineAttachment(typeUTI: noteLinkUTI, text: "错误类型"),
])
check("内联附件UTI不匹配时不替换正文", mismatchedInline?.text == "\u{FFFC}"
      && mismatchedInline?.isComplete == false)
for type in ["public.image", "com.apple.notes.inlinetextattachment.unknown"] {
    let unsupported = TopotextDecoder.decode(inlineProto("\u{FFFC}", runs: [inlineRun(1, id: "other", type: type)]),
        inlineAttachments: ["other": TopotextInlineAttachment(typeUTI: type, text: "不能当纯文本")])
    check("未支持附件类型不因存在显示文字而变完整：\(type)", unsupported?.text == "\u{FFFC}"
          && unsupported?.isComplete == false)
}
let mixedInline = TopotextDecoder.decode(inlineProto("\u{FFFC}\u{FFFC}", runs: [
    inlineRun(1, id: "tag-id", type: hashtagUTI),
    inlineRun(1, id: "image-id", type: "public.image"),
]), inlineAttachments: inlineMetadata)
check("标签与图片混合时仅还原标签并保留不完整状态", mixedInline?.text == "#项目🚀\u{FFFC}"
      && mixedInline?.isComplete == false)
let invalidInline = TopotextDecoder.decode(inlineProto("😀\u{FFFC}", runs: [
    fieldVar(1, 1), inlineRun(2, id: "tag-id", type: hashtagUTI),
]), inlineAttachments: inlineMetadata)
check("run切开UTF16代理对时拒绝错误附件替换", invalidInline?.text == "😀\u{FFFC}"
      && invalidInline?.isComplete == false)
let oversizedInline = TopotextDecoder.decode(inlineProto("\u{FFFC}", runs: [
    inlineRun(2, id: "tag-id", type: hashtagUTI),
]), inlineAttachments: inlineMetadata)
check("run越界时保留占位和不完整状态", oversizedInline?.text == "\u{FFFC}"
      && oversizedInline?.isComplete == false)
let missingPlaceholder = TopotextDecoder.decode(inlineProto("原", runs: [
    inlineRun(1, id: "tag-id", type: hashtagUTI),
]), inlineAttachments: inlineMetadata)
check("附件run缺少占位符时不覆盖原文", missingPlaceholder?.text == "原" && missingPlaceholder?.isComplete == false)
let malformedAttachment = TopotextDecoder.decode(inlineProto("\u{FFFC}", runs: [
    field(12, fieldStr(1, "image-id") + fieldStr(2, "public.image")),
    inlineRun(1, id: "tag-id", type: hashtagUTI),
]), inlineAttachments: inlineMetadata)
check("缺失长度的附件run不能被忽略后误标完整", malformedAttachment?.text == "\u{FFFC}"
      && malformedAttachment?.isComplete == false)

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

// ---------- 9. 原生模板正文直接生成 HTML，不经 Markdown 往返 ----------
func nativeHTMLDocument(_ chunks: [(String, TopotextRun)]) -> TopotextDoc {
    var text = ""
    var runs: [TopotextRun] = []
    for (chunk, style) in chunks {
        text += chunk
        var run = style
        run.length = chunk.utf16.count
        runs.append(run)
    }
    return TopotextDoc(runs: runs, text: text, totalLength: text.utf16.count)
}
let htmlBody = TopotextRun()
var htmlTitle = TopotextRun(); htmlTitle.paragraphType = 1
var htmlHeading = TopotextRun(); htmlHeading.paragraphType = 2
var htmlSubheading = TopotextRun(); htmlSubheading.paragraphType = 3
var htmlBold = TopotextRun(); htmlBold.bold = true
var htmlCode = TopotextRun(); htmlCode.monospaced = true; htmlCode.monospacedBlock = true
let nativeHTMLDoc = nativeHTMLDocument([
    ("Native Title\n", htmlTitle), ("Before ", htmlBody), ("bold", htmlBold), (" after\n", htmlBody),
    ("let a = 1\n", htmlCode), ("  next <tag>\n", htmlCode), ("Section\n", htmlHeading),
    ("Subsection\n", htmlSubheading), ("Done 😀", htmlBody)
])
let renderedNativeHTML = NativeNoteHTML.render(nativeHTMLDoc)
check("原生模板HTML只包含一次正文标题且使用标题标签", renderedNativeHTML.components(separatedBy: "Native Title").count == 2
      && renderedNativeHTML.contains("<h1") && renderedNativeHTML.contains("<h2")
      && !renderedNativeHTML.contains("# Native Title"))
check("原生模板跨run正文保留加粗且没有Markdown标记", renderedNativeHTML.contains("Before ")
      && renderedNativeHTML.contains("<strong>bold</strong>") && renderedNativeHTML.contains(" after")
      && !renderedNativeHTML.contains("**bold**"))
check("连续原生等宽段落生成单个灰色多行代码块", renderedNativeHTML.components(separatedBy: "<pre").count == 2
      && renderedNativeHTML.contains("background-color:") && renderedNativeHTML.contains("<code")
      && renderedNativeHTML.contains("let a = 1\n  next &lt;tag&gt;") && !renderedNativeHTML.contains("```"))
check("原生HTML保留Unicode和段落顺序", renderedNativeHTML.contains("Done 😀")
      && renderedNativeHTML.range(of: "Native Title")!.lowerBound < renderedNativeHTML.range(of: "Section")!.lowerBound)
var htmlInline = TopotextRun(); htmlInline.italic = true; htmlInline.underline = true; htmlInline.strikethrough = true
var htmlTag = TopotextRun(); htmlTag.inlineAttachmentType = hashtagUTI
var htmlSafeLink = TopotextRun(); htmlSafeLink.link = "https://example.com?a=1&b=2"
var htmlBadLink = TopotextRun(); htmlBadLink.link = "javascript:alert(1)"
let styledHTML = NativeNoteHTML.render(nativeHTMLDocument([
    ("styled", htmlInline), (" #项目🚀", htmlTag), (" safe", htmlSafeLink), (" <script>&\"", htmlBadLink)
]))
check("原生HTML保留斜体下划线删除线和标签颜色", styledHTML.contains("<em>") && styledHTML.contains("<u>")
      && styledHTML.contains("<s>") && styledHTML.contains("color:") && styledHTML.contains("#项目🚀"))
check("原生HTML转义文本和链接属性并拒绝活动脚本链接", styledHTML.contains("href=\"https://example.com?a=1&amp;b=2\"")
      && styledHTML.contains("&lt;script&gt;&amp;&quot;") && !styledHTML.contains("javascript:")
      && !styledHTML.contains("<script>"))
var htmlList = TopotextRun(); htmlList.paragraphType = 5
var htmlNestedList = htmlList; htmlNestedList.listLevel = 1
var htmlOrdered = htmlList; htmlOrdered.numbered = true
var htmlTodo = htmlList; htmlTodo.isTodo = true; htmlTodo.todoDone = true
let listsHTML = NativeNoteHTML.render(nativeHTMLDocument([
    ("First\n", htmlList), ("Nested\n", htmlNestedList), ("Ordered\n", htmlOrdered), ("Task\n", htmlTodo), ("\nLast", htmlBody)
]))
check("原生HTML保留无序有序嵌套列表与待办状态", listsHTML.contains("<ul>") && listsHTML.contains("<ol>")
      && listsHTML.contains("<li>") && listsHTML.contains("☑ Task") && listsHTML.components(separatedBy: "<ul>").count >= 3)
check("原生HTML保留空段落", listsHTML.contains("<p><br></p>"))
let nativeCodeProto = inlineProto("code\n", runs: [fieldVar(1, 5) + field(2, fieldVar(1, 4))])
let nativeCodeDoc = TopotextDecoder.decode(nativeCodeProto)
check("原生等宽段落与行内等宽有独立语义", nativeCodeDoc?.runs.first?.monospaced == true
      && nativeCodeDoc?.runs.first?.monospacedBlock == true)
check("还原的标签run携带展示类型以保留颜色", inlineDoc?.runs.contains { $0.inlineAttachmentType == hashtagUTI } == true)

for documentType in [NSAttributedString.DocumentType.rtf, .rtfd] {
do {
    let attributed = try NSAttributedString(data: Data((renderedNativeHTML + "\n" + styledHTML).utf8),
        options: [.documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                  documentAttributes: [.documentType: documentType])
    let restored = try NSAttributedString(data: rtf,
        options: [.documentType: documentType], documentAttributes: nil)
    func attributes(_ text: String) -> [NSAttributedString.Key: Any] {
        let range = (restored.string as NSString).range(of: text)
        return range.location == NSNotFound ? [:] : restored.attributes(at: range.location, effectiveRange: nil)
    }
    let bodyFont = attributes("Before")[.font] as? NSFont
    let titleFont = attributes("Native Title")[.font] as? NSFont
    let headingFont = attributes("Section")[.font] as? NSFont
    let subheadingFont = attributes("Subsection")[.font] as? NSFont
    let codeAttributes = attributes("let a = 1")
    let codeFont = codeAttributes[.font] as? NSFont
    check("HTML经\(documentType.rawValue)往返后系统CSS使用无衬线正文13pt", bodyFont?.familyName?.lowercased().contains("helvetica") == true
          && abs((bodyFont?.pointSize ?? 0) - 13) < 0.1,
          "font=\(bodyFont?.fontName ?? "nil") size=\(bodyFont?.pointSize ?? 0)")
    check("HTML经\(documentType.rawValue)往返后标题20pt小标题17pt副标题15pt", abs((titleFont?.pointSize ?? 0) - 20) < 0.1
          && abs((headingFont?.pointSize ?? 0) - 17) < 0.1 && abs((subheadingFont?.pointSize ?? 0) - 15) < 0.1)
    check("HTML经\(documentType.rawValue)往返后代码固定使用Menlo而非默认Courier", codeFont?.fontName.lowercased().contains("menlo") == true
          && codeFont?.isFixedPitch == true && abs((codeFont?.pointSize ?? 0) - 13) < 0.1,
          "font=\(codeFont?.fontName ?? "nil") size=\(codeFont?.pointSize ?? 0) mono=\(codeFont?.isFixedPitch ?? false)")
    let background = (codeAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
    check("HTML经\(documentType.rawValue)往返后代码灰色背景保留", background != nil && background!.redComponent > 0.8
          && abs(background!.redComponent - background!.greenComponent) < 0.05
          && abs(background!.greenComponent - background!.blueComponent) < 0.05)
    let tagColor = (attributes("#项目🚀")[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
    check("HTML经\(documentType.rawValue)往返后标签橙色保留", tagColor != nil && tagColor!.redComponent > 0.5
          && tagColor!.redComponent > tagColor!.greenComponent && tagColor!.greenComponent > tagColor!.blueComponent)
} catch {
    check("HTML导入与\(documentType.rawValue)往返成功", false, error.localizedDescription)
}
}

try? FileManager.default.removeItem(atPath: fixturePath)
print(failures == 0 ? "\nALL LIBRARY TESTS PASSED" : "\n\(failures) LIBRARY FAILURES")
exit(failures == 0 ? 0 : 1)
