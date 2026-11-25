import AppKit
import SwiftUI

/// 通过 GitHub Releases 检查并**自动安装**新版本。
///
/// 流程：后台检查发现新版本只发系统通知（`UpdateNotifier`），点通知打开设置的「关于」页，
/// 在那里点「更新到 x…」才弹更新窗口（`UpdateDialog`）：写着这期间各版改了什么，
/// 「立即更新」在同一个窗口里显示下载进度，装完自动重启。手动「检查更新」查到新版本直接弹更新窗口。
///
/// 安装机制照搬 PasteMemo 的更新器：下载当前架构的 DMG → 校验字节数 → 挂载 →
/// 用 shell 脚本**原地替换 .app 的内容**（保持 bundle 路径与身份，辅助功能
/// 授权跟着证书 + bundle ID 走，不会丢）→ 重新启动。
///
/// 脚本里删除/拷贝资源 bundle 一律 glob，绝不写死名字 —— updater 脚本是
/// 编译进当前版本的，一旦写死某个 bundle 名发出去，将来新增 SPM 依赖时
/// 旧 updater 会漏拷新 bundle，而且已装旧版的用户没法远程修复
/// （PasteMemo issue #38）。
@MainActor
final class UpdateChecker: ObservableObject {

    private static let repo = "lifedever/TabFlick"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    private static let lastCheckKey = "lastUpdateCheck"
    /// 发过通知的版本：同一版只发一次，没理会就等下一版。
    private static let notifiedKey = "notifiedUpdateVersion"

    /// 谁发起的检查。决定查到结果后怎么告诉用户。
    enum Trigger {
        /// 定时检查：有新版本只发系统通知，没有、失败都不出声。
        case background
        /// 用户点的「检查更新」：有新版本弹更新窗口，已是最新、失败弹提示。
        case manual
        /// 点通知打开「关于」页时补查一次（TabFlick 重启过，内存里没有结果）：只改页面上的状态。
        case quiet
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 查到的更新（版本、安装包、各版说明）。`status` 是 `.available` 时一定有。
    @Published private(set) var offer: UpdateOffer?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    /// 下载完、挂载替换中。随后 app 退出重启。
    @Published private(set) var isInstalling = false

    /// 自动检查频率。事实源在 AppSettings，这里只在到点对账时现读，
    /// 所以设置改动立即生效，不需要重建计时器。
    var frequency: () -> UpdateCheckFrequency = { .daily }

    private var trigger: Trigger = .background
    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    /// 每开始 / 取消一次下载加一。回调带着自己的代号，对不上的是已经取消的那次，丢掉 ——
    /// 不然「取消后马上再点立即更新」时，旧任务的「已取消」会被当成新下载失败。
    private var downloadGeneration = 0
    private var periodicTimer: Timer?
    private lazy var dialog = UpdateDialogController(updates: self)

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查

    func check(_ trigger: Trigger) {
        guard !isDownloading, !isInstalling else {
            // 正在下载 / 安装时点了「检查更新」：把更新窗口提到前面，别没反应
            if trigger == .manual { presentUpdate() }
            return
        }
        if status == .checking {
            // 后台那次还在路上时用户点了「检查更新」：结果按用户点的来报，不然这一下没反应
            if trigger == .manual { self.trigger = .manual }
            return
        }
        self.trigger = trigger
        status = .checking

        Task {
            let result = await fetchOffer()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let trigger = self.trigger

            switch result {
            case .failure(let message):
                status = .failed(message)
                log("⬆️ 检查更新失败：\(message)")
                if trigger == .manual { presentFailure(message) }

            case .success(let found?):
                offer = found
                status = .available(version: found.version)
                log("⬆️ 有新版本 \(found.version)（当前 \(currentVersion)，落下 \(found.notes.count) 版）")
                switch trigger {
                case .background: notifyOnce(found)
                case .manual: dialog.show(found)
                case .quiet: break
                }

            case .success(nil):
                offer = nil
                status = .upToDate
                if trigger == .manual { presentUpToDate() }
            }
        }
    }

    /// 「关于」页的「更新到 x…」：弹更新窗口。
    func presentUpdate() {
        if let offer { dialog.show(offer) } else { check(.manual) }
    }

    /// 点了通知、「关于」页打开时：内存里没有查到的结果（TabFlick 重启过）就静默补查一次，
    /// 页面上的按钮跟着变成「更新到 x…」。
    func refreshForNotification() {
        guard offer == nil, status != .checking else { return }
        check(.quiet)
    }

