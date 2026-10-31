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
    var pasteMenus: [String] = []
    var standardPastes = 0
    let retainedPaste = NotesBridge.dispatchPreparedPaste(preservingStyle: true,
        isOperationValid: { true }, triggerMenu: { pasteMenus.append($0); return true },
        postStandardPaste: { standardPastes += 1; return nil })
    check(retainedPaste == nil && pasteMenus == ["Paste and Retain Style"] && standardPastes == 0,
          "rich writeback explicitly dispatches retain-style paste rather than the ordinary paste command")
    pasteMenus = []
    let ordinaryPaste = NotesBridge.dispatchPreparedPaste(preservingStyle: false,
        isOperationValid: { true }, triggerMenu: { pasteMenus.append($0); return true },
        postStandardPaste: { standardPastes += 1; return nil })
    check(ordinaryPaste == nil && pasteMenus.isEmpty && standardPastes == 1,
          "plain text writeback retains the standard paste path")
    let localizedPaste = NotesBridge.dispatchPreparedPaste(preservingStyle: true,
        isOperationValid: { true }, triggerMenu: { pasteMenus.append($0); return $0 == "粘贴并保留样式" },
        postStandardPaste: { standardPastes += 1; return nil })
    check(localizedPaste == nil && pasteMenus == ["Paste and Retain Style", "粘贴并保留样式"] && standardPastes == 1,
          "rich writeback supports the localized retain-style menu without invoking standard paste")
    pasteMenus = []
    let unavailablePaste = NotesBridge.dispatchPreparedPaste(preservingStyle: true,
        isOperationValid: { true }, triggerMenu: { pasteMenus.append($0); return false },
        postStandardPaste: { standardPastes += 1; return nil })
    check(unavailablePaste != nil && !pasteMenus.isEmpty && standardPastes == 1,
          "missing retain-style menu reports failure without silently pasting unformatted text")
    pasteMenus = []
    let cancelledRetainPaste = NotesBridge.dispatchPreparedPaste(preservingStyle: true,
        isOperationValid: { false }, triggerMenu: { pasteMenus.append($0); return true },
        postStandardPaste: { standardPastes += 1; return nil })
    check(cancelledRetainPaste != nil && pasteMenus.isEmpty && standardPastes == 1,
          "cancelled rich writeback invokes neither paste path")
    var stillValid = true
    let cancelledDuringLookup = NotesBridge.dispatchPreparedPaste(preservingStyle: true,
        isOperationValid: { stillValid }, triggerMenu: { pasteMenus.append($0); stillValid = false; return false },
        postStandardPaste: { standardPastes += 1; return nil })
    check(cancelledDuringLookup != nil && pasteMenus == ["Paste and Retain Style"] && standardPastes == 1,
          "cancellation after a missing menu prevents all later menu actions")

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

    // Validate the native rich payload on an isolated pasteboard; this does not
    // establish how a focused Notes paragraph imports or displays that payload.
    let nativePasteboard = NSPasteboard(name: .init("local.notescopilot.rtf-writeback-tests." + UUID().uuidString))
    let nativeHTML = """
    <h1 style="font-size:24px;font-weight:bold;">标题中文😀</h1>
    <p style="font-size:13px;">普通正文 <strong>标记粗体</strong></p>
    <pre style="background-color:#f2f2f2;padding:12px;font-family:Menlo,monospace;white-space:pre-wrap;"><code>let café = &quot;世界🙂&quot;
    print(café)</code></pre>
    <p><span style="color:#ff9500;">#橙色🚀</span></p>
    """
    let nativeText = "标题中文😀\n普通正文 标记粗体\nlet café = \"世界🙂\"\nprint(café)\n#橙色🚀"
    let nativeBridge = NotesBridge()
    nativePasteboard.clearContents()
    let restoreEmpty = nativeBridge.preparePasteboard(text: nativeText, html: nativeHTML, pasteboard: nativePasteboard)
    let nativeRTF = nativePasteboard.data(forType: .rtf)
    let nativeRTFD = nativePasteboard.data(forType: .rtfd)
    check(nativeRTF != nil, "rich clipboard transport supplies native RTF alongside HTML and plain text")
    check(nativeRTFD != nil, "rich clipboard transport supplies standard flat RTFD before the fallbacks")
    let nativeItems = nativePasteboard.pasteboardItems ?? []
    check(nativeItems.count == 1 && nativeItems[0].data(forType: .rtfd) == nativeRTFD
          && nativeItems[0].data(forType: .rtf) == nativeRTF
          && nativeItems[0].data(forType: .html) == NotesBridge.htmlPasteboardData(nativeHTML)
          && nativeItems[0].string(forType: .string) == nativeText,
          "native RTFD RTF HTML and plain text belong to the same clipboard item")
    for (payload, documentType, formatName) in [(nativeRTF, NSAttributedString.DocumentType.rtf, "RTF"),
                                               (nativeRTFD, NSAttributedString.DocumentType.rtfd, "RTFD")] {
        guard let payload else { continue }
        do {
            let decoded = try NSAttributedString(data: payload,
                options: [.documentType: documentType], documentAttributes: nil)
            func attribute(_ key: NSAttributedString.Key, at text: String) -> Any? {
                let range = (decoded.string as NSString).range(of: text)
                return range.location == NSNotFound ? nil : decoded.attribute(key, at: range.location, effectiveRange: nil)
            }
            let titleFont = attribute(.font, at: "标题中文😀") as? NSFont
            let bodyFont = attribute(.font, at: "普通正文") as? NSFont
            check(titleFont != nil && bodyFont != nil && titleFont!.pointSize > bodyFont!.pointSize
                  && NSFontManager.shared.traits(of: titleFont!).contains(.boldFontMask)
                  && !NSFontManager.shared.traits(of: bodyFont!).contains(.boldFontMask),
                  "native \(formatName) keeps the heading larger and bold while the ordinary paragraph stays unbolded")
            let spanFont = attribute(.font, at: "标记粗体") as? NSFont
            check(spanFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                  "native \(formatName) preserves bold spans inside the ordinary paragraph")
            let codeFont = attribute(.font, at: "let café") as? NSFont
            check(codeFont.map { $0.isFixedPitch || $0.fontName.localizedCaseInsensitiveContains("Menlo") } == true
                  && decoded.string.contains("let café = \"世界🙂\"\nprint(café)"),
                  "native \(formatName) preserves the monospace font and multiple lines of the code block")
            func nonWhite(_ color: NSColor?) -> Bool {
                guard let rgb = color?.usingColorSpace(.deviceRGB) else { return false }
                return rgb.alphaComponent > 0.1
                    && min(rgb.redComponent, min(rgb.greenComponent, rgb.blueComponent)) < 0.99
            }
            let codeBackground = attribute(.backgroundColor, at: "let café") as? NSColor
            let codeParagraph = attribute(.paragraphStyle, at: "let café") as? NSParagraphStyle
            check(nonWhite(codeBackground) || codeParagraph?.textBlocks.contains { nonWhite($0.backgroundColor) } == true,
                  "native \(formatName) retains the code block background as a text or paragraph block attribute")
            let tagColor = (attribute(.foregroundColor, at: "#橙色🚀") as? NSColor)?.usingColorSpace(.deviceRGB)
            check(tagColor.map { $0.redComponent > 0.8 && $0.greenComponent > 0.25
                  && $0.greenComponent < 0.8 && $0.blueComponent < 0.2 && $0.alphaComponent > 0.9 } == true,
                  "native \(formatName) preserves the orange inline tag color")
            check(decoded.string.contains("标题中文😀") && decoded.string.contains("普通正文 标记粗体")
                  && decoded.string.contains("#橙色🚀") && !decoded.string.contains("\u{FFFD}")
                  && !decoded.string.contains("**") && !decoded.string.contains("```")
                  && !decoded.string.contains("# 标题"),
                  "native \(formatName) preserves Unicode text and has no generated Markdown formatting markers")
        } catch {
            check(false, "native \(formatName) payload cannot be decoded: \(error)")
        }
    }
    restoreEmpty()
    check((nativePasteboard.pasteboardItems ?? []).isEmpty && nativePasteboard.data(forType: .rtf) == nil
          && nativePasteboard.data(forType: .rtfd) == nil,
          "restoring an initially empty clipboard removes every rich payload type including RTF and RTFD")

    do {
        let oldRTF = try NSAttributedString(string: "旧剪贴板😀").data(from: NSRange(location: 0, length: "旧剪贴板😀".utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let firstItem = NSPasteboardItem()
        firstItem.setString("first original item", forType: .string)
        firstItem.setData(oldRTF, forType: .rtf)
        firstItem.setData(originalHTML, forType: .html)
        let secondItem = NSPasteboardItem()
        secondItem.setString("second original item", forType: .string)
        secondItem.setData(originalData, forType: customType)
        nativePasteboard.clearContents()
        if nativePasteboard.writeObjects([firstItem, secondItem]) {
            let restoreMultiple = nativeBridge.preparePasteboard(text: nativeText, html: nativeHTML, pasteboard: nativePasteboard)
            restoreMultiple()
            let restoredItems = nativePasteboard.pasteboardItems ?? []
            check(restoredItems.count == 2 && restoredItems[0].data(forType: .rtf) == oldRTF
                  && restoredItems[0].data(forType: .html) == originalHTML
                  && restoredItems[0].string(forType: .string) == "first original item"
                  && restoredItems[1].data(forType: customType) == originalData
                  && restoredItems[1].string(forType: .string) == "second original item",
                  "native rich clipboard restoration preserves multiple items old RTF and unrelated types")
            let staleNativeRestore = nativeBridge.preparePasteboard(text: nativeText, html: nativeHTML, pasteboard: nativePasteboard)
            nativePasteboard.clearContents()
            nativePasteboard.setString("newer copy", forType: .string)
            staleNativeRestore()
            check(nativePasteboard.string(forType: .string) == "newer copy"
                  && nativePasteboard.data(forType: .rtf) == nil && nativePasteboard.data(forType: .html) == nil,
                  "delayed native rich clipboard restoration leaves a newer copy untouched")
        } else {
            skip("named multi-item pasteboard service is unavailable; the general clipboard was not accessed")
        }
    } catch {
        check(false, "cannot build the synthetic original RTF clipboard item: \(error)")
    }
    nativePasteboard.releaseGlobally()

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

    // 模板直接替换捕获的命令范围，避免先删空新笔记标题再尝试重新定位笔记。
    let titleTrigger = "/会议纪要"
    let titleTarget = snapshot(noteID: "new-title-note", text: titleTrigger,
                               location: titleTrigger.utf16.count, length: 0)
    let titleRange = NotesBridge.suffixRange(in: titleTarget, characterCount: titleTrigger.count)!
    let expandedTemplate = "新标题😀\n第一段\n- 行动项"
    let expandedHTML = "<h1>新标题😀</h1><p>第一段</p><ul><li>行动项</li></ul>"
    var atomicCurrent: NotesBridge.SelectionSnapshot? = titleTarget
    var atomicWrites: [(target: NotesBridge.SelectionSnapshot, range: CFRange, text: String, html: String?)] = []
    let atomicBridge = NotesBridge(snapshotReader: { atomicCurrent }, replacementWriter: { target, range, text, html in
        atomicWrites.append((target, range, text, html))
        let updated = (target.documentText as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: text)
        atomicCurrent = snapshot(noteID: target.noteID, text: updated,
                                 location: range.location + text.utf16.count, length: 0, element: target.element)
        return nil
    })
    atomicBridge.writeWhenNotesActive(in: titleTarget, text: expandedTemplate, range: titleRange, html: expandedHTML) { error in
        check(error == nil && atomicWrites.count == 1 && atomicWrites[0].target.matches(titleTarget)
              && atomicWrites[0].range.location == 0 && atomicWrites[0].range.length == titleTrigger.utf16.count
              && atomicWrites[0].text == expandedTemplate && atomicWrites[0].html == expandedHTML,
              "sole title slash template is replaced with rich content in one verified write")
    }
    check(atomicCurrent?.noteID == titleTarget.noteID && atomicCurrent?.documentText == expandedTemplate
          && atomicCurrent?.range.location == expandedTemplate.utf16.count && atomicCurrent?.range.length == 0
          && atomicWrites.allSatisfy { !$0.text.isEmpty },
          "atomic title replacement retains note identity and ends at the inserted text without a blank-title write")

    let bodyPrefix = "已有标题\n😀 正文 "
    let bodyCommand = bodyPrefix + titleTrigger
    let bodyTarget = snapshot(noteID: "existing-body-note", text: bodyCommand,
                              location: bodyCommand.utf16.count, length: 0)
    let bodyRange = NotesBridge.suffixRange(in: bodyTarget, characterCount: titleTrigger.count)!
    atomicCurrent = bodyTarget
    atomicBridge.writeWhenNotesActive(in: bodyTarget, text: expandedTemplate, range: bodyRange, html: expandedHTML) { error in
        check(error == nil && atomicWrites.count == 2 && atomicWrites.last?.range.location == bodyPrefix.utf16.count
              && atomicCurrent?.documentText == bodyPrefix + expandedTemplate
              && atomicCurrent?.noteID == bodyTarget.noteID && atomicWrites.last?.html == expandedHTML,
              "atomic body slash replacement preserves the preceding title and Unicode text")
    }
    let writesBeforeStaleTargets = atomicWrites.count
    atomicCurrent = snapshot(noteID: "other-note", text: bodyCommand,
                             location: bodyTarget.range.location, length: 0, element: bodyTarget.element)
    atomicBridge.writeWhenNotesActive(in: bodyTarget, text: expandedTemplate, range: bodyRange, html: expandedHTML) { error in
        check(error != nil && atomicWrites.count == writesBeforeStaleTargets,
              "atomic template replacement rejects another note even with identical text and reused AX element")
    }
    atomicCurrent = snapshot(noteID: bodyTarget.noteID, text: bodyCommand, location: 0, length: 0,
                             element: bodyTarget.element)
    atomicBridge.writeWhenNotesActive(in: bodyTarget, text: expandedTemplate, range: bodyRange, html: expandedHTML) { error in
        check(error != nil && atomicWrites.count == writesBeforeStaleTargets,
              "atomic template replacement rejects a moved caret before changing the command range")
    }
    atomicCurrent = snapshot(noteID: bodyTarget.noteID, text: bodyCommand.replacingOccurrences(of: "已有", with: "修改"),
                             location: bodyTarget.range.location, length: 0, element: bodyTarget.element)
    atomicBridge.writeWhenNotesActive(in: bodyTarget, text: expandedTemplate, range: bodyRange, html: expandedHTML) { error in
        check(error != nil && atomicWrites.count == writesBeforeStaleTargets,
              "atomic template replacement rejects same-length edits outside the slash command")
    }
    var pendingTitleActivation: (() -> Void)?
    let delayedTitleBridge = NotesBridge(snapshotReader: { atomicCurrent }, replacementWriter: { target, range, text, html in
        atomicWrites.append((target, range, text, html))
        return nil
    }, activationScheduler: { pendingTitleActivation = $0 })
    atomicCurrent = titleTarget
    var delayedTitleCompletion = false
    delayedTitleBridge.writeWhenNotesActive(in: titleTarget, text: expandedTemplate, range: titleRange, html: expandedHTML) { error in
        delayedTitleCompletion = true
        check(error != nil && atomicWrites.count == writesBeforeStaleTargets,
              "delayed activation revalidates the original title before atomic rich replacement")
    }
    check(!delayedTitleCompletion && atomicWrites.count == writesBeforeStaleTargets,
          "atomic title replacement waits for activation without an early deletion")
    atomicCurrent = snapshot(noteID: "other-note", text: titleTrigger, location: titleTrigger.utf16.count,
                             length: 0, element: titleTarget.element)
    pendingTitleActivation?()

    let lease = NotesCommandExecution()
    check(lease.claim(original), "first command claims shared execution")
    check(!lease.claim(nextSelection), "menu and AX cannot claim overlapping command execution")
    lease.release()
    check(!lease.claim(original), "a repeated delivery of the same command target is suppressed")
    check(lease.claim(nextSelection), "a different command target can execute after release")
    lease.release()

    let templateLease = NotesCommandExecution()
    check(templateLease.claim(titleTarget) && !templateLease.claim(titleTarget, allowRepeat: true),
          "an explicit template retry cannot overlap an active command claim")
    templateLease.release(suppressUnchangedTarget: true, commandRange: titleRange)
    check(!templateLease.isBusy, "starting an asynchronous template releases global command arbitration")
    try? await Task.sleep(nanoseconds: 1_100_000_000)
    check(!templateLease.claim(titleTarget),
          "the automatic watcher cannot repeat an unchanged template after the ordinary cooldown expires")
    check(templateLease.claim(titleTarget, allowRepeat: true),
          "an explicit menu selection can retry the unchanged suppressed template")
    check(!templateLease.claim(bodyTarget, allowRepeat: true),
          "an explicit selection of a different target still respects an active command claim")
    templateLease.release(suppressUnchangedTarget: true, commandRange: titleRange)
    check(templateLease.claim(bodyTarget), "a different Notes target remains available while a template is pending")
    templateLease.release(suppressUnchangedTarget: true, commandRange: bodyRange)
    let stopDocument = bodyTarget.documentText + "\n/stop "
    let stopTarget = snapshot(noteID: bodyTarget.noteID, text: stopDocument,
                              location: stopDocument.utf16.count, length: 0, element: bodyTarget.element)
    check(templateLease.claim(stopTarget),
          "editing the same note to type stop can claim execution while the earlier template is pending")
    templateLease.release()

    let pendingTrigger = "/周报 "
    let pendingTarget = snapshot(noteID: "pending-template-note", text: pendingTrigger,
                                 location: pendingTrigger.utf16.count, length: 0)
    let pendingRange = NotesBridge.suffixRange(in: pendingTarget, characterCount: pendingTrigger.count)!
    @MainActor func reservedTemplateGate() -> NotesCommandExecution {
        let gate = NotesCommandExecution()
        _ = gate.claim(pendingTarget)
        gate.release(suppressUnchangedTarget: true, commandRange: pendingRange)
        return gate
    }
    let appendedStopText = pendingTrigger + "/stop "
    let appendedStopTarget = snapshot(noteID: pendingTarget.noteID, text: appendedStopText,
                                      location: appendedStopText.utf16.count, length: 0, element: pendingTarget.element)
    let observedAppendGate = reservedTemplateGate()
    observedAppendGate.observe(appendedStopTarget)
    check(!observedAppendGate.claim(pendingTarget),
          "observing appended stop text does not discard the original template suppression")

    let restoredAfterStop = reservedTemplateGate()
    restoredAfterStop.observe(appendedStopTarget)
    check(restoredAfterStop.claim(appendedStopTarget), "stop can claim arbitration after a template reservation")
    check(!restoredAfterStop.claim(pendingTarget, allowRepeat: true),
          "a rejected explicit retry during another command cannot consume the template reservation")
    restoredAfterStop.release()
    check(!restoredAfterStop.claim(pendingTarget),
          "deleting stop back to the original command cannot automatically restart the cancelled template")

    let otherNoteTarget = snapshot(noteID: "another-pending-note", text: pendingTrigger,
                                   location: pendingTrigger.utf16.count, length: 0, element: pendingTarget.element)
    let restoredAfterOtherNote = reservedTemplateGate()
    restoredAfterOtherNote.observe(snapshot(noteID: otherNoteTarget.noteID, text: "", location: 0, length: 0,
                                            element: pendingTarget.element))
    restoredAfterOtherNote.observe(otherNoteTarget)
    check(restoredAfterOtherNote.claim(otherNoteTarget), "another note can execute while the first template remains reserved")
    restoredAfterOtherNote.release()
    check(!restoredAfterOtherNote.claim(pendingTarget),
          "a command in another note cannot erase suppression when returning to the unchanged template")

    let editedTriggerGate = reservedTemplateGate()
    editedTriggerGate.observe(snapshot(noteID: pendingTarget.noteID, text: "", location: 0, length: 0,
                                      element: pendingTarget.element))
    editedTriggerGate.observe(pendingTarget)
    check(editedTriggerGate.claim(pendingTarget),
          "removing then retyping the identical trigger permits a fresh automatic template invocation")
    editedTriggerGate.release()

    let caretOnlyGate = reservedTemplateGate()
    caretOnlyGate.observe(snapshot(noteID: pendingTarget.noteID, text: pendingTrigger, location: 0, length: 0,
                                  element: pendingTarget.element))
    check(!caretOnlyGate.claim(pendingTarget), "moving the caret without editing the trigger retains template suppression")
    let otherElementGate = reservedTemplateGate()
    otherElementGate.observe(snapshot(noteID: pendingTarget.noteID, text: "", location: 0, length: 0,
                                     element: AXUIElementCreateApplication(12346)))
    check(!otherElementGate.claim(pendingTarget),
          "observing another AX element cannot invalidate a template reservation for the original editor")

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
