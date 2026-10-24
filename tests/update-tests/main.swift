import Foundation

private final class UpdateProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = ""
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var offline = false

    static func fixture(_ body: String, status: Int = 200, offline: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        responseBody = body
        responseStatus = status
        self.offline = offline
        requests = []
    }

    static var captured: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
        Self.lock.unlock()
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

private var passed = 0
private var failed = 0
private func check(_ condition: Bool, _ label: String) {
    if condition { passed += 1; print("PASS  \(label)") }
    else { failed += 1; print("FAIL  \(label)") }
}

private func release(_ tag: String = "v2.7.0", draft: Bool = false, prerelease: Bool = false) -> String {
    #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease)}"#
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
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func make(_ version: String = "2.6.1") -> AppUpdater {
        AppUpdater(currentVersion: version, defaults: defaults, session: session, now: { date })
    }
    func reset() { defaults.removePersistentDomain(forName: suite) }

    let updater = make()
    var completions: [Bool] = []
    updater.onCheckCompleted = { completions.append($0) }
    check(updater.automaticallyChecks && updater.status == .idle, "默认开启自动检查")
    UpdateProtocol.fixture(release())
    await updater.checkIfNeeded()
    check(updater.status == .available && updater.availableRelease?.version == "2.7.0", "自动检测更新版本")
    check(completions == [false], "自动检查结果不会被当作手动请求")
    check(updater.lastChecked == date && UpdateProtocol.captured.count == 1, "记录成功检查时间")
    let request = UpdateProtocol.captured.first!
    check(request.url == AppUpdater.endpoint && request.value(forHTTPHeaderField: "Authorization") == nil,
          "仅请求固定公开仓库，不发送模型凭据")
    check(request.timeoutInterval == 20 && request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
          "更新请求有超时并使用 GitHub JSON 接口")
    check(updater.availableRelease?.pageURL.absoluteString == "https://github.com/m0nkee/notescopilot/releases/tag/v2.7.0",
          "下载入口指向对应正式发布页")
    check(updater.shouldRemind(), "首次发现新版本需要提醒")
    updater.markReminded()
    check(!updater.shouldRemind(), "同一天不重复弹出提醒")
    await updater.checkIfNeeded()
    check(UpdateProtocol.captured.count == 1, "一天内不重复自动请求")
    let restored = make()
    check(restored.availableRelease == updater.availableRelease && !restored.shouldRemind(),
          "重新启动保留新版本入口和提醒间隔")
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
    UpdateProtocol.fixture(release())
    let background = make()
    var mergedResult: Bool?
    background.onCheckCompleted = { mergedResult = $0 }
    let automaticTask = Task { await background.check(userInitiated: false) }
    // Both calls enter the actor before URLSession can resume the first request.
    await Task.yield()
    await background.check()
    await automaticTask.value
    check(UpdateProtocol.captured.count == 1 && mergedResult == true, "手动检查合并启动中的请求并获得结果")
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
