import Foundation
import CryptoKit

private final class UpdateProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = ""
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var offline = false
    nonisolated(unsafe) private static var responseGate: DispatchSemaphore?
    nonisolated(unsafe) private static var responseGateTimedOut = false

    static func fixture(_ body: String, status: Int = 200, offline: Bool = false,
                        responseGate: DispatchSemaphore? = nil) {
        lock.lock()
        defer { lock.unlock() }
        responseBody = body
        responseStatus = status
        self.offline = offline
        self.responseGate = responseGate
        responseGateTimedOut = false
        requests = []
    }

    static var captured: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var didResponseGateTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return responseGateTimedOut
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.responseBody
        let status = Self.responseStatus
        let offline = Self.offline
        let responseGate = Self.responseGate
        Self.lock.unlock()
        if responseGate?.wait(timeout: .now() + 5) == .timedOut {
            Self.lock.lock()
            Self.responseGateTimedOut = true
            Self.lock.unlock()
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private var passed = 0
private var failed = 0
private func check(_ condition: Bool, _ label: String) {
    if condition { passed += 1; print("PASS  \(label)") }
    else { failed += 1; print("FAIL  \(label)") }
}

private func release(_ tag: String = "v2.7.0", draft: Bool = false, prerelease: Bool = false,
                       digest: String = "1111111111111111111111111111111111111111111111111111111111111111",
                       notes: String = "测试发布说明") -> String {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let asset = #"{"name":"NotesCopilot-\#(version)-arm64.dmg","size":13,"browser_download_url":"https://github.com/m0nkee/notescopilot/releases/download/\#(tag)/NotesCopilot-\#(version)-arm64.dmg","digest":"\#(digest)"}"#
    let checksumAsset = #"{"name":"NotesCopilot-\#(version)-arm64.dmg.sha256","size":96,"browser_download_url":"https://github.com/m0nkee/notescopilot/releases/download/\#(tag)/NotesCopilot-\#(version)-arm64.dmg.sha256"}"#
    return #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"body":"\#(notes)","assets":[\#(asset),\#(checksumAsset)]}"#
}

@MainActor
private func runTests() async {
    check(ReleaseVersion("v2.10.0")! > ReleaseVersion("2.9.9")!, "版本按数值比较，不按字符串排序")
    check(ReleaseVersion("2.6") == ReleaseVersion("v2.6.0"), "v 前缀和缺省补丁号一致")
    check(ReleaseVersion("2.6.1")! < ReleaseVersion("3.0.0")!, "跨主版本更新")
    for invalid in ["", "2..1", "2.7.0-beta.1", "2.7.0+build", "-1.0.0", "v", "2.7.0/evil", "2.7.0.1"] {
        check(ReleaseVersion(invalid) == nil, "拒绝非正式或异常版本：\(invalid)")
    }

    let suite = "nc.update-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let downloadDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("notescopilot-update-downloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: downloadDirectory) }
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func make(_ version: String = "2.6.1") -> AppUpdater {
        AppUpdater(currentVersion: version, defaults: defaults, session: session,
                   downloadDirectory: downloadDirectory, now: { date })
    }
    func reset() { defaults.removePersistentDomain(forName: suite) }

    let updater = make()
    var completions: [Bool] = []
    updater.onCheckCompleted = { completions.append($0) }
    check(updater.automaticallyChecks && updater.status == .idle, "默认开启自动检查")
    UpdateProtocol.fixture(release(digest: "sha256:\(sha256("SYNTHETIC-DMG"))"))
    await updater.checkIfNeeded()
    check(updater.status == .available && updater.availableRelease?.version == "2.7.0", "自动检测更新版本")
    check(completions == [false], "自动检查结果不会被当作手动请求")
    check(updater.lastChecked == date && UpdateProtocol.captured.count == 1, "记录成功检查时间")
    let request = UpdateProtocol.captured.first!
    check(request.url == AppUpdater.endpoint && request.value(forHTTPHeaderField: "Authorization") == nil,
          "仅请求固定公开仓库，不发送模型凭据")
    check(request.timeoutInterval == 20 && request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
          "更新请求有超时并使用 GitHub JSON 接口")
    check(updater.availableRelease?.notes == "测试发布说明", "更新信息包含发布说明")
    check(updater.availableRelease?.asset?.digest?.hasPrefix("sha256:") == true, "更新元数据包含 SHA-256 摘要")
    check(updater.availableRelease?.pageURL.absoluteString == "https://github.com/m0nkee/notescopilot/releases/tag/v2.7.0",
          "下载入口指向对应正式发布页")
    check(updater.availableRelease?.downloadURL.absoluteString == "https://github.com/m0nkee/notescopilot/releases/download/v2.7.0/NotesCopilot-2.7.0-arm64.dmg",
          "更新按钮直接下载对应版本 DMG")
    UpdateProtocol.fixture("SYNTHETIC-DMG")
    let downloadedURL = await updater.download()
    let downloadedData = downloadedURL.flatMap { try? Data(contentsOf: $0) }
    var downloadCompleted = false
    if case .completed = updater.downloadState { downloadCompleted = true }
    check(downloadedURL?.lastPathComponent == "NotesCopilot-2.7.0-arm64.dmg"
          && downloadedData == Data("SYNTHETIC-DMG".utf8)
          && downloadCompleted,
          "直接下载写入下载目录并保存完整 DMG")
    check(updater.downloadStatusMessage.contains(downloadedURL?.path ?? ""),
          "下载状态显示本地文件路径")
    try? Data("OLD-DMG".utf8).write(to: downloadDirectory.appendingPathComponent("NotesCopilot-2.7.0-arm64.dmg"))
    UpdateProtocol.fixture(release(digest: "sha256:\(sha256("REPLACED-DMG"))"))
    await updater.check()
    UpdateProtocol.fixture("REPLACED-DMG")
    let replacedURL = await updater.download()
    let replacedData = replacedURL.map { try? Data(contentsOf: $0) } ?? nil
    check(replacedURL == downloadedURL && replacedData == Data("REPLACED-DMG".utf8),
          "重复下载同版本会替换旧文件")
    UpdateProtocol.fixture("not-found", status: 404)
    let failedURL = await updater.download()
    check(failedURL == nil && updater.downloadStatusMessage.contains("HTTP 404")
          && !updater.isDownloading,
          "下载失败保留可读错误并退出下载状态")
    try? FileManager.default.removeItem(at: downloadDirectory.appendingPathComponent("NotesCopilot-2.7.0-arm64.dmg"))
    UpdateProtocol.fixture(release(digest: "sha256:\(sha256("SYNTHETIC-DMG"))"))
    await updater.check()
    UpdateProtocol.fixture("CORRUPTED-DMG")
    let corruptedURL = await updater.download()
    check(corruptedURL == nil && updater.downloadStatusMessage.contains("校验失败")
          && !FileManager.default.fileExists(atPath: downloadDirectory.appendingPathComponent("NotesCopilot-2.7.0-arm64.dmg").path),
          "校验失败时删除损坏文件且不提供安装入口")
    UpdateProtocol.fixture(release(digest: ""))
    await updater.check()
    UpdateProtocol.fixture("DMG-WITHOUT-CHECKSUM")
    let noChecksumURL = await updater.download()
    check(noChecksumURL == nil && updater.downloadStatusMessage.contains("缺少 SHA-256")
          && updater.downloadState != .completed(downloadDirectory),
          "缺少可信校验信息时拒绝下载")
    UpdateProtocol.fixture(release(digest: "sha256:\(sha256("SYNTHETIC-DMG"))"))
    await updater.check()
    let cancelGate = DispatchSemaphore(value: 0)
    UpdateProtocol.fixture("SYNTHETIC-DMG", responseGate: cancelGate)
    let cancellationTask = Task { await updater.download() }
    let downloadingDeadline = Date().addingTimeInterval(2)
    while !updater.isDownloading && Date() < downloadingDeadline { await Task.yield() }
    check(updater.isDownloading && updater.downloadProgress == 0, "下载中提供可观察进度")
    updater.cancelDownload()
    cancelGate.signal()
    let cancelledURL = await cancellationTask.value
    var downloadCancelled = false
    if case .cancelled = updater.downloadState { downloadCancelled = true }
    check(cancelledURL == nil && downloadCancelled && !updater.isDownloading
          && updater.downloadStatusMessage.contains("已取消下载")
          && !FileManager.default.fileExists(atPath: downloadDirectory.appendingPathComponent("NotesCopilot-2.7.0-arm64.dmg").path),
          "取消下载会停止写入并清理临时文件")
    check(updater.shouldRemind(), "首次发现新版本需要提醒")
    updater.markReminded()
    check(!updater.shouldRemind(), "同一天不重复弹出提醒")
    await updater.checkIfNeeded()
    check(UpdateProtocol.captured.count == 1, "一天内不重复自动请求")
    let restored = make()
    check(restored.availableRelease?.tag == updater.availableRelease?.tag && !restored.shouldRemind(),
          "重新启动保留新版本入口和提醒间隔")
    check(restored.availableRelease?.notes == "测试发布说明" && restored.availableRelease?.asset == nil,
          "重启缓存保留发布说明但不信任本地资产元数据")
    defaults.set(try? JSONEncoder().encode(AppRelease(
        tag: "v9.9.9", notes: "tampered",
        asset: ReleaseAsset(name: "NotesCopilot-9.9.9-arm64.dmg", size: 1,
                            browserDownloadURL: URL(string: "https://evil.example/dmg")!,
                            digest: "sha256:\(String(repeating: "0", count: 64))")
    )), forKey: "nc.update.availableRelease")
    let sanitized = make()
    check(sanitized.availableRelease?.asset == nil
          && sanitized.availableRelease?.downloadURL.absoluteString == "https://github.com/m0nkee/notescopilot/releases/download/v9.9.9/NotesCopilot-9.9.9-arm64.dmg",
          "篡改的本地缓存不会提供任意下载地址或摘要")
    date = date.addingTimeInterval(AppUpdater.checkInterval)
    check(restored.shouldRemind(), "稍后提醒满一天后可再次提示")
    await updater.checkIfNeeded()
    check(UpdateProtocol.captured.count == 2, "常驻应用满一天后重新检查")
    await updater.check()
    check(UpdateProtocol.captured.count == 3 && completions.last == true, "手动检查绕过每日限制")

    UpdateProtocol.fixture(release("v2.6.1"))
    await updater.check()
    check(updater.status == .current && updater.availableRelease == nil, "版本相同不提醒")
    check(make().availableRelease == nil, "远端不再有新版本时清除缓存入口")
    UpdateProtocol.fixture(release("v2.5.0"))
    await updater.check()
    check(updater.status == .current, "本地版本更高时不提示降级")

    updater.automaticallyChecks = false
    check(!make().automaticallyChecks, "自动检查开关持久保存")
    date = date.addingTimeInterval(AppUpdater.checkInterval)
    UpdateProtocol.fixture(release())
    await updater.checkIfNeeded()
    check(UpdateProtocol.captured.isEmpty, "关闭自动检查后不会联网")
    await updater.check()
    check(updater.status == .available && !updater.shouldRemind() && completions.last == true,
          "关闭自动检查后仍可手动检查，但不会自动提醒")
    check(make("2.7.0").availableRelease == nil, "更新安装后不显示已过期缓存")
    updater.automaticallyChecks = true
    updater.markReminded()
    UpdateProtocol.fixture(release("v2.8.0"))
    await updater.check()
    check(updater.shouldRemind(), "更高的新版本不受旧版本提醒间隔影响")

    let successfulCheck = updater.lastChecked
    for code in [403, 429, 404, 500] {
        UpdateProtocol.fixture("{}", status: code)
        await updater.check()
        if case .failed = updater.status { check(true, "HTTP \(code) 明确报告检查失败") }
        else { check(false, "HTTP \(code) 明确报告检查失败") }
        check(updater.availableRelease?.version == "2.8.0" && updater.lastChecked == successfulCheck,
              "请求失败保留已有下载入口，不伪造成功时间")
        check(!updater.shouldRemind(), "失败结果不触发自动弹窗")
    }
    for body in ["not-json", "{}", release("v2.9.0", draft: true), release("v2.9.0", prerelease: true),
                 release("v2.9.0-beta"), release("../other")] {
        UpdateProtocol.fixture(body)
        await updater.check()
        if case .failed = updater.status { check(true, "拒绝异常响应、草稿或预发布：\(body)") }
        else { check(false, "拒绝异常响应、草稿或预发布：\(body)") }
    }
    UpdateProtocol.fixture("", offline: true)
    await updater.check()
    check(updater.statusMessage.contains("网络") && !updater.shouldRemind(), "离线给出可重试提示，自动检查静默失败")

    reset()
    let responseGate = DispatchSemaphore(value: 0)
    UpdateProtocol.fixture(release(), responseGate: responseGate)
    let background = make()
    var mergedResult: Bool?
    background.onCheckCompleted = { mergedResult = $0 }
    let automaticTask = Task { await background.check(userInitiated: false) }
    // Hold the response until the manual call actually overlaps the automatic
    // request. Task.yield alone guarantees neither task order nor overlap.
    let overlapDeadline = Date().addingTimeInterval(2)
    while !background.isChecking && Date() < overlapDeadline { await Task.yield() }
    let overlapped = background.isChecking
    if overlapped { await background.check() }
    responseGate.signal()
    await automaticTask.value
    check(overlapped && !UpdateProtocol.didResponseGateTimeOut
          && UpdateProtocol.captured.count == 1 && mergedResult == true, "手动检查合并启动中的请求并获得结果")
    reset()
    UpdateProtocol.fixture(release())
    let unknownVersion = make("")
    await unknownVersion.check()
    check(UpdateProtocol.captured.isEmpty && unknownVersion.statusMessage.contains("当前版本"), "缺少本地版本时不误判最新版本")

    print("update-tests: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

Task { @MainActor in await runTests() }
RunLoop.main.run()
