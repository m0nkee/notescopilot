import Foundation
import AppKit
import SQLite3

private var passed = 0
private var failed = 0
private func check(_ condition: Bool, _ label: String) {
    if condition { passed += 1; print("PASS  \(label)") }
    else { failed += 1; print("FAIL  \(label)") }
}

private func renderingTests() {
    check(MarkdownDocument.blocks("# 标题\n\n正文") == [.heading(1, "标题"), .paragraph("正文")], "标题与正文分块")
    check(MarkdownDocument.blocks("#话题") == [.paragraph("#话题")], "普通话题不误当标题")
    check(MarkdownDocument.blocks("- a\n- b\n\n1. c\n2. d") == [.list(false, ["a", "b"]), .list(true, ["c", "d"])], "有序无序列表分块")
    check(MarkdownDocument.blocks("```swift\nlet a = 1") == [.code("swift", "let a = 1")], "流式未闭合代码块仍能预览")
    check(MarkdownDocument.blocks("| 项目 | 状态 |\n| --- | :---: |\n| 写回 | 通过 |") == [.table(["项目", "状态"], [["写回", "通过"]])], "表格解析与对齐标记")
    check(MarkdownDocument.blocks("> 引用\n> 第二行\n\n---") == [.quote("引用\n第二行"), .divider], "引用与分隔线")
    let html = MarkdownDocument.html("# 标题\n\n**粗体** 和 *斜体*\n\n```html\n<script>alert(1)</script>\n```")
    check(html.contains("<h1>标题</h1>") && html.contains("<strong>粗体</strong>") && html.contains("<em>斜体</em>"), "HTML 保留标题与行内样式")
    check(!html.contains("<script>") && html.contains("&lt;script&gt;"), "代码与原始HTML均转义")
    check(MarkdownDocument.inlineHTML("`**原文**`") == "<code>**原文**</code>", "行内代码不被重新解析为加粗")
    check(MarkdownDocument.inlineHTML("[网页](https://example.com?a=1&b=2)").contains("href=\"https://example.com?a=1&amp;b=2\""), "超链接参数正确转义")
    check(!MarkdownDocument.inlineHTML("[危险](javascript:alert(1))").contains("<a "), "拒绝活动脚本链接")
    check(MarkdownDocument.html("| A | B |\n| --- | --- |\n| 1 | 2 |").contains("<td>2</td>"), "表格可写回为HTML")
    let tasks = MarkdownDocument.html("- [ ] 待办\n- [X] 完成")
    check(tasks.contains("☐ 待办") && tasks.contains("☑ 完成") && !tasks.contains("[X]"), "清单预览与HTML写回一致")
}

private func templateImportTests() {
    let original = TemplateNote(name: "Weekly", content: "original")
    let result = NotesTemplateImporter.merging([
        ("weekly", "new"), ("会议纪要", "正文"), (" 会议纪要 ", "duplicate"), ("", "text"), ("Empty", "  ")
    ], into: [original])
    check(result.addedCount == 1 && result.skippedCount == 4, "模板导入跳过重名与空笔记")
    check(result.templates.first == original, "导入保留已有模板及身份")
    check(result.templates.last?.name == "会议纪要" && result.templates.last?.content == "正文", "导入保留正文并清理名称空白")
}

