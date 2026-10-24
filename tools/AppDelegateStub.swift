import AppKit

// 仅用于离屏渲染工具（不进 App target）：补齐 LibraryView/Slash 对 AppDelegate 的编译期引用
final class AppDelegate: NSObject, NSApplicationDelegate {
    var notesStore: NotesStore?
    var notesStoreError: String?
    var notesStoreLoading = false
    @objc func retryNotesStore() {}
    @objc func showPanel() {}
    @objc func showLibrary() {}
    @objc func openPanelWithNote(_ note: Any?) {}
}
