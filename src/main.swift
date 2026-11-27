import AppKit
import SwiftUI
import Combine
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
    private var notesStoreFailure: Error?
    var notesStoreError: String? { notesStoreFailure?.localizedDescription }
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
    private var localizationObserver: AnyCancellable?
    private var regularFeaturesStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if startBackgroundServices { FrontmostTracker.shared.start() }
        buildStatusItem()
        buildPanel()
        if startBackgroundServices { registerHotkey() }

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

        // accessory（LSUIElement）应用没有主菜单，⌘V/⌘C 的快捷键等价物会失效，
        // 导致设置窗口的 SecureField 无法粘贴——构建标准 mainMenu 修复
        NSApp.mainMenu = Self.buildMainMenu()
        localizationObserver = NotificationCenter.default.publisher(for: L10n.didChange, object: L10n.shared)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshLocalization() } }
        AppUpdater.shared.onCheckCompleted = { [weak self] userInitiated in
            self?.presentUpdateResult(userInitiated: userInitiated)
        }
        NSApp.servicesProvider = SelectionAIPanel.shared
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true {
            if startBackgroundServices { NSUpdateDynamicServices() }
            showPrimaryWindow()
        } else if startBackgroundServices {
            if SelectionScope.allowsGlobalSelection() {
                KeywordListener.shared.startIfNeeded()
                SelectionWatcher.shared.startIfNeeded()
            }
            // A Service can cold-launch the app with just a string. Start Notes integration
            // when the user next enters Notes or opens a regular NotesCopilot window.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == NotesBridge.notesBundleID {
                    MainActor.assumeIsolated { self?.startRegularFeaturesIfNeeded() }
                }
            }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        if startBackgroundServices { SelectionWatcher.shared.stop() }
    }

    private func showPrimaryWindow() {
        if Config.baseURL.isEmpty { showSettings() }
        else { revealPanel(captureContext: false) }
    }

    private func startRegularFeaturesIfNeeded() {
        guard startBackgroundServices, !regularFeaturesStarted else { return }
        regularFeaturesStarted = true
        KeywordListener.shared.startIfNeeded()
        AXSlashWatcher.shared.startIfNeeded()
        SelectionWatcher.shared.startIfNeeded()
        TemplateSeeder.ensureSeeded()
        retryNotesStore()
        Task { await AppUpdater.shared.checkIfNeeded() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in await AppUpdater.shared.checkIfNeeded() }
        }
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
        appMenu.addItem(withTitle: L10n.text("About NotesCopilot"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: L10n.text("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit NotesCopilot"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("Edit"))
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("Window"))
        windowMenu.addItem(withTitle: L10n.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.text("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
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
        }
        statusItem.isVisible = true
        buildStatusMenu()
    }

    private func refreshLocalization() {
        NSApp.mainMenu = Self.buildMainMenu()
        buildStatusMenu()
        refreshUpdateMenu()
        settingsWindow?.title = L10n.text("NotesCopilot Settings")
        libraryWindow?.title = L10n.text("Note Library · NotesCopilot")
    }

    private func buildStatusMenu() {
        statusItem.button?.toolTip = L10n.text("NotesCopilot · ⇧⌘Space to open the panel")
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, _ keyEquivalent: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = target
            menu.addItem(item)
            return
        }
        // 监听状态行（菜单展开时实时刷新，见 menuNeedsUpdate）
        let statusLine = NSMenuItem(title: L10n.text("Keyboard listener: Checking…"), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        add(L10n.text("Check Permissions and Log"), #selector(selfCheck), target: self)
        menu.addItem(.separator())
        add(L10n.text("Open Panel (⇧⌘Space)"), #selector(showPanel), target: self)
        add(L10n.text("Note Library…"), #selector(showLibrary), "l", target: self)
        add(L10n.text("Settings…"), #selector(showSettings), ",", target: self)
        add(L10n.text("Check for Updates…"), #selector(checkForUpdates), target: self)
        let updateItem = NSMenuItem(title: L10n.text("Update Available"), action: #selector(openUpdateDownload), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        menu.addItem(.separator())
        add(L10n.text("Open Accessibility Settings"), #selector(openAXSettings), target: self)
        menu.addItem(.separator())
        add(L10n.text("Quit NotesCopilot"), #selector(NSApplication.terminate(_:)), "q", target: nil)
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
            first.title = L10n.text("Slash commands: ○ Off. Markdown shortcuts and links still work.")
        } else if !NotesBridge.shared.isTrusted {
            first.title = L10n.text("Notes integration: ○ Waiting for Accessibility access")
        } else if NotesBridge.shared.accessIssue == .automationDenied {
            first.title = L10n.text("Notes integration: ○ Grant Automation access to control Notes")
        } else if cgRunning {
            first.title = L10n.text("Keyboard listener: ● Running. Slash commands are available.")
        } else if axRunning {
            first.title = L10n.text("Slash commands: ● Available via Accessibility. Keyboard navigation is inactive.")
        } else {
            first.title = L10n.text("Keyboard listener: ○ Inactive. Check Accessibility access.")
        }
    }

    @objc func checkForUpdates() {
        Task { await AppUpdater.shared.check() }
    }

    @objc func openUpdateDownload() {
        let updater = AppUpdater.shared
        if updater.isDownloading {
            updater.cancelDownload()
            return
        }
        Task { @MainActor in
            guard let fileURL = await AppUpdater.shared.download() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func refreshUpdateMenu() {
        let release = AppUpdater.shared.availableRelease
        updateMenuItem?.isHidden = release == nil
        updateMenuItem?.title = AppUpdater.shared.isDownloading
            ? L10n.format("Cancel Download v%@…", release?.version ?? "")
            : L10n.format("Download Update v%@…", release?.version ?? "")
    }

    private func presentUpdateResult(userInitiated: Bool) {
        let updater = AppUpdater.shared
        refreshUpdateMenu()
        guard userInitiated || updater.shouldRemind() else { return }
        let alert = NSAlert()
        if updater.status == .available, let release = updater.availableRelease {
            alert.messageText = L10n.format("NotesCopilot v%@ Is Available", release.version)
            var informativeText = L10n.format(
                "Current version: v%@\nDownload the update for the latest features and fixes. NotesCopilot verifies the DMG with SHA-256, saves it in Downloads, and reveals it in Finder. Drag the app into Applications to replace the previous version.\nIf macOS cannot verify the app, click Done, then Open Anyway in System Settings → Privacy & Security.",
                updater.currentVersion)
            if let notes = release.alertNotes {
                informativeText += L10n.format("\n\nRelease Notes\n%@", notes)
            }
            alert.informativeText = informativeText
            alert.addButton(withTitle: L10n.text("Download"))
            alert.addButton(withTitle: L10n.text("Remind Later"))
            updater.markReminded()
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openUpdateDownload() }
        } else {
            alert.messageText = updater.status == .current ? L10n.text("You're Up to Date") : L10n.text("Update Check Failed")
            alert.informativeText = updater.statusMessage
            alert.addButton(withTitle: L10n.text("OK"))
            if updater.status != .current { alert.addButton(withTitle: L10n.text("Open Releases")) }
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
        alert.messageText = L10n.text("Permissions")
        let accessibilityStatus = ax ? L10n.text("✅ Granted")
            : L10n.text("❌ Grant access to use slash commands.")
        let keyboardStatus = KeywordListener.shared.isRunning ? L10n.text("✅ Listening")
            : L10n.text("Inactive. You can still click commands.")
        let monitoringStatus = listen ? L10n.text("✅ Granted") : L10n.text("Not granted")
        let notesStatus = NotesBridge.shared.refreshAccessIssue()?.message ?? L10n.text(
            "No access errors recorded. Try a slash command or selection tool in Notes.")
        alert.informativeText = L10n.format(
            "Accessibility: %@\nKeyboard navigation and keyword expansion: %@\nInput Monitoring (optional): %@\nNotes access: %@\n\nApp path: %@\nLog: ~/Library/Logs/NotesCopilot-debug.log",
            accessibilityStatus, keyboardStatus, monitoringStatus, notesStatus, Bundle.main.bundleURL.path)
        alert.addButton(withTitle: L10n.text("OK"))
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
        startRegularFeaturesIfNeeded()
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
        startRegularFeaturesIfNeeded()
        // The floating AI panel would otherwise cover the normal settings window.
        panel?.orderOut(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.text("NotesCopilot Settings")
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
        startRegularFeaturesIfNeeded()
        panel?.orderOut(nil)
        if notesStore == nil { retryNotesStore() }
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.text("Note Library · NotesCopilot")
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
        notesStoreFailure = nil
        NotificationCenter.default.post(name: .init("nc.storeAvailable"), object: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try NotesStore() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.notesStoreLoading = false
                switch result {
                case .success(let store):
                    self.notesStore = store
                    self.notesStoreFailure = nil
                    self.storeWatcher = StoreWatcher(store: store)
                    self.storeWatcher?.start()
                    self.refreshNotesTemplates()
                case .failure(let error):
                    self.notesStoreFailure = error
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
