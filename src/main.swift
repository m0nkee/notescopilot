import AppKit
import SwiftUI
import Carbon
import Carbon.HIToolbox

#if NC_APP
// MARK: - 应用主体（菜单栏常驻 + 浮动面板 + 全局快捷键 ⇧⌘Space）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = ChatEngine()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var settingsWindow: NSWindow?
    private var libraryWindow: NSWindow?
    /// LiberatorLite：NoteStore 直读（懒加载，无权限时为 nil）
    private(set) var notesStore: NotesStore?
    /// FSEvents 监听：NoteStore.sqlite 变更后自动重索引（对应 ProNotes 的 fsEventStream）
    private var storeWatcher: StoreWatcher?
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FrontmostTracker.shared.start()
        buildStatusItem()
        buildPanel()
        registerHotkey()
        KeywordListener.shared.startIfNeeded()
        // AX 轮询通道：无需「输入监控」权限，只要辅助功能授权即可用（ProNotes 同款方案：pollTextArea）
        AXSlashWatcher.shared.startIfNeeded()
        // 选中即 AI：选中稳定后弹悬浮快捷加工条（可设置页关闭）
        SelectionWatcher.shared.startIfNeeded()

        NotificationCenter.default.addObserver(
            forName: .init("nc.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in self?.showSettings() }

        // 外部触发（调试/自动化取证）：notifyutil -p nc.openSettings 或分布式通知
        DistributedNotificationCenter.default().addObserver(
            forName: .init("nc.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in self?.showSettings() }

        // 全局斜杠命令：AI 完成后自动把结果写回 Notes 光标处
        NotificationCenter.default.addObserver(
            forName: .init("nc.autoInsert"), object: nil, queue: .main
        ) { note in
            guard let text = note.object as? String, !text.isEmpty else { return }
            _ = NotesBridge.shared.insertIntoNotes(text)
        }

        // 懒打开笔记库：能打开就开，无权限则静默降级（窗口内有引导）
        notesStore = try? NotesStore()

        // FSEvents 监听 Notes 落盘 → 去抖重索引（证据：FSEventStreamStart / fsEventStream / notesDb）
        if let store = notesStore {
            storeWatcher = StoreWatcher(store: store)
            storeWatcher?.start()
        }

        // accessory（LSUIElement）应用没有主菜单，⌘V/⌘C 的快捷键等价物会失效，
        // 导致设置窗口的 SecureField 无法粘贴——构建标准 mainMenu 修复
        NSApp.mainMenu = Self.buildMainMenu()

        // 内置模板 seed（对齐 ProNotes _defaultTemplates；幂等，仅首次）
        TemplateSeeder.ensureSeeded()

        if Config.baseURL.isEmpty { showSettings() }
    }

    // MARK: 主菜单（提供 Edit 快捷键等价物，修复无法粘贴/复制）

    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 NotesCopilot",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                                   accessibilityDescription: "NotesCopilot")
        }
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
        add("打开输入监控设置…", #selector(openListenEventSettings), target: self)
        add("权限自检（写入日志）", #selector(selfCheck), target: self)
        menu.addItem(.separator())
        add("打开面板（全局快捷键 ⇧⌘Space）", #selector(togglePanel), target: self)
        add("笔记库…", #selector(showLibrary), "l", target: self)
        add("设置…", #selector(showSettings), ",", target: self)
        menu.addItem(.separator())
        add("打开辅助功能设置", #selector(openAXSettings), target: self)
        menu.addItem(.separator())
        add("退出", #selector(NSApplication.terminate(_:)), "q", target: nil)
        statusItem.menu = menu
    }

    /// 菜单展开时刷新监听状态行，让「斜杠不生效」一眼可诊断
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu, let first = menu.items.first else { return }
        let cgRunning = KeywordListener.shared.isRunning
        let axRunning = AXSlashWatcher.shared.isRunning
        let slashOn = UserDefaults.standard.object(forKey: "nc.slash.global") == nil
            ? true : UserDefaults.standard.bool(forKey: "nc.slash.global")
        if cgRunning {
            first.title = "键盘监听：● 运行中（斜杠命令可用）"
        } else if axRunning {
            first.title = "斜杠命令：● AX 通道运行中（Notes 内可用）"
        } else if !slashOn {
            first.title = "键盘监听：○ 全局斜杠命令已关闭（设置中开启）"
        } else {
            first.title = "键盘监听：○ 未授权（点击「打开输入监控设置」勾选本应用）"
        }
    }

    @objc func openListenEventSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
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
        输入监控（键盘监听通道依赖）：\(listen ? "✅ 已授权" : "⚠️ 未授权（不影响 AX 通道，仅影响关键词扩展与 Markdown 扩展）")

        二进制路径：\(Bundle.main.bundleURL.path)
        日志：~/Library/Logs/NotesCopilot-debug.log
        """
        alert.runModal()
    }

    // MARK: 浮动面板

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered, defer: false)
        p.title = "NotesCopilot"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentViewController = NSHostingController(rootView: PanelView(engine: engine))
        p.center()
        panel = p
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            revealPanel()
        }
    }

    /// 呼出面板（不隐藏）并抓取选中：全局斜杠命令与热键共用
    func revealPanel() {
        if let sel = NotesBridge.shared.readSelectedText(), !sel.isEmpty {
            engine.noteContext = sel
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 设置窗口

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "NotesCopilot 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
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
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openAXSettings() {
        NotesBridge.shared.openAccessibilityPrefs()
    }

    // MARK: 笔记库窗口（LiberatorLite）

    @objc func showLibrary() {
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
        // 首次或上次无权限时重试打开
        if notesStore == nil {
            notesStore = try? NotesStore()
            (libraryWindow?.contentView as? NSHostingView<LibraryView>)?.rootView = LibraryView()
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 从笔记库把笔记正文送入 AI 面板（笔记库 ⇄ Ask AI 桥接）
    @objc func openPanelWithNote(_ sender: Any?) {
        guard let note = sender as? NoteSummary else { return }
        if let store = notesStore,
           let blob = store.noteBodyData(pk: note.pk),
           let doc = TopotextDecoder.decode(blob) {
            engine.noteContext = MarkdownConverter.applyRuns(doc)
        } else {
            engine.noteContext = note.snippet
        }
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
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
        InstallEventHandler(GetApplicationEventTarget(), upp, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4E435043), id: 1)  // 'NCPC'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey),
                            id, GetApplicationEventTarget(), 0, &hotkeyRef)
    }
}
#endif

// MARK: - 入口

#if NC_APP
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
