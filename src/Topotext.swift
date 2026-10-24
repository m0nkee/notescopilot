import Foundation
import Compression
import zlib

// MARK: - Protobuf wire 解析（无依赖手工实现，复刻 ProNotes 的 Topotext_* SwiftProtobuf 通道）

enum ProtoWire {
    struct Field {
        let number: Int
        let wireType: Int
        let varint: UInt64?
        let bytes: Data?
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func parse(_ data: Data) -> [Field] {
        var out: [Field] = []
        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            guard let key = readVarint(data, &i), i < end else { break }
            let number = Int(key >> 3)
            let wt = Int(key & 7)
            guard number > 0 else { break }
            switch wt {
            case 0:
                guard let v = readVarint(data, &i) else { return out }
                out.append(Field(number: number, wireType: 0, varint: v, bytes: nil))
            case 1:
                guard end - i >= 8 else { return out }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(data[i + k]) << (8 * UInt64(k)) }
                i += 8
                out.append(Field(number: number, wireType: 1, varint: v, bytes: nil))
            case 2:
                guard let len = readVarint(data, &i), len <= UInt64(end - i) else { return out }
                let sub = data[i ..< data.index(i, offsetBy: Int(len))]
                i = data.index(i, offsetBy: Int(len))
                out.append(Field(number: number, wireType: 2, varint: len, bytes: Data(sub)))
            case 5:
                guard end - i >= 4 else { return out }
                i += 4
                out.append(Field(number: number, wireType: 5, varint: nil, bytes: nil))
            default:
                return out
            }
        }
        return out
    }

    private static func readVarint(_ data: Data, _ i: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        while i < data.endIndex, count < 10 {
            let b = data[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            count += 1
        }
        return nil
    }

    /// zlib 解压（0x78 头）：Apple Compression 的 COMPRESSION_ZLIB 实为 raw DEFLATE，
    /// 需剥掉 zlib 容器头（2 字节）与 adler32 尾（4 字节）后解码。
    static func zlibInflate(_ data: Data) -> Data? {
        if data.starts(with: [0x1f, 0x8b]) { return gzipInflate(data) }
        guard data.count > 8, data[data.startIndex] == 0x78 else { return nil }
        let raw = data.dropFirst(2).dropLast(4)
        var dst = [UInt8](repeating: 0, count: data.count * 16)
        let src = [UInt8](raw)
        for _ in 0..<6 {
            let n = src.withUnsafeBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    compression_decode_buffer(dp.baseAddress!, dp.count,
                                               sp.baseAddress!, sp.count,
                                               nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < dst.count { return Data(dst.prefix(n)) }
            if n == dst.count {
                dst = [UInt8](repeating: 0, count: dst.count * 4)
                continue
            }
            return nil
        }
        return nil
    }

    /// Apple Notes normally stores a gzip container, rather than raw DEFLATE.
    /// zlib validates the container checksum and enforces a decompression cap.
    static func gzipInflate(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            var output = Data()
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            while output.count < 64 * 1024 * 1024 {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: chunk.prefix(chunkSize - Int(stream.avail_out)))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, stream.avail_in > 0 || stream.avail_out == 0 else { return nil }
            }
            return nil
        }
    }
}

// MARK: - Topotext 解码（对应 ProNotes 的 Topotext_Document / AttributeRun / CRDT 类型族）
//
// 结构采用公开逆向共识 + 防御性解析：
// 外层 NoteData protobuf → 字段中的 topotext Document（或其 zlib 压缩形态）
// Document = repeated AttributeRun（length / paragraphStyle / font / todo / attachment）
// 文本字符以 CRDT Item 树存储，防回退策略：按序收割 UTF-8 字符串

struct TopotextRun: Equatable {
    var length = 0
    var paragraphType = 0       // 0=正文 1=标题 2=大标题 3=副标题 4=小标题 5=列表项 …
    var listLevel = 0
    var isTodo = false
    var todoDone = false
    var bold = false
    var italic = false
    var strikethrough = false
    var underline = false
    var monospaced = false
    var numbered = false
    var blockQuote = false
    var link: String?
}

struct TopotextDoc {
    var runs: [TopotextRun] = []
    var text = ""
    var totalLength = 0
    var isComplete = true
    var warnings: [String] = []
}