private func notesTemplateTests() throws {
    let defaults = UserDefaults.standard
    let previousDefaults = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let previousNotes = TemplateStore.notesTemplates
    defer {
        defaults.setVolatileDomain(previousDefaults, forName: UserDefaults.argumentDomain)
        TemplateStore.updateNotesTemplates(previousNotes)
    }
    let local = TemplateNote(name: " daily-report ", content: "local version")
    let localOnly = TemplateNote(name: "Local", content: "local only")
    let stored = try JSONEncoder().encode([local, localOnly])
    var fixtureDefaults = previousDefaults
    fixtureDefaults["nc.templates"] = stored
    defaults.setVolatileDomain(fixtureDefaults, forName: UserDefaults.argumentDomain)
    TemplateStore.updateNotesTemplates([])

    let path = NSTemporaryDirectory() + "nc-template-fixture-\(UUID().uuidString).sqlite"
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
        throw NSError(domain: "TemplateFixture", code: 1)
    }
    defer { sqlite3_close(db); try? FileManager.default.removeItem(atPath: path) }
    func sql(_ statement: String, _ values: [Any] = []) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw NSError(domain: "TemplateFixture.prepare", code: Int(sqlite3_errcode(db)))
        }
        defer { sqlite3_finalize(prepared) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let value as Int: sqlite3_bind_int64(prepared, position, Int64(value))
            case let value as String: sqlite3_bind_text(prepared, position, value, -1, SQLITE_TRANSIENT)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(prepared, position, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            default: throw NSError(domain: "TemplateFixture.bind", code: 1)
            }
        }
        guard sqlite3_step(prepared) == SQLITE_DONE else {
            throw NSError(domain: "TemplateFixture.step", code: Int(sqlite3_errcode(db)))
        }
    }
    func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            bytes.append(value == 0 ? byte : byte | 0x80)
        } while value != 0
        return bytes
    }
    func field(_ number: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }
    func body(_ text: String) -> Data {
        // Native Notes schema: NoteStoreProto.2 -> Document.3 -> Note.text.2.
        Data(field(2, field(3, field(2, Array(text.utf8)))))
    }
    try sql("""
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZTITLE1 TEXT,
          ZTITLE2 TEXT, ZSNIPPET TEXT, ZISPINNED INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER,
          ZMODIFICATIONDATE1 REAL, ZCREATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER DEFAULT 0,
          ZNOTEDATA INTEGER, ZDATA BLOB, ZTYPEUTI1 TEXT, ZALTTEXT TEXT, ZNOTE1 INTEGER
        )
        """)
    try sql("CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, ZNAME TEXT)")
    for (id, name) in [(11, "ICFolder"), (12, "ICNote"), (13, "ICNoteData")] {
        try sql("INSERT INTO Z_PRIMARYKEY VALUES (?, ?)", [id, name])
    }
    for (id, name) in [(1, "Templates"), (2, "tEmPlAtEs"), (3, "Work"), (4, "Templates")] {
        try sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE2, ZFOLDERTYPE) VALUES (?, 11, ?, 0)", [id, name])
    }
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMARKEDFORDELETION = 1 WHERE Z_PK = 4")
    func note(_ id: Int, _ folder: Int, _ title: String, _ identifier: String, _ text: String?) throws {
        try sql("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZNOTEDATA, ZMODIFICATIONDATE1)
            VALUES (?, 12, ?, ?, ?, ?, ?)
            """, [id, identifier, title, folder, id + 1000, id])
        if let text {
            try sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZDATA) VALUES (?, 13, ?)", [id + 1000, body(text)])
        }
    }
    let validUUID = "11111111-2222-3333-4444-555555555555"
    try note(10, 1, " Daily Report ", validUUID, " Daily Report \n{{date}} first version")
    try note(11, 1, "Delete Me", "legacy-delete", "Delete Me\ndelete body")
    try note(12, 1, "Move Me", "", "Move Me\nmove body")
    try note(13, 2, "Other Account", "legacy-other", "Other Account\nsecond folder")
    try note(14, 2, "daily-report", "duplicate-other", "daily-report\nduplicate body")
    try note(15, 1, "daily-report", "duplicate-same", "daily-report\nlater duplicate")
    try note(16, 3, "Ordinary", "ordinary", "Ordinary\nnot a template")
    try note(17, 4, "Deleted Folder", "deleted-folder", "Deleted Folder\nnot a template")
    try note(18, 1, "Deleted Note", "deleted-note", "Deleted Note\nnot a template")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMARKEDFORDELETION = 1 WHERE Z_PK = 18")
    try note(19, 1, "Locked", "locked", nil)
    try note(20, 1, "Empty", "empty", " \n ")
    try note(21, 1, "  ", "empty-title", "  \nunnamed body")
    try note(22, 1, "Attachment", "attachment", "Attachment\nbody \u{FFFC}")

    let store = try NotesStore(path: path, enableFTS: false)
    let first = NotesTemplateImporter.readTemplates(from: store)
    check(Set(first.map(\.name)) == Set(["Daily Report", "Delete Me", "Move Me", "Other Account"]),
          "默认读取所有 Templates 文件夹，过滤普通/删除/空白/不完整笔记并去重")
    let daily = first.first { $0.name == "Daily Report" }
    check(daily?.id == UUID(uuidString: validUUID) && daily?.sourceNotesID == validUUID,
          "Notes 模板保留笔记 UUID 和来源")
    check(daily?.content.contains("first version") == true && first == NotesTemplateImporter.readTemplates(from: store),
          "同名模板确定性选择且重复读取保持身份及内容稳定")
    let fallbackIDs = first.filter { $0.name == "Delete Me" || $0.name == "Move Me" }.map(\.id)
    check(Set(fallbackIDs).count == 2, "非标准及缺失 UUID 的笔记获得不同稳定身份")
    TemplateStore.updateNotesTemplates(first)
    let templateCommands = buildSlashCommands().filter { $0.group == .template }
    check(templateCommands.count == 5 && templateCommands.contains { $0.name == "Daily-Report" && $0.detail.contains("Notes 模板") },
          "Notes 模板无需导入即进入斜杠命令并显示来源，同名时优先 Notes")
    let typedTemplate = AXSlashWatcher.matchSlashToken("/Daily-Report")
    if case .insertTemplate(let template) = typedTemplate?.action {
        check(template.sourceNotesID == validUUID, "Notes 模板显示的英文命令名可直接键入执行")
    } else {
        check(false, "Notes 模板显示的英文命令名可直接键入执行")
    }
    check(TemplateStore.templates == [local, localOnly] && defaults.data(forKey: "nc.templates") == stored,
          "Notes 模板读取及命令合并不覆盖或持久化本地模板")

    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZDATA = ? WHERE Z_PK = 1010", [body("Daily Report\n{{time}} edited version")])
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMARKEDFORDELETION = 1 WHERE Z_PK = 11")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZFOLDER = 3 WHERE Z_PK = 12")
    let updated = NotesTemplateImporter.readTemplates(from: store)
    TemplateStore.updateNotesTemplates(updated)
    let updatedDaily = TemplateStore.availableTemplates.first { $0.sourceNotesID == validUUID }
    check(updatedDaily?.id == daily?.id && updatedDaily?.content.contains("edited version") == true,
          "Notes 正文修改在刷新后生效且模板身份不变")
    check(!TemplateStore.availableTemplates.contains { $0.name == "Delete Me" || $0.name == "Move Me" },
          "Notes 删除或移出 Templates 后模板从命令来源移除")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE2 = 'Archive' WHERE Z_PK IN (1, 2)")
    TemplateStore.updateNotesTemplates(NotesTemplateImporter.readTemplates(from: store))
    check(TemplateStore.notesTemplates.isEmpty && TemplateStore.availableTemplates == [local, localOnly],
          "Templates 文件夹重命名后清空 Notes 缓存并恢复同名本地模板")
    let legacy = Data("[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"Legacy\",\"content\":\"text\"}]".utf8)
    check(try JSONDecoder().decode([TemplateNote].self, from: legacy).first?.sourceNotesID == nil,
          "旧本地模板缺少 Notes 来源字段仍能反序列化")

    // Core Data 的实体注册表使用 Z_NAME；实体编号随系统版本变化，不能依赖默认值。
    try sql("ALTER TABLE Z_PRIMARYKEY RENAME COLUMN ZNAME TO Z_NAME")
    try sql("UPDATE Z_PRIMARYKEY SET Z_ENT = CASE Z_ENT WHEN 11 THEN 15 WHEN 12 THEN 27 WHEN 13 THEN 28 ELSE Z_ENT END")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET Z_ENT = CASE Z_ENT WHEN 11 THEN 15 WHEN 12 THEN 27 WHEN 13 THEN 28 ELSE Z_ENT END")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE2 = 'Templates' WHERE Z_PK IN (1, 2)")
    let nativeRegistryStore = try NotesStore(path: path, enableFTS: false)
    check(nativeRegistryStore.folders().contains { $0.pk == 1 && $0.name == "Templates" },
          "Core Data Z_NAME 注册表正确识别非默认编号的 Templates 文件夹")
    let nativeDaily = nativeRegistryStore.notes(folderPK: 1).first { $0.pk == 10 }
    let nativeBody = nativeDaily.map { nativeRegistryStore.content(for: $0) }
    check(nativeBody?.isComplete == true && nativeBody?.markdown.contains("edited version") == true,
          "Core Data Z_NAME 注册表正确识别非默认编号的笔记及正文实体")
    let nativeTemplates = NotesTemplateImporter.readTemplates(from: nativeRegistryStore)
    check(Set(nativeTemplates.map(\.name)) == Set(["Daily Report", "Other Account"])
          && nativeTemplates.first { $0.sourceNotesID == validUUID }?.content.contains("edited version") == true,
          "真实 Core Data 注册表列名和实体编号下仍默认发现完整 Notes 模板")

    // Inline hashtags and note links are text attachments in native Notes. The
    // identifier/type in the protobuf must match metadata owned by this note.
    let hashtagType = "com.apple.notes.inlinetextattachment.hashtag"
    let linkType = "com.apple.notes.inlinetextattachment.link"
    let imageType = "public.jpeg"
    func inlineBody(_ parts: [(text: String, id: String?, type: String?)]) -> Data {
        var text = ""
        var runs: [UInt8] = []
        for part in parts {
            text += part.text
            var run = varint(1 << 3) + varint(UInt64(part.text.utf16.count))
            if let identifier = part.id, let type = part.type {
                run += field(12, field(1, Array(identifier.utf8)) + field(2, Array(type.utf8)))
            }
            runs += field(5, run)
        }
        return Data(field(2, field(3, field(2, Array(text.utf8)) + runs)))
    }
    func inlineNote(_ id: Int, _ title: String, _ parts: [(text: String, id: String?, type: String?)]) throws {
        try sql("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZNOTEDATA, ZMODIFICATIONDATE1)
            VALUES (?, 27, ?, ?, 1, ?, ?)
            """, [id, "inline-note-\(id)", title, id + 1000, id])
        try sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZDATA) VALUES (?, 28, ?)", [id + 1000, inlineBody(parts)])
    }
    func attachment(_ id: Int, _ noteID: Int, _ identifier: String, _ type: String, _ text: String) throws {
        try sql("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT, ZNOTE1) VALUES (?, 29, ?, ?, ?, ?)
            """, [id, identifier, type, text, noteID])
    }
    try inlineNote(30, "Tagged Weekly", [
        ("Tagged Weekly\nWeek 😀 ", nil, nil), ("\u{FFFC}", "weekly-tag", hashtagType), ("\n{{date}}", nil, nil)
    ])
    try inlineNote(31, "Linked Plan", [
        ("Linked Plan\nPlan ", nil, nil), ("\u{FFFC}", "plan-tag", hashtagType), ("\nSee ", nil, nil),
        ("\u{FFFC}", "plan-link", linkType), (" next", nil, nil)
    ])
    try inlineNote(32, "Image Template", [("Image Template\nPhoto ", nil, nil), ("\u{FFFC}", "image", imageType)])
    try attachment(2030, 30, "weekly-tag", hashtagType, "#weekly")
    try attachment(2031, 31, "plan-tag", hashtagType, "#planning")
    try attachment(2032, 31, "plan-link", linkType, "Roadmap")
    try attachment(2033, 32, "image", imageType, "A photo")
    let inlineSummaries = Dictionary(uniqueKeysWithValues: nativeRegistryStore.notes(folderPK: 1).map { ($0.pk, $0) })
    guard let weekly = inlineSummaries[30], let linked = inlineSummaries[31], let image = inlineSummaries[32] else {
        throw NSError(domain: "TemplateFixture.inlineSummaries", code: 1)
    }
    let weeklyContent = nativeRegistryStore.content(for: weekly)
    check(weeklyContent.isComplete && weeklyContent.plainText == "Tagged Weekly\nWeek 😀 #weekly\n{{date}}"
          && !weeklyContent.markdown.contains("\u{FFFC}"),
          "NotesStore 用本笔记的行内标签元数据还原完整文本并保留 emoji 与模板变量")
    let linkedContent = nativeRegistryStore.content(for: linked)
    check(linkedContent.isComplete && linkedContent.plainText == "Linked Plan\nPlan #planning\nSee Roadmap next"
          && linkedContent.markdown.contains("Roadmap") && !linkedContent.markdown.contains("\u{FFFC}"),
          "NotesStore 同时还原行内标签与笔记链接的显示文本")
    let resolvedTemplates = NotesTemplateImporter.readTemplates(from: nativeRegistryStore)
    check(resolvedTemplates.contains { $0.name == "Tagged Weekly" && $0.content.contains("#weekly") }
          && resolvedTemplates.contains { $0.name == "Linked Plan" && $0.content.contains("Roadmap") },
          "包含已还原行内标签和笔记链接的 Notes 笔记默认成为模板")
    check(!nativeRegistryStore.content(for: image).isComplete && !resolvedTemplates.contains { $0.name == "Image Template" },
          "有显示元数据的图片仍标记不完整并排除模板，不能冒充文本附件")

    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTYPEUTI1 = ? WHERE Z_PK = 2030", [linkType])
    check(!nativeRegistryStore.content(for: weekly).isComplete,
          "行内附件 protobuf 类型与本笔记元数据不符时拒绝完整解码")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTYPEUTI1 = ?, ZIDENTIFIER = 'unmatched-id' WHERE Z_PK = 2030", [hashtagType])
    check(!nativeRegistryStore.content(for: weekly).isComplete,
          "缺少匹配标识符的行内附件元数据时仍标记不完整")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZIDENTIFIER = 'weekly-tag', ZNOTE1 = 31 WHERE Z_PK = 2030")
    check(!nativeRegistryStore.content(for: weekly).isComplete && nativeRegistryStore.content(for: linked).isComplete,
          "行内附件只能匹配自身笔记的元数据，不能跨笔记借用同一标识符")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZNOTE1 = 30, ZALTTEXT = '' WHERE Z_PK = 2030")
    check(!nativeRegistryStore.content(for: weekly).isComplete,
          "行内附件缺少显示文本时不能假定完整还原")
    try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZALTTEXT = '#weekly', ZMARKEDFORDELETION = 1 WHERE Z_PK = 2030")
    check(!nativeRegistryStore.content(for: weekly).isComplete,
          "已删除的行内附件元数据不参与正文还原")

    let richText = "Native Rich\n{{date: yyyy-MM-dd}}周记录\nBold line\nfirst code\nsecond code\nItem\n"
    func styledRun(_ text: String, paragraph: UInt64? = nil, bold: Bool = false) -> [UInt8] {
        var run = varint(1 << 3) + varint(UInt64(text.utf16.count))
        if let paragraph { run += field(2, varint(1 << 3) + varint(paragraph)) }
        if bold { run += varint(5 << 3) + varint(1) }
        return field(5, run)
    }
    let richRuns = styledRun("Native Rich\n", paragraph: 0)
        + styledRun("{{date: yyyy-MM-dd}}周记录\n")
        + styledRun("Bold line\n", bold: true)
        + styledRun("first code\nsecond code\n", paragraph: 4)
        + styledRun("Item\n", paragraph: 101)
    let richBody = Data(field(2, field(3, field(2, Array(richText.utf8)) + richRuns)))
    try sql("""
        INSERT INTO ZICCLOUDSYNCINGOBJECT
        (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZNOTEDATA, ZMODIFICATIONDATE1)
        VALUES (40, 27, 'native-rich-template', 'Outdated cached title', 1, 1040, 40)
        """)
    try sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZDATA) VALUES (1040, 28, ?)", [richBody])
    let richTemplate = NotesTemplateImporter.readTemplates(from: nativeRegistryStore).first { $0.name == "Native Rich" }
    let expectedRichText = "{{date: yyyy-MM-dd}}周记录\nBold line\nfirst code\nsecond code\nItem\n"
    check(richTemplate?.name == "Native Rich" && richTemplate?.content == expectedRichText,
          "Notes 模板首行仅作为模板名，实际首行优先于缓存标题且不进入插入内容")
    check(richTemplate?.sourceDocument?.text == expectedRichText
          && richTemplate?.sourceDocument?.runs.first?.paragraphType == 1,
          "第二行日期变量保持原文并提升为新文档标题样式")
    func styledFragments(_ document: TopotextDoc?) -> [(text: String, run: TopotextRun)] {
        guard let document else { return [] }
        let text = document.text as NSString
        var offset = 0
        var fragments: [(text: String, run: TopotextRun)] = []
        for run in document.runs {
            guard run.length >= 0, offset + run.length <= text.length else { return [] }
            fragments.append((text.substring(with: NSRange(location: offset, length: run.length)), run))
            offset += run.length
        }
        return offset == text.length ? fragments : []
    }
    let richFragments = styledFragments(richTemplate?.sourceDocument)
    check(richFragments.contains { $0.text == "Bold line\n" && $0.run.bold && $0.run.paragraphType != 1 }
          && richFragments.contains { $0.text == "first code\nsecond code\n" && $0.run.monospacedBlock }
          && richTemplate?.sourceDocument?.totalLength == expectedRichText.utf16.count,
          "去掉模板名后富文本范围同步移动，正文粗体和多行等宽块保留且不继承标题")

    func nativeFixture(_ id: Int, _ title: String, _ text: String, _ runs: [UInt8] = []) throws {
        try sql("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZNOTEDATA, ZMODIFICATIONDATE1)
            VALUES (?, 27, ?, ?, 1, ?, ?)
            """, [id, "name-semantics-\(id)", title, id + 1000, id])
        let data = Data(field(2, field(3, field(2, Array(text.utf8)) + runs)))
        try sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZDATA) VALUES (?, 28, ?)", [id + 1000, data])
    }
    try nativeFixture(41, "Name only", "Name only")
    try nativeFixture(42, "Empty after name", "Empty after name\n \n\t")
    try nativeFixture(43, "Cached name", " \nActual title\nbody")
    let unicodeTitle = "{{date: yyyy-MM-dd}}😀周记录\r\n"
    let unicodePrefix = "模版😀\r\n\r\n"
    let unicodeCode = "line😀 one\r\nline two\r\n"
    let unicodeContent = unicodeTitle + "\r\n" + unicodeCode
    let unicodeText = unicodePrefix + unicodeContent
    // A native run may cross the metadata/content boundary. Its length is UTF-16,
    // so both the emoji and CRLF have to be counted before retaining the suffix.
    let unicodeRuns = styledRun(unicodePrefix + unicodeTitle, paragraph: 0, bold: true)
        + styledRun("\r\n")
        + styledRun(unicodeCode, paragraph: 4)
    try nativeFixture(44, "模版😀", unicodeText, unicodeRuns)
    let finalTemplates = NotesTemplateImporter.readTemplates(from: nativeRegistryStore)
    check(!finalTemplates.contains { ["name-semantics-41", "name-semantics-42", "name-semantics-43"].contains($0.sourceNotesID ?? "") },
          "只有模板名、名后仅空白或首行空白的笔记不产生可插入模板")
    let unicodeTemplate = finalTemplates.first { $0.sourceNotesID == "name-semantics-44" }
    check(unicodeTemplate?.name == "模版😀" && unicodeTemplate?.content == unicodeContent,
          "CRLF 模板跳过名称后的空行，保留标题 emoji、日期变量与正文内部空行")
    let unicodeFragments = styledFragments(unicodeTemplate?.sourceDocument)
    check(unicodeFragments.first?.text == unicodeTitle
          && unicodeFragments.first?.run.paragraphType == 1
          && unicodeFragments.first?.run.bold == true
          && unicodeFragments.contains { $0.text == unicodeCode && $0.run.monospacedBlock }
          && unicodeTemplate?.sourceDocument?.totalLength == unicodeContent.utf16.count,
          "UTF-16 裁剪跨名称和内容的样式 run，CRLF 与 emoji 不错位且代码块保留")

    let codeTitleText = "Code name\nNew title\nCode body\n"
    try nativeFixture(45, "Code name", codeTitleText,
        styledRun("Code name\n", paragraph: 0) + styledRun("New title\nCode body\n", paragraph: 4))
    let listTitleText = "List name\nList title\nBody item\n"
    try nativeFixture(46, "List name", listTitleText,
        styledRun("List name\n", paragraph: 0) + styledRun("List title\nBody item\n", paragraph: 101))
    let paragraphTemplates = NotesTemplateImporter.readTemplates(from: nativeRegistryStore)
    let codeTitle = paragraphTemplates.first { $0.sourceNotesID == "name-semantics-45" }?.sourceDocument
    let listTitle = paragraphTemplates.first { $0.sourceNotesID == "name-semantics-46" }?.sourceDocument
    let codeHTML = codeTitle.map(NativeNoteHTML.render) ?? ""
    let listHTML = listTitle.map(NativeNoteHTML.render) ?? ""
    check(codeTitle?.runs.first?.paragraphType == 1 && codeTitle?.runs.first?.monospacedBlock == false
          && codeHTML.contains("<h1") && codeHTML.contains("New title") && codeHTML.contains("<pre")
          && styledFragments(codeTitle).contains { $0.text == "Code body\n" && $0.run.monospacedBlock },
          "第二行即使原为等宽块也转为文档标题，跨段 run 中的后续代码块继续保留")
    check(listTitle?.runs.first?.paragraphType == 1 && listHTML.contains("<h1")
          && listHTML.contains("List title") && listHTML.contains("<ul")
          && styledFragments(listTitle).contains { $0.text == "Body item\n" && $0.run.paragraphType == 5 },
          "第二行原列表段落转为文档标题，后续列表样式保持")
    check(daily?.sourceDocument?.runs.first?.paragraphType == 1
          && daily?.content == "{{date}} first version"
          && daily?.sourceDocument?.runs.map(\.length).reduce(0, +) == "{{date}} first version".utf16.count,
          "没有原生样式 run 的笔记补齐标题样式并只保留名称后内容")
    var oversized = TopotextRun()
    oversized.length = 100
    var negative = TopotextRun()
    negative.length = -1
    check(NotesTemplateImporter.splitTemplate(TopotextDoc(runs: [oversized], text: "Name\nTitle")) == nil
          && NotesTemplateImporter.splitTemplate(TopotextDoc(runs: [negative], text: "Name\nTitle")) == nil
          && NotesTemplateImporter.splitTemplate(TopotextDoc(text: "Name\nTitle", isComplete: false)) == nil,
          "超出文本、负数样式范围或不完整源文档拒绝产生模板")

}

