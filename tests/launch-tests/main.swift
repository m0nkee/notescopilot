import AppKit
import Foundation

/// Exercises the real delegate with isolated settings. Optional host processes provide synthetic selections.
@main
@MainActor
struct LaunchTests {
    private static var passed = 0
    private static var failed = 0
    private static var delegates: [AppDelegate] = []
    private static let ownedTitles: Set<String> = ["NotesCopilot", "NotesCopilot 设置", "笔记库 · NotesCopilot"]

    static func check(_ value: Bool, _ name: String) {
        if value { passed += 1; print("PASS  \(name)") }
        else { failed += 1; print("FAIL  \(name)") }
    }

    private static func settle() {
        let deadline = Date().addingTimeInterval(0.1)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while Date() < deadline
    }

    private static func closeWindows() {
        for window in NSApp.windows where ownedTitles.contains(window.title) { window.close() }
        settle()
    }

    private static func hasWindow(_ title: String) -> Bool {
        NSApp.windows.contains { $0.title == title && $0.isVisible && !$0.isMiniaturized }
    }

    private static func reachable(_ window: NSWindow) -> Bool {
        let frame = window.frame
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 24, width: frame.width, height: 24)
        return NSScreen.screens.contains {
            let intersection = $0.visibleFrame.intersection(titleBar)
            return !intersection.isNull && intersection.width >= min(100, frame.width) && intersection.height >= 20
        }
    }

    private static func moveOffscreen(_ window: NSWindow) {
        let screen = NSScreen.screens[0].visibleFrame
        window.setFrameOrigin(NSPoint(x: screen.maxX + 1000, y: screen.maxY + 1000))
        settle()
    }

    private static func configure(_ configured: Bool) throws {
        let profiles = configured ? [ModelProfile(name: "Synthetic launch profile", baseURL: "https://launch.invalid/v1", model: "synthetic")] : []
        let values: [String: Any] = [
            ProfileStore.key: try JSONEncoder().encode(profiles),
            ProfileStore.activeKey: profiles.first?.id.uuidString ?? "",
            "nc.templates": try JSONEncoder().encode([TemplateNote]()),
            "nc.templates.seeded.v1": true,
            "nc.kw.enabled": false, "nc.slash.global": false, "nc.selai.enabled": false,
            "nc.md.enabled": false, "nc.urltitle.enabled": false,
        ]
        let isolated = UserDefaults(suiteName: "local.notescopilot.launch-tests.\(UUID().uuidString)")!
        isolated.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        ProfileStore.defaults = isolated
        Config.defaults = isolated
        ProfileStore.secretStore = MemoryProfileSecretStore()
    }

    private static func launch(configured: Bool, defaultLaunch: Bool = true) throws -> AppDelegate {
        closeWindows()
        try configure(configured)
        let delegate = AppDelegate(startBackgroundServices: false)
        delegates.append(delegate)
        NSApp.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: defaultLaunch]))
        settle()
        let state = delegate.startupState()
        if JSONSerialization.isValidJSONObject(state),
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("STATE configured=\(configured) \(text)")
        }
        return delegate
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--send-service-fixture") {
            Task { @MainActor in await sendServiceFixture() }
            app.run()
            return
        }
        guard CommandLine.arguments.contains("--run-tests") else { exit(1) }
        Task { @MainActor in await runTests(app) }
        app.run()
    }

    private static let serviceFixture = "跨进程选区 📝"

    private static func sendServiceFixture() async -> Never {
        let fixture = Bundle(path: CommandLine.arguments[2])!
        let spec = (fixture.object(forInfoDictionaryKey: "NSServices") as! [[String: Any]])[0]
        let name = (spec["NSMenuItem"] as! [String: String])["default"]!
        let board = NSPasteboard(name: .init(CommandLine.arguments.last!))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        view.string = "prefix " + serviceFixture + " suffix"
        view.setSelectedRange((view.string as NSString).range(of: serviceFixture))
        let advertised = (spec["NSSendTypes"] as! [String]).map { NSPasteboard.PasteboardType($0) }
        let supported = advertised.filter { view.validRequestor(forSendType: $0, returnType: nil) != nil }
        let menu = NSMenu()
        let appMenu = NSMenu()
        let servicesMenu = NSMenu(title: "Services")
        menu.addItem(withTitle: "Application", action: nil, keyEquivalent: "").submenu = appMenu
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.mainMenu = menu
        NSApp.servicesMenu = servicesMenu
        NSApp.registerServicesMenuSendTypes(advertised, returnTypes: [])
        NSUpdateDynamicServices()
        let exported = view.writeSelection(to: board, types: supported)
        let deadline = Date().addingTimeInterval(10)
        var sent = false
        while exported && !sent && Date() < deadline {
            servicesMenu.update()
            sent = NSPerformService(name, board)
            if !sent { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        print("SERVICE CLIENT  exported=\(exported) dispatched=\(sent)")
        exit(sent ? 0 : 1)
    }

    private static func checkServiceDispatch(_ service: SelectionAIPanel) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NC_SERVICE_TEST_CLIENT"]!)
        peer.arguments = ["--send-service-fixture", Bundle.main.bundlePath, board.name.rawValue]
        try peer.run()
        let deadline = Date().addingTimeInterval(15)
        while (peer.isRunning || service.original != serviceFixture) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if peer.isRunning { peer.terminate(); check(false, "system service dispatch timed out"); return }
        check(peer.terminationStatus == 0 && service.isServiceSession && service.original == serviceFixture,
              "NSPerformService delivers just the selected text from a separate AppKit process")
        service.hide()
    }

    private static func checkWritingTools() async throws {
        _ = try launch(configured: true, defaultLaunch: false)
        guard let spec = (Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])?.first,
              let message = spec["NSMessage"] as? String,
              let service = NSApp.servicesProvider as? SelectionAIPanel else {
            check(false, "the application registers its declared writing service")
            return
        }
        let sendTypes = (spec["NSSendTypes"] as? [String] ?? []).map { NSPasteboard.PasteboardType($0) }
        check(service === SelectionAIPanel.shared && service.responds(to: NSSelectorFromString(message + ":userData:error:"))
              && sendTypes.contains(.string) && sendTypes.contains(.init("NSStringPboardType"))
              && spec["NSReturnTypes"] == nil, "the provider implements the declared send-only text selector")
        check(!hasWindow("NotesCopilot") && !hasWindow("NotesCopilot 设置"), "a service launch leaves the ordinary windows closed")
        if ProcessInfo.processInfo.environment["NC_TEST_SYSTEM_SERVICE"] == "1" {
            try await checkServiceDispatch(service)
        }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let selected = "下周三，我们会就测试反馈进行一次讨论。"
        source.string = "资料草稿\n" + selected + "\n待补充"
        let range = (source.string as NSString).range(of: selected)
        var error: NSString?
        for editable in [true, false] {
            source.isEditable = editable
            source.isSelectable = true
            source.setSelectedRange(range)
            board.clearContents()
            let supported = sendTypes.filter { source.validRequestor(forSendType: $0, returnType: nil) != nil }
            check(!supported.isEmpty && source.writeSelection(to: board, types: supported),
                  "native text view negotiates and exports its selection, editable=\(editable)")
            service.openSelectionWritingTools(board, userData: nil, error: &error)
            check(error == nil && service.isServiceSession && service.original == selected && service.phase == .menu
                  && !service.hasNotesTarget && service.formats.isEmpty && !service.canWrite,
                  "service opens the selected excerpt with copy-only capabilities, editable=\(editable)")
        }
        SelectionWatcher.shared.stop()
        check(service.isServiceSession, "disabling Notes automatic selection leaves the explicit service available")
        board.clearContents()
        board.setString(" \n ", forType: .string)
        service.openSelectionWritingTools(board, userData: nil, error: &error)
        check(error != nil && service.original == selected, "whitespace is rejected without replacing an open review")
        service.hide()
        await checkToolShortcuts(excerpt: selected)

        let element = AXUIElementCreateApplication(12345)
        let snapshot = NotesBridge.SelectionSnapshot(element: element, range: CFRange(location: range.location, length: range.length),
            text: selected, bounds: .zero, noteID: "writing-fixture", documentText: source.string)
        var current: NotesBridge.SelectionSnapshot? = snapshot
        var reads = 0, writes = 0
        var writtenRange: NSRange?
        var writtenText = ""
        let bridge = NotesBridge(snapshotReader: { reads += 1; return current }, replacementWriter: { _, range, text, _ in
            writes += 1
            writtenRange = NSRange(location: range.location, length: range.length)
            writtenText = text
            return nil
        })
        var inputs: [String] = []
        let candidate = "下周三讨论测试反馈。"
        let request = SelectionAIRequest(complete: { _, text in inputs.append(text); return candidate })
        let tools = SelectionAIPanel(request: request, notes: bridge, formatTitles: { ["Title", "Body"] })
        defer { tools.hide() }
        tools.showLauncher(at: .init(element: element, range: snapshot.range, bounds: nil))
        check(reads == 0 && inputs.isEmpty && tools.phase == .launcher && !tools.panelIsKey,
              "a passive Notes button takes no focus, reads no document and sends no request")
        if let launcher = NSApp.windows.compactMap({ $0.isVisible ? $0.contentView as? SelectionLauncherButton : nil }).first {
            check(launcher.attributedTitle.string.hasSuffix("M") && launcher.accessibilityLabel() == "Copilot 写作工具",
                  "the launcher labels its shortcut visually and exposes its action to Accessibility")
            try captureSelectionPreview("selection-launcher", view: launcher)
        }
        tools.openTools()
        check(tools.formats.map(\.menuTitle) == ["标题", "正文"] && inputs.isEmpty,
              "opening Notes tools binds the selection and exposes only the host's formats")
        try checkToolWindow("selection-menu", width: 340)
        let edit = selectionQuickActions.first { $0.name == "精简" }!
        tools.run(edit)
        await request.task?.value
        check(inputs == [selected] && tools.result == candidate && tools.canWrite && writes == 0, "generation previews a result without writing")
        try checkToolWindow("selection-review", width: 420)
        tools.showingOriginal = true
        tools.writeResult(append: false)
        tools.copyPreview(to: board)
        check(!tools.canWrite && writes == 0 && board.string(forType: .string) == selected,
              "original preview copies the source and cannot commit the candidate")
        tools.showingOriginal = false
        tools.copyPreview(to: board)
        check(board.string(forType: .string) == candidate, "result preview copies the displayed candidate")
        current = nil
        tools.writeResult(append: false)
        check(writes == 0 && tools.staleSelection && !tools.canWrite && tools.result == candidate,
              "a switched Notes target leaves the draft available only for copying")

        board.clearContents()
        board.setString(selected, forType: .string)
        tools.openSelectionWritingTools(board, userData: nil, error: &error)
        let readsBeforeService = reads
        tools.run(edit)
        await request.task?.value
        tools.writeResult(append: true)
        check(tools.phase == .review && tools.result == candidate && !tools.canWrite && writes == 0
              && reads == readsBeforeService, "global review neither reads Notes nor reaches the Notes writer")
        tools.chooseAnotherTool()
        check(tools.phase == .menu && tools.original == selected && tools.result.isEmpty,
              "choosing another action reuses the original service selection")

        current = snapshot
        for append in [false, true] {
            tools.showLauncher(at: .init(element: element, range: snapshot.range, bounds: nil))
            tools.openTools()
            tools.run(edit)
            await request.task?.value
            let before = writes
            sendToolKey(append ? "a" : "r", code: append ? 0 : 15)
            let expectedRange = append ? NSRange(location: NSMaxRange(range), length: 0) : range
            check(writes == before + 1 && writtenRange == expectedRange && writtenText == candidate,
                  "explicit Notes confirmation writes the reviewed draft once to its bound range, append=\(append)")
        }
    }

    /// Deliver through the app so AppKit dispatches to the real key window and its field editor.
    static func sendToolKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "NotesCopilot 写作工具" }),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: text, charactersIgnoringModifiers: text,
                                           isARepeat: repeating, keyCode: code) else { return }
        NSApp.sendEvent(event)
    }

    private static func checkToolShortcuts(excerpt: String) async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(excerpt, forType: .string)
        var instructions: [String] = []
        let request = SelectionAIRequest { instruction, _ in
            instructions.append(instruction)
            return "工具结果"
        }
        let panel = SelectionAIPanel(request: request)
        defer { panel.hide() }
        panel.openSelectionWritingTools(board, userData: nil, error: nil)
        settle()
        guard let window = NSApp.windows.first(where: { $0.isKeyWindow && $0.title == "NotesCopilot 写作工具" }) else {
            check(false, "the tool menu takes keyboard focus")
            return
        }
        check(window.firstResponder as? NSTextView == nil, "the menu opens ready for command letters")
        let shortcuts: [(String, UInt16, String)] = [
            ("t", 17, "翻译"), ("p", 35, "校对"), ("r", 15, "润色"), ("c", 8, "精简"), ("s", 1, "总结"), ("e", 14, "解释")
        ]
        for (letter, code, title) in shortcuts {
            let previous = instructions.count
            sendToolKey(letter, code: code)
            sendToolKey(letter, code: code, repeating: true)
            await request.task?.value
            check(panel.phase == .review && instructions.count == previous + 1 &&
                  instructions.last == selectionQuickActions.first(where: { $0.name == title })?.instruction,
                  "the displayed \(letter.uppercased()) key runs \(title) once")
            sendToolKey("b", code: 11)
            check(panel.phase == .menu && panel.original == excerpt, "B returns to the same excerpt after \(title)")
        }
        sendToolKey("T", code: 17, modifiers: .shift)
        check(panel.phase == .menu, "modified letters do not dispatch a bare command")
        sendToolKey("i", code: 34)
        guard let editor = window.firstResponder as? NSTextView, editor.isEditable else {
            check(false, "I assigns the keyboard to the instruction field")
            return
        }
        sendToolKey("i", code: 34, repeating: true)
        sendToolKey("t", code: 17)
        sendToolKey("i", code: 34)
        check(panel.phase == .menu && panel.customInstruction == "ti", "the editor receives shortcut letters and ignores repeat from the opening I")
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        sendToolKey("\u{1b}", code: 53)
        check(window.isVisible && window.firstResponder === editor && panel.phase == .menu,
              "Escape during marked input leaves editing with the input method")
        if editor.hasMarkedText() { editor.unmarkText() }
        sendToolKey("\u{1b}", code: 53)
        check(window.firstResponder !== editor && panel.phase == .menu, "Escape leaves editing and keeps the tools open")
        sendToolKey("i", code: 34)
        if let input = window.firstResponder as? NSTextView {
            input.insertText("请保留原意 ti", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
        }
        let draft = panel.customInstruction
        sendToolKey("\r", code: 36)
        await request.task?.value
        check(!draft.isEmpty && panel.phase == .review && instructions.last == draft, "Return submits the typed custom instruction")
        sendToolKey("o", code: 31)
        check(panel.showingOriginal, "O switches the review to the source text")
        sendToolKey("r", code: 15)
        sendToolKey("a", code: 0)
        check(!panel.canWrite && panel.phase == .review && !panel.writing, "A and R respect a read-only review")
        let count = instructions.count
        sendToolKey("g", code: 5)
        await request.task?.value
        check(instructions.count == count + 1 && instructions.last == draft && !panel.showingOriginal, "G regenerates the same instruction")
        sendToolKey("\u{1b}", code: 53)
        check(!window.isVisible, "Escape outside the editor closes the review")
    }

    private static func checkToolWindow(_ name: String, width: CGFloat) throws {
        settle()
        guard let view = NSApp.windows.first(where: { $0.title == "NotesCopilot 写作工具" && $0.isVisible })?.contentView else {
            check(false, "missing native panel for \(name)")
            return
        }
        check(view.bounds.width == width && view.bounds.height > 100 && view.bounds.size == view.fittingSize,
              "\(name) fits its real native panel at \(Int(view.bounds.width)) × \(Int(view.bounds.height))")
        try captureSelectionPreview(name, view: view)
    }

    private static func captureSelectionPreview(_ name: String, view: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["NC_SELECTION_PREVIEWS"], let window = view.window else { return }
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, suffix) in [(originalAppearance, ""), (NSAppearance(named: .aqua), "-light"), (NSAppearance(named: .darkAqua), "-dark")] {
            window.appearance = appearance
            settle()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + suffix + ".png"))
        }
    }

    private static func runTests(_ app: NSApplication) async {
        guard !NSScreen.screens.isEmpty else {
            print("UNAVAILABLE  No WindowServer screen connection; lifecycle assertions were not run.")
            exit(77)
        }
        let leftArea = NSRect(x: 0, y: 1085, width: 771, height: 32)
        let rightArea = NSRect(x: 956, y: 1085, width: 772, height: 32)
        check(AppDelegate.statusFrameOverlapsNotch(NSRect(x: 859, y: 1084, width: 38, height: 33), leftArea: leftArea, rightArea: rightArea),
              "observed status item frame is recognized as obscured by the notch")
        check(!AppDelegate.statusFrameOverlapsNotch(NSRect(x: 956, y: 1085, width: 38, height: 32), leftArea: leftArea, rightArea: rightArea),
              "status item in the right safe area is not obscured by the notch")
        check(!AppDelegate.statusFrameOverlapsNotch(NSRect(x: 800, y: 400, width: 500, height: 600), leftArea: leftArea, rightArea: rightArea),
              "ordinary content below the menu bar is not obscured by the notch")
        check(!AppDelegate.statusFrameOverlapsNotch(NSRect(x: 859, y: 1084, width: 38, height: 33), leftArea: nil, rightArea: nil),
              "screen without auxiliary areas has no notch obstruction")
        do {
            let configured = try launch(configured: true)
            check(hasWindow("NotesCopilot"), "configured cold launch displays the main panel")
            let panel = app.windows.first(where: { $0.title == "NotesCopilot" })!
            check(!KeywordListener.shared.isRunning && !AXSlashWatcher.shared.isRunning && !SelectionWatcher.shared.isRunning,
                  "test launch does not start keyboard, AX, or selection services")

            closeWindows()
            let handled = (configured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: false)
            settle()
            check(handled != nil && hasWindow("NotesCopilot"), "reopening the running app restores a closed main panel")

            _ = (configured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: true)
            settle()
            check(hasWindow("NotesCopilot"), "reopening an already visible app does not toggle its panel away")

            panel.miniaturize(nil)
            settle()
            let wasMiniaturized = panel.isMiniaturized
            _ = (configured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: false)
            settle()
            check(wasMiniaturized && panel.isVisible && !panel.isMiniaturized,
                  "reopening the running app restores a minimized main panel")

            moveOffscreen(panel)
            let wasOffscreen = !reachable(panel)
            _ = (configured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: true)
            settle()
            check(wasOffscreen && reachable(panel), "reopening restores an offscreen panel title bar to a screen")

            let ordinaryFrame = panel.frame
            var oversizedFrame = ordinaryFrame
            oversizedFrame.size.height = NSScreen.screens[0].visibleFrame.height + 200
            panel.setFrame(oversizedFrame, display: false)
            moveOffscreen(panel)
            _ = (configured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: true)
            settle()
            check(reachable(panel), "oversized panel recovery keeps its title bar inside a screen")
            panel.setFrame(ordinaryFrame, display: false)

            closeWindows()
            let action = app.sendAction(Selector(("showPanel")), to: configured, from: nil)
            settle()
            check(action && hasWindow("NotesCopilot"), "Open Panel menu action displays a closed panel")

            configured.engine.output = "Synthetic preserved result"
            configured.engine.noteContext = "Synthetic preserved context"
            let showAgain = app.sendAction(Selector(("showPanel")), to: configured, from: nil)
            settle()
            check(showAgain && panel.isVisible && !panel.isMiniaturized,
                  "Open Panel menu action keeps an already visible panel open")
            check(configured.engine.output == "Synthetic preserved result" && configured.engine.noteContext == "Synthetic preserved context",
                  "Open Panel menu action preserves current result and context")

            panel.miniaturize(nil)
            settle()
            let minimizedBeforeToggle = panel.isMiniaturized
            let toggleAction = app.sendAction(Selector(("togglePanel")), to: configured, from: nil)
            settle()
            check(minimizedBeforeToggle && toggleAction && panel.isVisible && !panel.isMiniaturized,
                  "hotkey toggle action restores a minimized panel")

            configured.engine.output = "Synthetic preserved result"
            configured.engine.noteContext = "Synthetic preserved context"
            configured.showSettings()
            settle()
            check(hasWindow("NotesCopilot 设置") && !panel.isVisible,
                  "opening settings hides the floating main panel")
            check(configured.engine.output == "Synthetic preserved result" && configured.engine.noteContext == "Synthetic preserved context",
                  "opening settings preserves current result and context")

            let unconfigured = try launch(configured: false)
            check(hasWindow("NotesCopilot 设置") && !hasWindow("NotesCopilot"), "unconfigured cold launch displays settings")
            let settings = app.windows.first(where: { $0.title == "NotesCopilot 设置" && $0.isVisible })!
            closeWindows()
            _ = (unconfigured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: false)
            settle()
            check(hasWindow("NotesCopilot 设置") && !hasWindow("NotesCopilot"), "unconfigured reopen restores settings")

            settings.miniaturize(nil)
            settle()
            let minimizedSettings = settings.isMiniaturized
            _ = (unconfigured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: false)
            settle()
            check(minimizedSettings && settings.isVisible && !settings.isMiniaturized, "unconfigured reopen restores minimized settings")

            moveOffscreen(settings)
            let settingsOffscreen = !reachable(settings)
            _ = (unconfigured as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: true)
            settle()
            check(settingsOffscreen && reachable(settings), "unconfigured reopen restores offscreen settings")
            try await checkWritingTools()
            try await checkGlobalInputFields()
        } catch {
            check(false, "launch harness error: \(error.localizedDescription)")
        }
        closeWindows()
        print("NOTE  选区检查使用合成文稿与确定性的模型响应。")
        print(failed == 0 ? "全部通过：\(passed) 项" : "失败 \(failed) 项 / 共 \(passed + failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
