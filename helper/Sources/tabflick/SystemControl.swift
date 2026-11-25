import AppKit
import SwiftUI

/// 「系统控制」插件（2026-11-25 用户要的）：锁屏、睡眠、重启、关机、隐藏所有窗口、切换深色模式这类
/// 不挂在任何 App 上的操作。有输入且命中时列在搜索面板的「插件」段，也能放进菜单栏（二级菜单）。
///
/// 会丢东西、不好撤回的（退出所有 App、重启、关机、退出登录、清空废纸篓）在面板里**回车两次**才执行
/// （`AppCommand.confirms`，同「结束进程…」那一下），菜单栏里没有「再按一次」，弹确认框。
///
/// 只走系统公开的路，不模拟按键：pmset、NSRunningApplication、NSWorkspace、AppleScript（loginwindow、
/// 系统事件、访达）。锁屏是原来「App 快捷操作」里那条，挪过来了（命令 id 不变，用户设的关键词还在）。
/// 勿扰 / 专注模式、蓝牙、屏幕亮度没有稳定的公开接口，不做。
///
/// 权限：重启 / 关机 / 退出登录第一次用会弹「允许 TabFlick 控制 loginwindow」（2026-11-25 用
/// `AEDeterminePermissionToAutomateTarget` 探过：需要用户同意），切换深色模式弹「系统事件」，
/// 清空废纸篓用访达的（收藏 Finder 目录时已经给过）。授权框上的字是 `packaging/Info.plist` 的
/// `NSAppleEventsUsageDescription`。
enum SystemControl {

    enum Kind: String, CaseIterable {
        case lock, hideAll, hideOthers, quitAll, displayOff, sleep, screenSaver
        case restart, shutDown, logOut, darkMode, mute, ejectAll, emptyTrash
    }

    /// 命令 id。锁屏沿用原来的 `system.lock`：命令关键词按 id 存，改了用户设的就丢了。
    static func id(_ kind: Kind) -> String { "system." + kind.rawValue }

    /// 回车两次（菜单里弹确认框）的那几条。
    static func confirms(_ kind: Kind) -> Bool {
        switch kind {
        case .quitAll, .restart, .shutDown, .logOut, .emptyTrash: return true
        default: return false
        }
    }

    @MainActor static func title(_ kind: Kind) -> String {
        switch kind {
        case .lock:        return L10n.t("锁定屏幕", "Lock Screen")
        case .hideAll:     return L10n.t("隐藏所有窗口", "Hide All Windows")
        case .hideOthers:  return L10n.t("隐藏其他 App", "Hide Other Apps")
        case .quitAll:     return L10n.t("退出所有 App", "Quit All Apps")
        case .displayOff:  return L10n.t("关闭显示器", "Turn Off Display")
        case .sleep:       return L10n.t("睡眠", "Sleep")
        case .screenSaver: return L10n.t("开始屏幕保护程序", "Start Screen Saver")
        case .restart:     return L10n.t("重新启动", "Restart")
        case .shutDown:    return L10n.t("关机", "Shut Down")
        case .logOut:      return L10n.t("退出登录", "Log Out")
        case .darkMode:    return L10n.t("切换深色模式", "Toggle Dark Mode")
        case .mute:        return L10n.t("切换静音", "Toggle Mute")
        case .ejectAll:    return L10n.t("推出所有磁盘", "Eject All Disks")
        case .emptyTrash:  return L10n.t("清空废纸篓", "Empty Trash")
        }
    }