enum TopotextDecoder {
    static let utf8printable: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.formUnion(CharacterSet.punctuationCharacters)
        s.formUnion(CharacterSet.symbols)
        s.insert(charactersIn: " \n\t·—…、。，；：？！“”‘’（）《》【】")
        // 常用 CJK 范围逐段插入（0xA0-0x2FF / 0x3000-0x9FFF / 0xF900-0xFAFF / 0xFF00-0xFFEF）
        var extra = CharacterSet()
        var scal: [Unicode.Scalar] = []
        for v in 0x00A0...0x02FF { if let u = Unicode.Scalar(v) { scal.append(u) } }
        for v in 0x3000...0x9FFF { if let u = Unicode.Scalar(v) { scal.append(u) } }
        for v in 0xF900...0xFAFF { if let u = Unicode.Scalar(v) { scal.append(u) } }
        for v in 0xFF00...0xFFEF { if let u = Unicode.Scalar(v) { scal.append(u) } }
        for u in scal { extra.insert(u) }
        s.formUnion(extra)
        return s
    }()

    /// 主入口：从 NoteStore 的 Z_DATA blob 还原文档
    static func decode(_ blob: Data) -> TopotextDoc? {
        var best: TopotextDoc?
        // blob 本身可能是 zlib 压缩的 protobuf（整段容器）
        var candidates: [Data] = [blob]
        if let inflated = ProtoWire.zlibInflate(blob) { candidates.append(inflated) }
        for candidate in candidates {
            if let document = parseNotesDocument(candidate) { return document }
        }
        candidates += candidatesFor(blob).dropFirst()
        for cand in candidates {
            if let doc = parseDocument(cand), doc.totalLength > 0 || !doc.text.isEmpty {
                if best == nil || doc.runs.count > best!.runs.count {
                    best = doc
                }
            }
        }
        if var b = best {
            b.isComplete = false
            b.warnings = ["正文使用兼容解析，格式或附件可能不完整。"]
            return b
        }
        // 防回退：纯字符串收割
        var doc = TopotextDoc()
        doc.text = harvest(blob)
        doc.isComplete = false
        doc.warnings = ["正文格式无法识别，当前为恢复出的文本，可能不完整。"]
        return doc.text.isEmpty ? nil : doc
    }

    // Notes' published reverse-engineered protobuf schema:
    // NoteStoreProto.2 -> Document.3 -> Note { text:2, attribute_run:5 }.
    // https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto
    private static func parseNotesDocument(_ data: Data) -> TopotextDoc? {
        guard let document = ProtoWire.parse(data).first(where: { $0.number == 2 && $0.wireType == 2 })?.bytes,
              let note = ProtoWire.parse(document).first(where: { $0.number == 3 && $0.wireType == 2 })?.bytes,
              let text = ProtoWire.parse(note).first(where: { $0.number == 2 && $0.wireType == 2 })?.string else { return nil }
        var doc = TopotextDoc()
        doc.text = text
        if text.contains("\u{FFFC}") {
            doc.isComplete = false
            doc.warnings.append("附件、图片或表格未导出，请在备忘录中查看原件。")
        }
        for field in ProtoWire.parse(note) where field.number == 5 && field.wireType == 2 {
            guard let bytes = field.bytes else { continue }
            let fields = ProtoWire.parse(bytes)
            guard let length = fields.first(where: { $0.number == 1 && $0.wireType == 0 })?.varint,
                  length <= UInt64(Int.max) else { continue }
            var run = TopotextRun()
            run.length = Int(length)
            for attribute in fields {
                switch attribute.number {
                case 2:
                    guard let style = attribute.bytes else { continue }
                    for value in ProtoWire.parse(style) {
                        switch value.number {
                        case 1:
                            switch value.varint {
                            case 0: run.paragraphType = 1
                            case 1: run.paragraphType = 2
                            case 2: run.paragraphType = 3
                            case 4: run.monospaced = true
                            case 100, 101: run.paragraphType = 5
                            case 102: run.paragraphType = 5; run.numbered = true
                            case 103: run.paragraphType = 5; run.isTodo = true
                            default: break
                            }
                        case 4: run.listLevel = Int(max(0, min(Int64(bitPattern: value.varint ?? 0), 20)))
                        case 5:
                            run.isTodo = true
                            run.todoDone = value.bytes.map { ProtoWire.parse($0).contains { $0.number == 2 && $0.varint == 1 } } ?? false
                        case 8: run.blockQuote = (value.varint ?? 0) > 0
                        default: break
                        }
                    }
                case 3:
                    if let font = attribute.bytes {
                        for hint in ProtoWire.parse(font) where hint.number == 3 {
                            run.bold = run.bold || ((hint.varint ?? 0) & 1) != 0
                            run.italic = run.italic || ((hint.varint ?? 0) & 2) != 0
                        }
                    }
                case 5:
                    run.bold = run.bold || ((attribute.varint ?? 0) & 1) != 0
                    run.italic = run.italic || ((attribute.varint ?? 0) & 2) != 0
                case 6: run.underline = attribute.varint == 1
                case 7: run.strikethrough = attribute.varint == 1
                case 9: run.link = attribute.string
                case 12:
                    doc.isComplete = false
                    if !doc.warnings.contains("附件、图片或表格未导出，请在备忘录中查看原件。") {
                        doc.warnings.append("附件、图片或表格未导出，请在备忘录中查看原件。")
                    }
                default: break
                }
            }
            doc.runs.append(run)
        }
        doc.totalLength = doc.runs.reduce(0) { $0 + $1.length }
        let count = text.utf16.count
        if !doc.runs.isEmpty && doc.totalLength != count {
            doc.runs = []
            doc.isComplete = false
            doc.warnings.append("正文样式范围不完整，已保留全部纯文本。")
        }
        return doc
    }

    private static func candidatesFor(_ data: Data) -> [Data] {
        var list = [data]
        let fields = ProtoWire.parse(data)
        for f in fields where f.wireType == 2 {
            if let b = f.bytes {
                list.append(b)
                if let inflated = ProtoWire.zlibInflate(b) { list.append(inflated) }
            }
        }
        return list
    }

    /// 解析 Document：字段 1 = repeated AttributeRun
    static func parseDocument(_ data: Data) -> TopotextDoc? {
        var doc = TopotextDoc()
        let fields = ProtoWire.parse(data)
        var found = false
        for f in fields {
            guard let b = f.bytes else { continue }
            if f.number == 1 {
                if let run = parseRun(b) {
                    doc.runs.append(run)
                    found = true
                } else {
                    // 嵌套：字段 1 可能是包装消息，内含 runs
                    for sub in ProtoWire.parse(b) where sub.number == 1 {
                        if let sb = sub.bytes, let run = parseRun(sb) {
                            doc.runs.append(run)
                            found = true
                        }
                    }
                }
            } else if f.number == 5, f.string == nil {
                continue
            }
        }
        // 文本：树内字符串
        doc.text = harvestTextRuns(data)
        doc.totalLength = doc.runs.reduce(0) { $0 + $1.length }
        if doc.text.count < doc.totalLength {
            doc.text = harvest(data)
        }
        guard found || !doc.text.isEmpty else { return nil }
        return doc
    }

    /// AttributeRun：小 varint = length；嵌套消息 = 样式
    private static func parseRun(_ data: Data) -> TopotextRun? {
        var run = TopotextRun()
        var styleLike = false
        var sawSomething = false
        for f in ProtoWire.parse(data) {
            switch f.wireType {
            case 0:
                let v = f.varint ?? 0
                if f.number == 4 || (run.length == 0 && v > 0 && v < 100_000) {
                    run.length = Int(v)
                } else if v == 0 || v == 1 {
                    run.bold = run.bold || v == 1
                }
                sawSomething = true
            case 2:
                guard let b = f.bytes else { continue }
                styleLike = true
                sawSomething = true
                interpretStyle(b, into: &run)
            default:
                break
            }
        }
        guard sawSomething, styleLike || run.length > 0 else { return nil }
        return run
    }

    /// 样式子消息解读：段级样式 / 列表 / todo / 字体 traits
    private static func interpretStyle(_ data: Data, into run: inout TopotextRun) {
        for f in ProtoWire.parse(data) {
            if f.wireType == 0 {
                let v = Int(truncatingIfNeeded: f.varint ?? 0)
                switch f.number {
                case 1 ... 8 where run.paragraphType == 0:
                    run.paragraphType = v
                default:
                    if v == 1 { run.bold = true }
                }
            } else if f.wireType == 2, let b = f.bytes {
                // 更深一层：list attribute / todo / font traits
                for g in ProtoWire.parse(b) {
                    if g.wireType == 0 {
                        let v = Int(truncatingIfNeeded: g.varint ?? 0)
                        if v == 1 { run.bold = true }
                        if v == 2 { run.italic = true }
                        if v == 3 { run.strikethrough = true }
                    } else if g.wireType == 2, let s = g.string {
                        if s.contains("bold") || s.contains("Bold") || s.contains("Semibold") { run.bold = true }
                        if s.contains("italic") || s.contains("Italic") { run.italic = true }
                    }
                }
            }
        }
    }

    /// 收割有序文本（真实 topotext 的字符以 Item 树/字符串片段存在）
    private static func harvestTextRuns(_ data: Data) -> String {
        let fields = ProtoWire.parse(data)
        var pieces: [String] = []
        for f in fields where f.wireType == 2 {
            guard let b = f.bytes else { continue }
            // 单字符或短文本字段按序拼接；递归一层
            if let s = f.string, s.count <= 1, s.unicodeScalars.allSatisfy({ utf8printable.contains($0) }) {
                pieces.append(s)
            } else {
                pieces.append(harvestTextRuns(b))
            }
        }
        return pieces.joined()
    }

    /// 全量字符串收割（防回退：跨所有嵌套层收集可读 UTF-8）
    static func harvest(_ data: Data) -> String {
        var acc: [String] = []
        walk(data, into: &acc)
        return acc.joined()
    }

    private static func walk(_ data: Data, into acc: inout [String]) {
        for f in ProtoWire.parse(data) where f.wireType == 2 {
            if let b = f.bytes {
                if let s = printableString(b) {
                    acc.append(s)
                } else {
                    walk(b, into: &acc)
                }
            }
        }
    }

    private static func printableString(_ d: Data) -> String? {
        guard let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        guard s.unicodeScalars.allSatisfy({ utf8printable.contains($0) }) else { return nil }
        return s
    }
}

