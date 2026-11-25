import SwiftUI

/// The launcher stays passive. Once opened, the panel owns its command keys
/// through the normal window responder chain, including for macOS Services.
final class SelectionKeyPanel: NSPanel {
    static let instructionKey = "i"
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    weak var instructionField: NSTextField?
    var performToolKey: ((String) -> Bool)?
    var dismiss: (() -> Void)?
    private var consumedKey: UInt16?

    func focusInstruction() -> Bool {
        // Returning from review creates a fresh hosting view. Attach its
        // native field before routing a rapidly following I keystroke.
        contentView?.layoutSubtreeIfNeeded()
        guard let field = instructionField, field.window === self,
              makeFirstResponder(field), let editor = field.currentEditor() else { return false }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp, consumedKey == event.keyCode {
            consumedKey = nil
            return
        }
        guard event.type == .keyDown, isKeyWindow, acceptsKeyboard else { super.sendEvent(event); return }
        if event.isARepeat, consumedKey == event.keyCode { return }
        if !event.isARepeat { consumedKey = nil }
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        guard !event.isARepeat, event.modifierFlags.intersection(modifiers).isEmpty else { super.sendEvent(event); return }
        let editor = firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { super.sendEvent(event); return }
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            guard editor?.isEditable != true, let key = event.charactersIgnoringModifiers?.lowercased(),
                  performToolKey?(key) == true else { super.sendEvent(event); return }
        }
        consumedKey = event.keyCode
    }

    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.isEditable {
            if !editor.hasMarkedText() { makeFirstResponder(nil) }
        } else {
            dismiss?()
        }
    }
}

private final class InstructionField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? SelectionKeyPanel)?.instructionField = self
    }
}

private struct SelectionInstructionField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = InstructionField()
        field.placeholderString = "描述想做的修改…"
        field.setAccessibilityLabel("自定义指令")
        field.setAccessibilityHelp("按 I 输入指令，按回车执行")
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byTruncatingTail
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectionInstructionField
        init(_ parent: SelectionInstructionField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        @objc func submit(_ sender: NSTextField) {
            guard (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = sender.stringValue
            parent.submit()
        }
    }
}

/// A nonactivating panel receives its first click directly in this AppKit button.
final class SelectionLauncherButton: NSButton {
    static let displayName = "Copilot 写作阅读助手"
    static let size = NSSize(width: 184, height: 32)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let label = Self.displayName
        title = label
        setAccessibilityLabel(label)
        toolTip = "打开\(label)（M）"
        setAccessibilityHelp("按 M 打开\(label)")
        image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        contentTintColor = .labelColor
        controlSize = .regular
        let caption = NSMutableAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        caption.append(NSAttributedString(string: "   M", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]))
        attributedTitle = caption
        self.target = target
        self.action = action
        // Open on the press, as a menu button does. The host can withdraw its
        // selection or redirect mouse-up when a nonactivating panel takes focus.
        sendAction(on: .leftMouseDown)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The host can be any colour, even when its appearance differs from ours.
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        bezel.fill()
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            bezel.fill()
        }
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.9 : 0.6).setStroke()
        bezel.lineWidth = highContrast ? 2 : 1.5
        bezel.stroke()
        super.draw(dirtyRect)
    }
}

