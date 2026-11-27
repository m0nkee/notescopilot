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
        case idle, checking, current, available, failed(UpdateError)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(Double?)
        case completed(URL)
        case failed(UpdateError)
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
        case .idle: return L10n.text("No update check yet.")
        case .checking: return L10n.text("Checking for updates…")
        case .current: return L10n.format("You're up to date (v%@).", currentVersion)
        case .available:
            return L10n.format("An update is available (v%@).", availableRelease?.version ?? "")
        case .failed(let error): return error.message
        }
    }

    var downloadStatusMessage: String {
        switch downloadState {
        case .idle:
            return ""
        case .downloading(let progress):
            let percent = progress.map { Int((max(0, min(1, $0)) * 100).rounded()) }
            let progressText = percent.map { L10n.format(" (%lld%%)", $0) } ?? ""
            return L10n.format("Downloading v%@%@. The download will appear in Finder when complete.",
                               availableRelease?.version ?? "", progressText)
        case .completed(let url):
            return L10n.format("Downloaded: %@", url.path)
        case .failed(let error):
            return error.message
        case .cancelled:
            return L10n.text("Download canceled. You can try again later.")
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
                throw UpdateError.unknownVersion
            }
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("NotesCopilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 403, 429: throw UpdateError.rateLimited
                case 404: throw UpdateError.noRelease
                default: throw UpdateError.checkHTTP(http.statusCode)
                }
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease, let remote = ReleaseVersion(release.tag_name) else {
                throw UpdateError.invalidRelease
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
            status = .failed(error as? UpdateError ?? .checkConnection)
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
            downloadState = .failed(.noDownload)
            return nil
        }
        guard !isDownloading else { return nil }

        downloadCancellationRequested = false
        downloadState = .downloading(0)
        let temporaryURL = downloadDirectory
            .appendingPathComponent(".\(release.fileName)-\(UUID().uuidString).part")
        do {
            guard let expectedDigest = try await fetchExpectedChecksum(for: release) else {
                throw UpdateError.missingChecksum
            }
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

            var request = URLRequest(url: release.downloadURL, timeoutInterval: 120)
            request.setValue("NotesCopilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.downloadHTTP(code)
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
                throw UpdateError.checksumMismatch
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
                downloadState = .failed(error as? UpdateError ?? .downloadConnection)
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

    enum UpdateError: Error, Equatable {
        case unknownVersion, invalidResponse, rateLimited, noRelease, invalidRelease, checkConnection
        case noDownload, missingChecksum, checksumMismatch, downloadConnection
        case checkHTTP(Int), downloadHTTP(Int)

        var message: String {
            switch self {
            case .unknownVersion:
                return L10n.text("Couldn't read the installed version. Check the releases page for updates.")
            case .invalidResponse:
                return L10n.text("The update service returned an invalid response. Try again later.")
            case .rateLimited:
                return L10n.text("The update service is rate limiting requests. Try again later or visit the releases page.")
            case .noRelease:
                return L10n.text("No release is available. Try again later or visit the releases page.")
            case .invalidRelease:
                return L10n.text("The update service returned no valid stable release. Visit the releases page.")
            case .checkConnection:
                return L10n.text("Couldn't check for updates. Check your connection and try again, or visit the releases page.")
            case .noDownload:
                return L10n.text("No update is ready to download. Check for updates first.")
            case .missingChecksum:
                return L10n.text("The download was stopped because the release is missing a SHA-256 checksum. Check the releases page.")
            case .checksumMismatch:
                return L10n.text("The download failed verification and the incomplete DMG was deleted. Try again or visit the releases page.")
            case .downloadConnection:
                return L10n.text("Couldn't download the update. Check your connection and try again.")
            case .checkHTTP(let code):
                return L10n.format("Couldn't check for updates (HTTP %lld). Try again later.", code)
            case .downloadHTTP(let code):
                return L10n.format("Couldn't download the update (HTTP %lld). Try again later.", code)
            }
        }
    }
}
