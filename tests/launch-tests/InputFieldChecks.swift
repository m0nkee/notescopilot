import AppKit
import ApplicationServices

extension LaunchTests {
    static func checkGlobalInputFields() async throws {
        guard let executable = ProcessInfo.processInfo.environment["NC_INPUT_FIELD_FIXTURE"] else { return }
        guard AXIsProcessTrusted() else {
            check(false, "cross-process input-field tests require Accessibility for the test runner")
            return
        }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("nc-input-\(UUID()).json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = [report.path]
        let commands = Pipe()
        child.standardInput = commands
        try child.run()
        defer {
            try? commands.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            try? FileManager.default.removeItem(at: report)
        }
        func waitFor(_ name: String, until predicate: () -> Bool) async throws {
            for _ in 0..<150 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw NSError(domain: "InputFieldTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + name])
        }
        func state() -> [String: String] {
            guard let data = try? Data(contentsOf: report) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        func send(_ command: String) async throws {
            try commands.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            try await waitFor(command) { state()["command"] == command }
        }
        try await waitFor("native fixture launch") { state()["command"] == "ready" }
        guard let host = NSRunningApplication(processIdentifier: child.processIdentifier) else {
            check(false, "native fixture has a process identity")
            return
        }
        let suite = "nc.input-fields.\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defer { prefs.removePersistentDomain(forName: suite) }
        let candidate = "新文字"
        let sample = "开头🙂 目标 / 目标 结尾"
        var requests: [String] = []
        var delayTranslation = false
        let request = SelectionAIRequest { _, excerpt in
            requests.append(excerpt)
            if delayTranslation { try await Task.sleep(nanoseconds: 1_200_000_000) }
            return excerpt == "这是什么？" ? "What is this?" : candidate
        }
        let panel = SelectionAIPanel(request: request, defaults: prefs)
        // Only the synthetic host is eligible for inspection, even if another app becomes active.
        let watcher = SelectionWatcher(panel: panel, defaults: prefs) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier ? host : nil
        }
        defer { watcher.stop() }
        try await send("first")
        try await waitFor("native fixture focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier }
        watcher.startIfNeeded()
        try await Task.sleep(nanoseconds: 680_000_000)
        check(SelectionScope.current(in: prefs) == .notes && !panel.isInputSession && requests.isEmpty,
              "default Notes scope ignores a real external text selection")
        check(!panel.openFromHostShortcut(), "M passes through when no launcher is visible")
        prefs.set(SelectionScope.global.rawValue, forKey: SelectionScope.defaultsKey)
        watcher.scopeDidChange()
        let action = selectionQuickActions.first { $0.name == "精简" }!

        let translate = selectionQuickActions.first { $0.name == "翻译" }!
        try await send("readonly")
        try await waitFor("read-only translation launcher") { panel.isInputSession && panel.phase == .launcher }
        panel.openTools()
        let toolWindow = NSApp.windows.first { $0.isVisible && $0.title == "NotesCopilot 写作工具" }
        let menuFrame = toolWindow?.frame
        delayTranslation = true
        panel.run(translate)
        check(menuFrame != nil && toolWindow?.frame == menuFrame, "the progress panel keeps the menu frame under the pointer")
        let pendingTranslation = request.task
        // Chromium republishes the same visible words through a different range
        // when focus leaves the document. There is no new user selection gesture.
        try await send("republishReadonly")
        try await Task.sleep(nanoseconds: 650_000_000)
        check(panel.phase == .working, "a republished read-only range cannot cancel an in-flight translation")
        await pendingTranslation?.value
        delayTranslation = false
        try await send("readonly")
        try await Task.sleep(nanoseconds: 500_000_000)
        let translated = NSPasteboard.withUniqueName()
        panel.copyPreview(to: translated)
        check(panel.phase == .review && translated.string(forType: .string) == candidate && !panel.hasReplacementTarget,
              "the read-only translation stays visible and copyable after another renderer update")
        translated.releaseGlobally()
        panel.dismiss()
        try await Task.sleep(nanoseconds: 650_000_000)
        check(!panel.isInputSession && !panel.openFromHostShortcut(), "closing a tool does not rearm M on the unchanged selection")
        panel.hide()
        watcher.scopeDidChange()
        try await send("first")
        try await waitFor("editable launcher before focus moves to the tool") { panel.isInputSession && panel.phase == .launcher }
        check(panel.openFromHostShortcut(), "M opens a confirmed editable selection")
        try await waitFor("keyboard-opened editable menu") { panel.phase == .menu }
        try await send("readonly")
        try await Task.sleep(nanoseconds: 700_000_000)
        check(panel.phase == .menu && panel.original == "目标" && panel.hasReplacementTarget,
              "a read-only range republished by the host cannot displace the keyboard-opened editor menu")
        panel.hide()
        watcher.scopeDidChange()
        for (control, collapse, excerpt) in [("translateDraft", "collapse", "这是什么？"), ("webStatic", "collapseWeb", "目标")] {
            try await send(control)
            try await waitFor("launcher before the host redraws") { panel.phase == .launcher && panel.isInputSession }
            let count = requests.count
            try await send(collapse)
            try await Task.sleep(nanoseconds: 650_000_000)
            check(panel.phase == .launcher && panel.isInputSession && requests.count == count,
                  "the passive launcher survives a renderer clearing its selection, " + control)
            panel.openTools()
            check(panel.phase == .menu && panel.original == excerpt && !panel.hasReplacementTarget,
                  "a click after selection loss opens the captured excerpt for reading, " + control)
            panel.run(translate)
            await request.task?.value
            check(requests.count == count + 1 && requests.last == excerpt && !panel.canWrite,
                  "only an explicit action processes the detached excerpt, " + control)
            panel.hide()
            watcher.scopeDidChange()
        }
        try await send("translateDraft")
        try await waitFor("launcher before secure focus") { panel.isInputSession && panel.phase == .launcher }
        try await send("password")
        try await Task.sleep(nanoseconds: 480_000_000)
        check(!panel.isInputSession, "a pending excerpt is dismissed when focus moves to a secure field")
        try await send("first")
        try await waitFor("launcher before the range recovers") { panel.isInputSession && panel.phase == .launcher }
        try await send("collapse")
        try await Task.sleep(nanoseconds: 500_000_000)
        try await send("first")
        try await Task.sleep(nanoseconds: 450_000_000)
        panel.openTools()
        check(panel.phase == .menu && panel.original == "目标" && panel.hasReplacementTarget,
              "a recovered live range retains its normal editing actions")
        panel.hide()
        watcher.scopeDidChange()
        try await send("translateDraft")
        try await waitFor("translation launcher") { panel.isInputSession && panel.phase == .launcher }
        check(panel.openFromHostShortcut(), "the visible external launcher accepts its M shortcut")
        try await waitFor("shortcut opens the same menu as a click") { panel.phase == .menu }
        check(!panel.openFromHostShortcut(), "M returns to text input once the menu is open")
        check(panel.phase == .menu && panel.original == "这是什么？", "translation menu captured the five-character excerpt")
        try await send("collapse")
        try await Task.sleep(nanoseconds: 480_000_000)
        // The fixture deliberately reactivates the source to collapse its range.
        // Re-enter the tool window before sending a panel-local shortcut.
        NSApp.windows.first { $0.isVisible && $0.title == "NotesCopilot 写作工具" }?.makeKeyAndOrderFront(nil)
        sendToolKey("t", code: 17)
        await request.task?.value
        let copy = NSPasteboard.withUniqueName()
        panel.copyPreview(to: copy)
        check(panel.phase == .review && requests.last == "这是什么？" && copy.string(forType: .string) == "What is this?",
              "translation survives a collapsed host selection, including watcher polls before the action")
        copy.releaseGlobally()
        panel.writeResult(append: true)
        try await waitFor("refuse stale translation write") { !panel.writing }
        try await send("inspect-translation")
        check(state()["first"] == "草稿：这是什么？" && !panel.canWrite, "a detached translation cannot write into the host")

        try await send("second")
        try await Task.sleep(nanoseconds: 750_000_000)
        check(panel.phase == .launcher && panel.isInputSession, "a new selection reopens the launcher after a detached result")
        panel.hide()
        watcher.scopeDidChange()
        try await send("first")

        func prepareReview(clickLauncher: Bool = false, writable: Bool = true, hoverMenu: Bool = false) async throws {
            do {
                try await waitFor("automatic external launcher") { panel.isInputSession && panel.phase == .launcher }
            } catch {
                let app = AXUIElementCreateApplication(host.processIdentifier)
                if let field = AXText.element(app, kAXFocusedUIElementAttribute) {
                    let role = AXText.attribute(field, kAXRoleAttribute) as? String ?? "unknown"
                    var selectedTextWritable = DarwinBoolean(false)
                    AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &selectedTextWritable)
                    print("FIXTURE", state()["command"] ?? "unknown", role, "range", String(describing: AXText.range(of: field)),
                          "selectedTextWritable", selectedTextWritable.boolValue, "front", host.isActive)
                }
                throw error
            }
            let count = requests.count
            if clickLauncher, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "NotesCopilot 写作工具" }) {
                guard let content = window.contentView,
                      let button = content.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) as? NSButton,
                      button.acceptsFirstMouse(for: nil), !button.needsPanelToBecomeKey else {
                    throw NSError(domain: "InputFieldTests", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The nonactivating launcher cannot receive the first click"])
                }
                button.performClick(nil)
                try await waitFor("clicking the native automatic launcher") { panel.phase == .menu }
            } else {
                panel.openTools()
            }
            if hoverMenu, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "NotesCopilot 写作工具" }),
               let screen = NSScreen.screens.first, let previous = CGEvent(source: nil)?.location {
                let point = CGPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
                CGWarpMouseCursorPosition(point)
                defer { if CGEvent(source: nil)?.location == point { CGWarpMouseCursorPosition(previous) } }
                try await Task.sleep(nanoseconds: 800_000_000)
                check(panel.containsPointer && panel.phase == .menu && panel.original == "目标",
                      "hovering inside an open read-only menu does not rediscover the web page behind it")
            }
            check(panel.phase == .menu && panel.original == "目标" && !panel.hasNotesTarget && panel.formats.isEmpty
                  && requests.count == count, "opening a global tool binds only the selected excerpt and waits for an action")
            panel.run(action)
            await request.task?.value
            check(requests.count == count + 1 && requests.last == "目标" && panel.result == candidate
                  && panel.canWrite == writable && panel.hasReplacementTarget == writable,
                  "the confirmed excerpt and write actions match the host's capabilities")
        }
        for field in ["first", "multiline", "webInput", "webArea", "webRich"] {
            if field != "first" { try await send(field) }
            try await prepareReview()
            try await send("inspect-" + field)
            check(state()[field] == sample, "the host remains untouched before confirmation, " + field)
            panel.writeResult(append: false)
            try await waitFor("finish replacement") { !panel.writing }
            try await send("result-" + field)
            let actual = state()[field]
            let replaced = (actual == "开头🙂 目标 / 新文字 结尾" || (field == "webRich" && actual == "开头🙂 目标 / 新文字\u{00A0}结尾")) && !panel.isInputSession
            check(replaced, "external " + field + " replaces only the selected duplicate and preserves adjacent Unicode")
            if !replaced {
                print("FIXTURE", field, "status", panel.status, "synthetic field", state()[field] ?? "missing")
                panel.hide()
                watcher.scopeDidChange()
            }
            if replaced && field.hasPrefix("web") {
                check(state()["edits"] == "1", "the web page receives one native input event, " + field)
                try await send("undoWeb")
                check(state()[field] == sample, "native browser Undo restores the original field, " + field)
            }
        }

        for field in ["first", "webArea", "webRich"] {
            try await send(field)
            try await prepareReview()
            panel.writeResult(append: true)
            try await waitFor("finish append") { !panel.writing }
            try await send("appended-" + field)
            let actual = state()[field]
            let appended = actual == "开头🙂 目标 / 目标新文字 结尾" || (field == "webRich" && actual == "开头🙂 目标 / 目标新文字\u{00A0}结尾")
            check(appended && !panel.isInputSession,
                  "append inserts at the selected occurrence and preserves the suffix, " + field)
            if !appended || panel.isInputSession { print("FIXTURE", field, "append status", panel.status, "synthetic field", actual ?? "missing") }
            if field == "webRich" {
                check(state()["bold"] == "目标", "append preserves the existing selected rich text")
            }
            panel.hide()
            watcher.scopeDidChange()
        }

        for change in ["move", "second", "editAround", "webInput"] {
            try await send("first")
            try await prepareReview()
            try await send(change)
            panel.writeResult(append: false)
            try await waitFor("refuse changed selection") { !panel.writing }
            try await send("inspect-" + change)
            let expected = change == "editAround" ? "另文🙂 目标 / 目标 结尾" : sample
            check(state()["first"] == expected && state()["second"] == sample
                  && (change != "webInput" || state()["webInput"] == sample) && panel.staleSelection
                  && !panel.canWrite && panel.result == candidate, "focus, range and content changes keep the draft copy-only: " + change)
            panel.hide()
            watcher.scopeDidChange()
        }
        try await send("first")
        try await prepareReview()
        prefs.set(SelectionScope.notes.rawValue, forKey: SelectionScope.defaultsKey)
        panel.writeResult(append: false)
        watcher.scopeDidChange()
        try await send("inspect-scope")
        check(state()["first"] == sample && !panel.isInputSession, "switching back to Notes withdraws external write permission immediately")
        prefs.set(SelectionScope.global.rawValue, forKey: SelectionScope.defaultsKey)
        for control in ["readonly", "webReadonly", "webStatic"] {
            watcher.scopeDidChange()
            try await send(control)
            try await prepareReview(clickLauncher: control == "readonly", writable: false, hoverMenu: control == "webStatic")
            let clipboard = NSPasteboard.withUniqueName()
            panel.copyPreview(to: clipboard)
            check(clipboard.string(forType: .string) == candidate, "read-only selection can copy its result, " + control)
            clipboard.releaseGlobally()
            panel.writeResult(append: false)
            panel.writeResult(append: true)
            try await send("inspect-" + control)
            check(!panel.writing && state()[control] == sample, "read-only source is unchanged, " + control)
            panel.hide()
        }
        for control in ["password", "webPassword"] {
            watcher.scopeDidChange()
            try await send(control)
            try await Task.sleep(nanoseconds: 660_000_000)
            check(InputFieldBridge.anchor(in: host) == nil && !panel.isInputSession,
                  "automatic tools skip the native " + control + " control")
        }
    }
}