    /// 另一种语言的名字、常见叫法、拼音（别名不走拼音索引，像「锁屏」「重启」要单独写拼音）。
    static func keywords(_ kind: Kind) -> [String] {
        switch kind {
        case .lock:        return ["Lock Screen", "锁定屏幕", "锁屏", "lock", "suoping"]
        case .hideAll:     return ["Hide All Windows", "隐藏所有窗口", "hide all", "hide", "隐藏", "显示桌面",
                                   "show desktop", "desktop", "桌面", "zhuomian"]
        case .hideOthers:  return ["Hide Other Apps", "隐藏其他 App", "隐藏其他应用", "hide others", "隐藏其他"]
        case .quitAll:     return ["Quit All Apps", "退出所有 App", "退出所有应用", "quit all", "退出全部", "关闭所有"]
        case .displayOff:  return ["Turn Off Display", "关闭显示器", "display off", "display sleep", "显示器睡眠",
                                   "关屏", "息屏", "熄屏", "screen off", "guanping"]
        case .sleep:       return ["Sleep", "睡眠", "休眠", "sleep"]
        case .screenSaver: return ["Start Screen Saver", "开始屏幕保护程序", "screen saver", "screensaver",
                                   "屏保", "屏幕保护", "pingbao"]
        case .restart:     return ["Restart", "重新启动", "重启", "restart", "reboot", "chongqi"]
        case .shutDown:    return ["Shut Down", "关机", "shutdown", "shut down", "power off", "guanji"]
        case .logOut:      return ["Log Out", "退出登录", "注销", "log out", "logout", "sign out", "zhuxiao"]
        case .darkMode:    return ["Toggle Dark Mode", "切换深色模式", "dark mode", "light mode", "深色模式",
                                   "浅色模式", "暗色", "夜间模式", "appearance", "外观"]
        case .mute:        return ["Toggle Mute", "切换静音", "mute", "unmute", "静音", "取消静音", "声音", "sound", "jingyin"]
        case .ejectAll:    return ["Eject All Disks", "推出所有磁盘", "eject", "推出", "弹出", "磁盘", "disk",
                                   "U 盘", "移动硬盘", "tuichu"]
        case .emptyTrash:  return ["Empty Trash", "清空废纸篓", "trash", "废纸篓", "垃圾桶", "回收站"]
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .lock:        return "lock.fill"
        case .hideAll:     return "eye.slash.fill"
        case .hideOthers:  return "macwindow.on.rectangle"
        case .quitAll:     return "xmark.circle.fill"
        case .displayOff:  return "display"
        case .sleep:       return "moon.fill"
        case .screenSaver: return "sparkles"
        case .restart:     return "arrow.clockwise.circle.fill"
        case .shutDown:    return "power"
        case .logOut:      return "rectangle.portrait.and.arrow.right"
        case .darkMode:    return "circle.lefthalf.filled"
        case .mute:        return "speaker.slash.fill"
        case .ejectAll:    return "eject.fill"
        case .emptyTrash:  return "trash.fill"
        }
    }

    /// 搜索面板里的命令。`front` 是打开面板前在用的 App：「隐藏其他 App」留着它，没有（前台是 TabFlick 自己）就不列这一条。
    @MainActor static func commands(front: WindowTarget?) -> [AppCommand] {
        Kind.allCases.compactMap { kind in
            if kind == .hideOthers, front == nil { return nil }
            return command(kind, keep: front.map { ($0.pid, $0.name) })
        }
    }

    /// keep：「隐藏其他 App」留着的那个 App（pid、名字）。
    @MainActor static func command(_ kind: Kind, keep: (pid: pid_t, name: String)?) -> AppCommand {
        var command = AppCommand(id: id(kind), bundleID: nil, title: title(kind), keywords: keywords(kind),
                                 symbol: symbol(kind), action: action(kind, keep: keep?.pid))
        command.confirms = confirms(kind)
        if kind == .hideOthers, let keep {
            command.subtitle = L10n.t("除了 \(keep.name)", "Except \(keep.name)")
        }
        switch kind {
        case .restart, .shutDown, .logOut: command.automationTarget = "loginwindow"
        case .darkMode: command.automationTarget = L10n.t("系统事件", "System Events")
        case .emptyTrash: command.automationTarget = L10n.t("访达", "Finder")
        default: break
        }
        return command
    }