    /// 周期检查：每小时对一次账，到期才真的查。改频率、睡醒补查都自然覆盖。
    func startPeriodicChecks() {
        clearStaleNotification()

        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        // 启动后稍等再对账，别抢启动窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard let interval = frequency().interval else { return }   // .never
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        check(.background)
    }

    // MARK: - 通知

    /// 同一版只发一次。没交给系统（没给通知权限）的不记，权限打开后下一次检查还会发。
    private func notifyOnce(_ offer: UpdateOffer) {
        let version = offer.version
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != version else { return }
        let heading = L10n.prefersChineseContent ? "更新内容" : "What's New"
        var body = offer.notes.first.map { UpdateFeed.summary(of: $0.body, heading: heading) } ?? ""
        if body.isEmpty { body = L10n.t("当前版本 \(currentVersion)", "You have \(currentVersion)") }
        UpdateNotifier.shared.notifyAvailable(version: version, body: body) { posted in
            guard posted else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(version, forKey: Self.notifiedKey)
                log("⬆️ 已发通知：有新版本 \(version)")
            }
        }
    }

    /// 发过通知的版本已经装上了（或者装回了更新的）：通知中心里那条撤掉。
    private func clearStaleNotification() {
        let defaults = UserDefaults.standard
        guard let notified = defaults.string(forKey: Self.notifiedKey),
              !UpdateFeed.isNewer(notified, than: currentVersion) else { return }
        defaults.removeObject(forKey: Self.notifiedKey)
        UpdateNotifier.shared.removeAvailable()
    }

    // MARK: - 网络

    private enum FetchResult {
        case success(UpdateOffer?)
        case failure(String)
    }

