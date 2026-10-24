// 斜杠面板分组展示 + 格式检查命令 单元测试
// 编译：swiftc -o slashgroup-tests main.swift ../../src/Chat.swift ../../src/Slash.swift ../../src/SlashSuggest.swift ../../src/NotesBridge.swift ../../src/FrontmostTracker.swift ../../src/FormatBridge.swift ../../src/TemplateEngine.swift ../../src/SelectionAI.swift
// 运行：./slashgroup-tests
import Foundation
import AppKit

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("PASS  \(name)") }
    else { fail += 1; print("FAIL  \(name)") }
}

// ---- 1. group 由 action 推导 ----
do {
    let cmds = buildSlashCommands()
    check(cmds.first { $0.name == "润色" }?.group == .ai, "润色 → AI 优化组")
    check(cmds.first { $0.name == "标题样式" }?.group == .markdown, "标题样式 → Markdown 格式组")
    check(cmds.first { $0.name == "表格" }?.group == .markdown, "表格 → Markdown 格式组")
    check(cmds.first { $0.name == "新会话" }?.group == .tool, "新会话 → 工具组")
    check(cmds.first { $0.name == "设置" }?.group == .tool, "设置 → 工具组")

    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = [TemplateNote(name: "Sign-off", content: "——", builtin: true)]
    check(buildSlashCommands().first { $0.name == "Sign-off" }?.group == .template, "用户模板 → 模板组")
}

// ---- 2. 新增「格式检查」命令 ----
do {
    let cmd = buildSlashCommands().first { $0.name == "格式检查" }
    check(cmd != nil, "格式检查命令存在")
    check(cmd?.group == .ai, "格式检查归 AI 优化组")
    check(cmd?.alias == "format", "格式检查别名 format")
    let prompt = cmd.map { cmd -> String in
        if case .run(let p) = cmd.action { return p } else { return "" }
    } ?? ""
    check(prompt.contains("格式问题") && prompt.contains("不要直接改写"), "格式检查提示词完整（列清单不改写）")
}

// ---- 3. buildRows 分组头与排序（注入已知模板保证 4 组齐全）----
do {
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = [TemplateNote(name: "Sign-off", content: "——", builtin: true)]
    let cmds = buildSlashCommands()
    let rows = SlashSuggestPanel.buildRows(cmds)
    let headers = rows.enumerated().filter { $0.element.isHeader }
    check(headers.count == 4, "全量命令产生 4 个分组头")
    // 分组顺序 = displayOrder
    let order = headers.compactMap {
        if case .header(let g) = $0.element { return g } else { return nil }
    }
    check(order == SlashGroup.displayOrder, "分组顺序与 displayOrder 一致")
    // 每个分组头后面紧跟命令行，无空组
    var ok = true
    for (i, h) in headers where i + 1 >= rows.count || rows[i + 1].isHeader { ok = false }
    check(ok, "每个分组头后至少一条命令")
    // 第一条命令行索引
    check(SlashSuggestPanel.firstCmdRow(in: rows) == 1, "首个命令行 = 索引 1（头后）")
}

// ---- 4. 键盘导航跳过分组头 ----
func navTests() {
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = [TemplateNote(name: "Sign-off", content: "——", builtin: true)]
    let rows = SlashSuggestPanel.buildRows(buildSlashCommands())
    // 取 Markdown 组头（第二个分组头）
    let headerIdx = rows.indices.filter { rows[$0].isHeader }
    guard headerIdx.count >= 2 else { check(false, "至少两个分组头"); return }
    let mdHeader = headerIdx[1]
    check(true, "MD 组头存在（索引 \(mdHeader)）")
    // 从 AI 组最后一条命令 ↓ 应跳过 MD 组头直达 MD 第一条命令
    let cross = SlashSuggestPanel.nextCmdRow(from: mdHeader - 1, delta: +1, rows: rows)
    check(cross == mdHeader + 1, "↓ 跨组跳过分组头（\(mdHeader-1) → \(cross ?? -1)）")
    let back = SlashSuggestPanel.nextCmdRow(from: mdHeader + 1, delta: -1, rows: rows)
    check(back == mdHeader - 1, "↑ 跨组跳过分组头")
    check(SlashSuggestPanel.nextCmdRow(from: rows.count - 1, delta: +1, rows: rows) == nil,
          "末行 ↓ 无下一命令行（nil）")
    check(SlashSuggestPanel.nextCmdRow(from: 0, delta: -1, rows: rows) == nil,
          "首行 ↑ 无上一命令行（nil）")
}
do { navTests() }

// ---- 5. 空查询各分组取前 5 ----
do {
    let list = AXSlashWatcher.suggestCandidates(for: "/")
    let groups = Dictionary(grouping: list, by: \.group)
    check(groups[.ai]?.count == 5, "空查询 AI 组 5 条")
    check(groups[.markdown]?.count == 5, "空查询 Markdown 组 5 条")
    check(groups[.tool]?.count == 5, "空查询 工具组 5 条")
    check(groups[.template] == nil || (groups[.template]?.count ?? 0) <= 5, "模板组 ≤5 条")
}

