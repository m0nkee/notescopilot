import Foundation
import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case code(String, String)
    case list(Bool, [String])
    case quote(String)
    case table([String], [[String]])
    case divider
}

/// Small, deterministic renderer for the writing formats exposed by NotesCopilot.
/// Raw HTML is always escaped; preview never loads remote images or executes content.
enum MarkdownDocument {
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3))
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(language, code.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1]) {
                let headers = cells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[index])
                    rows.append(Array((row + Array(repeating: "", count: headers.count)).prefix(headers.count)))
                    index += 1
                }
                result.append(.table(headers, rows)); continue
            }
            if let heading = heading(line) { result.append(.heading(heading.0, heading.1)); index += 1; continue }
            if ["---", "***", "___"].contains(trimmed) { result.append(.divider); index += 1; continue }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quote.joined(separator: "\n"))); continue
            }
            if let first = listItem(line) {
                var items: [String] = []
                while index < lines.count, let item = listItem(lines[index]), item.0 == first.0 {
                    items.append(item.1); index += 1
                }
                result.append(.list(first.0, items)); continue
            }
            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("```") || next.hasPrefix(">") || heading(lines[index]) != nil
                    || listItem(lines[index]) != nil || ["---", "***", "___"].contains(next)
                    || (index + 1 < lines.count && next.contains("|") && isTableSeparator(lines[index + 1])) { break }
                paragraph.append(lines[index]); index += 1
            }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return result
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let line = line.trimmingCharacters(in: .whitespaces)
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return (count, String(line.dropFirst(count + 1)))
    }

    private static func listItem(_ line: String) -> (Bool, String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") { return (false, String(text.dropFirst(2))) }
        guard let dot = text.firstIndex(of: "."), !text[..<dot].isEmpty,
              text[..<dot].allSatisfy(\.isNumber), text.index(after: dot) < text.endIndex,
              text[text.index(after: dot)] == " " else { return nil }
        return (true, String(text[text.index(dot, offsetBy: 2)...]))
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func taskItem(_ text: String) -> (marker: String, text: String)? {
        if text.hasPrefix("[ ] ") { return ("☐", String(text.dropFirst(4))) }
        if text.lowercased().hasPrefix("[x] ") { return ("☑", String(text.dropFirst(4))) }
        return nil
    }

    static func inlineHTML(_ text: String) -> String {
        var value = text
        var code: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"`([^`]+)`"#) {
            let ns = value as NSString
            for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed() {
                let placeholder = "\u{E000}\(code.count)\u{E001}"
                code.append("<code>\(escape(ns.substring(with: match.range(at: 1))))</code>")
                value = (value as NSString).replacingCharacters(in: match.range, with: placeholder)
            }
        }
        value = escape(value)
        let replacements = [
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, "<em>$1</em>"),
            (#"~~(.+?)~~"#, "<del>$1</del>"),
            (#"\[([^\]]+)\]\(((?:https?://|notes://)[^\s)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
            }
        }
        for (index, snippet) in code.enumerated() { value = value.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: snippet) }
        return value.replacingOccurrences(of: "\n", with: "<br>")
    }

    static func html(_ markdown: String) -> String {
        blocks(markdown).map { block in
            switch block {
            case .heading(let level, let text): return "<h\(level)>\(inlineHTML(text))</h\(level)>"
            case .paragraph(let text): return "<p>\(inlineHTML(text))</p>"
            case .code(_, let text): return "<pre><code>\(escape(text))</code></pre>"
            case .quote(let text): return "<blockquote>\(inlineHTML(text))</blockquote>"
            case .divider: return "<hr>"
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                return "<\(tag)>" + items.map {
                    let item = taskItem($0).map { "\($0.marker) \($0.text)" } ?? $0
                    return "<li>\(inlineHTML(item))</li>"
                }.joined() + "</\(tag)>"
            case .table(let headers, let rows):
                return "<table><tr>" + headers.map { "<th>\(inlineHTML($0))</th>" }.joined() + "</tr>"
                    + rows.map { "<tr>" + $0.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
        }.joined(separator: "\n")
    }
}

struct MarkdownPreview: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownDocument.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold))
        case .paragraph(let text): inline(text).font(.system(size: 13)).lineSpacing(4)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty { Text(language).font(.caption2).foregroundColor(.secondary) }
                ScrollView(.horizontal) { Text(text).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: true, vertical: false) }
            }.padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(MarkdownDocument.taskItem(item)?.marker ?? (ordered ? "\(index + 1)." : "•")).foregroundColor(.secondary)
                        inline(MarkdownDocument.taskItem(item)?.text ?? item)
                    }.font(.system(size: 13))
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                inline(text).foregroundColor(.secondary).font(.system(size: 13))
            }.fixedSize(horizontal: false, vertical: true)
        case .divider: Divider()
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { _, text in inline(text).bold() } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, text in inline(text) } }
                    }
                }.font(.system(size: 12)).padding(10)
            }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
