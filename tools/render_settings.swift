import SwiftUI
import AppKit

// 离屏渲染 + 进程内 accessibility 遍历取证（不依赖屏幕录制/系统 AX 权限）
// 用法：render_settings <输出.png>

@main
struct RenderSettingsApp {
    static func main() {
        let args = CommandLine.arguments
        let out = args.count > 1 ? args[1] : "preview-settings.png"
        _ = NSApplication.shared
        let view = SettingsView().frame(width: 920, height: 640)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .miniaturizable],
                           backing: .buffered, defer: false)
        win.contentView = host
        win.layoutIfNeeded()

        // 1) 结构取证：遍历 accessibility 元素（NSObject.perform 动态取值，适配 SwiftUI 自定义元素）
        var lines: [String] = []
        func attr(_ el: AnyObject, _ selName: String) -> Any? {
            guard let obj = el as? NSObject,
                  obj.responds(to: Selector((selName))) else { return nil }
            return obj.perform(Selector((selName)))?.takeUnretainedValue()
        }
        func children(_ el: AnyObject) -> [AnyObject] {
            (attr(el, "accessibilityChildren") as? [AnyObject]) ?? []
        }
        func walk(_ el: AnyObject, _ d: Int) {
            guard d < 18 else { return }
            let role = (attr(el, "accessibilityRole") as? String) ?? "?"
            let label = (attr(el, "accessibilityLabel") as? String) ?? ""
            let value = (attr(el, "accessibilityValue") as? String) ?? ""
            if role != "AXGroup" || !label.isEmpty {
                var line = String(repeating: " ", count: min(d, 12)) + role
                if !label.isEmpty { line += " [\(label.prefix(40))]" }
                if !value.isEmpty { line += " =\(value.prefix(40))" }
                lines.append(line)
            }
            for child in children(el) { walk(child, d + 1) }
        }
        walk(host, 0)
        print("==== AX DUMP (\(lines.count)) ====")
        print(lines.prefix(60).joined(separator: "\n"))

        // 2) 像素取证：输出到 PNG
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage else { print("RENDER FAIL"); exit(1) }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { print("CG FAIL"); exit(1) }
        let url = URL(fileURLWithPath: out) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { print("DEST FAIL"); exit(1) }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("SAVED \(out)")
    }
}
