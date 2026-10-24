import Foundation
import AppKit
import Accessibility

var pass = 0, fail = 0, skipped = 0
func check(_ condition: Bool, _ name: String) {
    if condition { pass += 1; print("PASS  \(name)") }
    else { fail += 1; print("FAIL  \(name)") }
}
func skip(_ name: String) { skipped += 1; print("SKIP  \(name)") }

@MainActor
final class CompletionGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

func snapshot(noteID: String = "note-a", text: String = "original", location: Int = 0,
              length: Int? = nil, element: AXUIElement? = nil) -> NotesBridge.SelectionSnapshot {
    let range = CFRange(location: location, length: length ?? text.utf16.count)
    let selected = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    return NotesBridge.SelectionSnapshot(element: element ?? AXUIElementCreateApplication(12345),
                                         range: range, text: selected, bounds: .zero,
                                         noteID: noteID, documentText: text)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    print("FAIL  writeback test timeout")
    exit(1)
}

Task { @MainActor in
    let htmlText = "用于验证中文😀 & < > \" ' 粗体 链接"
    let htmlFragment = "<p>用于验证中文😀 &amp; &lt; &gt; &quot; &#39; <strong>粗体</strong> <a href=\"https://example.invalid/path?a=1&amp;b=2\">链接</a></p>"
    do {
        let decoded = try NSAttributedString(data: NotesBridge.htmlPasteboardData(htmlFragment),
                                            options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        check(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines) == htmlText,
              "public.html bytes decode Chinese emoji and escaped characters without an encoding override")
        let boldRange = (decoded.string as NSString).range(of: "粗体")
        let font = boldRange.location == NSNotFound ? nil : decoded.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        check(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
              "the HTML payload preserves bold styling through the default AppKit importer")
        let linkRange = (decoded.string as NSString).range(of: "链接")
        let link = linkRange.location == NSNotFound ? nil : decoded.attribute(.link, at: linkRange.location, effectiveRange: nil)
        check((link as? URL)?.absoluteString == "https://example.invalid/path?a=1&b=2"
              || link as? String == "https://example.invalid/path?a=1&b=2",
              "the HTML payload preserves the link destination through the default AppKit importer")
    } catch {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == 4099 {
            skip("default AppKit HTML importer is unavailable in this process (NSCocoaErrorDomain 4099); Unicode and styling decoding require an unsandboxed run or real Notes verification")
        } else {
            check(false, "default AppKit HTML importer failed for the Unicode regression: \(error.domain) \(error.code)")
        }
    }

    let isolatedPasteboard = NSPasteboard(name: .init("local.notescopilot.html-writeback-tests." + UUID().uuidString))
    let originalItem = NSPasteboardItem()
    let customType = NSPasteboard.PasteboardType("local.notescopilot.synthetic-data")
    let originalHTML = Data("<b>synthetic original</b>".utf8)
    let originalData = Data([0, 1, 255])
    originalItem.setString("synthetic original", forType: .string)
    originalItem.setData(originalHTML, forType: .html)
    originalItem.setData(originalData, forType: customType)
    isolatedPasteboard.clearContents()
    if isolatedPasteboard.writeObjects([originalItem]) {
        let payloadBridge = NotesBridge()
        let restore = payloadBridge.preparePasteboard(text: htmlText, html: htmlFragment, pasteboard: isolatedPasteboard)
        check(isolatedPasteboard.data(forType: .html) == NotesBridge.htmlPasteboardData(htmlFragment),
              "real pasteboard preparation puts the decoder-tested payload bytes into public.html")
        check(isolatedPasteboard.string(forType: .string) == htmlText,
              "rich pasteboard preparation retains the exact Unicode plain-text fallback")
        restore()
        check(isolatedPasteboard.string(forType: .string) == "synthetic original"
              && isolatedPasteboard.data(forType: .html) == originalHTML && isolatedPasteboard.data(forType: customType) == originalData,
              "rich pasteboard restoration preserves the original text HTML and unrelated data types")
        let staleRestore = payloadBridge.preparePasteboard(text: htmlText, html: htmlFragment, pasteboard: isolatedPasteboard)
        isolatedPasteboard.clearContents()
        isolatedPasteboard.setString("synthetic later copy", forType: .string)
        staleRestore()
        check(isolatedPasteboard.string(forType: .string) == "synthetic later copy" && isolatedPasteboard.data(forType: .html) == nil,
              "a delayed rich pasteboard restore never overwrites a newer clipboard change")
    } else {
        skip("named pasteboard service is unavailable; no general clipboard access was attempted")
    }
    isolatedPasteboard.releaseGlobally()

    let original = snapshot()
    var trusted = false
    var identityCalls = 0
    var identityResult: (id: String?, errorNumber: Int?) = (nil, nil)
    let diagnosticBridge = NotesBridge(trustChecker: { trusted }, identityReader: {
        identityCalls += 1
        return identityResult
    })
    var accessEvents: [NotesAccessIssue?] = []
    let diagnosticID = ObjectIdentifier(diagnosticBridge)
    let accessObserver = NotificationCenter.default.addObserver(forName: NotesBridge.accessChangedNotification, object: nil, queue: nil) { note in
        guard let changed = note.object as? NotesBridge, ObjectIdentifier(changed) == diagnosticID else { return }
        accessEvents.append(changed.accessIssue)
    }
    check(diagnosticBridge.accessIssue == .accessibilityRequired,
          "missing accessibility permission is explained before Notes identity access")
    diagnosticBridge.refreshAccessIssue()
    diagnosticBridge.refreshAccessIssue()
    check(identityCalls == 0 && accessEvents == [.accessibilityRequired],
          "permission refresh never sends an identity request and deduplicates unchanged issues")
    check(NotesAccessIssue.accessibilityRequired.message.contains("辅助功能")
          && !NotesAccessIssue.accessibilityRequired.needsAutomationSettings,
          "accessibility guidance identifies the correct permission pane")

    trusted = true
    diagnosticBridge.refreshAccessIssue()
    diagnosticBridge.refreshAccessIssue()
    check(diagnosticBridge.accessIssue == nil && identityCalls == 0
          && accessEvents == [.accessibilityRequired, nil],
          "granting accessibility clears that issue without sending an AppleEvent")
    identityResult = (nil, -1743)
    check(diagnosticBridge.selectedNoteID() == nil && diagnosticBridge.accessIssue == .automationDenied,
          "Notes automation denial is classified on the selected-note identity path")
    check(NotesAccessIssue.automationDenied.needsAutomationSettings
          && NotesAccessIssue.automationDenied.message.contains("自动化"),
          "automation denial offers the automation permission pane")
    _ = diagnosticBridge.selectedNoteID()
    check(accessEvents == [.accessibilityRequired, nil, .automationDenied],
          "repeated identity errors publish only one diagnostic change")

    trusted = false
    check(diagnosticBridge.refreshAccessIssue() == .accessibilityRequired,
          "missing accessibility takes precedence over a previous automation denial")
    trusted = true
    check(diagnosticBridge.refreshAccessIssue() == .automationDenied,
          "the most recent identity error remains visible after accessibility is restored")
    identityResult = ("synthetic-untrusted-id", -1708)
    check(diagnosticBridge.selectedNoteID() == nil && diagnosticBridge.accessIssue == .identityUnavailable
          && !NotesAccessIssue.identityUnavailable.needsAutomationSettings,
          "other script failures never accept a note identity and give selection guidance")
    identityResult = (nil, nil)
    check(diagnosticBridge.selectedNoteID() == nil && diagnosticBridge.accessIssue == .identityUnavailable,
          "no single selected note is reported as identity unavailable")
    identityResult = (" \n ", nil)
    check(diagnosticBridge.selectedNoteID() == nil && diagnosticBridge.accessIssue == .identityUnavailable,
          "an empty selected-note identity cannot bypass the note identity safety gate")
    identityResult = ("  synthetic-note-id\n", nil)
    check(diagnosticBridge.selectedNoteID() == "synthetic-note-id" && diagnosticBridge.accessIssue == nil,
          "successful identity reading trims the identifier and clears the previous identity error")
    check(accessEvents == [.accessibilityRequired, nil, .automationDenied, .accessibilityRequired,
                           .automationDenied, .identityUnavailable, nil],
          "identity recovery publishes one cleared diagnostic without raw script data")
    NotificationCenter.default.removeObserver(accessObserver)

    var bypassCalls = 0
    let snapshotBypass = NotesBridge(snapshotReader: { original }, trustChecker: {
        bypassCalls += 1
        return false
    }, identityReader: {
        bypassCalls += 1
        return (nil, -1743)
    })
    check(snapshotBypass.readTextSnapshot()?.matches(original) == true
          && snapshotBypass.readSelectionSnapshot()?.matches(original) == true
          && snapshotBypass.readNotesSnapshot()?.matches(original) == true && bypassCalls == 0,
          "injected snapshots still bypass real permissions and AppleEvent identity reading")

    var current: NotesBridge.SelectionSnapshot? = original
    var writes: [(CFRange, String, String?)] = []
    let bridge = NotesBridge(snapshotReader: { current }, replacementWriter: { _, range, text, html in
        writes.append((range, text, html))
        return nil
    })

    check(bridge.replaceSelection(in: original, with: "new") == nil && writes.count == 1,
          "unchanged selection can be replaced")
    writes = []
    current = snapshot(noteID: "note-b")
    check(bridge.replaceSelection(in: original, with: "new") != nil && writes.isEmpty,
          "same text and range in another note cannot be replaced")
    current = snapshot(text: "modified")
    check(bridge.replaceSelection(in: original, with: "new") != nil && writes.isEmpty,
          "same-length edited selection cannot be replaced")
    current = snapshot(text: "original!", length: 8)
    check(bridge.appendAfterSelection(in: original, with: "new") != nil && writes.isEmpty,
          "document edits invalidate an append even when selection is unchanged")
    current = snapshot(location: 1, length: 7)
    check(bridge.replaceSelection(in: original, with: "new") != nil && writes.isEmpty,
          "moved selection cannot be restored over the current selection")
    current = snapshot(element: AXUIElementCreateApplication(12346))
    check(bridge.replaceSelection(in: original, with: "new") != nil && writes.isEmpty,
          "another text element cannot receive the old result")
    current = nil
    check(bridge.replaceSelection(in: original, with: "new") != nil && writes.isEmpty,
          "missing Notes focus cancels writeback")
    current = original
    check(bridge.appendAfterSelection(in: original, with: " appended") == nil
          && writes.last?.0.location == 8 && writes.last?.0.length == 0,
          "append is bound to the original selection end")
    writes = []
    bridge.writeWhenNotesActive(in: original, text: "confirmed") { error in
        check(error == nil && writes.count == 1, "confirmed write uses the captured target")
    }
    current = snapshot(noteID: "note-b")
    writes = []
    bridge.writeWhenNotesActive(in: original, text: "confirmed") { error in
        check(error != nil && writes.isEmpty, "confirmed write refuses a different note")
    }

    current = original
    var posted = 0, restored = 0
    let pasteError = bridge.validatedPaste(in: original, prepareClipboard: {
        current = snapshot(noteID: "note-b")
        return { restored += 1 }
    }, postPaste: { posted += 1; return nil })
    check(pasteError != nil && posted == 0, "target change while preparing clipboard prevents paste")
    check(restored == 1, "cancelled paste restores the prepared clipboard")

    current = original
    var insertionCallbacks = 0
    bridge.insertIntoNotes("manual insertion") { error in
        insertionCallbacks += 1
        check(error == nil && writes.count == 1, "manual insertion reports its completed write")
    }
    current = nil
    bridge.insertIntoNotes("manual insertion") { error in
        insertionCallbacks += 1
        check(error != nil, "manual insertion reports an unavailable target")
    }
    check(insertionCallbacks == 2, "manual insertion reports its result exactly once")

    UserDefaults.standard.setVolatileDomain(["nc.urltitle.enabled": true], forName: UserDefaults.argumentDomain)
    UrlTitleLinker.bridge = bridge

    @MainActor func startURL(_ url: String, gate: CompletionGate) async -> (NotesBridge.SelectionSnapshot, Task<Void, Never>?) {
        let raw = "prefix \(url) "
        let target = snapshot(text: raw, location: raw.utf16.count, length: 0)
        current = target
        writes = []
        UrlTitleLinker.fetcher = { _ in await gate.wait() }
        check(UrlTitleLinker.hit(raw), "URL conversion captures a target")
        let task = UrlTitleLinker.pendingTask
        await gate.waitUntilStarted()
        check(writes.isEmpty, "URL remains intact while fetching the title")
        return (target, task)
    }

    let successGate = CompletionGate()
    let (urlTarget, successTask) = await startURL("https://example.com/success", gate: successGate)
    successGate.finish("Page title")
    await successTask?.value
    check(writes.count == 1 && writes[0].0.location == 7
          && writes[0].0.length == urlTarget.documentText.utf16.count - 7
          && writes[0].1 == "Page title " && writes[0].2?.contains("href=") == true,
          "completed URL replaces only its original range and preserves whitespace")

    let whitespaceGate = CompletionGate()
    let whitespaceRaw = "😀 prefix https://example.com/whitespace  \t"
    current = snapshot(text: whitespaceRaw, location: whitespaceRaw.utf16.count, length: 0)
    writes = []
    UrlTitleLinker.fetcher = { _ in await whitespaceGate.wait() }
    check(UrlTitleLinker.hit(whitespaceRaw), "URL with multiple trailing whitespace starts conversion")
    let whitespaceTask = UrlTitleLinker.pendingTask
    await whitespaceGate.waitUntilStarted()
    whitespaceGate.finish("Page title")
    await whitespaceTask?.value
    if let write = writes.first {
        let replaced = (whitespaceRaw as NSString).replacingCharacters(
            in: NSRange(location: write.0.location, length: write.0.length), with: write.1)
        check(replaced == "😀 prefix Page title  \t", "URL replacement preserves its prefix and every trailing whitespace")
    } else {
        check(false, "URL replacement preserves its prefix and every trailing whitespace")
    }

    let movedGate = CompletionGate()
    let (movedTarget, movedTask) = await startURL("https://example.com/moved", gate: movedGate)
    current = snapshot(text: movedTarget.documentText, location: 0, length: 0)
    movedGate.finish("Wrong place")
    await movedTask?.value
    check(writes.isEmpty, "moving the cursor cancels URL replacement")

    let switchedGate = CompletionGate()
    let (switchedTarget, switchedTask) = await startURL("https://example.com/switched", gate: switchedGate)
    current = snapshot(noteID: "note-b", text: switchedTarget.documentText,
                       location: switchedTarget.range.location, length: 0)
    switchedGate.finish("Wrong note")
    await switchedTask?.value
    check(writes.isEmpty, "switching notes cancels URL replacement")

    let focusGate = CompletionGate()
    let (_, focusTask) = await startURL("https://example.com/focus", gate: focusGate)
    current = nil
    focusGate.finish("Other app")
    await focusTask?.value
    check(writes.isEmpty, "leaving Notes cancels URL replacement without a timeout paste")

    let roundTripGate = CompletionGate()
    let (roundTripTarget, roundTripTask) = await startURL("https://example.com/roundtrip", gate: roundTripGate)
    current = nil
    UrlTitleLinker.cancelIfTargetChanged()
    current = roundTripTarget
    roundTripGate.finish("Too late")
    await roundTripTask?.value
    check(writes.isEmpty, "a cancelled URL request stays cancelled after focus returns")

    let disabledGate = CompletionGate()
    let (_, disabledTask) = await startURL("https://example.com/disabled", gate: disabledGate)
    UserDefaults.standard.setVolatileDomain(["nc.urltitle.enabled": false], forName: UserDefaults.argumentDomain)
    disabledGate.finish("Disabled")
    await disabledTask?.value
    check(writes.isEmpty, "disabling URL conversion cancels pending writeback")

    let selectionGate = CompletionGate()
    let request = SelectionAIRequest(complete: { _, _ in await selectionGate.wait() })
    request.select(original)
    request.run(instruction: "rewrite")
    let oldTask = request.task
    await selectionGate.waitUntilStarted()
    let nextSelection = snapshot(noteID: "note-b", text: "different")
    request.select(nextSelection)
    selectionGate.finish("old selection result")
    await oldTask?.value
    check(request.snapshot?.noteID == "note-b" && request.resultText.isEmpty && !request.busy,
          "old selection completion cannot populate a new selection")

    let hiddenGate = CompletionGate()
    let hiddenRequest = SelectionAIRequest(complete: { _, _ in await hiddenGate.wait() })
    hiddenRequest.select(original)
    hiddenRequest.run(instruction: "rewrite")
    let hiddenTask = hiddenRequest.task
    await hiddenGate.waitUntilStarted()
    hiddenRequest.cancel()
    hiddenGate.finish("hidden result")
    await hiddenTask?.value
    check(hiddenRequest.snapshot == nil && hiddenRequest.resultText.isEmpty,
          "hiding a selection cancels its request and ignores late completion")

    let validRequest = SelectionAIRequest(complete: { _, context in "edited \(context)" })
    validRequest.select(original)
    validRequest.run(instruction: "rewrite")
    await validRequest.task?.value
    check(validRequest.resultText == "edited original" && !validRequest.busy,
          "a current selection receives its own completion")

    check(NotesBridge.context(in: snapshot(text: "first paragraph", location: 0, length: 0))?.text == "first paragraph",
          "cursor at zero uses its current paragraph")
    check(NotesBridge.context(in: snapshot(text: "first paragraph", location: 5, length: 0))?.text == "first paragraph",
          "cursor in paragraph includes text after cursor")
    check(NotesBridge.context(in: snapshot(text: "", location: 0, length: 0)) == nil,
          "empty Notes snapshot has no stale context")
    let unicodeContext = "😀 中文段落\n\n"
    check(NotesBridge.context(in: snapshot(text: unicodeContext, location: unicodeContext.utf16.count, length: 0))?.text == "😀 中文段落",
          "blank current paragraph falls back to preceding Unicode paragraph")
    check(NotesBridge.context(in: snapshot(text: "😀 中文段落", location: 3, length: 2))?.text == "中文",
          "selection context uses AX UTF-16 range after emoji")

    // 命令删除使用 AX UTF-16 范围，并在确认同一目标完成变更后才继续执行。
    let commandText = "😀 context/周报 "
    let commandTarget = snapshot(text: commandText, location: commandText.utf16.count, length: 0)
    var commandCurrent: NotesBridge.SelectionSnapshot? = commandTarget
    let commandBridge = NotesBridge(snapshotReader: { commandCurrent }, replacementWriter: { target, range, text, _ in
        let updated = (target.documentText as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: text)
        commandCurrent = snapshot(noteID: target.noteID, text: updated,
                                  location: range.location + text.utf16.count, length: 0, element: target.element)
        return nil
    })
    let suffix = NotesBridge.suffixRange(in: commandTarget, characterCount: 4)
    check(suffix?.location == "😀 context".utf16.count && suffix?.length == "/周报 ".utf16.count,
          "command suffix uses UTF-16 positions after emoji")
    var commandCompletions = 0
    commandBridge.removeSuffix(in: commandTarget, characterCount: 4) { target, error in
        commandCompletions += 1
        check(error == nil && target?.documentText == "😀 context" && target?.range.length == 0,
              "command action receives the verified post-deletion cursor")
    }
    check(commandCompletions == 1, "verified command deletion completes exactly once")
    commandCurrent = snapshot(noteID: "different", text: commandText, location: commandText.utf16.count, length: 0)
    commandBridge.removeSuffix(in: commandTarget, characterCount: 4) { target, error in
        check(target == nil && error != nil, "command deletion refuses a switched note before writing")
    }
    check(NotesBridge.suffixRange(in: commandTarget, characterCount: 1000) == nil,
          "oversized command cannot delete preceding unrelated text")

    let lease = NotesCommandExecution()
    check(lease.claim(original), "first command claims shared execution")
    check(!lease.claim(nextSelection), "menu and AX cannot claim overlapping command execution")
    lease.release()
    check(!lease.claim(original), "a repeated delivery of the same command target is suppressed")
    check(lease.claim(nextSelection), "a different command target can execute after release")
    lease.release()

    var retriedText = ""
    validRequest.writeResult(using: { _, _, _, completed in completed("write denied") }) { error in
        check(error == "write denied" && validRequest.resultText == "edited original"
              && validRequest.snapshot?.matches(original) == true,
              "failed selection write retains both generated result and original target")
    }
    validRequest.writeResult(using: { _, text, _, completed in
        retriedText = text
        completed(nil)
    }) { error in
        check(error == nil && retriedText == "edited original", "retained selection result can be retried")
    }
    // 取消必须在副作用之前生效，而不是仅忽略完成回调。
    var operationValid = true
    var delayedActivation: (() -> Void)?
    var cancelledWrites = 0
    let delayedBridge = NotesBridge(snapshotReader: { original }, replacementWriter: { _, _, _, _ in
        cancelledWrites += 1
        return nil
    }, activationScheduler: { delayedActivation = $0 })
    delayedBridge.writeWhenNotesActive(in: original, text: "must not write",
                                      isOperationValid: { operationValid }) { error in
        check(error != nil, "cancelling while Notes activation waits reports cancellation")
    }
    operationValid = false
    delayedActivation?()
    check(cancelledWrites == 0, "activation delay cancellation prevents the write itself")

    var clipboardPrepared = 0, clipboardRestored = 0, cancelledPosts = 0
    operationValid = true
    let cancelledPaste = bridge.validatedPaste(in: original, prepareClipboard: {
        clipboardPrepared += 1
        operationValid = false
        return { clipboardRestored += 1 }
    }, postPaste: { cancelledPosts += 1; return nil }, isOperationValid: { operationValid })
    check(cancelledPaste != nil && clipboardPrepared == 1 && clipboardRestored == 1 && cancelledPosts == 0,
          "cancellation during clipboard preparation restores clipboard without posting paste")
    operationValid = false
    _ = bridge.validatedPaste(in: original, prepareClipboard: {
        clipboardPrepared += 1
        return {}
    }, postPaste: { cancelledPosts += 1; return nil }, isOperationValid: { operationValid })
    check(clipboardPrepared == 1 && cancelledPosts == 0, "already cancelled paste never touches clipboard")

    var firstValidity: (() -> Bool)?
    validRequest.writeResult(using: { _, _, valid, _ in firstValidity = valid }) { _ in }
    check(firstValidity?() == true, "pending selection write receives a live operation token")
    validRequest.cancel()
    validRequest.select(original)
    validRequest.run(instruction: "rewrite")
    await validRequest.task?.value
    check(firstValidity?() == false && validRequest.resultText == "edited original",
          "cancel and rerun with identical text and target cannot revive an old write")

    current = original
    writes = []
    bridge.writeWhenNotesActive(in: original, text: "styled", html: "<b>styled</b>") { error in
        check(error == nil && writes.last?.2 == "<b>styled</b>", "explicit rich text survives verified writeback")
    }
    current = snapshot(noteID: "different")
    bridge.withNotesTargetActive(in: original) { error in
        check(error != nil, "generic format activation refuses stale Notes targets")
    }

    print(fail == 0 ? "全部通过：\(pass) 项" : "失败 \(fail) 项 / 共 \(pass + fail) 项")
    if skipped > 0 { print("环境限制跳过：\(skipped) 项（需要单独验收）") }
    exit(fail == 0 ? 0 : 1)
}
RunLoop.main.run()
