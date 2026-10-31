import AppKit
import SwiftUI
import Carbon
import Carbon.HIToolbox

#if NC_APP
// MARK: - 应用主体（菜单栏常驻 + 浮动面板 + 全局快捷键 ⇧⌘Space）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let startBackgroundServices: Bool
    init(startBackgroundServices: Bool = true) {
        self.startBackgroundServices = startBackgroundServices
        super.init()
    }
    let engine = ChatEngine()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var settingsWindow: NSWindow?
    private var libraryWindow: NSWindow?
    /// LiberatorLite：NoteStore 直读（懒加载，无权限时为 nil）
    private(set) var notesStore: NotesStore?
    private(set) var notesStoreError: String?
    private(set) var notesStoreLoading = false
    private(set) var notesTemplatesLoading = false
    private var templateRefreshID = UUID()
    /// FSEvents 监听：NoteStore.sqlite 变更后自动重索引（对应 ProNotes 的 fsEventStream）
    private var storeWatcher: StoreWatcher?
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var hotkeyHandlerStatus: OSStatus?
    private var hotkeyStatus: OSStatus?
    private var updateTimer: Timer?
    private var updateMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if startBackgroundServices { FrontmostTracker.shared.start() }
        buildStatusItem()
        buildPanel()
        if startBackgroundServices {
            registerHotkey()
            KeywordListener.shared.startIfNeeded()
            AXSlashWatcher.shared.startIfNeeded()
            SelectionWatcher.shared.startIfNeeded()
        }

        NotificationCenter.default.addObserver(
            forName: .init("nc.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.showSettings() } }

        // 外部触发（调试/自动化取证）：notifyutil -p nc.openSettings 或分布式通知
        DistributedNotificationCenter.default().addObserver(
            forName: .init("nc.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.showSettings() } }

        NotificationCenter.default.addObserver(forName: ProfileStore.errorNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.engine.lastError = note.object as? String }
        }

        // 全局斜杠命令：AI 完成后自动把结果写回 Notes 光标处
        NotificationCenter.default.addObserver(
            forName: .init("nc.autoInsert"), object: nil, queue: .main
        ) { [weak self] note in
            guard let text = note.object as? String, !text.isEmpty else { return }
            NotesBridge.shared.insertIntoNotes(text) { error in
                MainActor.assumeIsolated { self?.engine.lastError = error }
            }
        }

        // Full-text indexing runs off the main thread; errors remain visible and retryable.
        NotificationCenter.default.addObserver(
            forName: .init("nc.storeDidReindex"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshNotesTemplates() } }
        if startBackgroundServices { retryNotesStore() }

        // accessory（LSUIElement）应用没有主菜单，⌘V/⌘C 的快捷键等价物会失效，
        // 导致设置窗口的 SecureField 无法粘贴——构建标准 mainMenu 修复
        NSApp.mainMenu = Self.buildMainMenu()
        AppUpdater.shared.onCheckCompleted = { [weak self] userInitiated in
            self?.presentUpdateResult(userInitiated: userInitiated)
        }
        if startBackgroundServices {
            Task { await AppUpdater.shared.checkIfNeeded() }
            updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
                Task { @MainActor in await AppUpdater.shared.checkIfNeeded() }
            }
        }

        // 内置模板 seed（对齐 ProNotes _defaultTemplates；幂等，仅首次）
        if startBackgroundServices { TemplateSeeder.ensureSeeded() }

        showPrimaryWindow()
        recordStartupState("启动完成")
        // Status-bar window geometry settles after the launch callback returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recordStartupState("启动界面就绪")
        }
    }

    /// Finder / Launch Services reuse the running menu-bar process when opening
    /// the app again. Restore a window even when the status item is obscured.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true
        showPrimaryWindow()
        recordStartupState("重新打开应用")
        return false
    }

    private func showPrimaryWindow() {
        if Config.baseURL.isEmpty { showSettings() }
        else { revealPanel(captureContext: false) }
    }

    private func present(_ window: NSWindow) {
        // Recover windows left on a disconnected display, including their title bar.
        let screens = NSScreen.screens
        if !screens.contains(where: { $0.visibleFrame.contains(window.frame) }),
           let screen = window.screen ?? NSScreen.main ?? screens.first {
            let bounds = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
            frame.origin.y = frame.height > bounds.height
                ? bounds.maxY - frame.height
                : min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Only this app's UI metadata; no note text, endpoint credentials or user content.
    func startupState() -> [String: Any] {
        ["statusItemVisible": statusItem?.isVisible ?? false,
         "statusButton": statusItem?.button != nil,
         "statusImage": statusItem?.button?.image != nil,
         "statusFrame": statusItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "none",
         "statusItemObscuredByNotch": statusItem?.button?.window.map { window in
             NSScreen.screens.contains {
                 Self.statusFrameOverlapsNotch(window.frame, leftArea: $0.auxiliaryTopLeftArea, rightArea: $0.auxiliaryTopRightArea)
             }
         } ?? false,
         "screenCount": NSScreen.screens.count,
         "hotkeyHandlerStatus": hotkeyHandlerStatus.map(Int.init) ?? -1,
         "hotkeyStatus": hotkeyStatus.map(Int.init) ?? -1,
         "windows": NSApp.windows.filter { !$0.title.isEmpty }.map {
             ["title": $0.title, "visible": $0.isVisible, "key": $0.isKeyWindow, "frame": NSStringFromRect($0.frame)] as [String: Any]
         }]
    }

    static func statusFrameOverlapsNotch(_ frame: NSRect, leftArea: NSRect?, rightArea: NSRect?) -> Bool {
        guard let left = leftArea, let right = rightArea,
              right.minX > left.maxX else { return false }
        let bottom = max(left.minY, right.minY)
        let top = min(left.maxY, right.maxY)
        guard top > bottom else { return false }
        let notch = NSRect(x: left.maxX, y: bottom, width: right.minX - left.maxX, height: top - bottom)
        let overlap = frame.intersection(notch)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    private func recordStartupState(_ event: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: startupState(), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        NCLog.log("\(event)：\(json)")
    }

    // MARK: 主菜单（提供 Edit 快捷键等价物，修复无法粘贴/复制）

    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 NotesCopilot",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    // MARK: 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "NotesCopilot")
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "NotesCopilot")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            if image == nil { button.title = "NC" }
            button.toolTip = "NotesCopilot · ⇧⌘Space 打开面板"
        }
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, _ keyEquivalent: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = target
            menu.addItem(item)
            return
        }
        // 监听状态行（菜单展开时实时刷新，见 menuNeedsUpdate）
        let statusLine = NSMenuItem(title: "键盘监听：检查中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        add("权限自检（写入日志）", #selector(selfCheck), target: self)
        menu.addItem(.separator())
        add("打开面板（全局快捷键 ⇧⌘Space）", #selector(showPanel), target: self)
        add("笔记库…", #selector(showLibrary), "l", target: self)
        add("设置…", #selector(showSettings), ",", target: self)
        add("检查更新…", #selector(checkForUpdates), target: self)
        let updateItem = NSMenuItem(title: "有新版本可下载", action: #selector(openUpdateDownload), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        menu.addItem(.separator())
        add("打开辅助功能设置", #selector(openAXSettings), target: self)
        menu.addItem(.separator())
        add("退出", #selector(NSApplication.terminate(_:)), "q", target: nil)
        statusItem.menu = menu
    }

    /// 菜单展开时刷新监听状态行，让「斜杠不生效」一眼可诊断
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu, let first = menu.items.first else { return }
        refreshUpdateMenu()
        let cgRunning = KeywordListener.shared.isRunning
        let axRunning = AXSlashWatcher.shared.isRunning
        let slashOn = UserDefaults.standard.object(forKey: "nc.slash.global") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.slash.global")
        if !slashOn {
            first.title = "斜杠命令：○ 已关闭（Markdown 与 URL 独立运行）"
        } else if !NotesBridge.shared.isTrusted {
            first.title = "Notes 扩展：○ 等待辅助功能授权"
        } else if NotesBridge.shared.accessIssue == .automationDenied {
            first.title = "Notes 扩展：○ 需要允许自动化控制 Notes"
        } else if cgRunning {
            first.title = "键盘监听：● 运行中（斜杠命令可用）"
        } else if axRunning {
            first.title = "斜杠命令：● AX 通道可用，键盘导航未启动"
        } else {
            first.title = "键盘监听：○ 未启动，请检查辅助功能授权"
        }
    }

    @objc func checkForUpdates() {
        Task { await AppUpdater.shared.check() }
    }

    @objc func openUpdateDownload() {
        NSWorkspace.shared.open(AppUpdater.shared.availableRelease?.pageURL ?? AppUpdater.releasesURL)
    }

    private func refreshUpdateMenu() {
        let release = AppUpdater.shared.availableRelease
        updateMenuItem?.isHidden = release == nil
        updateMenuItem?.title = "下载新版本 v\(release?.version ?? "")…"
    }

    private func presentUpdateResult(userInitiated: Bool) {
        let updater = AppUpdater.shared
        refreshUpdateMenu()
        guard userInitiated || updater.shouldRemind() else { return }
        let alert = NSAlert()
        if updater.status == .available, let release = updater.availableRelease {
            alert.messageText = "NotesCopilot 有新版本 v\(release.version)"
            alert.informativeText = "当前版本：v\(updater.currentVersion)\n建议更新以获取最新功能和修复。\n下载 DMG 后，将 NotesCopilot 拖入「Applications」替换旧版本。"
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后提醒")
            updater.markReminded()
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openUpdateDownload() }
        } else {
            alert.messageText = updater.status == .current ? "已是最新版本" : "检查更新失败"
            alert.informativeText = updater.statusMessage
            alert.addButton(withTitle: "好")
            if updater.status != .current { alert.addButton(withTitle: "打开发布页") }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(AppUpdater.releasesURL) }
        }
    }

    /// 权限自检：把当前两项关键权限的实时状态写入日志（诊断「不生效」用）
    @objc func selfCheck() {
        let ax = NotesBridge.shared.isTrusted
        let listen = CGPreflightListenEventAccess()
        NCLog.log("权限自检：辅助功能 = \(ax)，输入监控 = \(listen)，二进制 = \(Bundle.main.bundleURL.path)")
        let alert = NSAlert()
        alert.messageText = "权限状态"
        alert.informativeText = """
        辅助功能（AX 通道依赖）：\(ax ? "✅ 已授权" : "❌ 未授权——这是斜杠命令不生效的最可能原因")
        键盘导航与关键词扩展：\(KeywordListener.shared.isRunning ? "✅ 监听已启动" : "监听未启动，可用鼠标点击命令")
        输入监控（当前键盘导航无需额外开启）：\(listen ? "✅ 已授权" : "未授权")
        Notes 访问：\(NotesBridge.shared.refreshAccessIssue()?.message ?? "未记录访问错误；请在 Notes 正文尝试命令或选区加工。")

        二进制路径：\(Bundle.main.bundleURL.path)
        日志：~/Library/Logs/NotesCopilot-debug.log
        """
        alert.runModal()
    }

    // MARK: 浮动面板

    private func buildPanel() {
        let height = min(760, max(640, (NSScreen.main?.visibleFrame.height ?? 810) - 50))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered, defer: false)
        p.title = "NotesCopilot"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentMinSize = NSSize(width: 520, height: 640)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentViewController = NSHostingController(rootView: PanelView(engine: engine))
        p.center()
        panel = p
    }

    @objc func showPanel() {
        revealPanel(captureContext: false)
    }

    @objc func togglePanel() {
        if panel.isVisible && !panel.isMiniaturized {
            panel.orderOut(nil)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                FrontmostTracker.shared.lastForeignApp?.activate()
            }
        } else {
            revealPanel()
        }
    }

    /// 呼出面板（不隐藏）并抓取选中：全局斜杠命令与热键共用
    func revealPanel(captureContext: Bool = true) {
        if captureContext && startBackgroundServices {
            let target = NotesBridge.shared.readNotesSnapshot()
            let context = target.flatMap { NotesBridge.context(in: $0) }
            let fromThisApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if target != nil || !fromThisApp {
                engine.setContext(context?.text ?? "", source: context?.source ?? "", noteID: target?.noteID)
            }
        }
        present(panel)
        recordStartupState("呼出面板")
    }

    // MARK: 设置窗口

    @objc func showSettings() {
        // The floating AI panel would otherwise cover the normal settings window.
        panel?.orderOut(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "NotesCopilot 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(discoverLocalModels: startBackgroundServices))
            w.center()
            // 双屏优先落在主屏（原点屏）；副屏 AX 窗口元素偶发不可用，取证/自动化也更稳
            if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
               NSScreen.screens.count > 1 {
                let f = primary.visibleFrame
                w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2,
                                         y: f.midY - w.frame.height / 2))
            }
            settingsWindow = w
        }
        if let window = settingsWindow { present(window) }
    }

    @objc func openAXSettings() {
        NotesBridge.shared.openAccessibilityPrefs()
    }

    // MARK: 笔记库窗口（LiberatorLite）

    @objc func showLibrary() {
        panel?.orderOut(nil)
        if notesStore == nil { retryNotesStore() }
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "笔记库 · NotesCopilot"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView())
            w.center()
            libraryWindow = w
        }
        if let window = libraryWindow { present(window) }
    }

    @objc func retryNotesStore() {
        guard startBackgroundServices, notesStore == nil, !notesStoreLoading else { return }
        notesStoreLoading = true
        notesStoreError = nil
        NotificationCenter.default.post(name: .init("nc.storeAvailable"), object: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try NotesStore() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.notesStoreLoading = false
                switch result {
                case .success(let store):
                    self.notesStore = store
                    self.notesStoreError = nil
                    self.storeWatcher = StoreWatcher(store: store)
                    self.storeWatcher?.start()
                    self.refreshNotesTemplates()
                case .failure(let error):
                    self.notesStoreError = error.localizedDescription
                }
                NotificationCenter.default.post(name: .init("nc.storeAvailable"), object: nil)
            }
        }
    }

    /// Keep Notes templates separate from local edits; stale scans cannot replace a newer result.
    @objc func refreshNotesTemplates() {
        guard let store = notesStore else { retryNotesStore(); return }
        let requestID = UUID()
        templateRefreshID = requestID
        notesTemplatesLoading = true
        NotificationCenter.default.post(name: TemplateStore.notesChangedNotification, object: nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let templates = NotesTemplateImporter.readTemplates(from: store)
            DispatchQueue.main.async {
                guard let self, self.templateRefreshID == requestID, self.notesStore === store else { return }
                self.notesTemplatesLoading = false
                TemplateStore.updateNotesTemplates(templates)
                NCLog.log("Notes 模板已更新：\(templates.count) 个")
            }
        }
    }

    /// 从笔记库把笔记正文送入 AI 面板（笔记库 ⇄ Ask AI 桥接）
    @objc func openPanelWithNote(_ sender: Any?) {
        guard let context = sender as? NoteAIContext, context.content.isComplete else { return }
        engine.setContext(context.content.markdown, source: "笔记库 · \(context.note.title)", noteID: context.note.uuid)
        engine.lastError = context.content.warning
        revealPanel(captureContext: false)
    }

    // MARK: 全局快捷键（Carbon RegisterEventHotKey）

    private func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let upp: EventHandlerUPP = { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(UInt32(kEventParamDirectObject)),
                              EventParamType(UInt32(typeEventHotKeyID)),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == 1 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
                MainActor.assumeIsolated {
                    delegate.togglePanel()
                }
            }
            return noErr
        }
        hotkeyHandlerStatus = InstallEventHandler(GetApplicationEventTarget(), upp, 1, &spec,
                                                  Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard hotkeyHandlerStatus == noErr else {
            NCLog.log("全局快捷键处理器安装失败：\(hotkeyHandlerStatus ?? -1)")
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4E435043), id: 1)  // 'NCPC'
        hotkeyStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey),
                                          id, GetApplicationEventTarget(), 0, &hotkeyRef)
        NCLog.log("全局快捷键注册：\(hotkeyStatus ?? -1)")
    }
}
#endif

// MARK: - 入口

#if NC_APP && !NC_APP_TEST
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
