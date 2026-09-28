import AppKit
import Carbon.HIToolbox

/// 内置命令：按 App 写死的几条高频操作（2026-09-28 用户定的「内置扩展」）。搜索面板里有输入且
/// 命中时跟在它的 App 下面（一级），App 的 ⌘↩ 里也列（二级）。只列装了的 App 的。
///
/// 为什么写死：试过读别的 App 的菜单当命令，用户看了实物说不是要的 —— 菜单里名字五花八门
///（Amphetamine 的「无限期」「5分钟」），搜不准；要的是 Raycast 扩展那种挑过的两三条。
/// 走 App 公开的 AppleScript 接口：`tell application id` 在 App 没运行时会先把它拉起来再执行，
/// 和 Raycast 的 Amphetamine 扩展同一条路。第一次用时系统会问「允许 TabFlick 控制 X」。
///
/// 加一个 App = 在 `all` 里加几条。没有脚本接口（`sdef <App路径>` 查不到命令）的 App 做不了。
///
/// 系统命令（`bundleID` 为 nil，现在只有锁屏，用户 2026-09-28 点名要的）不挂在任何 App 下面：
/// 一级命中时单独列在「应用」段末尾，画 SF Symbol、副标题写「macOS」，二级里没有。
struct AppCommand: Identifiable {
    enum Action {
        /// AppleScript 源码，一行一个元素（逐行交给 osascript 的 -e）；脚本的返回值 → 回响
        case appleScript([String], report: @MainActor (_ output: String) -> (text: String, kind: Toast.Kind))
        /// 在本进程里直接做（系统命令）
        case native(@MainActor () -> Void)
    }

    let id: String
    /// 属于哪个 App。nil = 系统命令。
    let bundleID: String?
    /// 行标题（跟界面语言）。
    let title: String
    /// 另一种语言的名字和别名：「start」「开始」不管界面是什么语言都要能搜到。
    let keywords: [String]
    /// 系统命令的图标（App 的命令画那个 App 的图标，不用它）。
    var symbol = "command"
    let action: Action
}

enum AppCommands {
    @MainActor static var all: [AppCommand] {
        let amphetamine = "com.if.Amphetamine"
        return [
            AppCommand(
                id: "amphetamine.start", bundleID: amphetamine,
                title: L10n.t("开始新会话", "Start New Session"),
                keywords: ["Start New Session", "开始新会话", "start"],
                // 时长、是否允许显示器睡眠都用 Amphetamine 设置里的默认值（它的脚本接口不传参数时就是这样）
                action: .appleScript(["tell application id \"\(amphetamine)\" to start new session"],
                                     report: { _ in (L10n.t("已开始新会话", "Session started"), .success) })),
            AppCommand(
                id: "amphetamine.end", bundleID: amphetamine,
                title: L10n.t("结束当前会话", "End Current Session"),
                keywords: ["End Current Session", "结束当前会话", "end", "stop"],
                // 先问有没有会话：没有也照结束的话，回响「已结束」是在说假话
                action: .appleScript(["tell application id \"\(amphetamine)\"",
                                      "if session is active then",
                                      "end session",
                                      "return \"ended\"",
                                      "end if",
                                      "return \"none\"",
                                      "end tell"],
                                     report: { output in
                                         output == "none"
                                             ? (L10n.t("现在没有进行中的会话", "No session is running"), .info)
                                             : (L10n.t("已结束会话", "Session ended"), .success)
                                     })),
            // 系统命令
            AppCommand(
                id: "system.lock", bundleID: nil,
                title: L10n.t("锁定屏幕", "Lock Screen"),
                // 标题「锁定屏幕」里没有连着的「锁屏」两个字，拼音也是 suodingpingmu，都得单独列
                keywords: ["Lock Screen", "锁定屏幕", "锁屏", "lock", "suoping"],
                symbol: "lock.fill",
                action: .native { lockScreen() }),
        ]
    }

    /// 某个 App 的内置命令（没有就是空）。系统命令不属于任何 App，这里拿不到。
    @MainActor static func commands(for bundleID: String?) -> [AppCommand] {
        guard let bundleID else { return [] }
        return all.filter { $0.bundleID == bundleID }
    }

    /// 锁屏，和 ⌃⌘Q 一样立刻锁。走 login.framework 的私有接口 `SACLockScreenImmediate`，
    /// 运行时 dlsym 查（同 WindowShadow 的做法，链接期不依赖它）；查不到（哪天系统把它挪了）
    /// 就发一次 ⌃⌘Q —— 有辅助功能权限，CGEvent 发得出去。
    @MainActor static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            let result = unsafeBitCast(symbol, to: LockFunction.self)()
            log("🔒 lock screen → \(result)")
            return
        }
        log("🔒 SACLockScreenImmediate not found, sending ⌃⌘Q")
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down)
            event?.flags = [.maskControl, .maskCommand]
            event?.post(tap: .cghidEventTap)
        }
    }

    /// 执行（面板已经关了）。osascript 子进程、后台队列：第一次会弹「自动化」授权框，
    /// 在主线程上同步等就把主线程卡在授权框上（同「收藏当前 Finder 目录」那条）。
    /// App 没运行时脚本会先把它拉起来，冷启动要一两秒 —— 回响等脚本跑完再给，提前说「已开始」是撒谎。
    @MainActor static func run(_ command: AppCommand, appName: String?) {
        let title = command.title
        let script: [String]
        let report: @MainActor (String) -> (text: String, kind: Toast.Kind)
        switch command.action {
        case .native(let perform):
            perform()
            return
        case .appleScript(let source, let reporter):
            script = source
            report = reporter
        }
        let appName = appName ?? title
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = script.flatMap { ["-e", $0] }
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                log("⚡️ \(title) failed to launch osascript: \(error)")
                return
            }
            // 兜底：App 卡死时别让这个子进程一直挂着。放宽到一分钟 —— 第一次用时用户可能正对着授权框想
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = process.terminationStatus
            log("⚡️ \(title) → exit \(status)\(out.isEmpty ? "" : ", \(out)")\(err.isEmpty ? "" : ", \(err)")")
            Task { @MainActor in
                if status == 0 {
                    let result = report(out)
                    Toast.show(result.text, detail: appName, kind: result.kind)
                } else if err.contains("-1743") {
                    // errAEEventNotPermitted：用户在授权框里点了「不允许」，或者之前拒过
                    Toast.show(L10n.t("没能执行「\(title)」", "Couldn't run “\(title)”"),
                               detail: L10n.t("系统设置 → 隐私与安全性 → 自动化里允许 TabFlick 控制「\(appName)」。",
                                              "Allow TabFlick to control \(appName) in System Settings → Privacy & Security → Automation."),
                               kind: .failure)
                } else {
                    Toast.show(L10n.t("没能执行「\(title)」", "Couldn't run “\(title)”"),
                               detail: err.isEmpty ? nil : String(err.prefix(160)), kind: .failure)
                }
            }
        }
    }
}
