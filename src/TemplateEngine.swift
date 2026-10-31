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
struct TemplateTextReplacement: Equatable {
    let range: NSRange
    let text: String
    var slot: Int? = nil
    var fallback: String? = nil
}

struct TemplateExpansionPlan: Equatable {
    static let sentinelOpen = "\u{E000}"
    static let sentinelClose = "\u{E001}"

    var text: String
    /// 占位序号 -> 问题/指令
    var asks: [Int: String]
    var ais: [Int: String]
    /// 原始正文范围；富文本展开后按这些范围调整原生样式，避免再次执行变量。
    var replacements: [TemplateTextReplacement] = []

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
        var replacements: [TemplateTextReplacement] = []
        for (i, m) in matches.reversed().enumerated() {
            let mi = matches.count - 1 - i
            let body = ns.substring(with: m.range(at: 1))
            // 转义 \{{...}} 输出字面 {{...}}，不解析
            if isEscaped(ns, at: m.range.location) {
                let full = NSRange(location: m.range.location - 1, length: m.range.length + 1)
                result = (result as NSString).replacingCharacters(in: full, with: "{{" + body + "}}")
                replacements.append(TemplateTextReplacement(range: full, text: "{{" + body + "}}"))
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
            replacements.append(TemplateTextReplacement(range: m.range, text: replacement,
                                                        slot: slotByMatch[mi],
                                                        fallback: "{{\(spec.kind.rawValue):\(spec.argument)}}"))
        }
        return TemplateExpansionPlan(text: result, asks: asks, ais: ais, replacements: replacements.reversed())
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

    static func resolvedReplacements(_ plan: TemplateExpansionPlan, answers: [Int: String],
                                     ais: [Int: String]) -> [TemplateTextReplacement] {
        plan.replacements.map { replacement in
            let value = replacement.slot.map { answers[$0] ?? ais[$0] ?? replacement.fallback ?? replacement.text }
                ?? replacement.text
            return TemplateTextReplacement(range: replacement.range, text: value)
        }
    }

    /// 变量跨越多个字体 run 时，以变量起点样式承载插入值；其余正文逐段保留。
    static func expanding(_ document: TopotextDoc, replacements: [TemplateTextReplacement]) -> TopotextDoc {
        let source = document.text as NSString
        var spans: [(range: NSRange, style: TopotextRun)] = []
        var offset = 0
        for run in document.runs where run.length > 0 {
            guard offset <= source.length, run.length <= source.length - offset else { break }
            spans.append((NSRange(location: offset, length: run.length), run))
            offset += run.length
        }
        if offset < source.length {
            var body = TopotextRun()
            body.length = source.length - offset
            spans.append((NSRange(location: offset, length: body.length), body))
        }
        var output = document
        output.text = ""
        output.runs = []
        func append(_ text: String, style: TopotextRun) {
            guard !text.isEmpty else { return }
            var run = style
            run.length = text.utf16.count
            output.text += text
            output.runs.append(run)
        }
        func appendOriginal(_ range: NSRange) {
            for span in spans {
                let part = NSIntersectionRange(range, span.range)
                guard part.length > 0 else { continue }
                append(source.substring(with: part), style: span.style)
            }
        }
        var cursor = 0
        for replacement in replacements.sorted(by: { $0.range.location < $1.range.location }) {
            let range = replacement.range
            guard range.location >= cursor, range.location <= source.length,
                  range.length <= source.length - range.location else { continue }
            appendOriginal(NSRange(location: cursor, length: range.location - cursor))
            let style = spans.first { NSLocationInRange(range.location, $0.range) }?.style
                ?? spans.last?.style ?? TopotextRun()
            append(replacement.text, style: style)
            cursor = NSMaxRange(range)
        }
        appendOriginal(NSRange(location: cursor, length: source.length - cursor))
        output.totalLength = output.text.utf16.count
        return output
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

private final class TemplateCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

@MainActor
enum TemplateRunner {
    typealias Ask = @MainActor (String) async -> String?
    typealias Completion = @MainActor (String, String) async throws -> String

    struct Output {
        let text: String
        let firstError: String?
        var replacements: [TemplateTextReplacement] = []
    }

    private static var tasks: [UUID: Task<Void, Never>] = [:]
    private static var cancellationGeneration = UUID()

    /// 同时停止 ask/AI 与等待 Notes 激活的写入；已排队的桥接回调也会失效。
    static func cancelAll() {
        cancellationGeneration = UUID()
        let pending = Array(tasks.values)
        tasks.removeAll()
        for task in pending { task.cancel() }
    }

    /// 展开并插入模板；返回任务供调用方取消或等待。剪贴板/ask 可注入以免测试触发系统 UI。
    @discardableResult
    static func run(_ template: TemplateNote,
                    selection: String,
                    clipboard: String? = nil,
                    ask: Ask? = nil,
                    complete: Completion? = nil,
                    isOperationValid: @escaping () -> Bool = { true },
                    insert: @escaping (String) -> Void,
                    onError: @escaping (String) -> Void) -> Task<Void, Never> {
        start(template, selection: selection, clipboard: clipboard, ask: ask, complete: complete,
              isOperationValid: isOperationValid, insert: { text, _, _ in insert(text) }, onError: onError)
    }

    @discardableResult
    static func runRich(_ template: TemplateNote,
                        selection: String,
                        clipboard: String? = nil,
                        ask: Ask? = nil,
                        complete: Completion? = nil,
                        isOperationValid: @escaping () -> Bool = { true },
                        insert: @escaping (String, String?) -> Void,
                        onError: @escaping (String) -> Void) -> Task<Void, Never> {
        start(template, selection: selection, clipboard: clipboard, ask: ask, complete: complete,
              isOperationValid: isOperationValid, insert: { text, html, _ in insert(text, html) }, onError: onError)
    }

    private static func start(_ template: TemplateNote,
                              selection: String, clipboard: String?, ask: Ask?, complete: Completion?,
                              isOperationValid: @escaping () -> Bool,
                              insert: @escaping (String, String?, @escaping () -> Bool) async -> Void,
                              onError: @escaping (String) -> Void) -> Task<Void, Never> {
        let clip = clipboard ?? NSPasteboard.general.string(forType: .string) ?? ""
        let plan = TemplateEngine.plan(template.content, selection: selection, clipboard: clip)
        // 在 Task/ask 开始前抓取，设置切换不会改变本次运行的任一 AI 请求。
        let complete = snapshotCompletion(for: plan, injected: complete)
        let id = UUID()
        let generation = cancellationGeneration
        let token = TemplateCancellationToken()
        let valid: () -> Bool = { !token.isCancelled && generation == cancellationGeneration && isOperationValid() }
        let task = Task { @MainActor in
            await withTaskCancellationHandler {
                defer { tasks[id] = nil }
                do {
                    try Task.checkCancellation()
                    guard valid() else { return }
                    let output = try await execute(plan, selection: selection, ask: ask, complete: complete)
                    try Task.checkCancellation()
                    guard valid() else { return }
                    if let error = output.firstError { onError(error) }
                    try Task.checkCancellation()
                    guard valid() else { return }
                    let text: String
                    let html: String
                    if let source = template.sourceDocument, source.text == template.content, source.isComplete {
                        let expanded = TemplateEngine.expanding(source, replacements: output.replacements)
                        text = expanded.text
                        html = NativeNoteHTML.render(expanded)
                    } else {
                        text = output.text
                        html = MarkdownDocument.html(output.text)
                    }
                    await insert(text, html, valid)
                } catch is CancellationError {
                    token.cancel()
                } catch {
                    if valid() { onError(error.localizedDescription) }
                }
            } onCancel: { token.cancel() }
        }
        tasks[id] = task
        return task
    }

    /// 无 UI 的异步计划执行入口；失败槽位保留原文，每槽只尝试一次。
    static func execute(_ plan: TemplateExpansionPlan,
                        selection: String,
                        ask: Ask? = nil,
                        complete: Completion? = nil) async throws -> Output {
        try Task.checkCancellation()
        let complete = snapshotCompletion(for: plan, injected: complete)
        var answers: [Int: String] = [:]
        for slot in plan.asks.keys.sorted() {
            try Task.checkCancellation()
            let question = plan.asks[slot] ?? ""
            let answer: String?
            if let ask { answer = await ask(question) }
            else { answer = askUser(question: question) }
            try Task.checkCancellation()
            guard let answer else { throw CancellationError() }
            answers[slot] = answer
        }

        var ais: [Int: String] = [:]
        var firstError: String?
        if let complete {
            for slot in plan.ais.keys.sorted() {
                try Task.checkCancellation()
                let instruction = plan.ais[slot] ?? ""
                do {
                    ais[slot] = try await complete(instruction, selection)
                    try Task.checkCancellation()
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    let message = "模板 {{ai:\(instruction.prefix(20))}}… 请求失败：\(error.localizedDescription)"
                    firstError = firstError ?? message
                }
            }
        }
        try Task.checkCancellation()
        return Output(text: TemplateEngine.render(plan, answers: answers, ais: ais), firstError: firstError,
                      replacements: TemplateEngine.resolvedReplacements(plan, answers: answers, ais: ais))
    }

    private static func snapshotCompletion(for plan: TemplateExpansionPlan,
                                           injected: Completion?) -> Completion? {
        if let injected { return injected }
        guard !plan.ais.isEmpty else { return nil }
        let configuration = Result { try AIRequestConfiguration.current() }
        return { instruction, context in
            try await AIService.complete(instruction: instruction, context: context,
                                         configuration: configuration.get())
        }
    }

    /// 弹窗输入（NSAlert + accessory TextField，回车确认 / Esc 取消）
    private static func askUser(question: String) -> String? {
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
        return resp == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// 全局斜杠通道：入口绑定原笔记与光标，异步完成时拒绝失效目标。
    @discardableResult
    static func runInNotes(_ template: TemplateNote,
                           selection: String,
                           bridge: NotesBridge = .shared,
                           clipboard: String? = nil,
                           ask: Ask? = nil,
                           complete: Completion? = nil,
                           target: NotesBridge.SelectionSnapshot? = nil,
                           replacementRange: CFRange? = nil,
                           isOperationValid: @escaping () -> Bool = { true },
                           onError: ((String) -> Void)? = nil) -> Task<Void, Never>? {
        let report: (String) -> Void = onError ?? { NCLog.log("模板执行警告：\($0)") }
        guard let target = target ?? bridge.readTextSnapshot() else {
            report("无法定位 Notes 原光标，已取消模板写入。")
            return nil
        }
        return start(template, selection: selection, clipboard: clipboard, ask: ask, complete: complete,
                     isOperationValid: isOperationValid, insert: { text, html, valid in
            // 保持任务运行直到桥接结束；Task.cancel 会同步使 durable token 失效，
            // DispatchQueue 的回调只检查 token，不读取自己的 Task.isCancelled。
            await withCheckedContinuation { continuation in
                bridge.writeWhenNotesActive(in: target, text: text, range: replacementRange, html: html,
                                            isOperationValid: valid) { error in
                    if let error, valid() { report(error) }
                    continuation.resume()
                }
            }
        }, onError: report)
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
