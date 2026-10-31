import AppKit
import Carbon.HIToolbox

// MARK: - 即时执行表格：mouseDown 直接执行命中行
// 修复真机 bug：面板每次刷新都预选第 0 行，点已选中的行不触发 selectionDidChange，
// 导致「点击无反应」。改为 mousedown 即时执行（ProNotes 同款交互），不依赖 selection 变化。
final class InstantTable: NSTableView {
    var onRowMouseDown: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = row(at: p)
        NCLog.log("InstantTable mouseDown：(\(p.x),\(p.y)) row=\(row)")
        if row >= 0 {
            onRowMouseDown?(row)
            return  // 不进 super：避免拖选/编辑等默认行为，面板只做单击执行
        }
        super.mouseDown(with: event)
    }
}

/// 选中高亮行视图：非 key window 下 NSTableView 默认不画选中态，
/// 自绘半透明 accent 背景保证 ↑↓ 导航时高亮始终可见。
final class HighlightRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        dirtyRect.fill()
    }
}

// MARK: - / 建议下拉面板（复刻 ProNotes 的斜杠命令下拉）
// 输入 / 未终止时跟随光标弹出：持续输入实时过滤，点选即执行，↑↓ 键盘导航 ⏎ 执行 esc 关闭
// （删除已输入的 /xxx 段并走 performGlobalSlash）。
// 关键：NSPanel.styleMask 含 .nonactivatingPanel —— 点击面板不抢 Notes 焦点，
// 文本光标不丢，键盘继续打进 Notes；键盘导航经 KeywordListener 的 active CGEventTap 拦截路由。
//
// IME 保护：有标记文本的组合期放行 ↑↓/⏎，避免破坏候选导航；中文输入法未组合时仍可导航。

@MainActor
final class SlashSuggestPanel: NSObject, NSWindowDelegate {
    static let shared = SlashSuggestPanel()

    /// 面板行：Magpie 风格分组头 + 命令行（↑↓ 导航只落在命令行）
    enum Row {
        case header(SlashGroup)
        case cmd(SlashCommand)

        var isHeader: Bool { if case .header = self { return true }; return false }
    }

    /// 分组行构建：按 displayOrder 重新归组（过滤查询可能打散顺序，分组头始终连续）
    nonisolated static func buildRows(_ cmds: [SlashCommand]) -> [Row] {
        var rows: [Row] = []
        for g in SlashGroup.displayOrder {
            let inGroup = cmds.filter { $0.group == g }
            guard !inGroup.isEmpty else { continue }
            rows.append(.header(g))
            rows += inGroup.map { Row.cmd($0) }
        }
        return rows
    }

    static let headerRowHeight: CGFloat = 26
    static let cmdRowHeight: CGFloat = 42

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private weak var keyboardHint: NSTextField?
    private var items: [SlashCommand] = []
    private var rows: [Row] = []
    /// 当前查询串（如 "/polish"），选中执行时删除它
    private var query = ""
    private var target: NotesBridge.SelectionSnapshot?
    private var dismissedQuery: String?
    /// 键盘导航当前行
    private var selectedRow: Int?
    /// 程序性 selectRow 触发的 selectionDidChange 不执行（只有用户点击才执行）
    private var suppressSelection = false
    /// 执行后抑制窗口：点选后已输入的 /xxx 要 0.4s 后才被退格删掉，
    /// 这期间轮询仍能读到旧文本，不抑制会重新弹面板
    private var suppressUntil: Date?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 外部接口（AXSlashWatcher 轮询驱动）

