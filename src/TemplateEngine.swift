import Foundation
import AppKit

// MARK: - 模板变量引擎
// ProNotes 取证结论（v0.7.8.2 二进制）：模板 = Notes「Templates」文件夹里的笔记，
// 标题即斜杠命令、正文即插入内容，为纯静态文本插入——无任何占位符/变量语法
// （全量 strings 负向检索：无 {{}} / %date% / cursor 等模板语法证据）。
// 本引擎在此之上引入 {{var}} 变量体系，让模板"活"起来：
//   {{date}} {{date:yyyy-MM-dd}}   日期（可带 DateFormatter 格式）
//   {{time}} {{time:HH:mm}}        时间
//   {{selection}}                  笔记选中/光标段落上下文
//   {{clipboard}}                  剪贴板文本
//   {{ask:问题}}                   插入时弹窗询问用户
//   {{ai:指令}}                    用当前生效配置请求 AI 动态生成（ProNotes 无此能力）
// 转义：\{{ 不解析，输出字面 {{。

struct TemplateVarSpec: Equatable {
    enum Kind: String {
        case date, time, selection, clipboard, ask, ai

        var badge: String {
            switch self {
            case .date: return "日期"
            case .time: return "时间"
            case .selection: return "选中"
            case .clipboard: return "剪贴板"
            case .ask: return "输入"
            case .ai: return "AI"
            }
        }
    }
    let kind: Kind
    /// date:/time: 的格式参数；ask:/ai: 的提示文字/指令
    let argument: String
}

/// 展开计划：阶段 1 替换静态变量后，ask/ai 以私有区哨兵占位
/// （U+E000 + 序号 + U+E001，不会与正常文本冲突）
struct TemplateExpansionPlan: Equatable {
    static let sentinelOpen = "\u{E000}"
    static let sentinelClose = "\u{E001}"

    var text: String
    /// 占位序号 -> 问题/指令
    var asks: [Int: String]
    var ais: [Int: String]

    var hasInteractive: Bool { !asks.isEmpty || !ais.isEmpty }
}

enum TemplateEngine {
    static let varPattern = "\\{\\{([^{}]+)\\}\\}"

