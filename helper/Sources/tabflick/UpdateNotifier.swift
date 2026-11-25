import AppKit
@preconcurrency import UserNotifications

/// 自动检查发现新版本时发的系统通知（照 PasteMemo 的 UpdateNotifier）。
///
/// 后台检查以前直接弹 NSAlert：抢前台、全屏视频被拉回桌面，人不在电脑前时
/// 窗口一直开着。现在只发一条通知，点了打开设置的「关于」页，在那里点更新才弹更新窗口。
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    /// 固定 identifier：再发一次替换旧的，通知中心里不会堆好几条。
    nonisolated static let availableID = "update.available"

    /// 点了通知。main.swift 接：打开设置的「关于」页。
    var onOpen: (() -> Void)?

    private override init() { super.init() }

    /// 打包成 .app 才能用通知：`swift run` 的裸二进制没有 bundle，碰
    /// `UNUserNotificationCenter.current()` 直接崩（bundleProxyForCurrentProcess is nil）。
    private var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// 启动时、`NSApplication.run()` 之前调：TabFlick 没在运行时点通知，系统会把它拉起来，
    /// delegate 要在那之前设好，点击才送得到。
    func install() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// 发「有新版本」。`posted` 在后台线程回调：真的交给系统了才是 true
    /// （没给通知权限、开发版没有 bundle 都是 false）。
    func notifyAvailable(version: String, body: String, posted: @escaping @Sendable (Bool) -> Void) {
        guard isAvailable else {
            log("⬆️ 有新版本 \(version)，开发版发不了通知")
            posted(false)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = L10n.t("有新版本 \(version)", "Version \(version) is available")
        content.body = body
        let request = UNNotificationRequest(identifier: Self.availableID, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()

        // 先查授权 → 没问过就先问 → 同意了再 add。请求授权和 add 并行的话第一条会丢（PasteMemo 踩过）
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error { log("⬆️ 更新通知发送失败：\(error.localizedDescription)") }
                    posted(error == nil)
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    guard granted else {
                        log("⬆️ 通知权限没给，更新只在设置 → 关于里看得到")
                        posted(false)
                        return
                    }
                    center.add(request) { error in posted(error == nil) }
                }
            default:
                log("⬆️ 通知权限关着，更新只在设置 → 关于里看得到")
                posted(false)
            }
        }
    }

    /// 已经装上新版本：通知中心里那条「有新版本」留着只会误导。
    func removeAvailable() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.availableID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == Self.availableID,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { UpdateNotifier.shared.onOpen?() }
            }
        }
        completionHandler()
    }

    /// 设置窗口开着时 TabFlick 算前台 App，系统先问这里要不要显示；默认是不显示。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notification.request.identifier == Self.availableID ? [.banner, .list] : [])
    }
}
