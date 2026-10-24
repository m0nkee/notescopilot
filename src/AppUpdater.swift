import Foundation
import Combine

struct ReleaseVersion: Comparable {
    private let components: [Int]

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppRelease: Codable, Equatable {
    let tag: String

    var version: String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    var pageURL: URL {
        AppUpdater.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    nonisolated static let releasesURL = URL(string: "https://github.com/m0nkee/notescopilot/releases")!
    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/m0nkee/notescopilot/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Status: Equatable {
        case idle, checking, current, available, failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: "nc.update.automatic") }
    }
    let currentVersion: String
    var onCheckCompleted: ((_ userInitiated: Bool) -> Void)?

    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date
    private var userRequestedResult = false

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         defaults: UserDefaults = .standard,
         session: URLSession = .shared,
         now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.session = session
        self.now = now
        automaticallyChecks = defaults.object(forKey: "nc.update.automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: "nc.update.lastChecked") as? Date
        if let tag = defaults.string(forKey: "nc.update.availableTag"),
           let remote = ReleaseVersion(tag), let local = ReleaseVersion(currentVersion), remote > local {
            availableRelease = AppRelease(tag: tag)
            status = .available
        }
    }

    var isChecking: Bool { status == .checking }

    var statusMessage: String {
        switch status {
        case .idle: return "尚未检查更新。"
        case .checking: return "正在检查更新…"
        case .current: return "当前已是最新版本（v\(currentVersion)）。"
        case .available: return "发现新版本 v\(availableRelease?.version ?? "")，建议更新。"
        case .failed(let message): return message
        }
    }

    func checkIfNeeded() async {
        guard automaticallyChecks else { return }
        if let lastAttempt = defaults.object(forKey: "nc.update.lastAttempt") as? Date,
           now().timeIntervalSince(lastAttempt) < Self.checkInterval { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool = true) async {
        userRequestedResult = userRequestedResult || userInitiated
        // A manual click during the startup request still receives its result.
        guard !isChecking else { return }
        status = .checking
        defaults.set(now(), forKey: "nc.update.lastAttempt")
        do {
            guard let local = ReleaseVersion(currentVersion) else {
                throw UpdateError("无法读取当前版本，请前往发布页查看更新。")
            }
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("NotesCopilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError("更新服务响应无效，请稍后重试。")
            }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 403, 429: throw UpdateError("更新服务暂时限制请求，请稍后重试或前往发布页。")
                case 404: throw UpdateError("暂未找到可用发布版本，请稍后重试或前往发布页。")
                default: throw UpdateError("检查更新失败（HTTP \(http.statusCode)），请稍后重试。")
                }
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease, let remote = ReleaseVersion(release.tag_name) else {
                throw UpdateError("更新服务未返回有效的正式版本，请前往发布页查看。")
            }
            availableRelease = remote > local ? AppRelease(tag: release.tag_name) : nil
            defaults.set(availableRelease?.tag, forKey: "nc.update.availableTag")
            lastChecked = now()
            defaults.set(lastChecked, forKey: "nc.update.lastChecked")
            status = availableRelease == nil ? .current : .available
        } catch {
            let message = (error as? UpdateError)?.message ?? "无法检查更新，请检查网络后重试，或前往发布页查看。"
            status = .failed(message)
        }
        let showResult = userRequestedResult
        userRequestedResult = false
        onCheckCompleted?(showResult)
    }

    func shouldRemind() -> Bool {
        guard automaticallyChecks, status == .available, let release = availableRelease else { return false }
        if defaults.string(forKey: "nc.update.remindedTag") != release.tag { return true }
        guard let date = defaults.object(forKey: "nc.update.lastReminder") as? Date else { return true }
        return now().timeIntervalSince(date) >= Self.checkInterval
    }

    func markReminded() {
        guard let release = availableRelease else { return }
        defaults.set(release.tag, forKey: "nc.update.remindedTag")
        defaults.set(now(), forKey: "nc.update.lastReminder")
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
