import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum SelectionScope: String {
    case notes, global

    enum PrivacyMode: String {
        case blocklist, allowlist

        static let defaultsKey = "nc.selai.privacy.mode"
    }

    static let defaultsKey = "nc.selai.scope"
    static let enabledKey = "nc.selai.enabled"
    static let pausedKey = "nc.selai.paused"
    static let privacyAppsKey = "nc.selai.privacy.apps"

    static func current(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .notes
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    static func privacyMode(in defaults: UserDefaults = .standard) -> PrivacyMode {
        defaults.string(forKey: PrivacyMode.defaultsKey).flatMap(PrivacyMode.init(rawValue:)) ?? .blocklist
    }

    static func isPaused(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pausedKey)
    }

    /// 只保存应用标识，不保存选中文本。
    static func privacyApps(in defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: privacyAppsKey) ?? []).filter { !$0.isEmpty }
    }

    static func allowsGlobalSelection(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && current(in: defaults) == .global && !isPaused(in: defaults)
    }

    static func allowsApplication(_ app: NSRunningApplication?, in defaults: UserDefaults = .standard) -> Bool {
        guard allowsGlobalSelection(in: defaults), let app else { return false }
        let identity = app.bundleIdentifier ?? app.localizedName ?? String(app.processIdentifier)
        return allows(identity: identity, in: defaults)
    }

    static func allows(identity: String, in defaults: UserDefaults = .standard) -> Bool {
        guard allowsGlobalSelection(in: defaults) else { return false }
        let apps = Set(privacyApps(in: defaults))
        return privacyMode(in: defaults) == .allowlist ? apps.contains(identity) : !apps.contains(identity)
    }
}

enum AXText {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ object: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(object, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
    }

    static func range(of element: AXUIElement, attribute name: String = kAXSelectedTextRangeAttribute) -> CFRange? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success else { return nil }
        return value
    }

    static func bounds(_ element: AXUIElement, _ selection: CFRange) -> CGRect? {
        var range = selection
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return rect(self.parameter(element, kAXBoundsForRangeParameterizedAttribute, parameter))
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty, !rect.isInfinite else { return nil }
        return rect
    }

    static func isProtected(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
            || attribute(element, "AXProtectedContent") as? Bool == true
    }

    static func isComposing(_ element: AXUIElement) -> Bool {
        (range(of: element, attribute: "AXMarkedTextRange")?.length ?? 0) > 0
    }
}

// Chromium and Electron expose the renderer's accessibility tree on request. Remember
// each activation because requesting the mode on every poll resets Chromium's debounce.
@MainActor
final class BrowserSelectionAccess {
    private var current: NSRunningApplication?
    private var attribute: String?
    private var requested = false
    private var nextCheck = Date.distantPast

    func update(for app: NSRunningApplication?) {
        if current != app {
            if let current, !current.isTerminated, requested, let attribute {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(current.processIdentifier), attribute as CFString, kCFBooleanFalse)
            }
            current = app
            attribute = nil
            requested = false
            nextCheck = .distantPast
        }
        guard let app, Date() >= nextCheck else { return }
        nextCheck = Date().addingTimeInterval(3)
        if attribute == nil {
            // Launch Services may announce a new process before its bundle and AX server are ready.
            guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks") else { return }
            let files = FileManager.default
            if files.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
                attribute = "AXManualAccessibility"
            } else if let bundles = try? files.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil),
                      bundles.contains(where: { framework in
                          framework.pathExtension == "framework" && files.fileExists(
                              atPath: framework.appendingPathComponent("Resources/chrome_100_percent.pak").path)
                      }) {
                attribute = "AXEnhancedUserInterface"
            } else {
                nextCheck = .distantFuture
                return
            }
        }
        guard let attribute else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        if AXText.attribute(element, attribute) as? Bool == true { return }
        if requested, AXText.attribute(element, "AXManualAccessibility") != nil,
           AXText.element(element, kAXFocusedUIElementAttribute) != nil { return }
        // Chrome forwards the request and can still report attributeUnsupported from AppKit.
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        if status == .success || status == .attributeUnsupported { requested = true }
    }
}

struct InputFieldHost {
    let application: NSRunningApplication
    let window: AXUIElement
    let editable: Bool
}

