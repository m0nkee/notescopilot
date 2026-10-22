import Foundation
import AppKit
import SQLite3
import Compression

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
            v.withUnsafeBytes { p in
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
check("CoreData 时间戳解码", list.first?.modified != nil)
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
check("FTS 中文命中", hit.count == 1 && hit.first?.pk == 11, "got \(hit.map(\.pk))")
let hit2 = store.search("牛奶")
check("FTS snippet 命中", hit2.count == 1 && hit2.first?.pk == 12)
let miss = store.search("不存在的词")
check("FTS 无命中", miss.isEmpty)
let multi = store.search("购物清单")
check("FTS 多词合并后前缀命中", multi.count == 1 && multi.first?.pk == 12, "got \(multi.map(\.pk))")
let multiAND = store.search("牛奶 鸡蛋")
check("FTS CJK连写多词(中段不可前缀)", multiAND.isEmpty, "got \(multiAND.map(\.pk)) — 预期空：unicode61 下「牛奶鸡蛋」是单token")

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

try? FileManager.default.removeItem(atPath: fixturePath)
// ---------- 7. 全局斜杠命令匹配（v1.3.0）----------
// 复刻 KeywordListener.matchSlash 逻辑（静态函数化以便测试）
func testMatchSlash(_ trigger: String) -> SlashCommand? {
    guard trigger.hasPrefix("/"), trigger.count > 1 else { return nil }
    let token = String(trigger.dropFirst()).lowercased()
    let cmds = buildSlashCommands().filter { !$0.alias.isEmpty }
    if let exact = cmds.first(where: { $0.alias.lowercased() == token }) { return exact }
    let prefix = cmds.filter { $0.alias.lowercased().hasPrefix(token) }
    return prefix.count == 1 ? prefix[0] : nil
}
check("slash 精确匹配 runse", testMatchSlash("/runse")?.name == "润色")
check("slash 精确匹配 zongjie", testMatchSlash("/zongjie")?.name == "总结")
check("slash 前缀唯一匹配 fany", testMatchSlash("/fany")?.name == "翻译")
check("slash 前缀唯一匹配 x", testMatchSlash("/x")?.name == "续写")  // 仅 xuxie
check("slash 前缀歧义不触发", testMatchSlash("/s") == nil)  // stop/set/savenote 多义
check("slash 单斜杠不匹配", testMatchSlash("/") == nil)
check("slash 非命令不匹配", testMatchSlash("/zzzz") == nil)
check("slash 别名小写归一", testMatchSlash("/RUNSE")?.name == "润色")
// 英文模板名作斜杠命令
TemplateStore.templates = [TemplateNote(name: "weekly", content: "# Weekly")]
check("英文模板名全局可匹配", testMatchSlash("/weekly")?.name == "weekly")
TemplateStore.templates = []

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURES")

// ---------- 8. v2.0：搜索四向排序（SearchSort）----------
do {
    let n1 = NoteSummary(pk: 1, uuid: "a", title: "A", snippet: "", modified: Date(timeIntervalSinceReferenceDate: 100),
                         created: Date(timeIntervalSinceReferenceDate: 50), folder: "")
    let n2 = NoteSummary(pk: 2, uuid: "b", title: "B", snippet: "", modified: Date(timeIntervalSinceReferenceDate: 200),
                         created: Date(timeIntervalSinceReferenceDate: 150), folder: "")
    let n3 = NoteSummary(pk: 3, uuid: "c", title: "C", snippet: "", modified: nil, created: nil, folder: "")
    let list = [n1, n2, n3]
    check("排序 updated↓ 首条=修改最晚", SearchSort.updatedDescending.sorted(list).first?.pk == 2)
    check("排序 updated↑ 首条=nil 最前", SearchSort.updatedAscending.sorted(list).first?.pk == 3,
          "distantPast 排升序最前")
    check("排序 created↓ 首条=创建最晚", SearchSort.createdDescending.sorted(list).first?.pk == 2)
    check("排序 created↑ 首条=nil 最前", SearchSort.createdAscending.sorted(list).first?.pk == 3,
          "distantPast 排升序最前")
    check("排序 nil 日期排最后（updated↓）", SearchSort.updatedDescending.sorted(list).last?.pk == 3)
}

// ---------- 9. v2.0：Markdown token 映射（FormatBridge.markdownToken）----------
check("token # → title", FormatBridge.markdownToken("#") == .title)
check("token ## → heading", FormatBridge.markdownToken("##") == .heading)
check("token ### → subheading", FormatBridge.markdownToken("###") == .subheading)
check("token [] → checklist", FormatBridge.markdownToken("[]") == .checklist)
check("token ``` → monostyled", FormatBridge.markdownToken("```") == .monostyled)
check("token > → blockQuote", FormatBridge.markdownToken(">") == .blockQuote)
check("token - → dashedList", FormatBridge.markdownToken("-") == .dashedList)
check("token * → bulletedList", FormatBridge.markdownToken("*") == .bulletedList)
check("token 1. → numberedList", FormatBridge.markdownToken("1.") == .numberedList)
check("token 非法 → nil", FormatBridge.markdownToken("abc") == nil)
check("token 空串 → nil", FormatBridge.markdownToken("") == nil)

// ---------- 10. v2.0：行首 Markdown 状态机（MarkdownLineTracker）----------
do {
    let t = MarkdownLineTracker.shared
    t.reset()
    // 行首 "#" + 空格 → 删 2 字符、触发 title
    check("状态机: # 不立即触发", t.feed("#") == nil)
    let hit1 = t.feed(" ")
    check("状态机: # +空格 → title 删 2 字", hit1 != nil && hit1!.delete == 2 && hit1!.style == .title,
          "got \(String(describing: hit1))")
    // 非行首不触发
    check("状态机: 非行首不触发", t.feed("h") == nil && t.feed("#") == nil && t.feed(" ") == nil)
    // 换行后回到行首："##" + 空格 → heading
    _ = t.feed("\n")
    _ = t.feed("#"); _ = t.feed("#")
    let hit2 = t.feed(" ")
    check("状态机: ## +空格 → heading 删 3 字", hit2 != nil && hit2!.delete == 3 && hit2!.style == .heading,
          "got \(String(describing: hit2))")
    // "[]" + 空格 → checklist 删 3 字
    _ = t.feed("\n")
    _ = t.feed("["); _ = t.feed("]")
    let hit3 = t.feed(" ")
    check("状态机: [] +空格 → checklist 删 3 字", hit3 != nil && hit3!.delete == 3 && hit3!.style == .checklist,
          "got \(String(describing: hit3))")
    // 退格回退："#"→ 退格 → 空格 不触发
    t.reset()
    _ = t.feed("#")
    t.backspace()
    let hit4 = t.feed(" ")
    check("状态机: 退格后空格不触发", hit4 == nil)
    // token 超 3 字符自动清理
    t.reset()
    _ = t.feed("#"); _ = t.feed("#"); _ = t.feed("#"); _ = t.feed("#")
    let hit5 = t.feed(" ")
    check("状态机: 超长 token 不触发", hit5 == nil)
    // 关闭开关后不触发
    t.reset()
    UserDefaults.standard.set(false, forKey: "nc.md.enabled")
    _ = t.feed("#")
    let hit6 = t.feed(" ")
    check("状态机: nc.md.enabled=false 不触发", hit6 == nil)
    UserDefaults.standard.removeObject(forKey: "nc.md.enabled")
    // expandMarkdown 开关：关闭 headers 后 # 不触发
    UserDefaults.standard.set(false, forKey: "nc.md.headers")
    t.reset()
    _ = t.feed("#")
    let hit7 = t.feed(" ")
    check("expandMarkdown headers=false 不触发", hit7 == nil)
    UserDefaults.standard.removeObject(forKey: "nc.md.headers")
    // 开关默认开：> 触发 blockQuote
    t.reset()
    _ = t.feed(">")
    let hit8 = t.feed(" ")
    check("expandMarkdown 默认开启 > → blockQuote", hit8 != nil && hit8!.style == .blockQuote)
    t.reset()
}

// ---------- 11. v2.0：格式斜杠命令（/title /bold 等映射 FormatStyle）----------
check("slash 命令 /bold → format(bold) 可匹配", testMatchSlash("/bold") != nil)
check("slash 命令 /checklist → format(checklist) 可匹配", testMatchSlash("/checklist") != nil)
check("slash 命令 /numberedlist → format(numberedList) 可匹配", testMatchSlash("/numberedlist") != nil)
if let cmd = testMatchSlash("/bold"), case .format(let st) = cmd.action {
    check("slash /bold action = .format(bold)", st == .bold, "got \(st)")
} else {
    check("slash /bold action = .format(bold)", false, "命令不存在或 action 非 format")
}
if let cmd = testMatchSlash("/title"), case .format(let st) = cmd.action {
    check("slash /title action = .format(title)", st == .title, "got \(st)")
} else {
    check("slash /title action = .format(title)", false, "命令不存在或 action 非 format")
}

// ---------- 12. v2.0：deeplink 构造（NotesBridge.deeplink）----------
check("deeplink: notes://show_note?paster=<id>",
      NotesBridge.deeplink(forNoteID: "x-coredata://ABC/ICNote/p123")
        == "notes://show_note?paster=x-coredata://ABC/ICNote/p123")

// ---------- 13. v2.1：AX 通道匹配器（仅靠辅助功能权限的轮询通道）----------
do {
    // 斜杠尾部匹配
    let s1 = AXSlashWatcher.matchAXSlashTail("你好 /runse ")
    check("AX 斜杠：/runse +空格 命中润色", s1?.cmd.name == "润色" && s1?.deleteCount == 7, "got \(String(describing: s1?.cmd.name)) del=\(s1?.deleteCount ?? -1)")
    let s2 = AXSlashWatcher.matchAXSlashTail("## " )
    check("AX 斜杠：无斜杠不命中", s2 == nil)
    let s3 = AXSlashWatcher.matchAXSlashTail("/runse")
    check("AX 斜杠：无终止符不命中", s3 == nil)
    let s4 = AXSlashWatcher.matchAXSlashTail("笔记 ／title ")
    check("AX 斜杠：全角 ／ 归一命中", s4?.cmd.name.contains("标题") == true, "got \(String(describing: s4?.cmd.name))")
    let s5 = AXSlashWatcher.matchAXSlashTail("/zzzz ")
    check("AX 斜杠：未知命令不命中", s5 == nil)

    // 行首 Markdown 匹配
    let m1 = AXSlashWatcher.matchAXMarkdownTail("行首\n# ")
    check("AX MD：行首 # +空格 → title 删 2", m1?.style == .title && m1?.delete == 2, "got \(String(describing: m1))")
    let m2 = AXSlashWatcher.matchAXMarkdownTail("## ")
    check("AX MD：首行 ## → heading 删 3", m2?.style == .heading && m2?.delete == 3)
    let m3 = AXSlashWatcher.matchAXMarkdownTail("[] ")
    check("AX MD：[] → checklist 删 3", m3?.style == .checklist && m3?.delete == 3)
    let m4 = AXSlashWatcher.matchAXMarkdownTail("前文 # ")
    check("AX MD：非行首不命中", m4 == nil)
    let m5 = AXSlashWatcher.matchAXMarkdownTail("#abc ")
    check("AX MD：token 后有正文不命中", m5 == nil)
    let m6 = AXSlashWatcher.matchAXMarkdownTail("#")
    check("AX MD：无空格不命中", m6 == nil)
    // 开关门控
    UserDefaults.standard.set(false, forKey: "nc.md.headers")
    let m7 = AXSlashWatcher.matchAXMarkdownTail("# ")
    check("AX MD：headers 开关关闭不命中", m7 == nil)
    UserDefaults.standard.removeObject(forKey: "nc.md.headers")
    let m8 = AXSlashWatcher.matchAXMarkdownTail("> ")
    check("AX MD：> → blockQuote", m8?.style == .blockQuote && m8?.delete == 2)

    // 全角 token（中文 IME 默认全角标点，真机取证 [] 打成【】）
    let fw1 = AXSlashWatcher.matchAXMarkdownTail("【】 ")
    check("AX MD：全角【】 → checklist 删 3", fw1?.style == .checklist && fw1?.delete == 3)
    let fw2 = AXSlashWatcher.matchAXMarkdownTail("＃ ")
    check("AX MD：全角＃ → title", fw2?.style == .title && fw2?.delete == 2)
    let fw3 = AXSlashWatcher.matchAXMarkdownTail("＞ ")
    check("AX MD：全角＞ → blockQuote", fw3?.style == .blockQuote)
    let fw4 = AXSlashWatcher.matchAXMarkdownTail("＊ ")
    check("AX MD：全角＊ → bulletedList", fw4?.style == .bulletedList)
    let fw5 = AXSlashWatcher.matchAXMarkdownTail("－ ")
    check("AX MD：全角－ → dashedList", fw5?.style == .dashedList)
    let fw6 = AXSlashWatcher.matchAXMarkdownTail("１． ")
    check("AX MD：全角１．NFKC 归一命中 numberedList", fw6?.style == .numberedList && fw6?.delete == 3)
    let fw7 = AXSlashWatcher.matchAXMarkdownTail("〖〗 ")
    check("AX MD：全角〖〗归一命中 checklist", fw7?.style == .checklist && fw7?.delete == 3)
    let fw8 = AXSlashWatcher.matchAXMarkdownTail("》 ")
    check("AX MD：全角》归一命中 blockQuote", fw8?.style == .blockQuote)

    // ---------- 17. / 建议下拉（activeSlashQuery + suggestCandidates） ----------
    let q1 = AXSlashWatcher.activeSlashQuery("你好这是测试/")
    check("建议：行尾 / → 查询为空命令串", q1 == "/", "got \(String(describing: q1))")
    let q2 = AXSlashWatcher.activeSlashQuery("你好/runse")
    check("建议：/runse 未终止 → 查询命中", q2 == "/runse", "got \(String(describing: q2))")
    check("建议：/runse + 空格已终止不弹", AXSlashWatcher.activeSlashQuery("你好/runse ") == nil)
    check("建议：URL 中的 / 不弹", AXSlashWatcher.activeSlashQuery("看 https://example.com") == nil)
    check("建议：行首 / 弹", AXSlashWatcher.activeSlashQuery("\n/xx") == "/xx")
    check("建议：超长段不弹", AXSlashWatcher.activeSlashQuery("/abcdefghijklmnopqrstuvwxyz") == nil)
    check("建议：全角 ／ 归一", AXSlashWatcher.activeSlashQuery("你好／run") == "/run")
    let sug1 = AXSlashWatcher.suggestCandidates(for: "/run")
    check("建议：/run 前缀命中 runse（润色）", sug1.first?.alias == "runse", "got \(String(describing: sug1.first?.alias))")
    let sug2 = AXSlashWatcher.suggestCandidates(for: "/")
    check("建议：裸 / 列全部且限 8 项", sug2.count == 8, "got \(sug2.count)")
    let sug3 = AXSlashWatcher.suggestCandidates(for: "/list")
    check("建议：/list 包含命中列表命令", sug3.contains { $0.alias == "bulletedlist" } == true, "got \(sug3.map(\.alias))")
    let sug4 = AXSlashWatcher.suggestCandidates(for: "/zzzz")
    check("建议：无匹配返回空", sug4.isEmpty)

    // ---------- 17b. 模板参与下拉与匹配（注入测试模板后跑，最后还原） ----------
    let savedTemplates = TemplateStore.templates
    TemplateStore.templates = [
        TemplateNote(id: UUID(), name: "周报模板", content: "## 进展"),
        TemplateNote(id: UUID(), name: "meeting-notes", content: "# 纪要"),
    ]
    defer { TemplateStore.templates = savedTemplates }
    let tsug = AXSlashWatcher.suggestCandidates(for: "/周报")
    check("模板：中文名过滤下拉命中", tsug.contains { $0.name == "周报模板" }, "got \(tsug.map(\.name))")
    let tsug2 = AXSlashWatcher.suggestCandidates(for: "/meet")
    check("模板：英文名模板下拉命中", tsug2.contains { $0.name == "meeting-notes" }, "got \(tsug2.map(\.name))")
    check("模板：中文名模板斜杠匹配（IME 提交场景）",
          AXSlashWatcher.matchSlashToken("/周报模板")?.name == "周报模板")
    check("模板：英文名模板别名匹配",
          AXSlashWatcher.matchSlashToken("/meetingnotes")?.name == "meeting-notes")
}

print(failures == 0 ? "\nALL v2.0 TESTS PASSED" : "\n\(failures) FAILURES (v2.0)")
exit(failures == 0 ? 0 : 1)
