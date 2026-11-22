import SwiftUI

/// A nonactivating panel receives its first click directly in this AppKit button.
final class SelectionLauncherButton: NSButton {
    static let size = NSSize(width: 154, height: 30)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let label = "Copilot 写作工具"
        title = label
        setAccessibilityLabel(label)
        toolTip = "打开写作工具（M）"
        setAccessibilityHelp("按 M 打开写作工具")
        image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        controlSize = .regular
        let caption = NSMutableAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)])
        caption.append(NSAttributedString(string: "   M", attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                                                                         .foregroundColor: NSColor.secondaryLabelColor]))
        attributedTitle = caption
        self.target = target
        self.action = action
        // Open on the press, as a menu button does. The host can withdraw its
        // selection or redirect mouse-up when a nonactivating panel takes focus.
        sendAction(on: .leftMouseDown)
    }

    required init?(coder: NSCoder) { nil }
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
            Image(systemName: "pencil.and.outline").foregroundStyle(Color.accentColor)
            Text(model.phase == .review ? (model.action?.name ?? "写作结果") : "Copilot 写作工具")
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
            .accessibilityLabel("关闭写作工具")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var menu: some View {
        Group {
            excerpt
            HStack(spacing: 6) {
                TextField("描述想做的修改…", text: $model.customInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.runCustom)
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
                        Button(action.name) { model.run(action) }
                            .help(action.name == "翻译" ? "翻译成英文" : action.name)
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
        }
    }

    private var excerpt: some View {
        Text(verbatim: model.original).font(.callout).foregroundStyle(.secondary)
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var review: some View {
        Group {
            if !model.result.isEmpty {
                Picker("查看文本", selection: $model.showingOriginal) {
                    Text("结果").tag(false)
                    Text("原文").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented)
                .accessibilityLabel("查看文本")
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
                Button("换个工具", action: model.chooseAnotherTool)
                if let action = model.action {
                    Button(model.result.isEmpty ? "重试" : "重新生成") { model.run(action) }
                }
                Spacer()
                if !model.result.isEmpty {
                    let preferReplace = model.canWrite && model.action?.group == .edit
                    resultButton(model.showingOriginal ? "复制原文" : "复制结果", primary: !preferReplace) { model.copyPreview() }
                    if model.hasReplacementTarget && !model.staleSelection {
                        Button("追加") { model.writeResult(append: true) }
                            .help("追加到原选区末尾").disabled(!model.canWrite)
                        resultButton("替换选区", primary: preferReplace) { model.writeResult(append: false) }
                            .disabled(!model.canWrite)
                    }
                }
            }
            .disabled(model.writing)
        }
    }

    @ViewBuilder private func resultButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(title, action: action)
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
