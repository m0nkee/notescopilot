import AppKit
import ApplicationServices
import Carbon.HIToolbox

extension LaunchTests {
    static func checkGlobalInputFields() async throws {
        guard let executable = ProcessInfo.processInfo.environment["NC_INPUT_FIELD_FIXTURE"] else { return }
        // Only an explicitly interactive run should prompt on the user's desktop.
        let prompt = ProcessInfo.processInfo.environment["NC_REQUEST_TEST_ACCESSIBILITY"] == "1"
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
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
        var instructions: [String] = []
        var delayTranslation = false
        let request = SelectionAIRequest { instruction, excerpt in
            instructions.append(instruction)
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
        check(!panel.openFromHostShortcut(in: host), "the shortcut cannot open outside the default Notes scope")
        watcher.stop()
        do {
            let listener = KeywordListener.shared
            let defaults = UserDefaults.standard
            let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            let hostID = host.bundleIdentifier ?? "local.notescopilot.input-field-fixture"
            var arguments = oldArguments
            arguments[SelectionScope.enabledKey] = true
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            prefs.set(SelectionScope.global.rawValue, forKey: SelectionScope.defaultsKey)
            prefs.set(SelectionScope.PrivacyMode.allowlist.rawValue, forKey: SelectionScope.PrivacyMode.defaultsKey)
            prefs.set([hostID], forKey: SelectionScope.privacyAppsKey)
            listener.hostShortcutTestPanel = panel
            defer {
                listener.stop()
                listener.hostShortcutTestPanel = nil
                defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
                prefs.removeObject(forKey: SelectionScope.PrivacyMode.defaultsKey)
                prefs.removeObject(forKey: SelectionScope.privacyAppsKey)
                panel.hide()
            }
            listener.startIfNeeded()
            check(listener.isRunning, "the real keyboard listener starts for the isolated host")
            let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            func inputProperty(_ key: CFString) -> String? {
                guard let inputSource, let raw = TISGetInputSourceProperty(inputSource, key) else { return nil }
                return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            }
            let inputMode = inputProperty(kTISPropertyInputSourceID) ?? "unknown"
            let directKeyboard = inputProperty(kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String
            print("NOTE  real double-M test input source: " + inputMode)

            func prepareHost(_ command: String) async throws {
                let restoring = panel.panelIsKey
                panel.hide()
                if restoring {
                    host.activate()
                    try await waitFor("focus restoration after closing the review") {
                        !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
                    }
                }
                try await send(command)
                try await waitFor("keyboard fixture focus") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
                }
            }
            let keySource = CGEventSource(stateID: .hidSystemState)
            func postHostKey(_ code: CGKeyCode, _ letter: String?, down: Bool,
                             flags: CGEventFlags = [], repeating: Bool = false) throws {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier else {
                    throw NSError(domain: "InputFieldTests", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "The keyboard fixture lost focus before posting a test key."])
                }
                let event = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down)!
                if let letter {
                    let units = Array(letter.utf16)
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                }
                event.flags = flags
                event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
                event.post(tap: .cghidEventTap)
            }
            func typeHostKeys(_ keys: [(CGKeyCode, String)], useKeyboardLayout: Bool = false) async throws {
                for (code, letter) in keys {
                    try postHostKey(code, useKeyboardLayout ? nil : letter, down: true)
                    try postHostKey(code, useKeyboardLayout ? nil : letter, down: false)
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            let m: (CGKeyCode, String) = (46, "m")
            try await prepareHost("shortcutDraft")
            try await typeHostKeys([m])
            try await Task.sleep(nanoseconds: 500_000_000)
            try await send("inspect-single-m")
            check(!panel.panelIsKey && state()["shortcutKeys"] == "m" && (!directKeyboard || state()["first"] == "fixture m"),
                  "the event tap preserves an ordinary single M")
            try await prepareHost("shortcutDraft")
            try await typeHostKeys([m, (0, "a"), m])
            try await Task.sleep(nanoseconds: 500_000_000)
            try await send("inspect-intervening-key")
            check(!panel.panelIsKey && state()["shortcutKeys"] == "mam" && (!directKeyboard || state()["first"] == "fixture mam"),
                  "the event tap does not reorder ordinary typing")
            try await prepareHost("shortcutDraft")
            try postHostKey(46, "m", down: true)
            try await Task.sleep(nanoseconds: 65_000_000)
            try postHostKey(46, "m", down: true, repeating: true)
            try await Task.sleep(nanoseconds: 65_000_000)
            try postHostKey(46, "m", down: true, repeating: true)
            try postHostKey(46, "m", down: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            try await send("inspect-held-m")
            check(!panel.panelIsKey && state()["shortcutKeys"] == "mmm",
                  "holding M preserves the original key and the host's repeats")
            try await prepareHost("shortcutDraft")
            for _ in 0..<2 {
                try postHostKey(46, "M", down: true, flags: .maskShift)
                try postHostKey(46, "M", down: false, flags: .maskShift)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await send("inspect-shift-m")
            check(!panel.panelIsKey && state()["shortcutKeys"]?.count == 2,
                  "two modified M presses are delivered only as normal keyboard events")

            for (policyKey, policyValue, inspection) in [
                (SelectionScope.pausedKey, true as Any, "paused"),
                (SelectionScope.privacyAppsKey, [] as [String] as Any, "excluded")
            ] {
                try await prepareHost("shortcutDraft")
                prefs.set(policyValue, forKey: policyKey)
                try await typeHostKeys([m, m])
                try await Task.sleep(nanoseconds: 500_000_000)
                try await send("inspect-" + inspection)
                check(!panel.panelIsKey && state()["shortcutKeys"] == "mm" && (!directKeyboard || state()["first"] == "fixture mm"),
                      "two ordinary Ms pass through when the source is " + inspection)
                prefs.removeObject(forKey: SelectionScope.pausedKey)
                prefs.set([hostID], forKey: SelectionScope.privacyAppsKey)
            }

            try await prepareHost("password")
            check(!panel.canReceiveHostShortcut(in: host), "the actual focused secure field is ineligible for the shortcut")
            try await typeHostKeys([m, m])
            try await Task.sleep(nanoseconds: 500_000_000)
            check(!panel.panelIsKey, "the keyboard tap cannot open a tool in a secure field")

            try await prepareHost("compositionDraft")
            let axHost = AXUIElementCreateApplication(child.processIdentifier)
            let markedField = AXText.element(axHost, kAXFocusedUIElementAttribute)
            check(state()["hasMarkedText"] == "true" && markedField.map(AXText.isComposing) == true,
                  "the fixture makes active native marked text visible to the listener")
            try await typeHostKeys([m, m])
            try await Task.sleep(nanoseconds: 500_000_000)
            try await send("inspect-composition")
            check(!panel.panelIsKey && state()["shortcutKeys"] == "mm",
                  "active marked text receives both ordinary Ms without opening the tool")

            try await prepareHost("first")
            try await typeHostKeys([m, m], useKeyboardLayout: true)
            try await waitFor("double-M selection menu") { panel.panelIsKey && panel.phase == .menu }
            try await send("inspect-double-m-selection")
            check(panel.original == "目标" && panel.hasReplacementTarget && !panel.isStandaloneSession
                  && state()["first"] == sample && state()["shortcutKeys"] == "",
                  "double M opens the selected text menu and consumes only the shortcut in " + inputMode)

            func openStandaloneReview(usingKeyboard: Bool) async throws {
                try await prepareHost("shortcutDraft")
                let app = AXUIElementCreateApplication(child.processIdentifier)
                guard let field = AXText.element(app, kAXFocusedUIElementAttribute) else {
                    throw NSError(domain: "InputFieldTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing draft text field"])
                }
                var caret = CFRange(location: 3, length: 0)
                guard let value = AXValueCreate(.cfRange, &caret),
                      AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                    throw NSError(domain: "InputFieldTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to position the draft caret"])
                }
                try await waitFor("draft caret at offset three") {
                    AXText.range(of: field)?.location == 3 && AXText.range(of: field)?.length == 0
                }
                try await waitFor("shortcut eligibility at the captured caret") {
                    panel.canReceiveHostShortcut(in: host)
                }
                if usingKeyboard {
                    try await typeHostKeys([m, m], useKeyboardLayout: true)
                } else {
                    // The keyboard path is exercised above each set of insertion cases.
                    // Start stale-target cases from the same captured, focused fixture editor.
                    panel.openStandaloneInstruction(returningTo: host)
                }
                try await waitFor("standalone editor to receive focus") { panel.panelIsKey && panel.isStandaloneSession }
                guard let window = NSApp.keyWindow as? SelectionKeyPanel,
                      let editor = window.firstResponder as? NSTextView, editor.isEditable else {
                    throw NSError(domain: "InputFieldTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Double M did not focus the instruction field"])
                }
                editor.insertText("Give me a title", replacementRange: editor.selectedRange())
                sendToolKey("\r", code: 36)
                await request.task?.value
            }

            try await openStandaloneReview(usingKeyboard: true)
            check(requests.last == "" && instructions.last == "Give me a title" && panel.result == candidate,
                  "the instruction excludes the surrounding host draft")
            try await send("inspect-double-m-standalone")
            check(state()["first"] == "fixture " && state()["shortcutKeys"] == "" && !panel.hasReplacementTarget && panel.canInsert,
                  "standalone double M captures the caret without typing trigger letters in " + inputMode)
            await checkResultToolbar(["Edit Instruction", "Regenerate", "Follow Up", "Insert", "Copy Result"],
                               unavailable: ["Append", "Replace"])
            sendToolKey("i", code: 34)
            try await waitFor("standalone insertion") { !panel.writing }
            try await send("inspect-standalone-insertion")
            check(state()["first"] == "fix" + candidate + "ture ",
                  "I inserts the result at the original caret and preserves both sides")

            for movedTarget in ["shortcutDraft", "second"] {
                try await openStandaloneReview(usingKeyboard: false)
                check(panel.canInsert, "the captured caret starts eligible before the host changes")
                try await send("inspect-original-caret-" + movedTarget)
                // shortcutDraft resets the same text field's caret to the end.
                try await send(movedTarget)
                panel.insertResult()
                try await waitFor("refuse changed insertion target") { !panel.writing }
                try await send("inspect-refused-insertion-" + movedTarget)
                check(state()["first"] == "fixture " && state()["second"] == sample && panel.result == candidate,
                      "insertion into a moved caret or another editor is refused, " + movedTarget)
            }
        }
        prefs.set(SelectionScope.global.rawValue, forKey: SelectionScope.defaultsKey)
        try await send("first")
        watcher.startIfNeeded()
        watcher.scopeDidChange()
        let action = selectionQuickActions.first { $0.name == "精简" }!