struct SelectionToolsView: View {
    @ObservedObject var model: SelectionAIPanel
    var pendingSize: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.phase {
            case .menu: menu
            case .working:
                excerpt
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在\(model.action?.name ?? "处理")…")
                    Spacer()
                    Button("取消", action: model.dismiss)
                }
            case .review: review
            case .unavailable:
                feedback
                Button("重新读取选区", action: model.openTools)
            case .launcher: EmptyView()
            }
        }
        .padding(12)
        .frame(width: pendingSize?.width ?? (model.phase == .review ? 420 : 340))
        .frame(minHeight: pendingSize?.height, alignment: .topLeading)
        .controlSize(.small)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.22)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "book").foregroundStyle(Color.accentColor)
            Text(model.phase == .review ? (model.action?.name ?? "处理结果") : SelectionLauncherButton.displayName)
                .font(.headline)
            Spacer()
            if let source = model.sourceName {
                Text("\(source) · \(model.original.count) 字").lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(action: model.dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭写作阅读助手")
            .help("关闭写作阅读助手（Esc）")
        }
    }

    private var menu: some View {
        Group {
            excerpt
            HStack(spacing: 6) {
                keyHint(SelectionKeyPanel.instructionKey)
                SelectionInstructionField(text: $model.customInstruction, submit: model.runCustom)
                    .frame(maxWidth: .infinity)
                Button(action: model.runCustom) { Image(systemName: "arrow.right") }
                    .accessibilityLabel("执行自定义指令")
                    .disabled(model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            ForEach(SelectionQuickAction.Group.allCases, id: \.self) { group in
                HStack(spacing: 6) {
                    Text(group.rawValue).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    ForEach(selectionQuickActions.filter { $0.group == group }, id: \.name) { action in
                        if let key = action.shortcut {
                            shortcutButton(action.name, key: key) { model.run(action) }
                                .help("\(action.instruction == .translate ? WritingInstruction.translationHint : action.name)（\(key.uppercased())）")
                        }
                    }
                }
            }
            if !model.formats.isEmpty {
                Divider()
                Menu("Notes 格式") {
                    ForEach(model.formats, id: \.menuTitle) { item in
                        Button(item.label) { model.applyFormat(item) }
                    }
                }
                .fixedSize()
            }
            feedback
            Text("按字母选工具 · 输入时 ↩ 执行，Esc 返回")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var excerpt: some View {
        Text(verbatim: model.original).font(.callout).foregroundStyle(.secondary)
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var review: some View {
        Group {
            if !model.result.isEmpty {
                HStack(spacing: 6) {
                    Picker("查看文本", selection: $model.showingOriginal) {
                        Text("结果").tag(false)
                        Text("原文").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .accessibilityLabel("查看文本")
                    .accessibilityHint("按 O 切换原文与结果")
                    keyHint(SelectionReviewKey.original.rawValue)
                }
                .help("切换原文与结果（O）")
                .disabled(model.writing)
                ScrollView {
                    Text(verbatim: model.showingOriginal ? model.original : model.result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 124)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            }
            feedback
            HStack {
                if model.needsConfiguration && model.result.isEmpty {
                    Button("模型设置…") {
                        model.hide()
                        NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
                    }
                }
                shortcutButton("换个工具", key: SelectionReviewKey.back.rawValue, action: model.chooseAnotherTool)
                if let action = model.action {
                    shortcutButton(model.result.isEmpty ? "重试" : "重新生成", key: SelectionReviewKey.generate.rawValue) { model.run(action) }
                }
                Spacer()
                if !model.result.isEmpty {
                    let preferReplace = model.canWrite && model.action?.group == .edit
                    shortcutButton(model.showingOriginal ? "复制原文" : "复制结果", key: SelectionReviewKey.copy.rawValue, primary: !preferReplace) { model.copyPreview() }
                    if model.hasReplacementTarget && !model.staleSelection {
                        shortcutButton("追加", key: SelectionReviewKey.append.rawValue) { model.writeResult(append: true) }
                            .help("追加到原选区末尾（A）").disabled(!model.canWrite)
                        shortcutButton("替换选区", key: SelectionReviewKey.replace.rawValue, primary: preferReplace) { model.writeResult(append: false) }
                            .disabled(!model.canWrite)
                    }
                }
            }
            .disabled(model.writing)
        }
    }

    private func keyHint(_ key: String) -> some View {
        Text(verbatim: key.uppercased()).font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary).accessibilityHidden(true)
    }

    @ViewBuilder private func shortcutButton(_ title: String, key: String, primary: Bool = false,
                                            action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 4) { Text(verbatim: title); keyHint(key) }
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text("快捷键 \(key.uppercased())"))
        .help("\(title)（\(key.uppercased())）")
        if primary { button.buttonStyle(.borderedProminent) } else { button }
    }

    @ViewBuilder private var feedback: some View {
        if !model.status.isEmpty {
            Text(verbatim: model.status).font(.caption).foregroundStyle(.secondary)
                .lineLimit(4).help(model.status)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
