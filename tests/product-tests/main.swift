import Foundation

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

renderingTests()
templateImportTests()
Task { @MainActor in
    await urlFallbackTests()
    print("product-tests: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
RunLoop.main.run()
