import AppKit
import Foundation

/// Runs the real delegate and AppKit windows with all external services disabled.
/// Window visibility under a locked session does not establish visual focus or screen placement.
@main
@MainActor
struct LaunchTests {
    private static var passed = 0
    private static var failed = 0
    private static var delegates: [AppDelegate] = []
    private static let ownedTitles: Set<String> = ["NotesCopilot", "NotesCopilot 设置", "笔记库 · NotesCopilot"]

    private static func check(_ value: Bool, _ name: String) {
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

    private static func launch(configured: Bool) throws -> AppDelegate {
        closeWindows()
        try configure(configured)
        let delegate = AppDelegate(startBackgroundServices: false)
        delegates.append(delegate)
        NSApp.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
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
        DispatchQueue.main.async { runTests(app) }
        app.run()
    }

    private static func runTests(_ app: NSApplication) {
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
        } catch {
            check(false, "launch harness error: \(error.localizedDescription)")
        }
        closeWindows()
        print("NOTE  Window state only; no visual focus or unlocked-screen validation.")
        print(failed == 0 ? "全部通过：\(passed) 项" : "失败 \(failed) 项 / 共 \(passed + failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
