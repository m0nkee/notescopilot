import AppKit
import SwiftUI
import Accessibility
import SQLite3

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
        let updater = AppUpdater(currentVersion: "2.6.1", defaults: defaults)
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
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-dark", directory: output, dark: true)

        try checkTemplates(output: output, defaults: defaults, values: values, delegate: delegate, updater: updater)
        try checkPromptCategories(output: output)

        let manualEngine = ChatEngine()
        manualEngine.output = "可以继续手动输入上下文和任务，使用 AI。"
        try render(PanelView(engine: manualEngine, notesAccessIssueProvider: { .accessibilityRequired }), size: NSSize(width: 560, height: 760), name: "panel-notes-access-ax-light", directory: output)
        try render(PanelView(engine: manualEngine, notesAccessIssueProvider: { .automationDenied }), size: NSSize(width: 560, height: 760), name: "panel-notes-access-automation-dark", directory: output, dark: true)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { .automationDenied }, initialPage: .general, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-notes-access-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { .automationDenied }, initialPage: .general, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-notes-access-dark", directory: output, dark: true)
        defaults.set("v2.7.0", forKey: "nc.update.availableTag")
        let availableUpdater = AppUpdater(currentVersion: "2.6.1", defaults: defaults)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, initialPage: .general, updater: availableUpdater), size: NSSize(width: 900, height: 620), name: "settings-update-available-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, initialPage: .general, updater: availableUpdater), size: NSSize(width: 900, height: 620), name: "settings-update-available-dark", directory: output, dark: true)
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
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-keychain-recovery-light", directory: output)
        try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil }, updater: updater), size: NSSize(width: 940, height: 640), name: "settings-keychain-recovery-dark", directory: output, dark: true)
        print("UI smoke: 23 native layouts rendered with isolated data")
    }

    @MainActor private static func checkPromptCategories(output: URL) throws {
        let templates = (1...12).map {
            TemplateNote(name: "Entry-\($0)", content: "template body \($0)", sourceNotesID: "synthetic-category-\($0)")
        }
        TemplateStore.updateNotesTemplates(templates)
        defer { TemplateStore.updateNotesTemplates([]) }
        var prompt = "/templates"
        var suggestions: [SlashCommand] = []
        var selectedIndex = -1
        var accepted: [SlashCommand] = []
        let promptView = PromptTextView(
            text: Binding(get: { prompt }, set: { prompt = $0 }), commands: { buildSlashCommands() },
            onSuggestions: { list, reset in
                suggestions = list
                if let reset { selectedIndex = reset }
            },
            onMove: { delta in
                guard !suggestions.isEmpty else { return }
                selectedIndex = selectedIndex < 0 ? (delta > 0 ? 0 : suggestions.count - 1)
                    : (selectedIndex + delta + suggestions.count) % suggestions.count
            },
            onAccept: { accepted.append($0); suggestions = []; selectedIndex = -1 }, onRun: {},
            onCancelSuggestions: { suggestions = []; selectedIndex = -1 }, selectedIndex: { selectedIndex })
        let coordinator = promptView.makeCoordinator()
        let textView = NSTextView()
        coordinator.textView = textView
        func query(_ value: String) {
            textView.string = value
            textView.selectedRange = NSRange(location: value.utf16.count, length: 0)
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        @discardableResult func key(_ selector: Selector) -> Bool {
            coordinator.textView(textView, doCommandBy: selector)
        }

        query("/templates")
        precondition(suggestions.count == 12 && suggestions.allSatisfy { $0.group == .template },
                     "Prompt /templates must list all 12 templates without the general five/eight limits")
        precondition(selectedIndex == -1, "A new category query must begin without a selected command")
        key(#selector(NSResponder.insertNewline(_:)))
        precondition(accepted.isEmpty, "Return before arrow navigation must not execute a command")
        query("/templates")
        precondition(key(#selector(NSResponder.moveDown(_:))) && selectedIndex == 0,
                     "Down from no selection must select the first template")
        precondition(key(#selector(NSResponder.moveUp(_:))) && selectedIndex == 11,
                     "Up from the first template must wrap to the last template")
        var updated = templates
        updated[11].content = "updated template body 12"
        TemplateStore.updateNotesTemplates(updated)
        precondition(selectedIndex == 11, "A Notes content refresh must preserve keyboard selection")
        if case .insertTemplate(let displayed) = suggestions[11].action {
            precondition(displayed.content == "updated template body 12", "The visible menu action must receive the refreshed template body")
        } else { preconditionFailure("Visible template row must keep its template action") }
        key(#selector(NSResponder.insertNewline(_:)))
        precondition(accepted.count == 1 && accepted[0].name == "Entry-12",
                     "Return must execute the explicitly selected template")
        if case .insertTemplate(let template) = accepted[0].action {
            precondition(template.content == "updated template body 12", "Template execution must use the refreshed body")
        } else { preconditionFailure("Selected template must keep its template action") }

        query("/templates ")
        precondition(suggestions.count == 12, "A category followed by a space must retain its full list")
        query("/templates Entry-1")
        precondition(Set(suggestions.map(\.name)) == Set(["Entry-1", "Entry-10", "Entry-11", "Entry-12"]),
                     "Category plus space must filter by template name")
        query("/templates Entry-12")
        precondition(suggestions.count == 1 && suggestions[0].name == "Entry-12", "Category text filtering must find its precise template")
        precondition(key(#selector(NSResponder.moveUp(_:))) && selectedIndex == 0,
                     "Up from no selection must select the last filtered command")
        for (category, group) in [("/ai", SlashGroup.ai), ("/markdown", .markdown), ("/tools", .tool)] {
            query(category)
            precondition(!suggestions.isEmpty && suggestions.allSatisfy { $0.group == group } && selectedIndex == -1,
                         "Prompt category \(category) must use the shared category filter and clear selection")
        }
        print("PASS prompt categories list all templates, filter with spaces, navigate explicitly, and execute refreshed content")

        let engine = ChatEngine()
        for dark in [false, true] {
            try render(PanelView(engine: engine, notesAccessIssueProvider: { nil }),
                       size: NSSize(width: 560, height: 760), name: "panel-templates-category-\(dark ? "dark" : "light")",
                       directory: output, dark: dark, prepare: { root in
                guard let input = promptTextView(in: root) else { preconditionFailure("Native panel must contain the real prompt input") }
                input.string = "/templates"
                input.selectedRange = NSRange(location: input.string.utf16.count, length: 0)
                input.didChangeText()
                guard let coordinator = input.delegate as? PromptTextView.Coordinator else { preconditionFailure("Native prompt must retain its coordinator") }
                precondition(coordinator.suggestions.count == 12,
                             "Mounted native panel must display all template category suggestions")
                precondition(coordinator.parent.selectedIndex() == -1,
                             "The actual panel must begin a category query without a selected row")
                _ = coordinator.textView(input, doCommandBy: #selector(NSResponder.moveDown(_:)))
                precondition(coordinator.parent.selectedIndex() == 0, "The actual panel's Down key must select the first result")
                _ = coordinator.textView(input, doCommandBy: #selector(NSResponder.moveUp(_:)))
                precondition(coordinator.parent.selectedIndex() == 11, "The actual panel's Up key must wrap to the last result")
                input.string = "/templates "
                input.selectedRange = NSRange(location: input.string.utf16.count, length: 0)
                input.didChangeText()
            }, verify: { root in
                guard let input = promptTextView(in: root) else { preconditionFailure("Native panel must retain the prompt input") }
                precondition(input.bounds.height > 0 && input.visibleRect.height >= min(44, input.bounds.height),
                             "Expanded category menu must keep the prompt input visible inside the outer scroll viewport")
            })
        }
    }

    @MainActor private static func promptTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.delegate is PromptTextView.Coordinator { return textView }
        return view.subviews.lazy.compactMap { promptTextView(in: $0) }.first
    }

    @MainActor private static func checkTemplates(output: URL, defaults: UserDefaults,
                                                 values: [String: Any], delegate: AppDelegate,
                                                 updater: AppUpdater) throws {
        let path = NSTemporaryDirectory() + "nc-template-ui-\(UUID().uuidString).sqlite"
        defer {
            delegate.notesStore = nil
            delegate.notesStoreError = nil
            delegate.notesStoreLoading = false
            delegate.notesTemplatesLoading = false
            TemplateStore.updateNotesTemplates([])
            defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(atPath: path)
        }
        delegate.notesStore = try makeEmptyNotesStore(path: path)
        TemplateStore.updateNotesTemplates([])
        func snapshot(_ name: String, dark: Bool = false) throws {
            try render(SettingsView(discoverLocalModels: false, notesAccessIssueProvider: { nil },
                                    initialPage: .templates, updater: updater),
                       size: NSSize(width: 900, height: 620), name: name, directory: output, dark: dark)
        }
        try snapshot("settings-templates-empty")

        var templateValues = values
        templateValues["nc.templates"] = try JSONEncoder().encode([
            TemplateNote(name: "本地签名", content: "祝好，\nNotesCopilot 用户")
        ])
        defaults.setVolatileDomain(templateValues, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(templateValues, forName: UserDefaults.argumentDomain)
        let notes = [
            TemplateNote(name: "会议纪要", content: "# 会议纪要\n\n日期：{{date}}\n参会人：{{ask:参会人}}\n\n{{ai:根据上下文提取讨论要点与行动项}}", sourceNotesID: "synthetic-meeting"),
            TemplateNote(name: "Daily Report", content: "# Daily Report\n\n{{date}}\n- 今日完成\n- 明日计划", sourceNotesID: "synthetic-daily")
        ]
        TemplateStore.updateNotesTemplates(notes)
        try snapshot("settings-templates-populated-light")
        try snapshot("settings-templates-populated-dark", dark: true)

        TemplateStore.updateNotesTemplates([])
        delegate.notesStore = nil
        delegate.notesStoreError = "无法读取 Notes 数据库——需要在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中授权 NotesCopilot。"
        try snapshot("settings-templates-permission-error")
        delegate.notesStoreError = nil
        delegate.notesStoreLoading = true
        try snapshot("settings-templates-loading")

        // Start with an unmatched query before a Notes scan finishes. The scan's
        // notification must refresh that query, but respect a later Escape.
        var prompt = "/NotesArrival"
        var suggestions: [SlashCommand] = []
        let promptView = PromptTextView(
            text: Binding(get: { prompt }, set: { prompt = $0 }), commands: { buildSlashCommands() },
            onSuggestions: { list, _ in suggestions = list }, onMove: { _ in }, onAccept: { _ in }, onRun: {},
            onCancelSuggestions: { suggestions = [] }, selectedIndex: { 0 })
        let coordinator = promptView.makeCoordinator()
        let textView = NSTextView()
        textView.string = prompt
        textView.selectedRange = NSRange(location: prompt.utf16.count, length: 0)
        coordinator.textView = textView
        coordinator.refreshSuggestions(textView)
        precondition(suggestions.isEmpty && !coordinator.active, "Unmatched query fixture must begin with no suggestions")
        let arrival = TemplateNote(name: "NotesArrival", content: "arrived", sourceNotesID: "synthetic-arrival")
        TemplateStore.updateNotesTemplates([arrival])
        precondition(suggestions.count == 1 && suggestions.first?.name == "NotesArrival" && coordinator.active,
                     "Notes scan completion must refresh a previously unmatched slash query")
        precondition(coordinator.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                     "Escape must dismiss active slash suggestions")
        TemplateStore.updateNotesTemplates([arrival])
        precondition(suggestions.isEmpty && !coordinator.active,
                     "A later Notes template notification must preserve Escape dismissal")
        print("PASS Notes template arrivals refresh unmatched queries and preserve Escape dismissal")
    }

    private static func makeEmptyNotesStore(path: String) throws -> NotesStore {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "TemplateUISyntheticStore", code: 1)
        }
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
              Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZTITLE1 TEXT, ZTITLE2 TEXT,
              ZSNIPPET TEXT, ZISPINNED INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER,
              ZMODIFICATIONDATE1 REAL, ZCREATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER DEFAULT 0,
              ZNOTEDATA INTEGER, ZDATA BLOB
            );
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, ZNAME TEXT);
            INSERT INTO Z_PRIMARYKEY VALUES (11, 'ICFolder'), (12, 'ICNote'), (13, 'ICNoteData');
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TemplateUISyntheticStore", code: Int(sqlite3_errcode(database)))
        }
        return try NotesStore(path: path, enableFTS: false)
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, name: String, directory: URL,
                                          dark: Bool = false, prepare: ((NSView) -> Void)? = nil,
                                          verify: ((NSView) -> Void)? = nil) throws {
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
        if let prepare {
            prepare(host)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        verify?(host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot allocate bitmap") }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        precondition(!host.hasAmbiguousLayout && host.bounds.width == size.width && host.bounds.height == size.height)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        print("PASS native layout \(name) \(Int(size.width))×\(Int(size.height))")
    }
}