    func update(items newItems: [SlashCommand], query newQuery: String, cursorRect: CGRect?) {
        guard NotesBridge.isFrontmostNotes(), Self.slashEnabled else { hide(); return }
        if dismissedQuery == newQuery { return }
        dismissedQuery = nil
        if let until = suppressUntil, Date() < until { return }
        suppressUntil = nil
        guard let target = NotesBridge.shared.readTextSnapshot() else { hide(); return }
        let queryChanged = query != newQuery
        let sameItems = itemsEqual(newItems)
        self.target = target
        self.query = newQuery
        // 即使名称没变，也替换 action 快照，避免执行已修改的旧 Notes 模板正文。
        items = newItems
        rows = Self.buildRows(items)
        refreshKeyboardHint()
        // 内容未变且面板已在：仅跟随光标移动，避免每 120ms 重绘
        if !queryChanged, sameItems, let p = panel, p.isVisible {
            relocateIfNeeded(cursorRect)
            return
        }
        guard !items.isEmpty else { hide(); return }

        let headerCount = rows.filter(\.isHeader).count
        let contentH = CGFloat(headerCount) * Self.headerRowHeight + CGFloat(items.count) * Self.cmdRowHeight
        let footerH: CGFloat = 24
        let h = min(contentH, 470) + footerH
        let w: CGFloat = 330

        if panel == nil { buildPanel(width: w) }
        guard let panel else { return }
        panel.setContentSize(NSSize(width: w, height: h))

        place(cursorRect: cursorRect, width: w, height: h)
        suppressSelection = true
        tableView?.reloadData()
        selectedRow = Self.initialCmdRow(for: newQuery, rows: rows)
        if let selectedRow {
            tableView?.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else {
            tableView?.deselectAll(nil)
        }
        suppressSelection = false
        refreshKeyboardHint()
        if !panel.isVisible {
            // nonactivating + canHide 取消：show 不夺焦点、Esc 不自动隐藏
            panel.orderFront(nil)
            NCLog.log("建议面板弹出：\(items.count) 项，查询 \(newQuery)")
        }
    }

    func hide() {
        panel?.orderOut(nil)
        target = nil
    }

    /// 点选/回车执行：删除已输入的 /xxx 段，走统一触发（含删除落地时序）
    private func perform(_ cmd: SlashCommand) {
        guard NotesBridge.isFrontmostNotes(), Self.slashEnabled,
              let target, NotesBridge.shared.isCurrent(target) else { hide(); return }
        let deleteCount = query.count
        hide()
        suppressUntil = Date().addingTimeInterval(1.5)
        NCLog.log("建议面板执行：\(cmd.name)，删除 \(deleteCount) 字符")
        KeywordListener.performGlobalSlash(cmd, deleteCount: deleteCount, target: target, expectedToken: query,
                                          isExplicitSelection: true)
    }

    /// 第一个命令行（初始选中；分组头不可选）
    nonisolated static func firstCmdRow(in rows: [Row]) -> Int {
        rows.firstIndex { !$0.isHeader } ?? 0
    }

    /// 分类名打开列表后需先用方向键选中，直接回车只保持列表展开。
    nonisolated static func initialCmdRow(for query: String, rows: [Row]) -> Int? {
        SlashQuery.isCategory(query) ? nil : rows.firstIndex { !$0.isHeader }
    }

    /// 从当前行出发按方向找下一个命令行（跳过分组头）
    nonisolated static func nextCmdRow(from start: Int?, delta: Int, rows: [Row]) -> Int? {
        guard delta != 0 else { return nil }
        var i = start.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        while rows.indices.contains(i) {
            if !rows[i].isHeader { return i }
            i += delta
        }
        return nil
    }

    // MARK: - 键盘导航（KeywordListener tap 回调路由，tap 在主 runloop = 主线程）

    /// 可见时接管 ↑↓/⏎/esc；返回 true = 已消费（吞掉事件，不透传给 Notes）
    func routeKeyIfVisible(_ code: CGKeyCode) -> Bool {
        guard NotesBridge.isFrontmostNotes(), Self.slashEnabled else { hide(); return false }
        guard panel?.isVisible == true, !rows.isEmpty, !Self.isIMEComposing else { return false }
        switch code {
        case 125:   // ↓
            moveSelection(+1); return true
        case 126:   // ↑
            moveSelection(-1); return true
        case 36:    // ⏎
            if let selectedRow, rows.indices.contains(selectedRow), case .cmd(let c) = rows[selectedRow] {
                DispatchQueue.main.async { self.perform(c) }
                return true
            }
            return SlashQuery.isCategory(query)
        case 53:    // esc：关闭面板，并抑制重弹（用户明确关闭后，光标前残留的 / 不应马上弹回）
            dismissedQuery = query
            hide(); return true
        default: break
        }
        return false
    }

    private static var slashEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "nc.slash.global") == nil || defaults.bool(forKey: "nc.slash.global")
    }

    private func moveSelection(_ delta: Int) {
        guard let next = Self.nextCmdRow(from: selectedRow, delta: delta, rows: rows) else { return }
        selectedRow = next
        suppressSelection = true
        tableView?.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        suppressSelection = false
        tableView?.scrollRowToVisible(next)
        refreshKeyboardHint()
    }

    // MARK: - 面板构建

    private func itemsEqual(_ newItems: [SlashCommand]) -> Bool {
        guard newItems.count == items.count else { return false }
        for (a, b) in zip(items, newItems)
            where a.alias != b.alias || a.name != b.name || a.detail != b.detail || a.group != b.group { return false }
        return true
    }

    private func buildPanel(width: CGFloat) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.canHide = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self

        // 毛玻璃背景 + 圆角
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10

        let table = InstantTable()
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.usesAutomaticRowHeights = false
        table.rowHeight = 42
        table.delegate = self
        table.dataSource = self
        table.onRowMouseDown = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .cmd(let c) = self.rows[row] else { return }
            self.perform(c)
        }
        let col = NSTableColumn(identifier: .init("cmd"))
        col.width = width
        table.addTableColumn(col)
        table.headerView = nil
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasVerticalRuler = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 底部快捷键提示条
        let footer = NSTextField(labelWithString: "")
        keyboardHint = footer
        refreshKeyboardHint()
        footer.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(scroll)
        effect.addSubview(divider)
        effect.addSubview(footer)
        p.contentView = effect
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        panel = p
        tableView = table
    }

    private func refreshKeyboardHint() {
        keyboardHint?.stringValue = KeywordListener.shared.isRunning
            ? (SlashQuery.isCategory(query) && selectedRow == nil
                ? "↑↓ 先选择    ⏎ 执行    esc 关闭    点击直接执行"
                : "↑↓ 选择    ⏎ 执行    esc 关闭    点击直接执行")
            : "键盘监听未启动 · 可点击命令 · 请检查辅助功能授权"
    }

    /// Quartz 坐标（左上原点）→ AppKit 坐标（左下原点），并尽量放在光标下方
    /// 真机取证（双屏：主屏 1728×1117@2x + 副屏 2560×1440@1x 在上方）：
    /// ① 光标矩形逐屏换算曾有 2x 缩放误差；② 行首打 / 时 sel.location=0 读不到矩形 →
    /// 旧 fallback 直接放鼠标点但不夹取屏幕。
    /// 现策略：光标矩形换算后做「合理性校验」——面板须落在鼠标所在屏附近；
    /// 不合理（换算 bug / 窗口跨屏）则改用鼠标位置（打字时鼠标大概率就在 Notes 附近）。
    private func place(cursorRect: CGRect?, width: CGFloat, height: CGFloat) {
        // 面板最终放置点（AppKit 全局坐标）
        var origin = NSEvent.mouseLocation   // 默认：鼠标位置（含夹取）
        if let qRect = cursorRect {
            var quartzDisplays = [CGDirectDisplayID](repeating: 0, count: 4)
            var displayCount: UInt32 = 0
            _ = CGGetDisplaysWithRect(qRect, 4, &quartzDisplays, &displayCount)
            var targetScreen = NSScreen.main ?? NSScreen.screens[0]
            if displayCount > 0, let matched = NSScreen.screens.first(where: {
                quartzFrame(of: $0).intersects(qRect)
            }) { targetScreen = matched }
            // 同屏换算：Quartz 局部 yTop → AppKit 局部 y（上下翻转）
            let screenQ = quartzFrame(of: targetScreen)
            let screenA = targetScreen.frame
            let localX = qRect.minX - screenQ.minX
            let localYTop = qRect.maxY - screenQ.minY
            let axX = screenA.minX + localX
            let axYBottom = screenA.minY + (screenA.height - localYTop)
            let candidate = CGPoint(x: axX, y: axYBottom)
            // 合理性校验：换算结果须离鼠标不太远（<1500pt）且在已知屏幕内。
            // 校验失败说明换算出 bug（历史事故：面板放屏幕外 y=-2046）→ 退回鼠标位置。
            let mouse = NSEvent.mouseLocation
            let dist = hypot(candidate.x - mouse.x, candidate.y - mouse.y)
            let inKnownScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -200, dy: -200).contains(candidate) }
            if dist < 1500 && inKnownScreen {
                origin = candidate
            } else {
                Self.logPlacementSuspiciousOnce("光标矩形换算可疑（dist=\(Int(dist))pt inScreen=\(inKnownScreen)），退回鼠标位置")
            }
        }
        // 用 origin 找屏幕并夹取：优先鼠标/光标所在屏，放不下就换屏
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main ?? NSScreen.screens[0]
        var x = origin.x
        var y = origin.y - height
        if y < screen.visibleFrame.minY {
            // 下方放不下：光标上方
            y = origin.y + 4
        }
        // 水平/垂直都夹取到屏幕可见区
        if x < screen.visibleFrame.minX + 4 || x + width > screen.visibleFrame.maxX - 4 {
            x = min(max(x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - width)
        }
        if y < screen.visibleFrame.minY + 4 { y = screen.visibleFrame.minY + 4 }
        if y + height > screen.visibleFrame.maxY - 4 { y = screen.visibleFrame.maxY - height - 4 }
        panel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// NSScreen 的 Quartz 全局 frame（左上原点）
    /// NSScreen 的 Quartz 全局 frame（左上原点）。
    /// 真机双屏取证（主屏 1728×1117@2x 下 + 副屏 2560×1440@1x 上，AppKit minY=1117）：
    /// Notes 副屏窗口 AX frame y=-899、caret y=-743，均在 [-1440, 0) 内——
    /// Quartz y=0 在主屏顶部；副屏向上排布 → origin.y = -(minY + height - 主屏高)。
    /// 旧公式 -(minY+height) 算出 -2557，面板被放到屏幕外（历史 y=-2046 事故同源）。
    private func quartzFrame(of s: NSScreen) -> CGRect {
        let f = s.frame
        let mainH = NSScreen.screens.first { $0.frame.minX == 0 && $0.frame.minY == 0 }?.frame.height
            ?? NSScreen.screens.map { $0.frame.height }.max() ?? f.height
        let qy = -(f.minY + f.height - mainH)
        return CGRect(x: f.minX, y: qy, width: f.width, height: f.height)
    }

    /// 定位可疑日志 5s 去重（鼠标停在远处时 fallback 每次轮询都刷，污染日志）
    private nonisolated(unsafe) static var lastSuspiciousLogAt = Date.distantPast
    private static func logPlacementSuspiciousOnce(_ msg: String) {
        guard Date().timeIntervalSince(lastSuspiciousLogAt) > 5 else { return }
        lastSuspiciousLogAt = Date()
        NCLog.log("面板定位：\(msg)")
    }

    private func relocateIfNeeded(_ cursorRect: CGRect?) {
        // 用户光标移动（换行等）时跟随
        place(cursorRect: cursorRect, width: panel?.frame.width ?? 330,
              height: panel?.frame.height ?? 240)
    }
}

