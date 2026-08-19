import AppKit
import ApplicationServices
import PermissionFlow

/// 辅助功能授权流程。
///
/// **刻意没有窗口。** PermissionFlow 的浮层只在系统设置是前台应用时可见，
/// 并且贴着系统设置窗口摆放 —— 我们自己的任何窗口都会把它盖住或挤走
/// （实测：浮层被压在授权窗口下面只露出左边一条，用户以为它"飘没了"）。
///
/// 所以入口放在菜单栏菜单项上，和 PasteMemo 一致：点完菜单立刻收起，
/// 不占前台也不遮挡，浮层就能稳稳待在系统设置旁边。
@MainActor
final class PermissionCoordinator {

    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?

    /// `promptForAccessibilityTrust: false` —— 系统那个原生弹窗只在首次请求时
    /// 出现，用户点过一次「拒绝」之后再调就毫无反应，靠它引导不可靠。
    private let controller = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false
        )
    )

    /// 开始等待授权。授权一生效就回调（调用方负责重启进程）。
    func startWaiting(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard AXIsProcessTrusted() else { return }
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                log("Accessibility granted — relaunching")
                self?.onGranted?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// 弹出 PermissionFlow 的拖拽授权浮层。
    func authorize() {
        // 缺资源 bundle 时碰 PermissionFlow 会在 Bundle.module 处 SIGTRAP
        // （PasteMemo issue #38：打包脚本漏拷 bundle，用户升级后必崩）。
        guard Self.bundleAvailable() else {
            log("⚠️  PermissionFlow resource bundle missing — falling back to plain deeplink")
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
            return
        }

        // 浮层从鼠标位置飞向系统设置窗口，传起点才有这段动画
        let location = NSEvent.mouseLocation
        let sourceFrame = CGRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32)

        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: sourceFrame,
            panelHint: L10n.t("把图标拖到「辅助功能」列表里", "Drag this icon into the Accessibility list"),
            panelTitle: L10n.t("授权 TabFlick", "Authorize TabFlick")
        )
    }

    /// 资源 bundle 是否就位。
    ///
    /// 两个位置都要认：签名构建把它放在 `Contents/Resources`，而 SwiftPM 生成的
    /// 访问器只认 `.app` 根目录。只查其中一个，另一种布局就会被误判成"文件缺失"
    /// （PasteMemo v1.7.15-beta.1 的假阳性）。
    private static func bundleAvailable() -> Bool {
        let name = "PermissionFlow_PermissionFlow.bundle"
        let candidates: [URL?] = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        return candidates.contains { candidate in
            guard let url = candidate?.appendingPathComponent(name) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
