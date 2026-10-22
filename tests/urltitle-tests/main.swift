// URL 自动转标题超链 单元测试
// 编译：swiftc -o urltitle-tests main.swift ../../src/Chat.swift ../../src/Slash.swift ../../src/SlashSuggest.swift ../../src/NotesBridge.swift ../../src/FrontmostTracker.swift ../../src/FormatBridge.swift ../../src/TemplateEngine.swift ../../src/SelectionAI.swift ../../src/UrlTitle.swift
// 运行：./urltitle-tests
import Foundation
import AppKit

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("PASS  \(name)") }
    else { fail += 1; print("FAIL  \(name)") }
}

// ---- 1. lastURLToken 提取 ----
do {
    let km = "https://www.apple.com"
    let hit = UrlTitleLinker.lastURLToken(in: "前面一些文字 \(km) ")
    check(hit?.url == km && hit?.deleteCount == km.count + 1, "URL+空格触发，删除数含触发空格")
    check(UrlTitleLinker.lastURLToken(in: "\(km) ")?.url == km, "行首 URL 也可触发")
    check(UrlTitleLinker.lastURLToken(in: "\(km)") == nil, "无触发空格不触发")
    check(UrlTitleLinker.lastURLToken(in: "看看 https://a.com 和 https://b.com ")?.url == "https://b.com", "取最后一个 URL")
    check(UrlTitleLinker.lastURLToken(in: "not a url ") == nil, "非 URL 不触发")
    check(UrlTitleLinker.lastURLToken(in: "http://has space.com ") == nil, "含空格的 token 不算 URL")
    check(UrlTitleLinker.lastURLToken(in: "ftp://example.com ") == nil, "非 http(s) 协议不触发")
    check(UrlTitleLinker.lastURLToken(in: "https://noscheme-path ") == nil, "域名无点不触发")
    check(UrlTitleLinker.lastURLToken(in: "https://example.com ") != nil, "无 path 的合法域名可触发")
    check(UrlTitleLinker.lastURLToken(in: "短 http://a.b ") == nil, "过短 token（<11 字符）不触发")
}

// ---- 2. parseTitle：title 优先、og:title 兜底、多行 ----
do {
    check(UrlTitleLinker.parseTitle(from: "<html><title>收集信息</title></html>") == "收集信息", "<title> 解析")
    check(UrlTitleLinker.parseTitle(from: "<TITLE>\n多行标题\n</TITLE>") == "多行标题", "多行/大小写不敏感")
    check(UrlTitleLinker.parseTitle(from: #"<meta property="og:title" content="OG 标题">"#) == "OG 标题", "og:title 兜底")
    check(UrlTitleLinker.parseTitle(from: #"<meta content="反序 OG" property="og:title">"#) == "反序 OG", "content 在前属性序也解析")
    check(UrlTitleLinker.parseTitle(from: "<title>收集信息</title>" + #"<meta property="og:title" content="OG">"#) == "收集信息", "title 优先于 og:title")
    check(UrlTitleLinker.parseTitle(from: "<html><body>无标题</body></html>") == nil, "无标题返回 nil")
    check(UrlTitleLinker.parseTitle(from: "<title>   </title>") == nil, "空白标题返回 nil")
}

// ---- 3. 实体解码 ----
do {
    check(UrlTitleLinker.decodeEntities("A&amp;B &lt;tag&gt; &quot;q&quot; &#39;s&#39;") == "A&B <tag> \"q\" 's'", "常见具名实体")
    check(UrlTitleLinker.decodeEntities("&#20013;&#x56FD;") == "中国", "十进制/十六进制数字实体")
    check(UrlTitleLinker.decodeEntities("A&nbsp;B") == "A B", "&nbsp; 解码")
    check(UrlTitleLinker.parseTitle(from: "<title>AT&amp;T &#20013;&#22269;</title>") == "AT&T 中国", "标题内实体先解码")
}

// ---- 4. 链接 HTML 构建 ----
do {
    let h = UrlTitleLinker.makeLinkHTML(title: "收集信息", url: "https://www.apple.com/1")
    check(h == "<a href=\"https://www.apple.com/1\">收集信息</a>", "标准超链 HTML")
    let h2 = UrlTitleLinker.makeLinkHTML(title: "a<b>&c", url: "https://x.com/p?a=1&b=2")
    check(h2.contains("a&lt;b&gt;&amp;c"), "标题中特殊字符转义")
    check(h2.contains("href=\"https://x.com/p?a=1&amp;b=2\""), "URL & 转义后 href 仍合法（HTML 规范要求 &amp;）")
    check(!h2.contains("\"a=1&b=2\"") || h2.contains("&amp;") , "href 内 & 已转义")
}

// ---- 5. 登录页判定 ----
do {
    check(UrlTitleLinker.isLoginTitle("统一登录 - 美团"), "中文登录页识别")
    check(UrlTitleLinker.isLoginTitle("Sign in to SSO"), "英文登录页识别")
    check(!UrlTitleLinker.isLoginTitle("收集信息"), "正常标题不误判")
}

print("")
print(fail == 0 ? "全部通过：\(pass) 项" : "失败 \(fail) 项 / 共 \(pass + fail) 项")
exit(fail == 0 ? 0 : 1)