        if let focused = InputFieldBridge.anchor(in: host), case .input(let editor) = focused.source {
            let initialHit = TextSelectionAnchor(element: focused.element, extent: focused.extent,
                source: .input(InputFieldHost(application: host, window: editor.window, editable: false)))
            let captured = InputFieldBridge.openSelection(initialHit, excerpt: InputFieldBridge.launcherExcerpt(initialHit))
            check(captured?.fieldValue == sample, "opening a pointer-discovered selection recognizes the now-focused editor")
        } else { check(false, "the fixture exposes its focused editor") }
        // Electron retains the field, value and selected range while reporting
        // no focused AX element until the nonactivating results panel closes.
        for append in [false, true] {
            try await send("first")
            guard let anchor = InputFieldBridge.anchor(in: host) else {
                check(false, "focus handoff starts in the editable fixture")
                return
            }
            panel.showLauncher(at: anchor)
            panel.openTools()
            try await send("suspendAXFocus")
            let app = AXUIElementCreateApplication(host.processIdentifier)
            check(AXText.element(app, kAXFocusedUIElementAttribute) == nil, "the fixture reports the Electron focus gap")
            panel.run(action)
            await request.task?.value
            check(panel.canWrite, "the verified selection stays writable while the tool owns focus")
            sendToolKey(append ? "a" : "r", code: append ? 0 : 15)
            check(panel.writing, "the keyboard shortcut immediately starts the write")
            try await Task.sleep(nanoseconds: 65_000_000)
            try await send("restoreAXFocus")
            try await waitFor("write after focus handoff") { !panel.writing }
            try await send("inspect-handoff-" + String(append))
            let expected = append ? "开头🙂 目标 / 目标新文字 结尾" : "开头🙂 目标 / 新文字 结尾"
            check(state()["first"] == expected, "the original field regains focus before the write")
            panel.hide()
        }
        try await send("first")
        if let anchor = InputFieldBridge.anchor(in: host), let original = InputFieldBridge.capture(anchor) {
            try await send("suspendAXFocus")
            try await send("collapse")
            check(!InputFieldBridge.selectionSurvivesFocusHandoff(original),
                  "a collapsed selection remains unwritable during a focus handoff")
            try await send("restoreAXFocus")
        } else { check(false, "the changed-selection test starts in the editable fixture") }
        let serviceBoard = NSPasteboard.withUniqueName()
        defer { serviceBoard.releaseGlobally() }
        for append in [false, true] {
            try await send("first")
            try await waitFor("editable launcher before Services") { panel.phase == .launcher && panel.isInputSession }
            serviceBoard.clearContents()
            serviceBoard.setString("目标", forType: .string)
            panel.openSelectionWritingTools(serviceBoard, userData: nil, error: nil)
            panel.run(action)
            await request.task?.value
            check(panel.canWrite, "Services keeps the verified editable source")
            panel.writeResult(append: append)
            try await waitFor("Services writeback") { !panel.writing }
            try await send("inspect-service-" + String(append))
            check(state()["first"] == (append ? "开头🙂 目标 / 目标新文字 结尾" : "开头🙂 目标 / 新文字 结尾"),
                  "Services writes to the selected duplicate and preserves its surroundings")
            panel.hide()
            watcher.scopeDidChange()
        }
        let translate = selectionQuickActions.first { $0.name == "翻译" }!
        try await send("readonly")
        try await waitFor("read-only translation launcher") { panel.isInputSession && panel.phase == .launcher }
        panel.openTools()
        let toolWindow = NSApp.windows.first { $0.isVisible && $0.title == SelectionLauncherButton.displayName }
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
        check(!panel.isInputSession && !panel.panelIsKey, "closing a tool does not recreate the launcher on the unchanged selection")
        panel.hide()
        watcher.scopeDidChange()
        try await send("first")
        try await waitFor("editable launcher before focus moves to the tool") { panel.isInputSession && panel.phase == .launcher }
        check(panel.openFromHostShortcut(in: host), "a recognized double M opens a confirmed editable selection")
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
        check(panel.openFromHostShortcut(in: host), "the visible external launcher accepts a recognized double M")
        try await waitFor("shortcut opens the same menu as a click") { panel.phase == .menu }
        check(!panel.openFromHostShortcut(in: host), "M returns to text input once the menu is open")
        check(panel.phase == .menu && panel.original == "这是什么？", "translation menu captured the five-character excerpt")
        try await send("collapse")
        try await Task.sleep(nanoseconds: 480_000_000)
        // The fixture deliberately reactivates the source to collapse its range.
        // Re-enter the tool window before sending a panel-local shortcut.
        NSApp.windows.first { $0.isVisible && $0.title == SelectionLauncherButton.displayName }?.makeKeyAndOrderFront(nil)
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
            if clickLauncher, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == SelectionLauncherButton.displayName }) {
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
            if hoverMenu, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == SelectionLauncherButton.displayName }),
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
        for field in ["first", "multiline", "webInput", "webArea", "webRich", "webEditor"] {
            if field != "first" { try await send(field) }
            try await prepareReview()
            try await send("inspect-" + field)
            check(state()[field] == sample, "the host remains untouched before an explicit write action, " + field)
            panel.writeResult(append: false)
            try await waitFor("finish replacement") { !panel.writing }
            try await send("result-" + field)
            let actual = state()[field]
            let replaced = (actual == "开头🙂 目标 / 新文字 结尾" || (["webRich", "webEditor"].contains(field) && actual == "开头🙂 目标 / 新文字\u{00A0}结尾")) && !panel.isInputSession
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

        for field in ["first", "webArea", "webRich", "webEditor"] {
            try await send(field)
            try await prepareReview()
            panel.writeResult(append: true)
            try await waitFor("finish append") { !panel.writing }
            try await send("appended-" + field)
            let actual = state()[field]
            let appended = actual == "开头🙂 目标 / 目标新文字 结尾" || (["webRich", "webEditor"].contains(field) && actual == "开头🙂 目标 / 目标新文字\u{00A0}结尾")
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