    @MainActor private static func action(_ kind: Kind, keep: pid_t?) -> AppCommand.Action {
        switch kind {
        case .lock:        return .native { AppCommands.lockScreen() }
        case .hideAll:     return .native { hideAllApps() }
        case .hideOthers:  return .native { hideApps(except: keep) }
        case .quitAll:     return .native { quitAllApps() }
        case .displayOff:  return .native { pmset("displaysleepnow") }
        case .sleep:       return .native { pmset("sleepnow") }
        case .screenSaver: return .native { startScreenSaver() }
        // 系统标准的「重启 / 关机 / 退出登录」事件（和苹果菜单里那三项一样，没保存的 App 会照常问）。
        // 不带「要不要重启」的那个系统确认框：面板里已经回车两次、菜单里已经弹过框了
        case .restart:     return loginWindow("rest")
        case .shutDown:    return loginWindow("shut")
        case .logOut:      return loginWindow("rlgo")
        case .darkMode:
            // 外观一变整个屏幕都变，不用再弹提示
            return .appleScript(["tell application id \"com.apple.systemevents\"",
                                 "tell appearance preferences",
                                 "set dark mode to not dark mode",
                                 "end tell",
                                 "end tell"],
                                report: { _ in nil })
        case .mute:
            // Standard Additions 在 osascript 自己进程里跑，不用「自动化」授权。有的输出设备（HDMI）没有静音，
            // 读到 missing value 时脚本报错，toast 照实说没能执行
            return .appleScript(["set wasMuted to output muted of (get volume settings)",
                                 "set volume output muted (not wasMuted)",
                                 "return (not wasMuted) as text"],
                                report: { output in
                                    output == "true" ? (L10n.t("已静音", "Muted"), .success)
                                                     : (L10n.t("已取消静音", "Unmuted"), .success)
                                })
        case .ejectAll:    return .native { ejectAllDisks() }
        case .emptyTrash:
            return .appleScript(["tell application id \"com.apple.finder\"",
                                 "set n to count items of trash",
                                 "if n is 0 then return \"0\"",
                                 "empty trash",
                                 "return n as text",
                                 "end tell"],
                                report: { output in
                                    output == "0" ? (L10n.t("废纸篓是空的", "The Trash is empty"), .info)
                                                  : (L10n.t("已清空废纸篓", "Emptied the Trash"), .success)
                                })
        }
    }

    private static func loginWindow(_ event: String) -> AppCommand.Action {
        .appleScript(["tell application \"loginwindow\" to «event aevt\(event)»"], report: { _ in nil })
    }

    // MARK: - 做

    /// 隐藏其他 App（同 ⌥⌘H）：keep 是前台那个，它一直在前台，藏别的不会引起系统换前台，一次藏完就行。
    /// TabFlick 自己、菜单栏工具（不是 regular）不动。窗口自己会动，成功不弹提示。
    ///
    /// `hide()` 是异步的，**返回 false 也照样会藏**（2026-11-25 实测：藏「计算器」回 false，0.8 秒后已藏好），
    /// 别拿返回值数「藏了几个」。
    @MainActor static func hideApps(except keep: pid_t?) {
        let targets = regularApps().filter { $0.processIdentifier != keep && !$0.isHidden }
        targets.forEach { $0.hide() }
        log("🖥 hide other apps (keep \(keep.map(String.init) ?? "none")) → requested \(targets.count)")
    }