    /// 解析模板中的全部变量（设置页徽章 + 速查用）
    static func specs(in content: String) -> [TemplateVarSpec] {
        guard let re = try? NSRegularExpression(pattern: varPattern) else { return [] }
        let ns = content as NSString
        var out: [TemplateVarSpec] = []
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            // 转义 \{{ 不算变量
            if isEscaped(ns, at: m.range.location) { continue }
            if let s = spec(from: ns.substring(with: m.range(at: 1))) { out.append(s) }
        }
        return out
    }

    static func spec(from body: String) -> TemplateVarSpec? {
        let raw = body.trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("{{") == false else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch head {
        case "date", "time", "selection", "clipboard":
            return TemplateVarSpec(kind: TemplateVarSpec.Kind(rawValue: head)!, argument: arg)
        case "ask", "ai":
            guard !arg.isEmpty else { return nil }
            return TemplateVarSpec(kind: TemplateVarSpec.Kind(rawValue: head)!, argument: arg)
        default:
            return nil   // 未知变量：原样保留（render 阶段不替换）
        }
    }

    /// 阶段 1：展开静态变量；ask/ai 收集为占位
    /// - Parameters:
    ///   - selection: 笔记选中/上下文文本（可为空）
    ///   - clipboard: 剪贴板文本（可为空）
    ///   - now: 展开时刻（测试注入）
    static func plan(_ content: String,
                     selection: String = "",
                     clipboard: String = "",
                     now: Date = Date()) -> TemplateExpansionPlan {
        guard let re = try? NSRegularExpression(pattern: varPattern) else {
            return TemplateExpansionPlan(text: content, asks: [:], ais: [:])
        }
        let ns = content as NSString
        var asks: [Int: String] = [:]
        var ais: [Int: String] = [:]
        var slot = 0

        // 先正向分配占位序号（ask/ai 按出现顺序编号，弹窗顺序与模板一致），
        // 再从后往前替换避免 range 失效。
        let matches = re.matches(in: content, range: NSRange(location: 0, length: ns.length))
        var slotByMatch: [Int: Int] = [:]   // match index -> slot
        for (i, m) in matches.enumerated() {
            let body = ns.substring(with: m.range(at: 1))
            if isEscaped(ns, at: m.range.location) { continue }
            guard let spec = spec(from: body) else { continue }
            switch spec.kind {
            case .ask:
                asks[slot] = spec.argument; slotByMatch[i] = slot; slot += 1
            case .ai:
                ais[slot] = spec.argument; slotByMatch[i] = slot; slot += 1
            default: break
            }
        }

        var result = content
        for (i, m) in matches.reversed().enumerated() {
            let mi = matches.count - 1 - i
            let body = ns.substring(with: m.range(at: 1))
            // 转义 \{{...}} 输出字面 {{...}}，不解析
            if isEscaped(ns, at: m.range.location) {
                let full = NSRange(location: m.range.location - 1, length: m.range.length + 1)
                result = (result as NSString).replacingCharacters(in: full, with: "{{" + body + "}}")
                continue
            }
            guard let spec = spec(from: body) else { continue }   // 未知变量原样保留
            let replacement: String
            switch spec.kind {
            case .date:
                replacement = formatDate(now, format: spec.argument.isEmpty ? "yyyy-MM-dd" : spec.argument)
            case .time:
                replacement = formatDate(now, format: spec.argument.isEmpty ? "HH:mm" : spec.argument)
            case .selection:
                replacement = selection
            case .clipboard:
                replacement = clipboard
            case .ask, .ai:
                // 哨兵占位：等 ask 输入 / ai 生成后回填
                let s = slotByMatch[mi] ?? 0
                replacement = TemplateExpansionPlan.sentinelOpen + "\(s)" + TemplateExpansionPlan.sentinelClose
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return TemplateExpansionPlan(text: result, asks: asks, ais: ais)
    }

    /// m.location 前一个字符是否为转义反斜杠
    private static func isEscaped(_ ns: NSString, at location: Int) -> Bool {
        location > 0 && ns.character(at: location - 1) == UInt16(UnicodeScalar("\\").value)
    }

    /// 阶段 2：回填 ask 答案与 ai 生成结果，产出最终文本
    static func render(_ plan: TemplateExpansionPlan, answers: [Int: String], ais: [Int: String]) -> String {
        var out = plan.text
        for (slot, answer) in answers.sorted(by: { $0.key < $1.key }) {
            out = out.replacingOccurrences(
                of: TemplateExpansionPlan.sentinelOpen + "\(slot)" + TemplateExpansionPlan.sentinelClose,
                with: answer)
        }
        for (slot, text) in ais.sorted(by: { $0.key < $1.key }) {
            out = out.replacingOccurrences(
                of: TemplateExpansionPlan.sentinelOpen + "\(slot)" + TemplateExpansionPlan.sentinelClose,
                with: text)
        }
        // 未回填的占位（用户取消/请求失败）保留原变量语义，尽量不输出乱码哨兵
        if let re = try? NSRegularExpression(
            pattern: TemplateExpansionPlan.sentinelOpen + "(\\d+)" + TemplateExpansionPlan.sentinelClose) {
            let ns = out as NSString
            var fixes: [(NSRange, String)] = []
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                guard let idx = Int(ns.substring(with: m.range(at: 1))) else { continue }
                if let q = plan.asks[idx] { fixes.append((m.range, "{{ask:\(q)}}")) }
                else if let a = plan.ais[idx] { fixes.append((m.range, "{{ai:\(a)}}")) }
            }
            for (r, s) in fixes.reversed() {
                // 基于当前 out 逐个修复（reversed 保证前面的 range 不失效）
                out = (out as NSString).replacingCharacters(in: r, with: s)
            }
        }
        return out
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: date)
    }
}

// MARK: - 默认模板（对齐 ProNotes 的 _defaultTemplates：内置模板与用户模板并存）

enum TemplateSeeder {
    static let seededKey = "nc.templates.seeded.v1"

    static var defaults: [TemplateNote] {
        [
            TemplateNote(name: "今日", content: "{{date}}", builtin: true),
            TemplateNote(name: "当前时间", content: "{{time:HH:mm}}", builtin: true),
            TemplateNote(name: "会议纪要",
                         content: "# 会议纪要 {{date}}\n\n- 参会：{{ask:参会人（逗号分隔）}}\n\n## 讨论要点\n\n## 行动项\n{{ai:从会议纪要内容中提取行动项，格式：- [ ] 事项（负责人）}}",
                         builtin: true),
            TemplateNote(name: "周报",
                         content: "# 周报 {{date}}\n\n{{ai:基于笔记上下文生成本周工作周报，分「本周进展 / 数据亮点 / 风险与需要的支持」三节}}",
                         builtin: true),
        ]
    }

    /// 首次启动 seed 一次；幂等（已 seed 过不再注入，用户可删除内置模板）
    static func ensureSeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: seededKey) else { return }
        var list = TemplateStore.templates
        let existing = Set(list.map(\.name))
        for t in defaults where !existing.contains(t.name) {
            list.append(t)
        }
        TemplateStore.templates = list
        d.set(true, forKey: seededKey)
        NCLog.log("已注入内置模板 \(defaults.count) 条（首次启动）")
    }
}

// MARK: - 模板执行编排（@MainActor）
// 完整流程：plan（静态变量）→ {{ask:}} 依次弹窗输入 → {{ai:}} 串行请求 → 回填 → 插入
// 任一 ask 取消 = 整体中止；ai 失败时保留 {{ai:...}} 原文并上报错误，其余照常插入。

