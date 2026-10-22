import AppKit

// MARK: - 跟踪最近活跃的非本应用（用于 AX 读选中文本时定位 Notes）

final class FrontmostTracker {
    static let shared = FrontmostTracker()
    private(set) var lastForeignApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        if let cur = NSWorkspace.shared.frontmostApplication,
           cur.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastForeignApp = cur
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastForeignApp = app
        }
    }
}