    /// 隐藏所有窗口，只剩桌面（2026-11-25 用户报的两轮「藏了又打开」，日志定的）。
    ///
    /// 系统不让前台停在一个藏着的 App 上：藏掉前台 App，它就自己激活另一个；所有 App 都藏了就激活访达；
    /// 访达在前台时再藏访达，它就激活最近用过的那个 App —— 而**激活一个藏着的 App 会把它连窗口一起显示回来**。
    /// 第一版一次全藏（含访达），访达带着窗口回来；第二版最后藏访达，Muxy（刚才在用的）被激活回来。
    /// 所以访达不藏，留在前台当「桌面」，它自己的窗口缩进程序坞：
    /// ① 先藏既不在前台、也不是访达的；② 它们藏好了再藏前台那个，系统把前台交给访达；
    /// ③ 访达到了前台，把它的窗口最小化（辅助功能，本来就有这个权限）。每步最多等一会儿（全屏的 App 藏不掉），到时间照样往下走。
    @MainActor static func hideAllApps() {
        let apps = regularApps()
        let finder = apps.first { $0.bundleIdentifier == finderID }
        let front = NSWorkspace.shared.frontmostApplication
            .flatMap { app in apps.first { $0.processIdentifier == app.processIdentifier } }
        let others = apps.filter {
            $0.processIdentifier != finder?.processIdentifier && $0.processIdentifier != front?.processIdentifier && !$0.isHidden
        }
        others.forEach { $0.hide() }
        let started = Date()
        waitUntil(timeout: 1.0, { others.allSatisfy { $0.isHidden || $0.isTerminated } }) {
            if let front, front.processIdentifier != finder?.processIdentifier { front.hide() }
            waitUntil(timeout: 1.5, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID }) {
                let finderFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID
                let hiddenCount = others.count + (front == nil || front?.processIdentifier == finder?.processIdentifier ? 0 : 1)
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                guard let finder else {
                    log("🖥 hide all → \(hiddenCount) app(s), no Finder, after \(elapsed)ms")
                    watchAfterHideAll()
                    return
                }
                minimizeWindows(of: finder.processIdentifier) { minimized in
                    log("🖥 hide all → \(hiddenCount) app(s), finder front \(finderFront), "
                        + "minimized \(minimized) Finder window(s), after \(elapsed)ms")
                    watchAfterHideAll()
                }
            }
        }
    }

    /// 把一个 App 的普通窗口都最小化（辅助功能，后台队列；每个调用 1 秒超时，访达卡住不拖主线程）。
    @MainActor private static func minimizeWindows(of pid: pid_t, done: @escaping @MainActor (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            var value: CFTypeRef?
            var minimized = 0
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for window in windows {
                    AXUIElementSetMessagingTimeout(window, 1)
                    var subrole: CFTypeRef?
                    var isMinimized: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimized)
                    // 只动普通窗口：桌面、面板、对话框不碰
                    guard (subrole as? String) == (kAXStandardWindowSubrole as String),
                          (isMinimized as? Bool) != true else { continue }
                    if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                        minimized += 1
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(minimized) } }
        }
    }

    /// 藏完之后 3 秒里谁又被激活、显示回来了，记日志（「藏了又打开」再出现时直接看是谁）。
    @MainActor private static func watchAfterHideAll() {
        let center = NSWorkspace.shared.notificationCenter
        let tokens = [NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let what = name == NSWorkspace.didUnhideApplicationNotification ? "unhide" : "activate"
                log("🖥 after hide all: \(what) \(app?.bundleIdentifier ?? "?")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { tokens.forEach(center.removeObserver) }
    }

    private static let finderID = "com.apple.finder"

    /// 普通 App（有 Dock 图标的），TabFlick 自己不算。
    @MainActor private static func regularApps() -> [NSRunningApplication] {
        let own = getpid()
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated
        }
    }

    /// 每 50ms 看一次条件，成立或到时间就接着做（在主线程上，不卡）。
    @MainActor private static func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool,
                                             then next: @escaping @MainActor () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() >= deadline { next(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
        }
        poll()
    }

    /// 一个个正常退出（同 ⌘Q，有没存的文档它自己会问）。访达、TabFlick、菜单栏工具不动。
    /// 5 秒后看还有谁没退，照实说（提前说「已退出」是撒谎）。
    @MainActor static func quitAllApps() {
        let own = getpid()
        let targets = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated
                && $0.bundleIdentifier != finderID
        }
        guard !targets.isEmpty else {
            Toast.show(L10n.t("没有要退出的 App", "No apps to quit"), kind: .info)
            return
        }
        for app in targets { _ = ProcessEnder.quit(app, force: false) }
        log("🖥 quit all apps → \(targets.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let left = targets.filter { !$0.isTerminated }
                if left.isEmpty {
                    Toast.show(L10n.t("已退出所有 App", "All apps have quit"))
                    return
                }
                let names = left.compactMap(\.localizedName).joined(separator: L10n.listSeparator)
                Toast.show(L10n.t("还有 App 没退出", "Some apps are still running"),
                           detail: L10n.t("\(names)。可能在等你保存文档。",
                                          "\(names). They may be waiting for you to save documents."),
                           kind: .info)
            }
        }
    }

    /// `pmset sleepnow` / `displaysleepnow`：不用 root。动一下鼠标、按个键就醒。
    @MainActor static func pmset(_ verb: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = [verb]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                log("🖥 pmset \(verb) → exit \(process.terminationStatus)")
            } catch {
                log("🖥 pmset \(verb) failed: \(error)")
            }
        }
    }

    @MainActor static func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            log("🖥 screen saver failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                Toast.show(L10n.t("没能开始屏幕保护程序", "Couldn't start the screen saver"), kind: .failure)
            }
        }
    }

    /// 推出能推出的卷宗：U 盘、移动硬盘、挂着的 DMG、网络共享（同访达侧栏里的 ⏏）。启动盘、内置盘不动。
    /// `unmountAndEjectDevice` 是同步的，盘在忙时要等几秒，放后台。
    @MainActor static func ejectAllDisks() {
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = ejectableVolumes()
            var ejected: [String] = []
            var failed: [String] = []
            for volume in volumes {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                    ejected.append(volume.name)
                } catch {
                    log("🖥 eject failed: \(error.localizedDescription)")
                    failed.append(volume.name)
                }
            }
            log("🖥 eject all → ejected \(ejected.count), failed \(failed.count)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if volumes.isEmpty {
                        Toast.show(L10n.t("没有可以推出的磁盘", "No disks to eject"), kind: .info)
                    } else if failed.isEmpty {
                        Toast.show(L10n.t("已推出所有磁盘", "Ejected all disks"),
                                   detail: ejected.joined(separator: L10n.listSeparator))
                    } else {
                        Toast.show(L10n.t("没能推出「\(failed.joined(separator: L10n.listSeparator))」",
                                          "Couldn't eject \(failed.joined(separator: L10n.listSeparator))"),
                                   detail: L10n.t("可能有 App 正在用它。", "An app may be using it."), kind: .failure)
                    }
                }
            }
        }
    }

    /// 能推出的卷宗：可推出、可移除、或者不在本机（网络共享）的；启动盘不算。
    /// **只看访达里看得见的（browsable）**：隐藏的卷里有 autofs 的 `/System/Volumes/Data/home`（不在本机）、
    /// iOS App 的只读挂载，按「不在本机」那条会被误选（2026-11-25 实测）。
    nonisolated static func ejectableVolumes() -> [(url: URL, name: String)] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeLocalizedNameKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, url.path != "/", values.volumeIsBrowsable == true,
                  values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false
            else { return nil }
            return (url, values.volumeLocalizedName ?? url.lastPathComponent)
        }
    }

    /// 菜单栏里没有「再按一次回车」，弹框确认（同「结束进程」的菜单）。返回 true = 确认了。
    @MainActor static func confirmFromMenu(_ kind: Kind) -> Bool {
        let alert = NSAlert()
        let button: String
        switch kind {
        case .quitAll:
            alert.messageText = L10n.t("退出所有 App？", "Quit all apps?")
            alert.informativeText = L10n.t("没保存的文档会先问你。访达和菜单栏工具不退。",
                                           "Apps with unsaved documents ask first. Finder and menu bar tools keep running.")
            button = L10n.t("全部退出", "Quit All")
        case .restart:
            alert.messageText = L10n.t("现在重新启动？", "Restart now?")
            alert.informativeText = L10n.t("没保存的文档会先问你。", "Apps with unsaved documents ask first.")
            button = L10n.t("重新启动", "Restart")
        case .shutDown:
            alert.messageText = L10n.t("现在关机？", "Shut down now?")
            alert.informativeText = L10n.t("没保存的文档会先问你。", "Apps with unsaved documents ask first.")
            button = L10n.t("关机", "Shut Down")
        case .logOut:
            alert.messageText = L10n.t("现在退出登录？", "Log out now?")
            alert.informativeText = L10n.t("没保存的文档会先问你。", "Apps with unsaved documents ask first.")
            button = L10n.t("退出登录", "Log Out")
        case .emptyTrash:
            alert.messageText = L10n.t("清空废纸篓？", "Empty the Trash?")
            alert.informativeText = L10n.t("废纸篓里的东西会永久删除，不能撤销。",
                                           "Items in the Trash are deleted permanently. This can't be undone.")
            button = L10n.t("清空", "Empty")
        default:
            return true
        }
        let confirm = alert.addButton(withTitle: button)
        confirm.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        // 状态栏 App 不抢激活，弹框要显式激活；关了框把前台还回去
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        return response == .alertFirstButtonReturn
    }
}

