import AppKit
import SwiftUI

/// 通过 GitHub Releases 检查并**自动安装**新版本。
///
/// 机制照搬 PasteMemo 的更新器：下载当前架构的 DMG → 校验字节数 → 挂载 →
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
    private static let skippedKey = "skippedUpdateVersion"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var pendingVersion = ""

    /// 自动检查频率。事实源在 AppSettings，这里只在到点对账时现读，
    /// 所以设置改动立即生效，不需要重建计时器。
    var frequency: () -> UpdateCheckFrequency = { .daily }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var downloadCancelled = false
    private var progressWindow: NSWindow?
    private var periodicTimer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查

    func check(userInitiated: Bool) {
        guard status != .checking, !isDownloading else { return }
        status = .checking

        Task {
            let result = await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            switch result {
            case .failure(let message):
                status = .failed(message)
                if userInitiated { presentFailure(message) }

            case .success(let release):
                if isNewer(release.version, than: currentVersion) {
                    status = .available(version: release.version)
                    // 自动检查尊重「跳过此版本」；手动检查永远弹
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                    if userInitiated || release.version != skipped {
                        presentAvailable(release)
                    }
                } else {
                    status = .upToDate
                    if userInitiated { presentUpToDate() }
                }
            }
        }
    }

    /// 周期检查：每小时对一次账，到期才真的查。改频率、睡醒补查都自然覆盖。
    func startPeriodicChecks() {
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
        check(userInitiated: false)
    }

    // MARK: - 网络

    private struct Latest {
        let version: String
        /// 当前架构的 DMG 资产；发布时漏传该架构的包时为 nil，降级到发布页。
        let assetURL: URL?
        let assetSize: Int64
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 一个 release 都还没发时 GitHub 返回 404，这不是错误
            if code == 404 {
                return .success(Latest(version: "0.0.0", assetURL: nil, assetSize: 0))
            }
            guard code == 200 else {
                return .failure(L10n.t("GitHub 返回 \(code)", "GitHub returned \(code)"))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure(L10n.t("无法解析发布信息", "Could not parse the release info"))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            // 找当前架构的 DMG。资产名形如 TabFlick-0.2.0-arm64.dmg
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            var assetURL: URL?
            var assetSize: Int64 = 0
            if let assets = json["assets"] as? [[String: Any]],
               let asset = assets.first(where: {
                   let name = $0["name"] as? String ?? ""
                   return name.contains(arch) && name.hasSuffix(".dmg")
               }) {
                assetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
            }
            return .success(Latest(version: version, assetURL: assetURL, assetSize: assetSize))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 逐段比较数字版本号。字符串比较会把 "0.10.0" 判成小于 "0.9.0"。
    private func isNewer(_ remote: String, than current: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 下载

    private func startDownload(_ latest: Latest) {
        guard let url = latest.assetURL, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadCancelled = false
        pendingVersion = latest.version
        showProgressWindow()

        let delegate = DownloadDelegate(
            expectedSize: latest.assetSize,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in self?.downloadFinished(result) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        closeProgressWindow()
    }

    private func downloadFinished(_ result: DownloadResult) {
        isDownloading = false
        downloadTask = nil
        closeProgressWindow()

        switch result {
        case .success(let fileURL):
            installAndRestart(from: fileURL)
        case .failure(let message):
            guard !downloadCancelled else { return }   // 用户主动取消，别再弹错误
            presentInstallFailure(message)
        }
    }

    // MARK: - 安装

    private func installAndRestart(from dmg: URL) {
        let destApp = Bundle.main.bundlePath
        // swift run 之类的非 .app 环境没有可替换的 bundle，别把 .build 目录搅了
        guard destApp.hasSuffix(".app") else {
            NSWorkspace.shared.open(dmg)
            return
        }

        guard let mountPoint = Self.mountDMG(at: dmg.path) else {
            presentInstallFailure(L10n.t("更新包无法打开", "The update image could not be opened"))
            return
        }
        let sourceApp = "\(mountPoint)/TabFlick.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            Self.detachDMG(mountPoint)
            presentInstallFailure(L10n.t("更新包内容不完整", "The update image is missing the app"))
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

        do {
            let scriptPath = NSTemporaryDirectory() + "tabflick_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()
            log("Updater launched — replacing app contents and relaunching")
            NSApp.terminate(nil)
        } catch {
            Self.detachDMG(mountPoint)
            NSWorkspace.shared.open(dmg)
        }
    }

    private static func mountDMG(at path: String) -> String? {
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

    private static func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 进度窗口

    private func showProgressWindow() {
        if progressWindow == nil {
            let host = NSHostingController(rootView: DownloadProgressView(updates: self))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled]           // 不给关闭按钮，取消走窗口里的按钮
            w.title = L10n.t("软件更新", "Software Update")
            w.isReleasedWhenClosed = false
            // 先布局定尺寸再居中（PasteMemo #66：反过来会以近零尺寸居中）
            host.view.layoutSubtreeIfNeeded()
            w.setContentSize(host.view.fittingSize)
            w.center()
            progressWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        progressWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeProgressWindow() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    // MARK: - 提示

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentAvailable(_ latest: Latest) {
        activate()
        let alert = NSAlert()
        alert.messageText = L10n.t("有新版本 \(latest.version)", "Version \(latest.version) is available")

        if latest.assetURL != nil {
            alert.informativeText = L10n.t(
                "当前版本 \(currentVersion)。点「下载并安装」后 TabFlick 会自动完成更新并重新启动。",
                "You have \(currentVersion). TabFlick will download the update, install it, and relaunch automatically."
            )
            alert.addButton(withTitle: L10n.t("下载并安装", "Download & Install"))
            alert.addButton(withTitle: L10n.t("稍后", "Later"))
            alert.addButton(withTitle: L10n.t("跳过此版本", "Skip This Version"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                startDownload(latest)
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(latest.version, forKey: Self.skippedKey)
            default:
                break
            }
        } else {
            // 这一版的 release 缺当前架构的 DMG，退回发布页手动下载
            alert.informativeText = L10n.t(
                "当前版本 \(currentVersion)。这一版没有找到适配本机的安装包，请前往发布页手动下载。",
                "You have \(currentVersion). No package for this Mac was found in the release — please download it from the releases page."
            )
            alert.addButton(withTitle: L10n.t("前往下载", "Open Download Page"))
            alert.addButton(withTitle: L10n.t("稍后", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        }
    }

    private func presentUpToDate() {
        activate()
        let alert = NSAlert()
        alert.messageText = L10n.t("已是最新版本", "You're up to date")
        alert.informativeText = L10n.t("当前版本 \(currentVersion)。", "TabFlick \(currentVersion) is the latest version.")
        alert.addButton(withTitle: L10n.t("好", "OK"))
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("检查更新失败", "Could not check for updates")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("好", "OK"))
        alert.runModal()
    }

    private func presentInstallFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("自动更新失败", "Automatic update failed")
        alert.informativeText = message + L10n.t(
            "\n\n可以前往发布页手动下载安装。",
            "\n\nYou can download and install it manually from the releases page."
        )
        alert.addButton(withTitle: L10n.t("前往下载", "Open Download Page"))
        alert.addButton(withTitle: L10n.t("稍后", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }
}

// MARK: - 下载进度视图

private struct DownloadProgressView: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("正在下载 TabFlick \(updates.pendingVersion)…",
                        "Downloading TabFlick \(updates.pendingVersion)…"))
                .font(.system(size: 13, weight: .medium))
            ProgressView(value: updates.downloadProgress)
                .frame(width: 280)
            HStack {
                Text("\(Int(updates.downloadProgress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L10n.t("取消", "Cancel")) {
                    updates.cancelDownload()
                }
            }
            .frame(width: 280)
        }
        .padding(20)
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
