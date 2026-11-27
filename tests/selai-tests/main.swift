// 选中即 AI 状态机单元测试（SelAIState reducer 纯逻辑）
// scripts/run-tests.sh selai-tests
import Foundation
import AppKit

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("PASS  \(name)") }
    else { fail += 1; print("FAIL  \(name)") }
}

typealias S = SelAIState
let show = S.StepAction.show, hide = S.StepAction.hide, none = S.StepAction.none

do {
    let suite = "nc.selection-scope.\(UUID())"
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    check(SelectionScope.current(in: prefs) == .notes && SelectionScope.isEnabled(in: prefs)
          && !SelectionScope.allowsGlobalSelection(in: prefs), "新用户默认只在 Notes 出现浮钮")
    prefs.set(false, forKey: SelectionScope.enabledKey)
    prefs.set("global", forKey: SelectionScope.defaultsKey)
    check(!SelectionScope.allowsGlobalSelection(in: prefs), "已有的关闭设置优先于全局范围")
    prefs.set(true, forKey: SelectionScope.enabledKey)
    check(SelectionScope.allowsGlobalSelection(in: prefs), "显式启用全局后允许其他输入框")
    prefs.set("unknown", forKey: SelectionScope.defaultsKey)
    check(SelectionScope.current(in: prefs) == .notes, "无法识别的范围回到仅 Notes")

    prefs.set("global", forKey: SelectionScope.defaultsKey)
    prefs.set(true, forKey: SelectionScope.pausedKey)
    check(!SelectionScope.allowsGlobalSelection(in: prefs)
          && !SelectionScope.allows(identity: "com.example.allowed", in: prefs),
          "临时暂停会阻止所有其他应用触发选区工具")
    prefs.set(false, forKey: SelectionScope.pausedKey)
    prefs.set(["", "com.example.blocked"], forKey: SelectionScope.privacyAppsKey)
    check(SelectionScope.privacyApps(in: prefs) == ["com.example.blocked"], "应用名单只保存非空标识")
    check(SelectionScope.privacyMode(in: prefs) == .blocklist, "默认使用黑名单模式")
    check(!SelectionScope.allows(identity: "com.example.blocked", in: prefs)
          && SelectionScope.allows(identity: "com.example.other", in: prefs),
          "黑名单应用不触发选区工具")
    prefs.set("allowlist", forKey: SelectionScope.PrivacyMode.defaultsKey)
    check(!SelectionScope.allows(identity: "com.example.other", in: prefs)
          && SelectionScope.allows(identity: "com.example.blocked", in: prefs),
          "白名单外的应用不触发选区工具")
    prefs.set(true, forKey: SelectionScope.pausedKey)
    check(!SelectionScope.allows(identity: "com.example.blocked", in: prefs), "暂停优先于白名单")
}

do {
    let lines = SelectionDiff.lines(original: "第一行\n第二行\n第三行", result: "第一行\n修改后的第二行\n第三行\n新增")
    check(lines.map(\.kind) == [.same, .removed, .added, .same, .added], "选区评审差异保留上下文并标记增删")
    check(lines.map(\.text) == ["第一行", "第二行", "修改后的第二行", "第三行", "新增"], "选区评审差异文本顺序稳定")
    let empty = SelectionDiff.lines(original: "", result: "新结果")
    check(empty.map(\.kind) == [.added], "原文为空时差异全部标记为新增")
}

// ---- 1. 无选中：任何状态回 idle 并隐藏 ----
do {
    let (s1, a1) = S.step(.idle, currentSig: nil)
    check(s1 == .idle && a1 == none, "idle 无选中保持 idle")
    let (s2, a2) = S.step(.watching(sig: "10:5", stable: 1), currentSig: nil)
    check(s2 == .idle && a2 == hide, "观察中选区消失 → 隐藏回 idle")
    let (s3, a3) = S.step(.shown(sig: "10:5"), currentSig: nil)
    check(s3 == .idle && a3 == hide, "已展示后选区消失 → 隐藏回 idle")
}