// MARK: - Markdown 转换器（对应 ProNotes MarkdownConverter / MarkdownConverterV2）

enum MarkdownConverter {
    /// 笔记 + topotext 文档 → Markdown
    static func convert(note: NoteSummary, doc: TopotextDoc?) -> String {
        var md = "# " + (note.title.isEmpty ? "无标题" : note.title) + "\n\n"
        if let doc {
            if !doc.warnings.isEmpty { md += "> 注意：" + doc.warnings.joined(separator: "；") + "\n\n" }
            md += applyRuns(doc)
        } else {
            let snippet = note.snippet.replacingOccurrences(of: "\u{FFFC}", with: "")
            md += "> 注意：无法读取完整正文，以下仅为摘要。\n\n"
            md += snippet.isEmpty ? "_（无可用摘要）_" : snippet
        }
        return md
    }

    static func applyRuns(_ doc: TopotextDoc) -> String {
        var out = ""
        var cursor = 0 // Apple Notes attribute lengths are UTF-16 code units.
        let text = doc.text
        if doc.runs.isEmpty {
            return text.isEmpty ? "_（正文解码失败或为空）_" : text
        }
        var atLineStart = true
        var merged: [TopotextRun] = []
        for run in doc.runs {
            if var last = merged.last {
                let combinedLength = last.length + run.length
                last.length = run.length
                if last == run {
                    merged[merged.count - 1].length = combinedLength
                    continue
                }
            }
            merged.append(run)
        }
        for run in merged {
            if run.length <= 0 { continue }
            let end = min(cursor + run.length, text.utf16.count)
            guard cursor < end else { continue }
            guard let range = Range(NSRange(location: cursor, length: end - cursor), in: text) else {
                // Malformed runs must never split a surrogate pair or lose text.
                return text
            }
            let chunk = String(text[range])
            cursor = end
            let lines = chunk.components(separatedBy: "\n")
            for (index, part) in lines.enumerated() {
                if !part.isEmpty {
                    if atLineStart {
                        switch run.paragraphType {
                        case 1: out += "# "
                        case 2: out += "## "
                        case 3: out += "### "
                        case 4: out += "#### "
                        case 5, 6, 7, 8:
                            out += String(repeating: "  ", count: min(20, max(0, run.listLevel)))
                            out += run.numbered ? "1. " : "- "
                            if run.isTodo { out += run.todoDone ? "[x] " : "[ ] " }
                        default: break
                        }
                        if run.blockQuote { out += "> " }
                    }
                    let leading = String(part.prefix(while: { $0.isWhitespace }))
                    let content = String(part.dropFirst(leading.count))
                    let trailing = String(content.reversed().prefix(while: { $0.isWhitespace }).reversed())
                    var styled = String(content.dropLast(trailing.count))
                    if styled.isEmpty { out += part; atLineStart = false; continue }
                    if run.monospaced { styled = "`" + styled.replacingOccurrences(of: "`", with: "\\`") + "`" }
                    if run.bold { styled = "**" + styled + "**" }
                    if run.italic { styled = "_" + styled + "_" }
                    if run.strikethrough { styled = "~~" + styled + "~~" }
                    if run.underline { styled = "<u>" + styled + "</u>" }
                    if let link = run.link, !link.isEmpty {
                        styled = "[" + styled + "](" + link.replacingOccurrences(of: ")", with: "%29") + ")"
                    }
                    out += leading + styled + trailing
                    atLineStart = false
                }
                if index < lines.count - 1 { out += "\n"; atLineStart = true }
            }
        }
        if cursor < text.utf16.count,
           let remainder = Range(NSRange(location: cursor, length: text.utf16.count - cursor), in: text) {
            out += text[remainder]
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