@MainActor
enum TemplateRunner {
    /// 展开并插入模板
    /// - Parameters:
    ///   - selection: 笔记选中/上下文（{{selection}} 的取值）
    ///   - insert: 最终文本落地回调（面板与全局斜杠各不相同）
    ///   - onError: 非致命错误回调（如 {{ai:}} 请求失败）
    static func run(_ template: TemplateNote,
                    selection: String,
                    insert: @escaping (String) -> Void,
                    onError: @escaping (String) -> Void) {
        // 剪贴板必须在插入前读取（typeExpansion 会临时改写剪贴板）
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        let plan = TemplateEngine.plan(template.content, selection: selection, clipboard: clip)

        guard plan.hasInteractive else {
            insert(TemplateEngine.render(plan, answers: [:], ais: [:]))
            return
        }

        collectAsks(plan: plan, answers: [:]) { answers in
            guard let answers else { return }   // 用户取消：整体中止
            runAI(plan: plan, answers: answers, ais: [:], firstError: nil) { final, error in
                if let error { onError(error) }
                insert(final)
            }
        }
    }

    /// 依次弹窗收集 {{ask:}} 输入；取消返回 nil
    private static func collectAsks(plan: TemplateExpansionPlan,
                                    answers: [Int: String],
                                    done: @escaping ([Int: String]?) -> Void) {
        guard let next = plan.asks.keys.filter({ answers[$0] == nil }).sorted().first else {
            done(answers)   // 无 ask 或全部答完
            return
        }
        let question = plan.asks[next] ?? ""
        askUser(question: question) { answer in
            guard let answer else { done(nil); return }
            var next2 = answers
            next2[next] = answer
            collectAsks(plan: plan, answers: next2, done: done)
        }
    }

    /// 弹窗输入（NSAlert + accessory TextField，回车确认 / Esc 取消）
    private static func askUser(question: String, done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "模板需要输入"
        alert.informativeText = question
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "输入后回车"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let resp = alert.runModal()
        done(resp == .alertFirstButtonReturn ? (field.stringValue.isEmpty ? "" : field.stringValue) : nil)
    }

    /// 串行执行 {{ai:}} 请求；失败槽位保留原文并记录首个错误
    private static func runAI(plan: TemplateExpansionPlan,
                              answers: [Int: String],
                              ais: [Int: String],
                              firstError: String?,
                              done: @escaping (String, String?) -> Void) {
        let pending = plan.ais.keys.filter { ais[$0] == nil }.sorted().first
        guard let next = pending else {
            done(TemplateEngine.render(plan, answers: answers, ais: ais), firstError)
            return
        }
        let instruction = plan.ais[next] ?? ""
        Task { @MainActor in
            do {
                let out = try await AIService.complete(instruction: instruction, context: selectionHint)
                var next2 = ais
                next2[next] = out
                runAI(plan: plan, answers: answers, ais: next2, firstError: firstError, done: done)
            } catch {
                let msg = "模板 {{ai:\(instruction.prefix(20))}}… 请求失败：\(error.localizedDescription)"
                runAI(plan: plan, answers: answers, ais: ais,
                      firstError: firstError ?? msg, done: done)
            }
        }
    }

    /// {{ai:}} 的上下文取值：跟随 {{selection}} 语义（全局斜杠已在面板/引擎侧设置）
    nonisolated(unsafe) static var selectionHint: String = ""

    /// 便捷入口：全局斜杠通道（Notes 内直接展开插入，零 UI 除 ask 弹窗外）
    static func runInNotes(_ template: TemplateNote, selection: String) {
        selectionHint = selection
        run(template, selection: selection) { text in
            NotesBridge.shared.typeExpansion(deleteCount: 0, insert: text)
        } onError: { msg in
            NCLog.log("模板执行警告：\(msg)")
        }
    }
}

// MARK: - 变量速查（设置页展示用）

struct TemplateCheatRow {
    let syntax: String
    let desc: String
    static let all: [TemplateCheatRow] = [
        TemplateCheatRow(syntax: "{{date}} / {{date:格式}}", desc: "日期，默认 yyyy-MM-dd，如 {{date:MMM d}}"),
        TemplateCheatRow(syntax: "{{time}} / {{time:格式}}", desc: "时间，默认 HH:mm"),
        TemplateCheatRow(syntax: "{{selection}}", desc: "Notes 选中文本 / 面板笔记上下文"),
        TemplateCheatRow(syntax: "{{clipboard}}", desc: "剪贴板文本"),
        TemplateCheatRow(syntax: "{{ask:问题}}", desc: "插入时弹窗询问，填入答案"),
        TemplateCheatRow(syntax: "{{ai:指令}}", desc: "用当前生效配置请求 AI，动态生成该片段"),
    ]
}