// ---- 6. 过滤查询仍可命中格式检查 ----
do {
    check(AXSlashWatcher.suggestCandidates(for: "/format").contains { $0.name == "格式检查" }, "/format 命中格式检查")
    check(AXSlashWatcher.suggestCandidates(for: "/格式检查").contains { $0.name == "格式检查" }, "中文命令名命中")
    check(AXSlashWatcher.matchSlashToken("/format")?.name == "格式检查", "matchSlashToken 命中格式检查")
}

// 英文别名同时用于菜单展示、前缀筛选和 Notes 正文执行，不保留拼音别名。
do {
    let old = TemplateStore.templates
    defer { TemplateStore.templates = old }
    TemplateStore.templates = []
    let commands = buildSlashCommands()
    let routes: [(name: String, legacy: String, english: String, instruction: String)] = [
        ("续写", "xuxie", "continue", "续写"),
        ("总结", "zongjie", "summarize", "要点"),
        ("翻译", "fanyi", "translate", "翻译成英文"),
        ("润色", "runse", "polish", "润色"),
        ("解释", "jieshi", "explain", "关键概念"),
        ("扩写", "kuoxie", "expand", "扩展"),
        ("要点", "yaodian", "keypoints", "Markdown 列表"),
        ("标题", "biaoti", "titles", "3 个候选标题"),
    ]
    for route in routes {
        check(commands.first { $0.name == route.name }?.alias == route.english,
              "\(route.name) 菜单展示英文别名 /\(route.english)")
        let suggested = AXSlashWatcher.suggestCandidates(for: "/" + route.english)
        let partial = AXSlashWatcher.suggestCandidates(for: "/" + String(route.english.prefix(3)))
        check(suggested.first?.name == route.name && partial.contains { $0.name == route.name && $0.alias == route.english },
              "/\(route.english) 完整与前缀查询筛选对应命令")
        let matched = AXSlashWatcher.matchSlashToken("/" + route.english.uppercased())
        let correctAction: Bool
        if let matched, case .run(let instruction) = matched.action {
            correctAction = matched.name == route.name && instruction.contains(route.instruction)
        } else { correctAction = false }
        check(correctAction, "/\(route.english) 不区分大小写并匹配对应 AI 动作")
        let tail = AXSlashWatcher.matchAXSlashTail("合成段落 /\(route.english) ")
        check(tail?.cmd.name == route.name && tail?.cmd.alias == route.english
              && tail?.deleteCount == route.english.count + 2,
              "/\(route.english) 加空格执行保留正确目标与删除长度")
        check(AXSlashWatcher.matchSlashToken("/" + route.legacy) == nil
              && !AXSlashWatcher.suggestCandidates(for: "/" + route.legacy).contains { $0.name == route.name },
              "旧拼音 /\(route.legacy) 不再匹配或筛选内置命令")
    }
    let aliases = commands.map { $0.alias.lowercased() }.filter { !$0.isEmpty }
    check(Set(aliases).count == aliases.count, "英文替换后所有内置别名互不冲突")
    let titleAction = AXSlashWatcher.matchSlashToken("/title")?.action
    if let titleAction, case .format(.title) = titleAction { check(true, "/title 保留 Notes 标题格式命令") }
    else { check(false, "/title 保留 Notes 标题格式命令") }
    let titleSuggestions = AXSlashWatcher.suggestCandidates(for: "/tit")
    check(titleSuggestions.contains { $0.alias == "titles" && $0.name == "标题" }
          && titleSuggestions.contains { $0.alias == "title" && $0.name == "标题样式" },
          "/tit 同时展示 AI 拟标题与 Notes 标题格式，完整命令各自可用")
}

// URL 路径不能抢先命中 /title 等命令并删掉用户的网址。
do {
    check(AXSlashWatcher.activeSlashQuery("https://example.com/title") == nil, "URL 路径不弹斜杠菜单")
    check(AXSlashWatcher.matchAXSlashTail("https://example.com/title ") == nil, "URL 路径与命令重名也不删除路径")
    check(AXSlashWatcher.matchAXSlashTail("https://title ") == nil, "URL 域名与命令重名也不触发")
    check(AXSlashWatcher.activeSlashQuery("www.example.com/body") == nil, "无协议 www URL 路径不弹菜单")
    check(AXSlashWatcher.matchAXSlashTail("段落 /title ")?.cmd.alias == "title", "普通行中斜杠命令仍可执行")
}

print("")
print(fail == 0 ? "全部通过：\(pass) 项" : "失败 \(fail) 项 / 共 \(pass + fail) 项")
exit(fail == 0 ? 0 : 1)
