import Foundation
import Combine
import CryptoKit

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
    let notes: String?
    let asset: ReleaseAsset?
    let checksumAsset: ReleaseAsset?

    init(tag: String, notes: String? = nil, asset: ReleaseAsset? = nil, checksumAsset: ReleaseAsset? = nil) {
        self.tag = tag
        self.notes = notes
        self.asset = asset
        self.checksumAsset = checksumAsset
    }

    var version: String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    var fileName: String { "NotesCopilot-\(version)-arm64.dmg" }

    /// NSAlert uses plain text; keep the release body bounded and readable.
    var alertNotes: String? {
        guard let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 800 else { return value }
        return String(value.prefix(800)) + "\n…"
    }

    var pageURL: URL {
        AppUpdater.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }

    var downloadURL: URL {
        asset?.browserDownloadURL
            ?? AppUpdater.releasesURL
                .appendingPathComponent("download")
                .appendingPathComponent(tag)
                .appendingPathComponent(fileName)
    }
}

struct ReleaseAsset: Codable, Equatable {
    let name: String
    let size: Int?
    let browserDownloadURL: URL?
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
        case digest
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

    enum DownloadState: Equatable {
        case idle
        case downloading(Double?)
        case completed(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: "nc.update.automatic") }
    }
    let currentVersion: String
    var onCheckCompleted: ((_ userInitiated: Bool) -> Void)?

    private let defaults: UserDefaults
    private let session: URLSession
    private let downloadDirectory: URL
    private let now: () -> Date
    private var userRequestedResult = false
    private var downloadCancellationRequested = false
    private static let availableReleaseKey = "nc.update.availableRelease"

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         defaults: UserDefaults = .standard,
         session: URLSession = .shared,
         downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory,
         now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.session = session
        self.downloadDirectory = downloadDirectory
        self.now = now
        automaticallyChecks = defaults.object(forKey: "nc.update.automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: "nc.update.lastChecked") as? Date
        if let cached = cachedRelease(currentVersion: currentVersion) {
            availableRelease = cached
            status = .available
        }
    }

    var isChecking: Bool { status == .checking }
    var isDownloading: Bool { if case .downloading = downloadState { return true }; return false }
    var downloadProgress: Double? {
        if case .downloading(let progress) = downloadState { return progress }
        return nil
    }

    var statusMessage: String {
        switch status {
        case .idle: return "尚未检查更新。"
        case .checking: return "正在检查更新…"
        case .current: return "当前已是最新版本（v\(currentVersion)）。"
        case .available: return "发现新版本 v\(availableRelease?.version ?? "")，建议更新。"
        case .failed(let message): return message
        }
    }

    var downloadStatusMessage: String {
        switch downloadState {
        case .idle:
            return ""
        case .downloading(let progress):
            let percent = progress.map { Int((max(0, min(1, $0)) * 100).rounded()) }
            let progressText = percent.map { "（\($0)%）" } ?? ""
            return "正在下载 v\(availableRelease?.version ?? "")\(progressText)，完成后会在 Finder 中显示。"
        case .completed(let url):
            return "已下载：\(url.path)"
        case .failed(let message):
            return message
        case .cancelled:
            return "已取消下载，可稍后重新下载。"
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
            let version = String(release.tag_name.dropFirst(release.tag_name.hasPrefix("v") ? 1 : 0))
            let fileName = "NotesCopilot-\(version)-arm64.dmg"
            let assets = release.assets ?? []
            let asset = assets.first { $0.name == fileName }
            let checksumAsset = assets.first { $0.name == "\(fileName).sha256" }
            availableRelease = remote > local
                ? AppRelease(tag: release.tag_name, notes: release.body, asset: asset, checksumAsset: checksumAsset)
                : nil
            if let availableRelease {
                // Persist only display metadata. Asset URLs and digests come
                // from the network on each successful check/download.
                let safeRelease = AppRelease(tag: availableRelease.tag, notes: availableRelease.alertNotes)
                defaults.set(try? JSONEncoder().encode(safeRelease), forKey: Self.availableReleaseKey)
                defaults.set(availableRelease.tag, forKey: "nc.update.availableTag")
            } else {
                defaults.removeObject(forKey: Self.availableReleaseKey)
                defaults.removeObject(forKey: "nc.update.availableTag")
            }
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

    func cancelDownload() {
        guard isDownloading else { return }
        downloadCancellationRequested = true
    }

    func download() async -> URL? {
        guard let release = availableRelease else {
            downloadState = .failed("尚未发现可下载的新版本，请先检查更新。")
            return nil
        }
        guard !isDownloading else { return nil }

        downloadCancellationRequested = false
        downloadState = .downloading(0)
        let temporaryURL = downloadDirectory
            .appendingPathComponent(".\(release.fileName)-\(UUID().uuidString).part")
        do {
            guard let expectedDigest = try await fetchExpectedChecksum(for: release) else {
                throw UpdateError("发布包缺少 SHA-256 校验信息，已停止下载。请前往发布页确认。")
            }
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

            var request = URLRequest(url: release.downloadURL, timeoutInterval: 120)
            request.setValue("NotesCopilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError("下载新版本失败（HTTP \(code)），请稍后重试。")
            }

            let handle = try FileHandle(forWritingTo: temporaryURL)
            var closed = false
            defer {
                if !closed { try? handle.close() }
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            var received = 0
            var buffer = [UInt8]()
            buffer.reserveCapacity(64 * 1024)
            let expectedSize = release.asset?.size
                ?? http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
            var lastReported = -1
            for try await byte in bytes {
                if downloadCancellationRequested { throw CancellationError() }
                try Task.checkCancellation()
                received += 1
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if let expected = expectedSize, expected > 0,
                   received - lastReported >= 1024 * 1024 || received == expected {
                    downloadState = .downloading(min(1, Double(received) / Double(expected)))
                    lastReported = received
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            closed = true
            try handle.close()

            let actualDigest = SHA256.hash(data: try Data(contentsOf: temporaryURL))
                .map { String(format: "%02x", $0) }.joined()
            guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                throw UpdateError("下载文件校验失败，已删除不完整的 DMG。请重试或前往发布页。")
            }

            let destination = downloadDirectory.appendingPathComponent(release.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
            downloadState = .completed(destination)
            return destination
        } catch {
            if error is CancellationError || downloadCancellationRequested {
                downloadState = .cancelled
            } else {
                let message = (error as? UpdateError)?.message
                    ?? "无法下载新版本，请检查网络后重试。"
                downloadState = .failed(message)
            }
            return nil
        }
    }

    private func fetchExpectedChecksum(for release: AppRelease) async throws -> String? {
        if let digest = release.asset?.digest,
           digest.lowercased().hasPrefix("sha256:"),
           digest.count == 7 + 64,
           digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) {
            return String(digest.dropFirst(7)).lowercased()
        }
        let checksumURL = release.checksumAsset?.browserDownloadURL
            ?? release.downloadURL.appendingPathExtension("sha256")
        return try await fetchChecksumText(at: checksumURL)
    }

    private func fetchChecksumText(at url: URL) async throws -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("NotesCopilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digest = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .first.map(String.init)
        guard digest?.count == 64, digest?.allSatisfy({ $0.isHexDigit }) == true else { return nil }
        return digest?.lowercased()
    }

    private func cachedRelease(currentVersion: String) -> AppRelease? {
        if let data = defaults.data(forKey: Self.availableReleaseKey),
           let release = try? JSONDecoder().decode(AppRelease.self, from: data),
           !release.tag.isEmpty,
           let remote = ReleaseVersion(release.tag), let local = ReleaseVersion(currentVersion),
           remote > local {
            return AppRelease(tag: release.tag, notes: release.alertNotes)
        }
        if let tag = defaults.string(forKey: "nc.update.availableTag"),
           let remote = ReleaseVersion(tag), let local = ReleaseVersion(currentVersion), remote > local {
            return AppRelease(tag: tag)
        }
        return nil
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
        let body: String?
        let assets: [ReleaseAsset]?
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
