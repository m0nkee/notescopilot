// 模板引擎单元测试（不依赖 NC_APP，独立 swiftc 编译运行）
// 编译：swiftc -o template-tests main.swift ../../src/Chat.swift ../../src/Slash.swift ../../src/NotesBridge.swift ../../src/FrontmostTracker.swift ../../src/FormatBridge.swift ../../src/TemplateEngine.swift
// 运行：./template-tests
import Foundation
import AppKit

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("PASS  \(name)") }
    else { fail += 1; print("FAIL  \(name)") }
}

// ---- 1. specs 解析 ----
do {
    let s = TemplateEngine.specs(in: "a {{date}} b {{time:HH:mm}} c {{selection}} d {{clipboard}} e {{ask:名字}} f {{ai:总结}} g {{unknown}} h {{ask:}} i {{AI:指令大写}}")
    check(s.count == 7, "specs 解析出 7 个合法变量（未知/空 arg 被忽略）")
    check(s[0].kind == .date && s[0].argument.isEmpty, "specs[0] date 无参数")
    check(s[1].kind == .time && s[1].argument == "HH:mm", "specs[1] time 带格式参数")
    check(s[4].kind == .ask && s[4].argument == "名字", "specs[4] ask 带提示文字")
    check(s[6].kind == .ai, "head 大小写不敏感：AI 命中 ai")
    let esc = TemplateEngine.specs(in: "\\{{date}}")
    check(esc.isEmpty, "转义 \\{{ 不算变量")
}

// ---- 2. plan 静态展开 ----
do {
    let now = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15 UTC ≈ 2025-06-16 北京时
    // 期望值用独立构造的 Formatter 计算（与时区无关地验证格式化本身）
    func fmt(_ format: String) -> String {
        let f = DateFormatter(); f.dateFormat = format; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: now)
    }
    let p = TemplateEngine.plan("今天是 {{date}} {{time}}，记于 {{date:yyyy/MM/dd}}",
                                selection: "选中内容", clipboard: "剪贴板内容", now: now)
    check(p.asks.isEmpty && p.ais.isEmpty && !p.hasInteractive, "纯静态模板无交互占位")
    check(p.text.contains(fmt("yyyy-MM-dd")), "date 默认格式 yyyy-MM-dd")
    check(p.text.contains(fmt("HH:mm")), "time 默认格式 HH:mm")
    check(p.text.contains(fmt("yyyy/MM/dd")), "date 自定义格式 yyyy/MM/dd")

    let p2 = TemplateEngine.plan("引用：{{selection}} + {{clipboard}}",
                                 selection: "选中内容", clipboard: "剪贴板内容", now: now)
    check(p2.text == "引用：选中内容 + 剪贴板内容", "selection/clipboard 注入")

    let p3 = TemplateEngine.plan("字面量：\\{{date}}，未知：{{who}}", now: now)
    check(!p3.text.contains(fmt("yyyy-MM-dd")), "转义与未知变量均不展开")
    check(p3.text.contains("{{date}}"), "转义输出字面 {{date}}")
    check(p3.text.contains("{{who}}"), "未知变量原样保留")

    let multi = TemplateEngine.plan("{{date}} {{selection}} {{date}}",
                                    selection: "S", clipboard: "", now: now)
    check(multi.text == "\(fmt("yyyy-MM-dd")) S \(fmt("yyyy-MM-dd"))", "多个同类变量从后往前全量替换（无 range 失效）")
}

// ---- 3. ask/ai 哨兵占位 ----
do {
    let now = Date()
    let p = TemplateEngine.plan("A {{ask:问题一}} B {{ai:指令一}} C {{ask:问题二}} D {{date}}",
                                selection: "", clipboard: "", now: now)
    check(p.hasInteractive, "含 ask/ai 判定为交互模板")
    check(p.asks == [0: "问题一", 2: "问题二"], "ask 按出现顺序编号")
    check(p.ais == [1: "指令一"], "ai 与 ask 统一顺序编号")
    check(p.text.contains("\u{E000}0\u{E001}"), "占位以哨兵 U+E000/U+E001 表示")
    check(!p.text.contains("{{"), "静态替换后正文不再有变量花括号")
}

// ---- 4. render 回填 ----
do {
    let now = Date()
    let p = TemplateEngine.plan("A {{ask:名字}} B {{ai:补一句}} C {{ask:角色}} D {{date}}",
                                selection: "", clipboard: "", now: now)
    let full = TemplateEngine.render(p, answers: [0: "张三", 2: "李四"], ais: [1: "AI结果"])
    check(full == "A 张三 B AI结果 C 李四 D \(TemplateEngine.plan("{{date}}", now: now).text)",
          "ask/ai 全量回填顺序正确")
    let partial = TemplateEngine.render(p, answers: [0: "张三"], ais: [:])
    check(partial.contains("A 张三"), "已答 ask 正常回填")
    check(partial.contains("{{ai:补一句}}"), "ai 失败槽位恢复字面 {{ai:...}}")
    check(partial.contains("{{ask:角色}}"), "未答 ask 槽位恢复字面 {{ask:...}}")
    check(!partial.contains("\u{E000}") && !partial.contains("\u{E001}"),
          "render 输出不含哨兵残留")
}