// ---- 2. 首次选中：开始观察，1 拍不出 ----
do {
    let (s, a) = S.step(.idle, currentSig: "10:5")
    check(s == .watching(sig: "10:5", stable: 1) && a == none, "新选区开始观察（stable=1）不弹出")
}

// ---- 3. 稳定 2 拍触发弹出 ----
do {
    let (s1, a1) = S.step(.watching(sig: "10:5", stable: 1), currentSig: "10:5")
    check(s1 == .shown(sig: "10:5") && a1 == show, "同一选区第 2 拍触发弹出")
    let (s2, a2) = S.step(.shown(sig: "10:5"), currentSig: "10:5")
    check(s2 == .shown(sig: "10:5") && a2 == none, "展示中选区不变不重复弹")
}

// ---- 4. 观察期换选区：重新计数（防抖） ----
do {
    let (s, a) = S.step(.watching(sig: "10:5", stable: 1), currentSig: "20:3")
    check(s == .watching(sig: "20:3", stable: 1) && a == none, "观察期换选区重开计数")
}

// ---- 5. 展示后换选区：隐藏 + 重新观察 ----
do {
    let (s, a) = S.step(.shown(sig: "10:5"), currentSig: "30:2")
    check(s == .watching(sig: "30:2", stable: 1) && a == hide, "换选区 → 隐藏并重新去抖")
}

// ---- 6. 长序列模拟：选择→稳定→展示→换选→取消选 ----
do {
    var s = S.idle
    var actions: [S.StepAction] = []
    for sig in ["5:2", "5:2", "5:2", "9:1", nil, "7:4", "7:4", "7:4"] {
        let r = S.step(s, currentSig: sig)
        s = r.state; actions.append(r.action)
    }
    check(actions[1] == show, "序列第 2 步（选区第 2 拍）弹出")
    check(actions[3] == hide, "换选区即隐藏")
    check(actions[4] == hide, "取消选中再隐藏")
    check(actions[6] == show, "重新选中稳定后再次弹出")
    check(s == .shown(sig: "7:4"), "终态为展示")
}

// ---- 7. 快捷动作清单完整性 ----
do {
    check(selectionQuickActions.count == 6, "6 个快捷动作")
    check(selectionQuickActions.allSatisfy { !$0.instruction.prompt(for: "原文").isEmpty }, "全部动作有指令")
    check(selectionQuickActions.filter { $0.group == .edit }.map(\.name) == ["校对", "润色", "精简"], "编辑组选区改写")
    check(selectionQuickActions.filter { $0.group == .read }.map(\.name) == ["总结", "翻译", "解释"], "阅读组选区加工")
}

do {
    let translation = selectionQuickActions.first { $0.shortcut == "t" }?.instruction
    for (source, target) in [
        ("这是什么？", "英文"), ("這是什麼？", "英文"), ("蓝色雨伞", "英文"),
        ("Where is my umbrella?", "简体中文"), ("Bonjour tout le monde !", "简体中文"),
        ("会議の資料をご確認ください。", "简体中文"), ("다음 주에 만나요.", "简体中文"),
        ("这个 API 支持离线翻译。", "英文"), ("Please return the 蓝色雨伞 tomorrow.", "简体中文")
    ] {
        check(translation?.prompt(for: source).hasPrefix("请将原文翻译成" + target) == true, "翻译「\(source)」的目标是\(target)")
    }
    for source in ["我们的 NotesCopilot 已经发布", "苹果发布了 Apple Intelligence 和 Writing Tools。"] {
        let prompt = translation?.prompt(for: source) ?? ""
        check(prompt.contains("翻译成英文") && !prompt.hasPrefix("请将原文翻译成简体中文"), "英文产品名不会强制中文句子译为中文：\(source)")
    }
    for source in ["123 🌻", ""] {
        let prompt = translation?.prompt(for: source) ?? ""
        check(prompt.contains("主要语言") && prompt.contains("翻译成英文") && prompt.contains("翻译成简体中文")
              && prompt.contains("只输出译文"), "混合文字或无可识别文字时，在同一次翻译中判断方向：\(source)")
    }
    check(WritingInstruction.text("请译成日文").prompt(for: "蓝色雨伞") == "请译成日文", "保留自定义指令的目标语言")
}

