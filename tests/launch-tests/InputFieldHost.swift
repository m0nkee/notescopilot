import AppKit
import WebKit

/// Separate AppKit process used exclusively with synthetic input in check-startup.sh.
@main @MainActor
final class InputFieldHostApp {
    let sample = "开头🙂 目标 / 目标 结尾"
    let window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 480, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let first = NSTextField()
    let second = NSTextField()
    let multiline = NSTextView()
    let readonly = NSTextView()
    let password = NSSecureTextField()
    let webWindow = NSWindow(contentRect: NSRect(x: 180, y: 210, width: 480, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let webView: WKWebView
    var webField: String?
    let report: URL

    init(report: URL) {
        self.report = report
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "Fixture")
        mainMenu.addItem(applicationItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webWindow.title = "NotesCopilot 网页输入框测试"
        webWindow.contentView = webView
        webView.loadHTMLString("""
            <input id="webInput"><textarea id="webArea"></textarea>
            <input id="webPassword" type="password"><input id="webReadonly" readonly>
            <div id="webRich" contenteditable="true" role="textbox"></div><p id="webStatic"></p>
            <script>var edits = 0; document.addEventListener('input', () => edits++);</script>
            """, baseURL: nil)
        window.title = "NotesCopilot 测试输入框"
        for (index, view) in [first, second, multiline, readonly, password].enumerated() {
            view.frame = NSRect(x: 20, y: 265 - index * 54, width: 425, height: 35)
            window.contentView?.addSubview(view)
        }
        first.stringValue = sample
        second.stringValue = sample
        multiline.string = sample
        readonly.string = sample
        readonly.isEditable = false
        password.stringValue = "sample"
        window.makeKeyAndOrderFront(nil)
    }

    func select(in view: NSView, range: NSRange) {
        webField = nil
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if let field = view as? NSTextField {
            field.selectText(nil)
            field.currentEditor()?.selectedRange = range
        } else {
            (view as? NSTextView)?.setSelectedRange(range)
        }
    }

    func handle(_ command: String) {
        let range = (sample as NSString).range(of: "目标", options: .backwards)
        switch command {
        case "translateDraft":
            first.stringValue = "草稿：这是什么？"
            select(in: first, range: (first.stringValue as NSString).range(of: "这是什么？"))
        case "collapse":
            if let editor = first.currentEditor() {
                let end = NSMaxRange(editor.selectedRange)
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        case "collapseWeb":
            webView.evaluateJavaScript("getSelection().removeAllRanges()") { _, _ in self.reportWebState(command) }
            return
        case "webInput", "webArea", "webPassword", "webReadonly", "webRich", "webStatic":
            webField = command
            NSApp.activate(ignoringOtherApps: true)
            webWindow.makeKeyAndOrderFront(nil)
            webWindow.makeFirstResponder(webView)
            webView.evaluateJavaScript("""
                {
                    const field = document.getElementById('\(command)');
                    if ('setSelectionRange' in field) {
                        field.value = '\(sample)';
                        field.focus();
                        const start = field.value.lastIndexOf('目标');
                        field.setSelectionRange(start, start + 2);
                    } else {
                        document.activeElement.blur();
                        field.innerHTML = '开头🙂 目标 / <b>目标</b> 结尾';
                        field.focus();
                        const selection = getSelection();
                        const range = document.createRange();
                        range.selectNodeContents(field.querySelector('b'));
                        selection.removeAllRanges();
                        selection.addRange(range);
                    }
                    edits = 0;
                }
                """) { _, error in
                self.writeState(command, webValue: error?.localizedDescription ?? "")
            }
            return
        case "undoWeb":
            webView.evaluateJavaScript("document.execCommand('undo')") { _, _ in self.reportWebState(command) }
            return
        case "first": first.stringValue = sample; select(in: first, range: range)
        case "second": second.stringValue = sample; select(in: second, range: range)
        case "multiline": multiline.string = sample; select(in: multiline, range: range)
        case "readonly": select(in: readonly, range: range)
        case "republishReadonly":
            select(in: readonly, range: (sample as NSString).range(of: "目标"))
        case "password": select(in: password, range: NSRange(location: 0, length: 3))
        case "move": select(in: first, range: (sample as NSString).range(of: "目标"))
        case "editAround":
            first.stringValue = sample.replacingOccurrences(of: "开头", with: "另文")
            select(in: first, range: range)
        case "quit": NSApp.terminate(nil)
        default: break
        }
        if webField != nil { reportWebState(command) } else { writeState(command) }
    }

    func reportWebState(_ command: String) {
        guard let webField else { return }
        webView.evaluateJavaScript("(() => { const el = document.getElementById('\(webField)'); return {value: el.value ?? el.textContent, bold: el.querySelector('b')?.textContent, edits} })()") { value, _ in
            let field = value as? [String: Any]
            self.writeState(command, webValue: field?["value"] as? String ?? "", edits: field?["edits"] as? Int ?? 0, bold: field?["bold"] as? String)
        }
    }

    func writeState(_ command: String, webValue: String = "", edits: Int = 0, bold: String? = nil) {
        var state = ["command": command, "first": first.stringValue, "second": second.stringValue,
                     "multiline": multiline.string, "readonly": readonly.string, "edits": String(edits)]
        state["bold"] = bold
        if let webField { state[webField] = webValue }
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: report, options: .atomic) }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let host = InputFieldHostApp(report: URL(fileURLWithPath: CommandLine.arguments[1]))
        host.handle("ready")
        DispatchQueue.global().async {
            while let command = readLine() {
                DispatchQueue.main.async { host.handle(command) }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        app.run()
    }
}
