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
    @ObservedObject private var localization = L10n.shared
    @Binding var text: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = InstructionField()
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
        field.placeholderString = L10n.text("Describe the change you want…")
        field.setAccessibilityLabel(L10n.text("Custom Instruction"))
        field.setAccessibilityHelp(L10n.text("Press I to enter an instruction, then Return to run it"))
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
    static var displayName: String { L10n.text("Copilot Writing Tools") }
    static let size = NSSize(width: 184, height: 32)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let label = Self.displayName
        title = label
        setAccessibilityLabel(label)
        toolTip = L10n.format("Open %@ (M)", label)
        setAccessibilityHelp(L10n.format("Press M to open %@", label))
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
    @ObservedObject private var localization = L10n.shared
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
                    Text(model.action.map { L10n.format("Running %@…", $0.displayName) }
                         ?? L10n.text("Working…"))
                    Spacer()
                    Button(L10n.text("Cancel"), action: model.dismiss)
                }
            case .review: review
            case .unavailable:
                feedback
                Button(L10n.text("Read Selection Again"), action: model.openTools)
            case .launcher: EmptyView()
            }
        }
        .padding(12)
        .frame(width: pendingSize?.width ?? (model.phase == .review ? 420 : 340))
        .frame(minHeight: pendingSize?.height, alignment: .topLeading)
        .environment(\.locale, localization.locale)
        .controlSize(.small)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.22)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "book").foregroundStyle(Color.accentColor)
            Text(model.phase == .review ? (model.action?.displayName ?? L10n.text("Result"))
                  : SelectionLauncherButton.displayName)
                .font(.headline)
            Spacer()
            if let source = model.sourceName {
                Text(L10n.format(model.original.count == 1 ? "%@ · %lld character" : "%@ · %lld characters",
                                 source, Int64(model.original.count))).lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(action: model.dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Close Writing Tools"))
            .help(L10n.text("Close Writing Tools (Esc)"))
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
                    .accessibilityLabel(L10n.text("Run Custom Instruction"))
                    .disabled(model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            ForEach(SelectionQuickAction.Group.allCases, id: \.self) { group in
                HStack(spacing: 6) {
                    Text(group.title).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    ForEach(selectionQuickActions.filter { $0.group == group }, id: \.name) { action in
                        if let key = action.shortcut {
                            shortcutButton(action.displayName, key: key) { model.run(action) }
                                .help(L10n.format("%@ (%@)",
                                                  action.instruction == .translate ? WritingInstruction.translationHint : action.displayName,
                                                  key.uppercased()))
                        }
                    }
                }
            }
            if !model.formats.isEmpty {
                Divider()
                Menu(L10n.text("Notes Formatting")) {
                    ForEach(model.formats, id: \.menuTitle) { item in
                        Button(item.label) { model.applyFormat(item) }
                    }
                }
                .fixedSize()
            }
            feedback
            Text(L10n.text("Choose by letter · Return to run · Esc to go back"))
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
                    Picker(L10n.text("View Text"), selection: $model.showingOriginal) {
                        Text(L10n.text("Result")).tag(false)
                        Text(L10n.text("Original")).tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .accessibilityLabel(L10n.text("View Text"))
                    .accessibilityHint(L10n.text("Press O to switch between the original and the result"))
                    keyHint(SelectionReviewKey.original.rawValue)
                }
                .help(L10n.text("Switch between original and result (O)"))
                Button {
                    model.showDiff()
                } label: {
                    Text(L10n.text("Show Changes"))
                }
                .buttonStyle(.borderless)
                .disabled(model.writing || model.original.isEmpty || model.result.isEmpty)
                if model.showingDiff {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.diffLines) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(verbatim: line.kind == .removed ? "-" : line.kind == .added ? "+" : " ")
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 12)
                                    Text(verbatim: line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(line.kind == .removed ? Color.red.opacity(0.12)
                                            : line.kind == .added ? Color.green.opacity(0.12) : Color.clear)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 124)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                } else if model.showingOriginal {
                    ScrollView {
                        Text(verbatim: model.original)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 124)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                } else {
                    TextEditor(text: Binding(
                        get: { model.result },
                        set: { model.updateResult($0) }
                    ))
                    .font(.system(.callout, design: .default))
                    .frame(height: 124)
                    .scrollContentBackground(.hidden)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    .disabled(model.writing)
                    .accessibilityLabel(L10n.text("Edit AI Result"))
                    if model.resultEdited {
                        Text(L10n.text("Your edits will be used when writing back."))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            feedback
            ViewThatFits(in: .horizontal) {
                HStack {
                    reviewNavigation
                    Spacer(minLength: 0)
                    reviewResultActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    reviewNavigation
                    reviewResultActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .disabled(model.writing)
            .confirmationDialog(model.writePreviewTitle, isPresented: Binding(
                get: { model.pendingWriteAppend != nil },
                set: { if !$0 { model.cancelWritePreview() } }
            ), titleVisibility: .visible) {
                let title = model.pendingWriteAppend == true ? L10n.text("Confirm Append") : L10n.text("Confirm Replacement")
                Button(title, role: .destructive) {
                    model.confirmPendingWrite()
                }
                Button(L10n.text("Cancel"), role: .cancel) { model.cancelWritePreview() }
            } message: {
                Text(model.writePreviewText)
            }
        }
    }

    private var reviewNavigation: some View {
        HStack {
            if model.needsConfiguration && model.result.isEmpty {
                Button(L10n.text("Model Settings…")) {
                    model.hide()
                    NotificationCenter.default.post(name: .init("nc.openSettings"), object: nil)
                }
            }
            shortcutButton(L10n.text("Back to Tools"), key: SelectionReviewKey.back.rawValue, action: model.chooseAnotherTool)
            if let action = model.action {
                let title = model.result.isEmpty ? L10n.text("Retry") : L10n.text("Regenerate")
                shortcutButton(title, key: SelectionReviewKey.generate.rawValue) { model.run(action) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var reviewResultActions: some View {
        if !model.result.isEmpty {
            let preferReplace = model.canWrite && model.action?.group == .edit
            let copyTitle = model.showingOriginal ? L10n.text("Copy Original") : L10n.text("Copy Result")
            HStack {
                shortcutButton(copyTitle, key: SelectionReviewKey.copy.rawValue, primary: !preferReplace) { model.copyPreview() }
                if model.hasReplacementTarget && !model.staleSelection {
                    shortcutButton(L10n.text("Append"), key: SelectionReviewKey.append.rawValue) { model.prepareWrite(append: true) }
                        .help(L10n.text("Append after the original selection (A)")).disabled(!model.canWrite)
                    shortcutButton(L10n.text("Replace"), key: SelectionReviewKey.replace.rawValue, primary: preferReplace) { model.prepareWrite(append: false) }
                        .disabled(!model.canWrite)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
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
        .accessibilityHint(Text(L10n.format("Shortcut %@", key.uppercased())))
        .help(L10n.format("%@ (%@)", title, key.uppercased()))
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