// MARK: - 插件

@MainActor
final class SystemControlPlugin: Plugin {
    let id = "systemControl"
    var title: String { L10n.t("系统控制", "System Control") }
    var summary: String {
        L10n.t("锁屏、睡眠、重启、关机、隐藏所有窗口、切换深色模式、推出磁盘、清空废纸篓等。退出所有 App、重启、关机这类要按两次回车。",
               "Lock, sleep, restart, shut down, hide all windows, toggle dark mode, eject disks, empty the Trash and more. Quitting all apps, restarting and the like need ↩ twice.")
    }
    let symbol = "power"
    var tint: Color { .teal }
    var icon: NSImage? { BuiltinPluginIcons.systemControl }
    let origin = PluginOrigin.builtin

    var panelCommands: [PluginCommandInfo] {
        SystemControl.Kind.allCases.map {
            PluginCommandInfo(id: SystemControl.id($0), title: SystemControl.title($0), symbol: SystemControl.symbol($0))
        }
    }

    func commands(_ context: PluginContext) -> [AppCommand] { SystemControl.commands(front: context.windowTarget) }

    let systemMenu = SystemControlMenu()
    var menu: PluginMenu? { systemMenu }
}

/// 状态栏里「系统控制 ▸」：全部命令按用途分几组。内容是固定的，不用等。
@MainActor
final class SystemControlMenu: PluginMenu {
    var snapshot: [PluginMenuRow]? { rows() }

