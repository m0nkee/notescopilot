import Foundation
import Compression

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
}

// MARK: - Topotext 解码（对应 ProNotes 的 Topotext_Document / AttributeRun / CRDT 类型族）
//
// 结构采用公开逆向共识 + 防御性解析：
// 外层 NoteData protobuf → 字段中的 topotext Document（或其 zlib 压缩形态）
// Document = repeated AttributeRun（length / paragraphStyle / font / todo / attachment）
// 文本字符以 CRDT Item 树存储，防回退策略：按序收割 UTF-8 字符串

struct TopotextRun {
    var length = 0
    var paragraphType = 0       // 0=正文 1=标题 2=大标题 3=副标题 4=小标题 5=列表项 …
    var listLevel = 0
    var isTodo = false
    var todoDone = false
    var bold = false
    var italic = false
    var strikethrough = false
}

struct TopotextDoc {
    var runs: [TopotextRun] = []
    var text = ""
    var totalLength = 0
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
        candidates += candidatesFor(blob).dropFirst()
        for cand in candidates {
            if let doc = parseDocument(cand), doc.totalLength > 0 || !doc.text.isEmpty {
                if best == nil || doc.runs.count > best!.runs.count {
                    best = doc
                }
            }
        }
        if let b = best { return b }
        // 防回退：纯字符串收割
        var doc = TopotextDoc()
        doc.text = harvest(blob)
        return doc.text.isEmpty ? nil : doc
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
                let v = Int(f.varint ?? 0)
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
                        let v = Int(g.varint ?? 0)
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
            md += applyRuns(doc)
        } else {
            let snippet = note.snippet.replacingOccurrences(of: "\u{FFFC}", with: "")
            md += snippet.isEmpty ? "_（正文解码失败或为空）_" : snippet
        }
        return md
    }

    static func applyRuns(_ doc: TopotextDoc) -> String {
        var out = ""
        var cursor = 0
        let text = doc.text
        if doc.runs.isEmpty {
            return text.isEmpty ? "_（正文解码失败或为空）_" : text
        }
        var openBold = false, openItalic = false
        for run in doc.runs {
            if run.length == 0 { continue }
            let end = min(cursor + run.length, text.count)
            guard cursor < end else { continue }
            let chunk = String(text[text.index(text.startIndex, offsetBy: cursor) ..< text.index(text.startIndex, offsetBy: end)])
            cursor = end
            var line = chunk
            // 行级样式
            switch run.paragraphType {
            case 1: line = "# " + line
            case 2: line = "## " + line
            case 3: line = "### " + line
            case 4: line = "#### " + line
            case 5, 6, 7, 8:
                let indent = String(repeating: "  ", count: max(0, run.listLevel))
                line = indent + "- " + (run.isTodo ? (run.todoDone ? "[x] " : "[ ] ") : "") + line
            default: break
            }
            // 行内样式（简化：整块加粗/斜体）
            if run.bold && !openBold { line = "**" + line; openBold = true }
            if !run.bold && openBold { line += "**"; openBold = false }
            if run.italic && !openItalic { line = "_" + line; openItalic = true }
            if !run.italic && openItalic { line += "_"; openItalic = false }
            out += line
        }
        if openBold { out += "**" }
        if openItalic { out += "_" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