// MARK: - IME 检测

/// IME 是否处于组合期（拼音等组合式输入法正在编辑未上屏文字）。
/// 组合期内 ↑↓/⏎/esc 是 IME 候选窗交互键，必须放行不拦截；
/// 组合结束（含中文 IME 激活但未输入时）键盘导航正常接管——
/// 检测方式：Notes 焦点元素的 AXMarkedTextRange（组合文本存在即组合中）。
/// 旧实现按「输入源是中文」一刀切，导致中文输入法激活时 / 下拉永远无法用箭头选择。
extension SlashSuggestPanel {
    nonisolated static var isIMEComposing: Bool {
        guard let notes = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Notes"
        }) else { return false }
        let axApp = AXUIElementCreateApplication(notes.processIdentifier)
        var fRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &fRef) == .success,
              let f = fRef else { return false }
        let el = unsafeBitCast(f, to: AXUIElement.self)
        var rRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXMarkedTextRange" as CFString, &rRef) == .success,
              let rv = rRef else { return false }
        var range = CFRange()
        AXValueGetValue(unsafeBitCast(rv, to: AXValue.self), .cfRange, &range)
        return range.length > 0
    }
}

// MARK: - NSTableView 数据源与代理

extension SlashSuggestPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && rows[row].isHeader ? Self.headerRowHeight : Self.cmdRowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // 分组头行用普通行（无高亮）；命令行用自绘高亮
        rows.indices.contains(row) && rows[row].isHeader ? NSTableRowView() : HighlightRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .header(let g) = rows[row] {
            return makeHeaderCell(g)
        }
        guard case .cmd(let item) = rows[row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("cmdCell")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
            ?? makeCell(id: id)
        v.textField?.stringValue = item.name
        if let detail = v.viewWithTag(99) as? NSTextField { detail.stringValue = item.detail }
        if let alias = v.viewWithTag(98) as? NSTextField {
            // 中文名模板（alias 为空）显示 /模板名 不可盲打，改显示「模板」标记
            alias.stringValue = item.alias.isEmpty ? "模板" : "/" + item.alias
        }
        return v
    }

    /// Magpie 风格分组头：accent 色 11pt 半粗小标题 + 计数
    private func makeHeaderCell(_ g: SlashGroup) -> NSView {
        let id = NSUserInterfaceItemIdentifier("headerCell")
        if let v = tableView?.makeView(withIdentifier: id, owner: nil) {
            if let t = (v.subviews.first as? NSStackView)?.arrangedSubviews.first as? NSTextField {
                let count = items.filter { $0.group == g }.count
                t.stringValue = "\(g.title) · \(count)    /\(g.commandAlias)"
            }
            return v
        }
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .controlAccentColor
        let count = items.filter { $0.group == g }.count
        title.stringValue = "\(g.title) · \(count)    /\(g.commandAlias)"
        title.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [title])
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.identifier = id
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: 3),
        ])
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let alias = NSTextField(labelWithString: "")
        alias.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        alias.textColor = .systemPurple
        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.tag = 99
        // 一行内：命令名 + /别名（可盲打的触发词）右侧对齐，详情第二行
        alias.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [name, alias])
        stack.orientation = .horizontal
        stack.spacing = 6
        let vstack = NSStackView(views: [stack, detail])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 2
        vstack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            vstack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = name
        alias.tag = 98
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // 分组头不可选：↑↓/点击都只落在命令行
        !(rows.indices.contains(row) && rows[row].isHeader)
    }

    /// 单击选中即执行（suppressSelection 区分程序性选择）
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection,
              let tv = notification.object as? NSTableView,
              tv == tableView,
              let row = tv.selectedRowIndexes.first,
              rows.indices.contains(row), case .cmd(let cmd) = rows[row] else { return }
        // 键盘导航已同步 selectedRow；selection 与 selectedRow 一致时跳过（避免双触发）
        selectedRow = row
        perform(cmd)
    }
}