    /// 取发布列表（不用 /releases/latest）：落下好几版时，更新窗口要把这几版的说明都列出来。
    private func fetchOffer() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 仓库还没公开 / 改名时是 404，不当错误
            if code == 404 { return .success(nil) }
            guard code == 200 else {
                return .failure(L10n.t("GitHub 返回 \(code)", "GitHub returned \(code)"))
            }
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure(L10n.t("无法解析发布信息", "Could not parse the release info"))
            }
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            return .success(UpdateFeed.offer(from: releases, current: currentVersion, arch: arch))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - 下载

    /// 更新窗口里点「立即更新」。
    func startDownload(_ offer: UpdateOffer) {
        guard let url = offer.assetURL, !isDownloading, !isInstalling else { return }
        isDownloading = true
        downloadProgress = 0
        downloadGeneration += 1
        let generation = downloadGeneration
        log("⬆️ 开始下载 \(offer.version)")

        let delegate = DownloadDelegate(
            expectedSize: offer.assetSize,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in self?.downloadFinished(result, version: offer.version, generation: generation) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
        // 任务跑完就放掉 session（它强引用着 delegate），不然每下一次漏一个
        session.finishTasksAndInvalidate()
    }

    func cancelDownload() {
        guard isDownloading else { return }
        downloadGeneration += 1   // 被取消的任务随后回来的「已取消」不再理会
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        log("⬆️ 取消下载")
    }

    private func downloadFinished(_ result: DownloadResult, version: String, generation: Int) {
        guard generation == downloadGeneration, isDownloading else { return }   // 已取消的那次
        isDownloading = false
        downloadTask = nil

        switch result {
        case .success(let fileURL):
            installAndRestart(from: fileURL, version: version)
        case .failure(let message):
            log("⬆️ 下载失败：\(message)")
            dialog.close()
            presentInstallFailure(message)
        }
    }

    // MARK: - 安装

    private func installAndRestart(from dmg: URL, version: String) {
        let destApp = Bundle.main.bundlePath
        // swift run 之类的非 .app 环境没有可替换的 bundle，别把 .build 目录搅了
        guard destApp.hasSuffix(".app") else {
            dialog.close()
            NSWorkspace.shared.open(dmg)
            return
        }
        isInstalling = true
        // hdiutil attach 要一两秒，放后台，更新窗口里的「安装中…」不卡
        DispatchQueue.global(qos: .userInitiated).async {
            let mountPoint = Self.mountDMG(at: dmg.path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.replaceAndRelaunch(dmg: dmg, mountPoint: mountPoint, destApp: destApp, version: version)
                }
            }
        }
    }

    private func replaceAndRelaunch(dmg: URL, mountPoint: String?, destApp: String, version: String) {
        guard let mountPoint else {
            failInstall(L10n.t("更新包无法打开", "The update image could not be opened"))
            return
        }
        let sourceApp = "\(mountPoint)/TabFlick.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            Self.detachDMG(mountPoint)
            failInstall(L10n.t("更新包内容不完整", "The update image is missing the app"))
            return
        }

        // 只替换内容、不动 .app 目录本身：bundle 的路径与身份保持不变，
        // 辅助功能授权（证书 + bundle ID）跟着保住。_CodeSignature 必须和
        // 它封印的内容一起换，否则签名校验从此失败。
        let script = """
        #!/bin/bash
        sleep 2
        rm -rf "\(destApp)/Contents/MacOS" "\(destApp)/Contents/Resources" "\(destApp)/Contents/_CodeSignature"
        rm -rf "\(destApp)"/*.bundle
        cp -R "\(sourceApp)/Contents/MacOS" "\(destApp)/Contents/MacOS"
        cp -R "\(sourceApp)/Contents/Resources" "\(destApp)/Contents/Resources"
        cp "\(sourceApp)/Contents/Info.plist" "\(destApp)/Contents/Info.plist"
        if [ -d "\(sourceApp)/Contents/_CodeSignature" ]; then
            cp -R "\(sourceApp)/Contents/_CodeSignature" "\(destApp)/Contents/_CodeSignature"
        fi
        for b in "\(sourceApp)"/*.bundle; do
            [ -d "$b" ] && cp -R "$b" "\(destApp)/"
        done
        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null
        xattr -dr com.apple.quarantine "\(destApp)" 2>/dev/null
        open "\(destApp)"
        rm -f "$0"
        """

        // 更新窗口里已经看过这一版的说明，重启后别再弹一遍「更新内容」（ReleaseNotes 认这个标记）。
        // 脚本起来之前写好并落盘：紧接着就 terminate 了
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: ReleaseNotes.seenBeforeInstallKey)
        defaults.synchronize()
        do {
            let scriptPath = NSTemporaryDirectory() + "tabflick_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()
            log("Updater launched — replacing app contents with \(version) and relaunching")
            NSApp.terminate(nil)
        } catch {
            defaults.removeObject(forKey: ReleaseNotes.seenBeforeInstallKey)
            Self.detachDMG(mountPoint)
            isInstalling = false
            dialog.close()
            NSWorkspace.shared.open(dmg)
        }
    }

    private func failInstall(_ message: String) {
        isInstalling = false
        dialog.close()
        presentInstallFailure(message)
    }

    /// 在后台线程上跑（hdiutil 要一两秒）。
    nonisolated private static func mountDMG(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-noverify"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 提示

    /// 弹提示框。`runModal` 不能直接在 `Task` 里跑：主队列不可重入，弹窗开着时主线程上
    /// 别的派发（搜索键的 `main.async`、MainActor 任务）全卡住。挂到 run loop 的 default 模式上跑。
    private func runAlert(_ alert: NSAlert, then handle: ((NSApplication.ModalResponse) -> Void)? = nil) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                handle?(response)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = L10n.t("已是最新版本", "You're up to date")
        alert.informativeText = L10n.t("当前版本 \(currentVersion)。", "TabFlick \(currentVersion) is the latest version.")
        alert.addButton(withTitle: L10n.t("好", "OK"))
        runAlert(alert)
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("检查更新失败", "Could not check for updates")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("好", "OK"))
        runAlert(alert)
    }

    private func presentInstallFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("自动更新失败", "Automatic update failed")
        alert.informativeText = message + L10n.t(
            "\n\n可以去发布页手动下载。",
            "\n\nYou can download it manually from the releases page."
        )
        alert.addButton(withTitle: L10n.t("前往下载", "Open Download Page"))
        alert.addButton(withTitle: L10n.t("稍后", "Later"))
        runAlert(alert) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
        }
    }
}

// MARK: - 下载代理

/// 下载结果。失败侧直接携带展示用的文案，不套 Error。
private enum DownloadResult {
    case success(URL)
    case failure(String)
}

/// URLSession 的回调不在主线程，单独一个类接住，回主线程只传数据。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let expectedSize: Int64
    private let onProgress: (Double) -> Void
    private let onFinish: (DownloadResult) -> Void
    /// 成功路径已经回调过，didCompleteWithError 的 nil error 不再重复回调。
    private var finished = false

    init(expectedSize: Int64,
         onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (DownloadResult) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TabFlick-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        // location 是系统临时文件，回调返回后立即被删，必须先挪走
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finished = true
            onFinish(.failure(error.localizedDescription))
            return
        }

        // 校验字节数：CDN 截断、连接中断的包不能进安装环节
        if expectedSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != expectedSize {
            try? FileManager.default.removeItem(at: dest)
            finished = true
            onFinish(.failure("Incomplete download (\(fileSize)/\(expectedSize) bytes)"))
            return
        }

        finished = true
        onFinish(.success(dest))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error.localizedDescription))
    }
}
