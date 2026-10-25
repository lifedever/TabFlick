import AppKit
import ApplicationServices

/// 辅助功能权限相关的小工具。引导流程在 `PermissionCoordinator`。
enum PermissionGuide {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 重启自己。授权生效后、状态栏菜单的「重启 TabFlick」都走这里。
    ///
    /// 权限只在进程启动时被读取，所以授权后必须重开。与其让用户自己想起来
    /// 手动退出再打开，不如替他做掉。
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        // 先退出再启动：两个实例同时活着会撞在同一个 WebSocket 端口上，而且旧进程还在时
        // `open` 只会把它激活、不会再开一个。所以 shell 先等这个 pid 真退出（最多 10 秒）再拉起。
        // 开发版（`dev-run.sh`）不是 .app，`open` 目录会打开访达，直接起可执行文件。
        let launch = path.hasSuffix(".app")
            ? "open \(shellQuoted(path))"
            : "nohup \(shellQuoted(Bundle.main.executablePath ?? path)) >/dev/null 2>&1 &"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "for _ in $(seq 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; \(launch)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