private func urlFallbackTests() async {
    var visited: [Int] = []
    let title = await UrlTitleLinker.firstUsableTitle([
        { visited.append(1); return "Sign in to SSO" },
        { visited.append(2); return "统一登录" },
        { visited.append(3); return "  内网文档  " },
    ])
    check(title == "内网文档" && visited == [1, 2, 3], "登录页继续尝试已登录标题来源")
    visited = []
    let first = await UrlTitleLinker.firstUsableTitle([
        { visited.append(1); return "公开文章" },
        { visited.append(2); return "多余请求" },
    ])
    check(first == "公开文章" && visited == [1], "正常标题不触发多余来源")
    let empty = await UrlTitleLinker.firstUsableTitle([{ " " }, { nil }, { "Login" }])
    check(empty == nil, "全部来源无效时回退原URL")
    let longURL = "https://example.com/article/" + String(repeating: "long-path-", count: 100)
    check(UrlTitleLinker.lastURLToken(in: longURL + " ")?.url == longURL, "长URL保持完整识别")
    let task = Task { () -> String? in
        withUnsafeCurrentTask { $0?.cancel() }
        return await UrlTitleLinker.firstUsableTitle([{ "不应出现" }])
    }
    check(await task.value == nil, "取消后不继续读取标题来源")
}

