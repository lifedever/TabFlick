import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 搜索面板里的命令（一级命中时列在「插件」段，App 的命令也在 App 的 ⌘↩ 里）。都经插件进面板（`PluginRegistry.commands`）。
///
/// 系统命令（`bundleID` 为 nil：锁屏、睡眠、关机这些，见 `SystemControl`；窗口命令，见 `WindowCommands`）不挂在任何
/// App 下面：画 SF Symbol、副标题写「macOS」（窗口命令写「App 名 的窗口」），二级里没有。
/// 挂在第三方 App 下面的（`bundleID` 是那个 App：Amphetamine、CleanShot X）来自商店的 App 插件
///（2026-11-26 从内置的「App 快捷操作」挪过去，见 plugins/README.md「App 插件」）：只在那个 App 装着时出现，
/// 画那个 App 的图标、副标题写 App 名，二级里也有。
///
/// 为什么不读别的 App 的菜单当命令：试过，用户看了实物说不是要的 —— 菜单里名字五花八门
///（Amphetamine 的「无限期」「5分钟」），搜不准；要的是 Raycast 扩展那种挑过的几条。
struct AppCommand: Identifiable {
    enum Action {
        /// AppleScript 源码，一行一个元素（逐行交给 osascript 的 -e）；脚本的返回值 → 回响（nil = 不弹：
        /// 切深色模式、重启这类结果自己看得见）
        case appleScript([String], report: @MainActor (_ output: String) -> (text: String, kind: Toast.Kind)?)
        /// 在本进程里直接做（系统命令；商店 App 插件的命令也走这里，交给插件的 `command(id)`）
        case native(@MainActor () -> Void)
        /// 调整前台 App 的窗口（`WindowCommands`）
        case window(WindowAction, WindowTarget)
        /// 「打开方式…」：面板不关，列表换成能打开访达里选中项目的 App（`OpenWithCommand`）
        case openWith
        /// 「结束进程…」：面板不关，列表换成进程（`ProcessesCommand`）
        case processes
        /// 「最近文件…」：面板不关，列表换成 30 天内打开过的文件（`RecentFilesCommand`）
        case recentFiles
        /// 插件的列表（股票…）：面板不关，列表换成插件给的行。参数是插件 id
        case pluginList(String)
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
    /// 行的第二行。nil = 写命令的主人（App 名，系统命令写 macOS）；窗口命令写要动的是谁的窗口。
    var subtitle: String? = nil
    /// 图标方块的底色。nil = 灰；经插件进面板的系统命令由 `PluginRegistry.commands` 补成插件自己的颜色，
    /// 和设置里那个图标一样（用户 2026-11-06）。不归插件的（「打开方式…」）留灰
    var tint: Color? = nil
    /// 代表整个插件的命令（「结束进程…」、插件列表的入口）画插件的图标，和设置里的一样。nil = 方块里画 `symbol`
    var icon: NSImage? = nil
    /// 会丢东西、不好撤回的（重启、关机、退出所有 App、清空废纸篓）：面板里回车两次才执行，第一下那一行标红写
    /// 「再按 ↩ 确认」（同「结束进程…」里结束一个进程）
    var confirms = false
    /// 脚本控制的是谁（「系统事件」「访达」「loginwindow」）：没给「自动化」授权时 toast 指路用。nil = App 名
    var automationTarget: String? = nil
    let action: Action
}

enum AppCommands {
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
        let report: @MainActor (String) -> (text: String, kind: Toast.Kind)?
        switch command.action {
        case .native(let perform):
            perform()
            return
        case .window(let action, let target):
            WindowMover.perform(action, on: target)
            return
        case .openWith, .processes, .recentFiles, .pluginList:
            return   // 面板自己接（选中它不关面板），走不到这里
        case .appleScript(let source, let reporter):
            script = source
            report = reporter
        }
        // 系统命令的回响不写副标题（写「macOS」没有信息量），App 命令写 App 名
        let detail = command.bundleID == nil ? nil : (appName ?? title)
        let controlled = command.automationTarget ?? appName ?? title
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
                    if let result = report(out) {
                        Toast.show(result.text, detail: detail, kind: result.kind)
                    }
                } else if err.contains("-1743") {
                    // errAEEventNotPermitted：用户在授权框里点了「不允许」，或者之前拒过
                    Toast.show(L10n.t("没能执行「\(title)」", "Couldn't run “\(title)”"),
                               detail: L10n.t("系统设置 → 隐私与安全性 → 自动化里允许 TabFlick 控制「\(controlled)」。",
                                              "Allow TabFlick to control \(controlled) in System Settings → Privacy & Security → Automation."),
                               kind: .failure)
                } else {
                    Toast.show(L10n.t("没能执行「\(title)」", "Couldn't run “\(title)”"),
                               detail: err.isEmpty ? nil : String(err.prefix(160)), kind: .failure)
                }
            }
        }
    }
}