    func refresh(_ done: @escaping @MainActor ([PluginMenuRow]) -> Void) { done(rows()) }

    private func rows() -> [PluginMenuRow] {
        let groups: [[SystemControl.Kind]] = [
            [.lock, .displayOff, .screenSaver, .sleep],
            [.hideAll, .hideOthers, .quitAll],
            [.darkMode, .mute, .ejectAll, .emptyTrash],
            [.restart, .shutDown, .logOut],
        ]
        var rows: [PluginMenuRow] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { rows.append(.separator) }
            for kind in group {
                rows.append(.item(PluginMenuItem(
                    title: SystemControl.title(kind) + (SystemControl.confirms(kind) ? "…" : ""),
                    symbol: SystemControl.symbol(kind),
                    action: { Self.run(kind) })))
            }
        }
        return rows
    }

    /// 菜单打开时 TabFlick 不抢前台，「隐藏其他 App」留的就是此刻的前台 App。
    private static func run(_ kind: SystemControl.Kind) {
        guard !SystemControl.confirms(kind) || SystemControl.confirmFromMenu(kind) else { return }
        let front = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == getpid() ? nil : ($0.processIdentifier, $0.localizedName ?? "") }
        if kind == .hideOthers, front == nil { return }
        log("🖥 system control from menu → \(kind.rawValue)")
        AppCommands.run(SystemControl.command(kind, keep: front), appName: nil)
    }
}
