import AppKit
import ApplicationServices

/// 辅助功能权限相关的小工具。
///
/// 引导界面在 `PermissionWindowController` —— 那里需要一个可拖拽的 app 图标
/// 和常驻的等待状态，NSAlert 两样都做不到（它是模态的，弹着就没法轮询）。
enum PermissionGuide {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 重启自己。
    ///
    /// 权限只在进程启动时被读取，所以授权后必须重开。与其让用户自己想起来
    /// 手动退出再打开，不如替他做掉。
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        // 先退出再启动：两个实例同时活着会撞在同一个 WebSocket 端口上。
        // 用一条 detached 的 shell 命令延迟拉起，自己立刻终止。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 1; open \(shellQuoted(path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