/// 「打开方式…」（2026-10-17，照 Raycast 的 Open With）：访达在前台时打开面板，打「open」「打开方式」
/// 命中它，回车列出能打开访达里选中项目的 App，挑一个打开。系统命令，列在「操作」段（核心功能，不归插件）；
/// 选中它面板不关，列表换成那些 App（同 ⌘↩ 的二级，Esc 退回）。
enum OpenWithCommand {
    /// selection 是打开面板时预读到的选中项：副标题写它的名字，回车前就看得到要开的是什么。
    /// 没预读到（还没允许控制访达、或者还没读回来）只写「访达」。
    @MainActor static func command(selection: FileSelection?) -> AppCommand {
        AppCommand(id: "system.openWith", bundleID: nil,
                   title: L10n.t("打开方式…", "Open With…"),
                   keywords: ["Open With", "打开方式"],
                   symbol: "arrow.up.forward.app",
                   subtitle: ([L10n.t("访达", "Finder")] + [selection?.name].compactMap { $0 }).joined(separator: " · "),
                   action: .openWith)
    }
}

/// 「结束进程…」（2026-10-26 用户要的，照 Raycast 的 Kill Process）：打「kill」「进程」「端口」命中，
/// 回车列表换成你自己的进程（`ProcessList.swift`）。系统命令，和锁屏一样列在「插件」段。
enum ProcessesCommand {
    static let symbol = "xmark.octagon.fill"
    /// 插件图标的底色（设置里、面板命令行、进程列表底栏三处同一个）
    static let tint = Color.red
    @MainActor static var title: String { L10n.t("结束进程…", "Kill Process…") }

    @MainActor static var command: AppCommand {
        AppCommand(id: "system.processes", bundleID: nil,
                   title: title,
                   // 打端口号也该想到它：「3000 被谁占了」
                   keywords: ["Kill Process", "结束进程", "kill", "process", "进程", "port", "端口",
                              "force quit", "强制退出", "Activity Monitor", "活动监视器"],
                   symbol: symbol,
                   action: .processes)
    }
}

/// 「最近文件…」（2026-11-13 用户要的）：打「最近」「recent」「文件」命中，回车列表换成 30 天内打开过的文件
///（`RecentFiles.swift`，和访达「最近使用」同一个来源）。系统命令，和「结束进程…」一样列在「插件」段。
enum RecentFilesCommand {
    static let symbol = "doc.badge.clock.fill"
    /// 插件图标的底色（设置里、面板命令行、列表底栏三处同一个）
    static let tint = Color.blue
    /// 插件名（设置侧边栏、列表底栏、输入框右边的胶囊）
    @MainActor static var name: String { L10n.t("最近文件", "Recent Files") }
    @MainActor static var title: String { L10n.t("最近文件…", "Recent Files…") }

    @MainActor static var command: AppCommand {
        AppCommand(id: "system.recentFiles", bundleID: nil,
                   title: title,
                   keywords: ["Recent Files", "最近文件", "recent", "recents", "最近使用", "最近打开", "文件", "file", "files"],
                   symbol: symbol,
                   action: .recentFiles)
    }
}
