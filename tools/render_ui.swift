import AppKit
import SwiftUI
import Accessibility

/// Exercises recovery UI without reading or changing the user's Keychain.
private final class SyntheticFailingProfileSecretStore: ProfileSecretStore {
    private(set) var readCount = 0
    private var error: APIError { APIError(status: -25308, message: "钥匙串访问失败：Synthetic Keychain access denied") }
    func read(id: UUID) throws -> String? { readCount += 1; throw error }
    func write(_ secret: String, id: UUID) throws { throw error }
    func remove(id: UUID) throws { throw error }
}

/// Render the actual native views with synthetic, isolated data. No Notes or AI calls.
@main
struct RenderUI {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/ui-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "nc.ui-smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ModelProfile(name: "本地写作", baseURL: "http://localhost:11434/v1", apiKey: "", model: "qwen3:32b")
        let values: [String: Any] = [
            "nc.profiles": try JSONEncoder().encode([profile]), "nc.activeProfileID": profile.id.uuidString,
            "nc.templates": try JSONEncoder().encode([TemplateNote]()), "nc.kw.rules": Data(),
            "nc.sys": Config.defaultSystem, "nc.temp": 0.7, "nc.maxTokens": 2048, "nc.continuous": true,
        ]
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        ProfileStore.defaults = defaults
        Config.defaults = defaults
        ProfileStore.secretStore = MemoryProfileSecretStore()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        let engine = ChatEngine()
        try render(PanelView(engine: engine, notesAccessIssueProvider: { nil }), size: NSSize(width: 560, height: 760), name: "panel-empty", directory: output)
        engine.setContext("本周完成编辑器交互优化，下周继续验证笔记写回与模型切换。", source: "选中文本", noteID: "synthetic-note")
        engine.output = "## 本周进展\n\n- **交互优化**：完善选区加工流程。\n- [ ] 验证写回失败恢复\n- [x] 修复请求状态冲突\n\n| 项目 | 状态 |\n| --- | --- |\n| 回归测试 | 通过 |\n\n```swift\nlet note = currentNote\n```"
        try render(PanelView(engine: engine, notesAccessIssueProvider: { nil }), size: NSSize(width: 560, height: 760), name: "panel-result", directory: output)
        engine.pendingTarget = NotesBridge.SelectionSnapshot(element: AXUIElementCreateSystemWide(), range: CFRange(location: 0, length: 4), text: "原始文本", bounds: .zero, noteID: "synthetic-note", documentText: "原始文本")
        engine.pendingResult = engine.output
        try render(PanelView(engine: engine, notesAccessIssueProvider: { nil }), size: NSSize(width: 520, height: 640), name: "panel-review-small", directory: output)
        engine.dismissReview()
        engine.lastError = "响应尚未完成，已保留当前结果。可以继续生成、重新生成，或复制已有内容。写回前请确认目标笔记。"
        try render(PanelView(engine: engine, notesAccessIssueProvider: { nil }), size: NSSize(width: 520, height: 640), name: "panel-error-small", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }), size: NSSize(width: 940, height: 640), name: "settings-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }), size: NSSize(width: 940, height: 640), name: "settings-dark", directory: output, dark: true)

        let manualEngine = ChatEngine()
        manualEngine.output = "可以继续手动输入上下文和任务，使用 AI。"
        try render(PanelView(engine: manualEngine, notesAccessIssueProvider: { .accessibilityRequired }), size: NSSize(width: 560, height: 760), name: "panel-notes-access-ax-light", directory: output)
        try render(PanelView(engine: manualEngine, notesAccessIssueProvider: { .automationDenied }), size: NSSize(width: 560, height: 760), name: "panel-notes-access-automation-dark", directory: output, dark: true)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { .automationDenied }, initialPage: .general), size: NSSize(width: 940, height: 640), name: "settings-notes-access-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { .automationDenied }, initialPage: .general), size: NSSize(width: 940, height: 640), name: "settings-notes-access-dark", directory: output, dark: true)
        let notices = VStack(spacing: 12) {
            NotesAccessNoticeView(issue: .accessibilityRequired, allowsManualInput: true)
            NotesAccessNoticeView(issue: .automationDenied, allowsManualInput: true)
            NotesAccessNoticeView(issue: .identityUnavailable, allowsManualInput: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        try render(notices, size: NSSize(width: 560, height: 450), name: "notes-access-notices-light", directory: output)
        try render(notices, size: NSSize(width: 560, height: 450), name: "notes-access-notices-dark", directory: output, dark: true)

        // A real save preflight reaches the fake backend even while the profile
        // metadata remains volatile. A failed save must preserve that metadata
        // and expose the same recovery card shown after a credential-load error.
        let failingSecrets = SyntheticFailingProfileSecretStore()
        ProfileStore.secretStore = failingSecrets
        var deniedDraft = profile
        deniedDraft.apiKey = "synthetic-key-render-only"
        let metadataBeforeSave = defaults.data(forKey: ProfileStore.key)
        precondition(!ProfileStore.save([deniedDraft]) && ProfileStore.lastError?.contains("钥匙串") == true,
                     "Synthetic credential failure must reach the recovery UI")
        precondition(defaults.data(forKey: ProfileStore.key) == metadataBeforeSave,
                     "Failed synthetic credential save must preserve existing metadata")
        precondition(failingSecrets.readCount > 0 && UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[ProfileStore.key] != nil,
                     "Recovery fixture must use only the isolated store and preserve standard synthetic defaults")
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }), size: NSSize(width: 940, height: 640), name: "settings-keychain-recovery-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }), size: NSSize(width: 940, height: 640), name: "settings-keychain-recovery-dark", directory: output, dark: true)
        print("UI smoke: 14 native layouts rendered with isolated data")
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, name: String, directory: URL, dark: Bool = false) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let root = view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot allocate bitmap") }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        precondition(!host.hasAmbiguousLayout && host.bounds.width == size.width && host.bounds.height == size.height)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        print("PASS native layout \(name) \(Int(size.width))×\(Int(size.height))")
    }
}
