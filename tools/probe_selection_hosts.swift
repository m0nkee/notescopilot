import AppKit
import WebKit
import PDFKit

/// Measures actual Services requestor support on this Mac with synthetic, in-memory documents.
@main
struct SelectionHosts {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await inspect() }
            catch { print("ERROR", error.localizedDescription); exit(1) }
            exit(0)
        }
        app.run()
    }

    @MainActor static func inspect() async throws {
        let expected = "Selected words"
        let frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic selection fixture"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); window.orderOut(nil) }
        let types: [NSPasteboard.PasteboardType] = [.string, .init("NSStringPboardType")]
        func probe(_ name: String, responder: NSResponder?, selected: Bool) {
            var offered = false, delivered = false
            for type in types {
                guard let requestor = responder?.validRequestor(forSendType: type, returnType: nil) else { continue }
                offered = true
                board.clearContents()
                if (requestor as AnyObject).writeSelection?(to: board, types: [type]) == true {
                    delivered = board.string(forType: .string) == expected
                }
                if delivered { break }
            }
            print("\(name)  selection=\(selected) serviceRequestor=\(offered) exportedExactText=\(delivered)")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: frame, configuration: config)
        window.contentView = web
        window.makeFirstResponder(web)
        web.loadHTMLString("<p>Before</p><div id='target'>Selected words</div><p>After</p>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('target')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for editable in [false, true] {
            let chosen = try await web.evaluateJavaScript("""
            (() => {
                const target = document.getElementById('target');
                target.contentEditable = '\(editable)';
                target.focus();
                const range = document.createRange();
                range.selectNodeContents(target);
                const selection = getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                return selection.toString();
            })()
            """) as? String
            try await Task.sleep(nanoseconds: 150_000_000)
            probe("WKWebView editable=\(editable)", responder: window.firstResponder, selected: chosen == expected)
        }
        let printable = NSTextView(frame: frame)
        printable.string = "Before\n" + expected + "\nAfter"
        let pdf = PDFView(frame: frame)
        pdf.document = PDFDocument(data: printable.dataWithPDF(inside: frame))
        window.contentView = pdf
        window.makeFirstResponder(pdf)
        pdf.currentSelection = pdf.document?.findString(expected, withOptions: []).first
        probe("PDFKit text layer", responder: window.firstResponder, selected: pdf.currentSelection?.string == expected)
        let secure = NSSecureTextField(frame: frame)
        secure.stringValue = "synthetic"
        window.contentView = secure
        window.makeFirstResponder(secure)
        secure.selectText(nil)
        let offersText = types.contains { window.firstResponder?.validRequestor(forSendType: $0, returnType: nil) != nil }
        print("NSSecureTextField  serviceRequestor=\(offersText)")
    }
}