// ---- 5. seed 幂等（用独立 suite 避免污染真实 defaults）----
do {
    let suiteName = "nc-test-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old; suite.removePersistentDomain(forName: suiteName) }

    TemplateStore.templates = []
    // seed 逻辑重放（ensureSeeded 用 standard，这里按同代码路径验证幂等语义）
    var list = TemplateStore.templates
    var injected = 0
    let existing = Set(list.map(\.name))
    for t in TemplateSeeder.defaults where !existing.contains(t.name) { list.append(t); injected += 1 }
    TemplateStore.templates = list
    check(injected == 4 && TemplateStore.templates.count == 4, "首次注入 4 条默认模板")

    var list2 = TemplateStore.templates
    var injected2 = 0
    let existing2 = Set(list2.map(\.name))
    for t in TemplateSeeder.defaults where !existing2.contains(t.name) { list2.append(t); injected2 += 1 }
    TemplateStore.templates = list2
    check(injected2 == 0 && TemplateStore.templates.count == 4, "二次 seed 不重复注入（幂等）")
    check(TemplateStore.templates.allSatisfy(\.isBuiltin), "内置模板 builtin 标记齐全")
    let meeting = TemplateStore.templates.first { $0.name == "会议纪要" }
    check((meeting?.content).map { TemplateEngine.specs(in: $0).count } ?? 0 >= 3,
          "会议纪要模板含 ≥3 个变量")
}

// ---- 6. buildSlashCommands 集成（模板命令生成）----
do {
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = [
        TemplateNote(name: "会议纪要", content: "# 会议纪要 {{date}} {{ask:参会人}} {{ai:提取行动项}}", builtin: true),
        TemplateNote(name: "签名", content: "—— NotesCopilot 用户", builtin: false),
    ]
    let cmds = buildSlashCommands()
    let tpl = cmds.first { $0.name == "会议纪要" }
    check(tpl != nil, "模板进入斜杠命令表")
    check((tpl?.detail).map { $0.contains("内置模板") && $0.contains("日期/输入/AI") } ?? false,
          "内置模板 detail 含徽章摘要")
    let custom = cmds.first { $0.name == "签名" }
    check((custom?.detail).map { $0.contains("插入模板") } ?? false, "自定义模板 detail 正常")
    let plain = cmds.first { $0.name == "新会话" }
    check(plain != nil, "原有命令不受模板影响")
}

// ---- 7. matchSlashToken 命中模板命令 ----
do {
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = [
        TemplateNote(name: "会议纪要", content: "# 纪要 {{date}}", builtin: true),
        TemplateNote(name: "Sign-off", content: "—— NotesCopilot", builtin: true),
    ]
    check(AXSlashWatcher.matchSlashToken("/会议纪要")?.name == "会议纪要", "中文名命中 /会议纪要")
    check(AXSlashWatcher.matchSlashToken("/signoff")?.name == "Sign-off", "英文名模板走拼音/英文别名")
    check(AXSlashWatcher.matchSlashToken("/huiyijiyao") == nil, "中文名无拼音别名（IME 限制，预期不命中）")
    check(AXSlashWatcher.matchSlashToken("/cont")?.name == "续写", "前缀唯一命中 /cont → 续写")
    check(AXSlashWatcher.matchSlashToken("/不存在zz") == nil, "未知命令不命中")
    check(AXSlashWatcher.matchSlashToken("/") == nil, "单个斜杠不命中")
}

// ---- 8. TemplateNote Codable 旧数据兼容 ----
do {
    // 旧版本数据没有 builtin key，解码后 builtin 应为 nil（isBuiltin=false）
    let legacy = """
    [{"id":"11111111-1111-1111-1111-111111111111","name":"旧模板","content":"abc"}]
    """
    let list = try JSONDecoder().decode([TemplateNote].self, from: legacy.data(using: .utf8)!)
    check(list.count == 1 && list[0].builtin == nil && !list[0].isBuiltin, "旧数据无 builtin key 可正常解码为非内置")
    let re = try JSONEncoder().encode(list)
    let again = try JSONDecoder().decode([TemplateNote].self, from: re)
    check(again[0].builtin == nil, "builtin=nil 编解码往返稳定")
}

print("")
print(fail == 0 ? "全部通过：\(pass) 项" : "失败 \(fail) 项 / 共 \(pass + fail) 项")
exit(fail == 0 ? 0 : 1)