// ---- 8. Notes 原生格式菜单（动态枚举 → 本地化标签） ----
do {
    let all = NotesBridge.formatMenuItems.map(\.menu)
    check(all.count == 13, "格式全集 13 项")
    check(all == ["标题", "小标题", "副标题", "正文", "等宽样式", "斜体", "下划线", "删除线", "显示颜色", "项目符号列表", "短划线列表", "编号列表", "块引用"], "格式全集与顺序稳定")

    // 枚举乱序返回（AX 无序保证）→ 输出仍按 canonical 顺序
    let shuffled = NotesFormatButton.items(presenting: ["块引用", "标题", "正文", "编号列表"])
    check(shuffled.map(\.menuTitle) == ["标题", "正文", "编号列表", "块引用"], "乱序枚举输出按 canonical 顺序")
    // 只保留 Notes 菜单实际存在的项
    check(NotesFormatButton.items(presenting: ["不存在的项"]).isEmpty, "未知标题被过滤")
    check(NotesFormatButton.items(presenting: []).isEmpty, "空枚举 → 无按钮")
    check(NotesFormatButton.items(presenting: all).count == 13, "全量枚举 → 13 个按钮")
    let defaults = UserDefaults.standard
    let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    var preferences = previous
    preferences[L10n.preferenceKey] = AppLanguage.simplifiedChinese.rawValue
    defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    let byMenu = Dictionary(uniqueKeysWithValues: NotesFormatButton.items(presenting: all).map { ($0.menuTitle, $0.label) })
    check(byMenu["等宽样式"] == "等宽", "等宽样式 → 等宽")
    check(byMenu["项目符号列表"] == "圆点列表", "项目符号列表 → 圆点列表")
    check(byMenu["短划线列表"] == "短划线", "短划线列表 → 短划线")
    check(byMenu["标题"] == "标题", "标题标签不变")
    check(byMenu["斜体"] == "斜体" && byMenu["下划线"] == "下划线" && byMenu["删除线"] == "删除线", "字体样式标签直出")
    check(byMenu["显示颜色"] == "颜色", "显示颜色 → 颜色")

    preferences[L10n.preferenceKey] = AppLanguage.english.rawValue
    defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    let englishFormat = NotesFormatButton.items(presenting: ["标题", "正文"])
    check(englishFormat.map(\.menuTitle) == ["标题", "正文"] && englishFormat.map(\.label) == ["Title", "Body"],
          "英文界面可匹配中文 Notes 样式并提供英文标签")
    check(selectionQuickActions.map(\.displayName) == ["Proofread", "Polish", "Shorten", "Summarize", "Translate", "Explain"],
          "选区快捷动作随界面语言切换")
}

// 总开关对键盘与 AX 通道一致生效；格式菜单标题统一中英文别名。
do {
    let defaults = UserDefaults.standard
    let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(["nc.md.enabled": false, "nc.md.headers": true], forName: UserDefaults.argumentDomain)
    check(AXSlashWatcher.matchAXMarkdownTail("# ") == nil, "Markdown 总开关关闭时 AX 不删除标题标记")
    check(AXSlashWatcher.matchAXMarkdownTail("[] ") == nil, "Markdown 总开关关闭时 AX 不删除检查项标记")
    defaults.setVolatileDomain(["nc.md.enabled": true, "nc.md.headers": true], forName: UserDefaults.argumentDomain)
    check(AXSlashWatcher.matchAXMarkdownTail("# ")?.style == .title, "重新开启总开关后 AX 即时恢复")
    defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
    check(NotesBridge.formatMenuTitles(for: "标题").contains("Title"), "标题格式支持英文 Notes")
    check(NotesBridge.formatMenuTitles(for: "块引用").contains("Block Quote"), "块引用格式支持英文 Notes")
    check(NotesBridge.formatMenuTitles(for: "显示颜色").contains("Show Colors"), "颜色面板支持英文 Notes")
    check(NotesFormatButton.items(presenting: ["Title", "Body"]).map(\.menuTitle) == ["标题", "正文"],
          "英文菜单枚举仍构造规范格式按钮")
}

