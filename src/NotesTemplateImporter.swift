import Foundation
import CryptoKit

enum NotesTemplateImporter {
    struct Result {
        let templates: [TemplateNote]
        let addedCount: Int
        let skippedCount: Int
    }

    /// Import is explicit and additive: an existing local template is never overwritten.
    static func merging(_ candidates: [(name: String, content: String)], into existing: [TemplateNote]) -> Result {
        var templates = existing
        var names = Set(existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var skipped = 0
        for candidate in candidates {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !content.isEmpty, names.insert(name.lowercased()).inserted else { skipped += 1; continue }
            templates.append(TemplateNote(name: name, content: candidate.content))
        }
        return Result(templates: templates, addedCount: templates.count - existing.count, skippedCount: skipped)
    }

    static func read(from store: NotesStore) -> [(name: String, content: String)] {
        readTemplates(from: store).map { (name: $0.name, content: $0.content) }
    }

    /// 每次读取都以 Notes 为准；固定排序使多个账户的同名命令保持同一个来源。
    static func readTemplates(from store: NotesStore) -> [TemplateNote] {
        let notes = store.folders().filter { $0.name.caseInsensitiveCompare("Templates") == .orderedSame }
            .sorted { $0.pk < $1.pk }
            .flatMap { folder in store.notes(folderPK: folder.pk).sorted { $0.pk < $1.pk } }
        var names = Set<String>()
        return notes.compactMap { note in
            // 首行只是模板名称；载荷从后续内容开始，不能插入 Notes 缓存标题或导出 Markdown。
            guard let source = store.document(for: note.pk),
                  let (name, document) = splitTemplate(source),
                  names.insert(TemplateStore.commandKey(for: name)).inserted else { return nil }
            let sourceID = note.uuid.isEmpty ? "pk:\(note.pk)" : note.uuid
            let id = UUID(uuidString: note.uuid) ?? stableID(for: "\(store.path)\u{0}\(sourceID)\u{0}\(note.pk)")
            return TemplateNote(id: id, name: name, content: document.text, sourceNotesID: sourceID,
                                sourceDocument: document)
        }
    }

    /// Notes 的第一行定义模板名；首个内容段落定义新文档标题。
    /// 所有裁切均使用原生样式的 UTF-16 范围，避免中文、emoji 或跨段 run 错位。
    static func splitTemplate(_ source: TopotextDoc) -> (name: String, document: TopotextDoc)? {
        guard source.isComplete else { return nil }
        let text = source.text as NSString
        guard text.length > 0 else { return nil }
        func line(at offset: Int) -> (end: Int, contentEnd: Int) {
            var end = 0, contentEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentEnd,
                              for: NSRange(location: offset, length: 0))
            return (end, contentEnd)
        }
        let first = line(at: 0)
        let name = text.substring(to: first.contentEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var start = first.end
        // 模板名与内容之间可以留空行；正文内部的空行保持原样。
        while start < text.length {
            let current = line(at: start)
            let value = text.substring(with: NSRange(location: start, length: current.contentEnd - start))
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = current.end
        }
        guard start < text.length else { return nil }
        let titleEnd = line(at: start).end
        var document = source
        document.text = text.substring(from: start)
        document.totalLength = text.length - start
        document.runs = []

        func append(_ run: TopotextRun, from lower: Int, to upper: Int) {
            let lower = max(lower, start)
            guard lower < upper else { return }
            if lower < titleEnd {
                var title = run
                title.length = min(upper, titleEnd) - lower
                title.paragraphType = 1
                title.listLevel = 0
                title.isTodo = false
                title.todoDone = false
                title.numbered = false
                title.blockQuote = false
                title.monospacedBlock = false
                document.runs.append(title)
            }
            if upper > max(lower, titleEnd) {
                var body = run
                body.length = upper - max(lower, titleEnd)
                document.runs.append(body)
            }
        }
        var offset = 0
        for run in source.runs {
            guard run.length >= 0, run.length <= text.length - offset else { return nil }
            append(run, from: offset, to: offset + run.length)
            offset += run.length
        }
        if offset < text.length { append(TopotextRun(), from: offset, to: text.length) }
        return (name, document)
    }

    private static func stableID(for source: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(source.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // 自定义 UUID（version 8）
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
