import AppKit
import ApplicationServices

/// 辅助功能授权流程。入口在菜单栏的「授权 TabFlick…」，未授权时没有别的界面。
@MainActor
final class PermissionCoordinator {

    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?

    private static let accessibilityPane =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

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

    /// 登记进列表，打开「辅助功能」那一页。
    ///
    /// 每次都开设置页，不指望系统提示：它只在列表里还没有 TabFlick 时弹，开关被关掉
    /// 的老用户什么都看不到。第一次启动时两个会同时出现，指向同一个动作，不冲突。
    func authorize() {
        registerInList()
        NSWorkspace.shared.open(Self.accessibilityPane)
        // 系统设置已经开着、压在别的窗口后面时，光开链接不一定会提到前面
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.activate()
    }

    /// 带提示的 `AXIsProcessTrustedWithOptions` 会把 TabFlick 登记进「辅助功能」列表
    /// （开关关着），用户打开开关就行；第一次调用时系统还会弹它自己的提示。
    /// 不调用的话列表里没有 TabFlick，用户得自己点「+」去「应用程序」里找。
    private func registerInList() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