enum SelectionExtent {
    case characters(CFRange)
    case markers(AXTextMarkerRange)
    case excerpt(String) // Some read-only controls expose only AXSelectedText.

    enum Identity: Hashable {
        case characters(Int, Int), markers(Data, Data), excerpt(String)
    }

    var identity: Identity {
        switch self {
        case .characters(let range): return .characters(range.location, range.length)
        case .markers(let range):
            func bytes(_ marker: AXTextMarker) -> Data {
                Data(bytes: AXTextMarkerGetBytePtr(marker), count: AXTextMarkerGetLength(marker))
            }
            return .markers(bytes(AXTextMarkerRangeCopyStartMarker(range)), bytes(AXTextMarkerRangeCopyEndMarker(range)))
        case .excerpt(let text): return .excerpt(text)
        }
    }

    func bounds(in element: AXUIElement) -> CGRect? {
        switch self {
        case .characters(let range): return AXText.bounds(element, range)
        case .markers(let range):
            return AXText.rect(AXText.parameter(element, "AXBoundsForTextMarkerRange", range))
        case .excerpt: return nil
        }
    }

    func text(in element: AXUIElement) -> String? {
        if case .markers(let range) = self,
           let text = AXText.parameter(element, "AXStringForTextMarkerRange", range) as? String, !text.isEmpty { return text }
        if case .excerpt(let text) = self { return text }
        return AXText.attribute(element, kAXSelectedTextAttribute) as? String
    }
}

struct TextSelectionAnchor {
    enum Source { case notes, input(InputFieldHost) }
    let element: AXUIElement
    let extent: SelectionExtent
    var bounds: CGRect?
    let source: Source

    init(element: AXUIElement, extent: SelectionExtent, bounds: CGRect? = nil, source: Source) {
        self.element = element
        self.extent = extent
        self.bounds = bounds
        self.source = source
    }

    init(element: AXUIElement, range: CFRange, bounds: CGRect?) {
        self.init(element: element, extent: .characters(range), bounds: bounds, source: .notes)
    }

    var signature: String {
        let owner: String
        switch source {
        case .notes: owner = "notes"
        case .input(let host): owner = "\(host.application.processIdentifier):\(CFHash(host.window)):\(host.editable)"
        }
        return "\(owner):\(CFHash(element)):\(extent.identity.hashValue)"
    }

    func matches(_ element: AXUIElement, _ range: CFRange) -> Bool {
        CFEqual(self.element, element) && extent.identity == .characters(range.location, range.length)
    }
}

struct InputFieldSelection {
    let host: InputFieldHost
    let anchor: TextSelectionAnchor
    let text: String
    let fieldValue: String? // Full value is captured only for a verified editable target.
    let document: String?
    let windowTitle: String?
}

/// A local snapshot of an editable caret, captured before the instruction panel takes focus.
@MainActor
struct InstructionInsertionTarget {
    private enum Destination {
        case notes(NotesBridge.InstructionCaret)
        case input(InputFieldBridge.InstructionCaret)
    }

    private let destination: Destination
    private let foreground: SourceForeground

    @MainActor
    private final class SourceForeground {
        private let center = NSWorkspace.shared.notificationCenter
        private var observer: NSObjectProtocol?
        private(set) var switchedAway = false

        init(application: NSRunningApplication) {
            let sourcePID = application.processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                if pid != sourcePID && pid != ownPID {
                    MainActor.assumeIsolated { self?.switchedAway = true }
                }
            }
        }

