import AppKit
import Foundation

/// 通过 GitHub Releases 检查新版本。
///
/// 只做「发现并告知」，不自动下载安装：本机没有 Developer ID 证书，应用只能
/// ad-hoc 签名，而 macOS 用代码哈希（cdhash）识别这类应用 —— 就地替换 app
/// 会让系统当成另一个应用，用户的辅助功能授权随即失效，⌃⇥ 直接失灵。
/// 与其做一个「更新完就坏」的自动安装，不如把人送到发布页，让替换这件事
/// 是他自己知情做的。拿到证书之后再补自动安装不迟。
@MainActor
final class UpdateChecker: ObservableObject {

    private static let repo = "lifedever/TabFlick"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func check(userInitiated: Bool) {
        guard status != .checking else { return }
        status = .checking

        Task {
            let result = await fetchLatestTag()
            switch result {
            case .failure(let message):
                status = .failed(message)
                if userInitiated { presentFailure(message) }

            case .success(let latest):
                if isNewer(latest, than: currentVersion) {
                    status = .available(version: latest)
                    if userInitiated { presentAvailable(latest) }
                } else {
                    status = .upToDate
                    if userInitiated { presentUpToDate() }
                }
            }
        }
    }

    // MARK: - 网络

    private enum FetchResult {
        case success(String)
        case failure(String)
    }

    private func fetchLatestTag() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 一个 release 都还没发时 GitHub 返回 404，这不是错误
            if code == 404 {
                return .success("0.0.0")
            }
            guard code == 200 else {
                return .failure(L10n.t("GitHub 返回 \(code)", "GitHub returned \(code)"))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure(L10n.t("无法解析发布信息", "Could not parse the release info"))
            }
            return .success(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
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

    // MARK: - 提示

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentAvailable(_ version: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = L10n.t("有新版本 \(version)", "Version \(version) is available")
        alert.informativeText = L10n.t(
            """
            当前版本 \(currentVersion)。

            下载后请把新的 TabFlick 拖到「应用程序」替换旧版。由于应用使用 \
            ad-hoc 签名，替换后 macOS 会要求重新授予「辅助功能」权限 —— \
            TabFlick 会在启动时引导你完成。
            """,
            """
            You have \(currentVersion).

            After downloading, drag the new TabFlick into Applications to replace \
            the old one. Because the app is ad-hoc signed, macOS will ask for \
            Accessibility permission again — TabFlick walks you through it on launch.
            """
        )
        alert.addButton(withTitle: L10n.t("前往下载", "Open Download Page"))
        alert.addButton(withTitle: L10n.t("稍后", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
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
}