@MainActor
private func keyboardListenerTests() async {
    let defaults = UserDefaults.standard
    let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    func features(keywords: Bool, slash: Bool) {
        var fixture = previous
        fixture["nc.kw.enabled"] = keywords
        fixture["nc.slash.global"] = slash
        defaults.setVolatileDomain(fixture, forName: UserDefaults.argumentDomain)
    }
    var messages: [String] = []
    let observer = NotificationCenter.default.addObserver(forName: .init("nc.kwStatus"), object: nil, queue: nil) { notification in
        guard let message = notification.object as? String else { return }
        MainActor.assumeIsolated { messages.append(message) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    features(keywords: false, slash: true)
    var attempts = 0
    var tapOptions: [UInt32] = []
    let accessible = KeywordListener(accessibilityTrusted: { true }, tapFactory: { options in
        attempts += 1
        tapOptions.append(options.rawValue)
        return nil
    })
    defer { accessible.stop() }
    accessible.startIfNeeded()
    check(attempts == 1 && tapOptions == [CGEventTapOptions.defaultTap.rawValue],
          "辅助功能已授权时主动键盘tap不受输入监控未授权阻断")
    check(!accessible.isRunning, "tap工厂失败不会误报键盘导航或关键词监听已运行")
    check(messages.last?.contains("键盘") == true && messages.last?.contains("输入监控") == false
          && messages.last?.contains("Markdown") == false,
          "tap失败只报告键盘导航与关键词状态而不要求额外输入监控")
    try? await Task.sleep(nanoseconds: 3_300_000_000)
    check(attempts >= 2 && !accessible.isRunning, "创建tap失败后仍按3秒间隔重试且不误报成功")
    accessible.stop()

    features(keywords: true, slash: false)
    var blockedAttempts = 0
    var trusted = false
    let inaccessible = KeywordListener(accessibilityTrusted: { trusted }, tapFactory: { _ in
        blockedAttempts += 1
        return nil
    })
    defer { inaccessible.stop() }
    inaccessible.startIfNeeded()
    check(blockedAttempts == 0 && !inaccessible.isRunning, "缺少辅助功能时不会创建可拦截按键的主动tap")
    check(messages.last?.contains("辅助功能") == true && messages.last?.contains("Markdown") == false,
          "辅助功能缺失给出准确键盘功能授权提示")
    trusted = true
    try? await Task.sleep(nanoseconds: 3_300_000_000)
    check(blockedAttempts >= 1 && !inaccessible.isRunning, "辅助功能授权变化后重试真实启动路径但nil工厂不代表成功")
    let attemptsBeforeRevocation = blockedAttempts
    trusted = false
    inaccessible.handleTapDisabled()
    inaccessible.startIfNeeded()
    check(blockedAttempts == attemptsBeforeRevocation && !inaccessible.isRunning
          && messages.last?.contains("辅助功能") == true,
          "权限撤销的禁用回调不盲目重启主动tap而是等待重新授权")
    inaccessible.stop()

    features(keywords: false, slash: false)
    var disabledAttempts = 0
    let disabled = KeywordListener(accessibilityTrusted: { true }, tapFactory: { _ in
        disabledAttempts += 1
        return nil
    })
    defer { disabled.stop() }
    disabled.startIfNeeded()
    check(disabledAttempts == 0 && !disabled.isRunning, "关键词与斜杠菜单均关闭时不启动键盘tap")
    messages.append("菜单键盘导航与关键词监听已启动。")
    let messageCountBeforeRestart = messages.count
    disabled.restart()
    check(messages.count == messageCountBeforeRestart + 1 && messages.last == "菜单键盘导航与关键词扩展已关闭。",
          "关闭全部键盘功能后restart会发布关闭状态以替换界面缓存的已启动消息")
}

renderingTests()
templateImportTests()
do { try notesTemplateTests() }
catch { check(false, "Notes 模板合成数据库测试：\(error)") }
Task { @MainActor in
    await keyboardListenerTests()
    await urlFallbackTests()
    print("product-tests: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
RunLoop.main.run()