        deinit {
            if let observer { center.removeObserver(observer) }
        }
    }

    static func capture(in app: NSRunningApplication) -> Self? {
        guard !app.isTerminated, !IsSecureEventInputEnabled(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let foreground = SourceForeground(application: app)
        let destination: Destination
        if app.bundleIdentifier == NotesBridge.notesBundleID {
            guard let caret = NotesBridge.shared.captureInstructionCaret(in: app) else { return nil }
            destination = .notes(caret)
        } else {
            guard let caret = InputFieldBridge.captureInstructionCaret(in: app) else { return nil }
            destination = .input(caret)
        }
        guard !foreground.switchedAway else { return nil }
        return Self(destination: destination, foreground: foreground)
    }

    func insert(_ text: String, isValid: @escaping () -> Bool) async -> String? {
        guard isValid(), !Task.isCancelled else { return L10n.text("Operation canceled.") }
        guard !text.isEmpty else { return nil }
        guard !foreground.switchedAway else { return L10n.text("The original app, text field, or selection changed.") }
        let isCurrent = { !foreground.switchedAway && isValid() }
        switch destination {
        case .notes(let caret):
            return await NotesBridge.shared.insertInstruction(text, into: caret, isValid: isCurrent)
        case .input(let caret):
            return await InputFieldBridge.insertInstruction(text, into: caret, isValid: isCurrent)
        }
    }

    /// The standalone panel activates NotesCopilot. Only that handoff may
    /// reactivate the bound app. Never pull focus back from a different app.
    static func restoreHost(_ app: NSRunningApplication, isValid: () -> Bool) async -> Bool {
        guard isValid(), !Task.isCancelled, !app.isTerminated, !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.processIdentifier == app.processIdentifier { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard front.processIdentifier == ownPID, app.activate(options: []) else { return false }
        for _ in 0..<16 {
            guard isValid(), !Task.isCancelled, !app.isTerminated, !IsSecureEventInputEnabled(),
                  let current = NSWorkspace.shared.frontmostApplication else { return false }
            if current.processIdentifier == app.processIdentifier { return true }
            guard current.processIdentifier == ownPID else { return false }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    static func isCaret(_ range: CFRange, in value: NSString) -> Bool {
        guard range.length == 0, (0...value.length).contains(range.location) else { return false }
        // AX offsets are UTF-16. A collapsed range may sit between combining
        // characters but cannot split the two halves of one scalar.
        return range.location == value.length || !(0xDC00...0xDFFF).contains(value.character(at: range.location))
    }
}

@MainActor
enum InputFieldBridge {
    struct InstructionFieldSnapshot {
        let value: String
        let range: CFRange
        private let editorIsEmpty: Bool?

        init(value: String, range: CFRange, editorIsEmpty: Bool?) {
            self.value = value
            self.range = range
            self.editorIsEmpty = !value.isEmpty && range.location == 0 && range.length == 0 ? editorIsEmpty : nil
        }

        var showsPlaceholder: Bool { editorIsEmpty == true }

        func matches(_ current: Self) -> Bool {
            range.location == current.range.location && range.length == current.range.length
                && value.utf16.elementsEqual(current.value.utf16)
                && editorIsEmpty == current.editorIsEmpty
        }

        func expectedValue(inserting text: String) -> String {
            if showsPlaceholder { return text }
            return (value as NSString).replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: text)
        }

        func verifiesInsertion(_ actual: String, expected: String, pasted: Bool,
                               editorIsEmpty: @autoclosure () -> Bool?) -> Bool {
            if showsPlaceholder {
                guard actual.utf16.elementsEqual(expected.utf16) else { return false }
                // If the result literally equals the placeholder, AXValue cannot
                // distinguish an unchanged editor from a successful paste.
                return !actual.utf16.elementsEqual(value.utf16) || editorIsEmpty() == false
            }
            let length = expected.utf16.count - value.utf16.count + range.length
            return InputFieldBridge.matchesWrite(actual, expected: expected,
                inserted: NSRange(location: range.location, length: length), pasted: pasted)
        }
    }

    struct InstructionCaret {
        let host: InputFieldHost
        let element: AXUIElement
        let field: InstructionFieldSnapshot
        let document: String?
        let windowTitle: String?
    }

    private enum CaretFocus: Equatable { case ready, restoring, changed }

    private static func selection(in element: AXUIElement) -> SelectionExtent? {
        if let ranges = AXText.attribute(element, kAXSelectedTextRangesAttribute) as? [Any], ranges.count > 1 { return nil }
        let range = AXText.range(of: element)
        if let range, range.location >= 0, range.length > 0 { return .characters(range) }
        if let raw = AXText.attribute(element, "AXSelectedTextMarkerRange"), CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() {
            let markers = raw as! AXTextMarkerRange
            let start = AXTextMarkerRangeCopyStartMarker(markers), end = AXTextMarkerRangeCopyEndMarker(markers)
            guard !CFEqual(start, end) else { return nil }
            if let length = AXText.parameter(element, "AXLengthForTextMarkerRange", markers) as? NSNumber, length.intValue <= 0 { return nil }
            return .markers(markers)
        }
        if range == nil, let text = AXText.attribute(element, kAXSelectedTextAttribute) as? String, !text.isEmpty { return .excerpt(text) }
        return nil
    }

    private static func isField(_ role: String?) -> Bool {
        guard let role else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    private static func isWritable(_ element: AXUIElement) -> Bool {
        // WebKit advertises writable AXSelectedText even for readonly HTML inputs.
        AXText.attribute(element, kAXEnabledAttribute) as? Bool != false &&
            (AXText.isSettable(element, kAXValueAttribute) ||
             (AXText.attribute(element, "AXEditable") as? Bool == true && AXText.isSettable(element, kAXSelectedTextAttribute)))
    }

    private static func instructionRange(in element: AXUIElement, value: String) -> CFRange? {
        guard isField(AXText.attribute(element, kAXRoleAttribute) as? String), isWritable(element),
              AXText.attribute(element, "AXEditable") as? Bool != false,
              !AXText.isProtected(element), !AXText.isComposing(element),
              let range = AXText.range(of: element), InstructionInsertionTarget.isCaret(range, in: value as NSString),
              selection(in: element) == nil,
              ((AXText.attribute(element, kAXSelectedTextRangesAttribute) as? [Any])?.count ?? 0) <= 1,
              (AXText.attribute(element, kAXSelectedTextAttribute) as? String)?.isEmpty != false
        else { return nil }
        return range
    }

    nonisolated static func emptyProseMirrorState(
        role: String?, classes: [String]?, children: @autoclosure () -> [(role: String?, classes: [String]?)]?
    ) -> Bool? {
        guard let role else { return nil }
        guard role == kAXTextAreaRole else { return false }
        guard let classes else { return nil }
        guard classes.contains("ProseMirror") else { return false }
        guard let children = children() else { return nil }
        guard children.count == 1 else { return false }
        guard let child = children.first, let childRole = child.role else { return nil }
        guard childRole == kAXGroupRole else { return false }
        return child.classes.map { $0.contains("is-empty") && $0.contains("is-editor-empty") }
    }

    private static func emptyProseMirrorState(in element: AXUIElement) -> Bool? {
        func directChildren() -> [(role: String?, classes: [String]?)]? {
            guard let children = AXText.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            // Two children already rule out the empty-editor structure.
            return children.prefix(2).map {
                (AXText.attribute($0, kAXRoleAttribute) as? String,
                 AXText.attribute($0, "AXDOMClassList") as? [String])
            }
        }
        return emptyProseMirrorState(role: AXText.attribute(element, kAXRoleAttribute) as? String,
                                    classes: AXText.attribute(element, "AXDOMClassList") as? [String],
                                    children: directChildren())
    }

    private static func instructionField(in element: AXUIElement) -> InstructionFieldSnapshot? {
        guard !AXText.isProtected(element), !AXText.isComposing(element),
              let value = AXText.attribute(element, kAXValueAttribute) as? String,
              let range = instructionRange(in: element, value: value) else { return nil }
        let editorIsEmpty = range.location == 0 && !value.isEmpty ? emptyProseMirrorState(in: element) : nil
        return InstructionFieldSnapshot(value: value, range: range, editorIsEmpty: editorIsEmpty)
    }

    static func captureInstructionCaret(in app: NSRunningApplication) -> InstructionCaret? {
        guard AXIsProcessTrusted(), !app.isTerminated, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = AXText.element(application, kAXFocusedWindowAttribute),
              let element = AXText.element(application, kAXFocusedUIElementAttribute),
              let field = instructionField(in: element) else { return nil }
        let caret = InstructionCaret(host: InputFieldHost(application: app, window: window, editable: true),
                                     element: element, field: field, document: document(of: window),
                                     windowTitle: AXText.attribute(window, kAXTitleAttribute) as? String)
        return instructionFocus(caret) == .ready ? caret : nil
    }

    private static func instructionFocus(_ target: InstructionCaret) -> CaretFocus {
        let app = target.host.application
        let element = target.element
        guard !app.isTerminated, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return .changed }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = AXText.element(application, kAXFocusedWindowAttribute), CFEqual(window, target.host.window),
              document(of: window) == target.document,
              AXText.attribute(window, kAXTitleAttribute) as? String == target.windowTitle
        else { return .changed }

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        let focus: CaretFocus
        if status == .success, let focused {
            guard CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, element) else { return .changed }
            focus = .ready
        } else if status == .noValue || (status == .success && focused == nil) {
            // The same editor may briefly lose reported focus during an
            // Electron handoff. This state may wait but can never write.
            focus = .restoring
        } else {
            return .changed
        }

        let owner = AXText.element(element, kAXWindowAttribute)
        if let owner {
            guard CFEqual(owner, window) else { return .changed }
        } else if focus == .restoring {
            return .changed
        }
        guard let field = instructionField(in: element), target.field.matches(field),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !IsSecureEventInputEnabled()
        else { return .changed }

        if focus == .ready {
            guard let liveWindow = AXText.element(application, kAXFocusedWindowAttribute), CFEqual(liveWindow, window),
                  let liveEditor = AXText.element(application, kAXFocusedUIElementAttribute), CFEqual(liveEditor, element)
            else { return .changed }
        }
        return focus
    }

    static func anchor(in app: NSRunningApplication, allowPointerLookup: Bool = true) -> TextSelectionAnchor? {
        guard AXIsProcessTrusted(), !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != NotesBridge.notesBundleID else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let window = AXText.element(axApp, kAXFocusedWindowAttribute) else { return nil }
        let focused = AXText.element(axApp, kAXFocusedUIElementAttribute)
        if let focused, AXText.isProtected(focused) { return nil }

        func find(from start: AXUIElement, focusedPath: Bool) -> TextSelectionAnchor? {
            var ancestor: AXUIElement? = start
            for _ in 0..<16 {
                guard let node = ancestor else { break }
                let role = AXText.attribute(node, kAXRoleAttribute) as? String
                if role == kAXWindowRole || role == kAXApplicationRole || AXText.isProtected(node) { break }
                if let extent = selection(in: node) {
                    if let owner = AXText.element(node, kAXWindowAttribute), !CFEqual(owner, window) { return nil }
                    let editable = focusedPath && isField(role) && isWritable(node)
                    let host = InputFieldHost(application: app, window: window, editable: editable)
                    return TextSelectionAnchor(element: node, extent: extent, source: .input(host))
                }
                if isField(role) || role == "AXWebArea" { break }
                ancestor = AXText.element(node, kAXParentAttribute)
            }
            return nil
        }
        if let focused {
            if let anchor = find(from: focused, focusedPath: true) { return anchor }
            if isField(AXText.attribute(focused, kAXRoleAttribute) as? String) { return nil }
        }
        // Read-only documents can keep keyboard focus on the window while text is dragged.
        guard allowPointerLookup, let point = CGEvent(source: nil)?.location else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hit) == .success, let hit,
              let hitWindow = AXText.element(hit, kAXWindowAttribute), CFEqual(hitWindow, window) else { return nil }
        return find(from: hit, focusedPath: false)
    }

    private static func currentAnchor(_ original: TextSelectionAnchor) -> TextSelectionAnchor? {
        guard case .input(let host) = original.source,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == host.application.processIdentifier || front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let current = anchor(in: host.application), case .input(let currentHost) = current.source,
              CFEqual(host.window, currentHost.window), CFEqual(original.element, current.element),
              current.extent.identity == original.extent.identity else { return nil }
        // A pointer hit can discover the selection before the editor gains focus.
        // Capture derives permission from the live field; a read-only observation
        // must not permanently downgrade the same window, element and range.
        return current
    }

    static func isFocused(_ original: TextSelectionAnchor) -> Bool { currentAnchor(original) != nil }

    // Keep only the selected text while the passive button is visible. A renderer
    // can clear AXSelectedText on mouse-up or as the pointer leaves the web view.
    static func launcherExcerpt(_ anchor: TextSelectionAnchor) -> InputFieldSelection? {
        guard case .input(let host) = anchor.source,
              let text = anchor.extent.text(in: anchor.element), !text.isEmpty,
              selection(in: anchor.element)?.identity == anchor.extent.identity else { return nil }
        return InputFieldSelection(host: host, anchor: anchor, text: text, fieldValue: nil,
                                   document: document(of: host.window),
                                   windowTitle: AXText.attribute(host.window, kAXTitleAttribute) as? String)
    }

    static func isInSourceContext(_ excerpt: InputFieldSelection, front: NSRunningApplication?) -> Bool {
        let host = excerpt.host
        guard AXIsProcessTrusted(), front?.processIdentifier == host.application.processIdentifier,
              !host.application.isTerminated else { return false }
        let app = AXUIElementCreateApplication(host.application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = AXText.element(app, kAXFocusedWindowAttribute), CFEqual(window, host.window),
              excerpt.document == document(of: window),
              excerpt.windowTitle == AXText.attribute(window, kAXTitleAttribute) as? String else { return false }
        return AXText.element(app, kAXFocusedUIElementAttribute).map(AXText.isProtected) != true
    }

    static func openSelection(_ anchor: TextSelectionAnchor, excerpt: InputFieldSelection?) -> InputFieldSelection? {
        if let live = capture(anchor) {
            guard let excerpt else { return live }
            guard live.text.utf16.elementsEqual(excerpt.text.utf16),
                  live.document == excerpt.document, live.windowTitle == excerpt.windowTitle else { return nil }
            return live
        }
        guard let excerpt, isInSourceContext(excerpt, front: NSWorkspace.shared.frontmostApplication) else { return nil }
        if let other = self.anchor(in: excerpt.host.application),
           other.extent.text(in: other.element)?.utf16.elementsEqual(excerpt.text.utf16) != true { return nil }
        return excerpt
    }

    static func capture(_ anchor: TextSelectionAnchor) -> InputFieldSelection? {
        guard let current = currentAnchor(anchor), case .input(let host) = current.source,
              let text = current.extent.text(in: current.element), !text.isEmpty else { return nil }
        var fieldValue: String?
        if host.editable, case .characters(let range) = current.extent,
           let value = AXText.attribute(current.element, kAXValueAttribute) as? String {
            let full = value as NSString
            if range.location <= full.length, range.length <= full.length - range.location,
               full.substring(with: NSRange(location: range.location, length: range.length)).utf16.elementsEqual(text.utf16) {
                fieldValue = value
            }
        }
        let snapshot = InputFieldSelection(host: host, anchor: current, text: text, fieldValue: fieldValue,
                                           document: document(of: host.window),
                                           windowTitle: AXText.attribute(host.window, kAXTitleAttribute) as? String)
        return isFocused(current) ? snapshot : nil
    }

    private static func document(of window: AXUIElement) -> String? {
        let document = AXText.attribute(window, kAXDocumentAttribute)
        return (document as? URL)?.absoluteString ?? document as? String
    }

    static func isCurrent(_ original: InputFieldSelection) -> Bool {
        guard let current = capture(original.anchor) else { return false }
        if let value = original.fieldValue {
            guard let other = current.fieldValue, value.utf16.elementsEqual(other.utf16) else { return false }
        } else if current.fieldValue != nil { return false }
        return original.document == current.document && original.windowTitle == current.windowTitle
            && original.text.utf16.elementsEqual(current.text.utf16)
    }

    // Electron can leave its focused element empty while a nonactivating tool panel
    // owns the keyboard. The original editor still exposes its exact live selection.
    static func selectionSurvivesFocusHandoff(_ original: InputFieldSelection) -> Bool {
        let host = original.host
        let element = original.anchor.element
        guard host.editable, let value = original.fieldValue, !host.application.isTerminated,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == host.application.processIdentifier || front.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(host.application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusStatus == .noValue || (focusStatus == .success && focused == nil),
              let window = AXText.element(app, kAXFocusedWindowAttribute), CFEqual(window, host.window),
              let owner = AXText.element(element, kAXWindowAttribute), CFEqual(owner, window),
              original.document == document(of: window),
              original.windowTitle == AXText.attribute(window, kAXTitleAttribute) as? String,
              !AXText.isProtected(element), !AXText.isComposing(element), isWritable(element),
              let live = selection(in: element), live.identity == original.anchor.extent.identity,
              let text = live.text(in: element), text.utf16.elementsEqual(original.text.utf16),
              let full = AXText.attribute(element, kAXValueAttribute) as? String else { return false }
        return full.utf16.elementsEqual(value.utf16)
    }

    // WebKit may acknowledge an AXSelectedText setter without editing the DOM. Use its
    // native edit command once so the host also handles input events, rich text and Undo.
    private static func needsPaste(_ element: AXUIElement) -> Bool {
        guard AXText.isSettable(element, kAXSelectedTextAttribute) else { return true }
        var ancestor: AXUIElement? = element
        for _ in 0..<32 {
            guard let current = ancestor else { break }
            let role = AXText.attribute(current, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return true }
            if role == kAXWindowRole { break }
            ancestor = AXText.element(current, kAXParentAttribute)
        }
        return false
    }

    /// Find the ordinary Copy/Paste menu in the bound application, independently of its language.
    private static func pasteItem(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let bar = AXText.element(application, kAXMenuBarAttribute),
              let headings = AXText.attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        func hasShortcut(_ item: AXUIElement, _ key: String) -> Bool {
            guard let character = AXText.attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                  character.lowercased() == key else { return false }
            return (AXText.attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
        }
        for heading in headings {
            guard let menus = AXText.attribute(heading, kAXChildrenAttribute) as? [AXUIElement], let menu = menus.first,
                  let items = AXText.attribute(menu, kAXChildrenAttribute) as? [AXUIElement],
                  items.contains(where: { hasShortcut($0, "c") }) else { continue }
            if let paste = items.first(where: { hasShortcut($0, "v") }) { return paste }
        }
        return nil
    }

    private static var pasteInProgress = false

    static func pasteText(_ text: String, into app: NSRunningApplication,
                          isReady: () -> Bool, verify: () async -> String?) async -> String? {
        guard !pasteInProgress, let item = pasteItem(in: app) else {
            return L10n.text("Paste is unavailable in this app.")
        }
        let stale = L10n.text("The original app, text field, or selection changed.")
        guard isReady(), !IsSecureEventInputEnabled() else { return stale }
        pasteInProgress = true
        let board = NSPasteboard.general
        let restore = NotesBridge.shared.preparePasteboard(text: text, html: nil, pasteboard: board)
        defer {
            restore()
            pasteInProgress = false
        }
        let version = board.changeCount
        // Resolving the menu and preparing the clipboard can both block. Validate
        // the exact saved caret again before dispatching one native Paste command.
        guard AXText.attribute(item, kAXEnabledAttribute) as? Bool != false else {
            return L10n.text("Paste is unavailable in this app.")
        }
        guard isReady(), !IsSecureEventInputEnabled(),
              board.changeCount == version, board.string(forType: .string)?.utf16.elementsEqual(text.utf16) == true,
              board.changeCount == version else { return stale }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            return L10n.text("The original app didn’t accept the paste.")
        }
        return await verify()
    }

    // WebKit can preserve a visible boundary space in contenteditable by making it a NBSP.
    nonisolated private static func matchesWrite(_ actual: String, expected: String, inserted: NSRange, pasted: Bool) -> Bool {
        if actual.utf16.elementsEqual(expected.utf16) { return true }
        guard pasted, actual.utf16.count == expected.utf16.count else { return false }
        for (index, pair) in zip(actual.utf16, expected.utf16).enumerated() where pair.0 != pair.1 {
            guard (index == inserted.location - 1 || index == NSMaxRange(inserted)),
                  pair.0 == 0x00A0, pair.1 == 0x0020 else { return false }
        }
        return true
    }

    static func insertInstruction(_ text: String, into target: InstructionCaret,
                                  isValid: () -> Bool) async -> String? {
        let stale = L10n.text("The original app, text field, or selection changed.")
        let app = target.host.application
        guard await InstructionInsertionTarget.restoreHost(app, isValid: isValid) else { return stale }
        for _ in 0..<16 {
            guard isValid(), !Task.isCancelled else { return L10n.text("Operation canceled.") }
            let focus = instructionFocus(target)
            if focus == .ready { break }
            guard focus == .restoring else { return stale }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        let expected = target.field.expectedValue(inserting: text)
        func ready() -> Bool {
            isValid() && !Task.isCancelled && instructionFocus(target) == .ready && isValid() && !Task.isCancelled
        }
        func verify(pasted: Bool) async -> String? {
            for attempt in 0..<20 {
                if let value = AXText.attribute(target.element, kAXValueAttribute) as? String,
                   target.field.verifiesInsertion(value, expected: expected, pasted: pasted,
                                                  editorIsEmpty: emptyProseMirrorState(in: target.element)) {
                    return nil
                }
                guard attempt < 19 else { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            return L10n.text("Couldn’t verify the final text. Check the original field.")
        }

        // Web editors may acknowledge AX edits without delivering a DOM input
        // event. Native Paste preserves the editor's input and Undo semantics.
        if needsPaste(target.element) {
            return await pasteText(text, into: app, isReady: ready) { await verify(pasted: true) }
        }
        guard ready() else { return stale }
        let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
        switch status {
        case .success:
            return await verify(pasted: false)
        case .attributeUnsupported, .notImplemented, .illegalArgument:
            return await pasteText(text, into: app, isReady: ready) { await verify(pasted: true) }
        default:
            return L10n.text("The text field didn’t accept the replacement.")
        }
    }

    static func write(_ original: InputFieldSelection, text: String, append: Bool, isValid: () -> Bool) async -> String? {
        let stale = L10n.text("The original app, text field, or selection changed.")
        let app = original.host.application
        guard isValid(), let value = original.fieldValue, case .characters(let selected) = original.anchor.extent else { return stale }
        // Closing the panel restores Electron's focused editor asynchronously.
        // Wait only while the same verified selection is still in the focus handoff.
        for _ in 0..<12 {
            if isCurrent(original) { break }
            guard isValid(), selectionSurvivesFocusHandoff(original) else { return stale }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard isValid(), isCurrent(original) else { return stale }
        if !append && text.utf16.elementsEqual(original.text.utf16) { return nil }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            guard app.activate(options: []) else { return stale }
            for _ in 0..<12 {
                guard isValid(), let front = NSWorkspace.shared.frontmostApplication else { return stale }
                if front.processIdentifier == app.processIdentifier { break }
                guard front.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return stale }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        let insertion = append ? CFRange(location: selected.location + selected.length, length: 0) : selected
        let expected = (value as NSString).replacingCharacters(in: NSRange(location: insertion.location, length: insertion.length), with: text)
        let element = original.anchor.element
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        func ready(at range: CFRange) -> Bool {
            guard isValid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let window = AXText.element(axApp, kAXFocusedWindowAttribute), CFEqual(window, original.host.window),
                  let focused = AXText.element(axApp, kAXFocusedUIElementAttribute), CFEqual(focused, element),
                  !AXText.isProtected(element), isWritable(element),
                  let current = AXText.range(of: element), current.location == range.location, current.length == range.length,
                  let currentValue = AXText.attribute(element, kAXValueAttribute) as? String,
                  currentValue.utf16.elementsEqual(value.utf16) else { return false }
            return document(of: window) == original.document && AXText.attribute(window, kAXTitleAttribute) as? String == original.windowTitle
        }
        func setRange(_ range: CFRange) -> Bool {
            var range = range
            guard let parameter = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, parameter) == .success
        }
        func prepareInsertion() async -> Bool {
            guard ready(at: selected) else { return false }
            guard append else { return true }
            guard setRange(insertion) else { return false }
            // Chromium's renderer acknowledges the command before its AX tree exposes the caret.
            for attempt in 0..<12 {
                if ready(at: insertion) { return true }
                guard isValid(), attempt < 11 else { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return false
        }
        // Collapse the real selection for append so rich-text spans keep their original formatting.
        defer { if append && ready(at: insertion) { _ = setRange(selected) } }
        var restore: (() -> Void)?
        defer { if let restore { restore(); pasteInProgress = false } }
        let paste = needsPaste(element)
        if paste {
            guard !pasteInProgress, let item = pasteItem(in: app) else {
                return L10n.text("Paste is unavailable in this app.")
            }
            guard ready(at: selected) else { return stale }
            pasteInProgress = true
            let board = NSPasteboard.general
            restore = NotesBridge.shared.preparePasteboard(text: text, html: nil, pasteboard: board)
            let version = board.changeCount
            guard await prepareInsertion(), board.changeCount == version, board.string(forType: .string) == text else { return stale }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                return L10n.text("The original app didn’t accept the paste.")
            }
        } else {
            guard await prepareInsertion() else { return stale }
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                return L10n.text("The text field didn’t accept the replacement.")
            }
        }
        for attempt in 0..<20 {
            if let value = AXText.attribute(element, kAXValueAttribute) as? String,
               matchesWrite(value, expected: expected, inserted: NSRange(location: insertion.location, length: text.utf16.count), pasted: paste) {
                return nil
            }
            guard attempt < 19 else { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return L10n.text("Couldn’t verify the final text. Check the original field.")
    }
}