// The same preparation coordinator is used by SelectionWatcher.poll; no AX or
// real Notes access is needed to make a snapshot fail and later recover.
do {
    var polling = SelectionPollingState()
    let origin = Date(timeIntervalSinceReferenceDate: 100)
    var readable = false
    var snapshotReads = 0
    func prepareSnapshot() -> Bool { snapshotReads += 1; return readable }
    _ = polling.poll(currentSig: "10:5", now: origin, prepareShow: prepareSnapshot)
    let failed = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.2), prepareShow: prepareSnapshot)
    check(failed == .none && polling.state != .shown(sig: "10:5"),
          "快照读取失败不能把真实轮询提交为已展示")
    readable = true
    let recovered = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(1.2), prepareShow: prepareSnapshot)
    check(recovered == .show && polling.state == .shown(sig: "10:5") && snapshotReads == 2,
          "同一选区权限恢复后无需重新选中文字即可展示")
    let unchanged = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(1.4), prepareShow: prepareSnapshot)
    check(unchanged == .none && snapshotReads == 2, "成功展示后同一选区不重复读快照或弹窗")
}

do {
    var polling = SelectionPollingState()
    let origin = Date(timeIntervalSinceReferenceDate: 200)
    var snapshotReads = 0
    func unavailableSnapshot() -> Bool { snapshotReads += 1; return false }
    _ = polling.poll(currentSig: "10:5", now: origin, prepareShow: unavailableSnapshot)
    _ = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.2), prepareShow: unavailableSnapshot)
    for tick in 2...5 {
        _ = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(Double(tick) * 0.2), prepareShow: unavailableSnapshot)
    }
    check(snapshotReads == 1, "快照失败后一秒内不随0.2秒轮询反复请求权限")
    _ = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(1.2), prepareShow: unavailableSnapshot)
    check(snapshotReads == 2, "节流结束后同一选区仍会自动重试")
}

do {
    let origin = Date(timeIntervalSinceReferenceDate: 300)
    var polling = SelectionPollingState()
    _ = polling.poll(currentSig: "10:5", now: origin) { false }
    _ = polling.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.2)) { false }
    let changed = polling.poll(currentSig: "20:3", now: origin.addingTimeInterval(0.3)) { true }
    check(changed == .none && polling.state == .watching(sig: "20:3", stable: 1),
          "失败后换选区会清除旧节流并重新去抖")
    let ready = polling.poll(currentSig: "20:3", now: origin.addingTimeInterval(0.5)) { true }
    check(ready == .show && polling.state == .shown(sig: "20:3"), "新选区不继承失败选区的等待时间")

    var deselected = SelectionPollingState()
    _ = deselected.poll(currentSig: "10:5", now: origin) { false }
    _ = deselected.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.2)) { false }
    let hidden = deselected.poll(currentSig: nil, now: origin.addingTimeInterval(0.3)) { true }
    check(hidden == .hide && deselected.state == .idle, "失败节流中取消选择仍立即隐藏并清除观察状态")
    _ = deselected.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.4)) { true }
    let reselected = deselected.poll(currentSig: "10:5", now: origin.addingTimeInterval(0.6)) { true }
    check(reselected == .show, "取消后重新选择同一范围不残留失败节流")
}

print("")
print(fail == 0 ? "全部通过：\(pass) 项" : "失败 \(fail) 项 / 共 \(pass + fail) 项")
exit(fail == 0 ? 0 : 1)
