import AppKit
import ApplicationServices

/// 某个 App 里一个具体的窗口，搜索面板里单独一行、回车直接跳过去（用户 2026-09-29 要的）。
/// 目前只有微信：开着的小程序、单独弹出来的聊天窗口。
struct AppWindow: Identifiable, Equatable {
    enum Kind: String {
        /// 小程序：窗口挂在微信主进程名下，里面的内容由别的进程画，读不到任何子元素
        case miniProgram
        /// 单独弹出来的聊天窗口：标题是人名或群名
        case chat
        /// 微信自己的其他窗口（设置、朋友圈）
        case other
    }

    let title: String
    let kind: Kind
    /// 行首图标：小程序用「小程序」的图标，其余用微信的
    let iconPath: String
    /// 在微信窗口列表里的前后（0 = 最前）
    let order: Int

    var id: String { "win#\(kind.rawValue)#\(title)" }

    var subtitle: String {
        switch kind {
        case .miniProgram: return L10n.t("小程序", "Mini program")
        case .chat:        return L10n.t("微信聊天", "WeChat chat")
        case .other:       return L10n.t("微信", "WeChat")
        }
    }
}

/// 读微信的窗口、跳到其中一个。
///
/// 实测（2026-09-29）：每个小程序是一个 `com.tencent.flue.WeApp` 进程，但**窗口挂在微信主进程名下**
/// （CGWindowList 的 owner、AX 的窗口列表都是微信），小程序进程自己一个窗口都没有，所以认不出哪个进程
/// 是哪个小程序，也没法按进程记各自的使用时间。区分靠窗口里有没有子元素：小程序的内容是别的进程画的，
/// AX 里一个子元素都没有；聊天窗口、主窗口至少有左上角三个按钮。微信主窗口和聊天窗口**里面的内容读不到**
/// （只有那三个按钮），所以没弹出来的聊天定位不到具体的人。
enum WeChatWindows {
    static let bundleID = "com.tencent.xinWeChat"
    static let miniProgramBundleID = "com.tencent.flue.WeApp"
    /// 不是聊天的微信窗口（标题按中英文界面各一份），第二行写「微信」而不是「微信聊天」
    private static let nonChatTitles: Set<String> = ["设置", "Settings", "朋友圈", "Moments"]

    /// 读的时候要用到的、只能在主线程取的东西；微信没开就是 nil。
    struct Target {
        let pid: pid_t
        let mainTitle: String
        let wechatPath: String
        let miniProgramPath: String?
    }

    @MainActor static func target() -> Target? {
        let running = NSWorkspace.shared.runningApplications
        guard let wechat = running.first(where: { $0.bundleIdentifier == bundleID }),
              let path = wechat.bundleURL?.path else { return nil }
        let miniPath = running.first { $0.bundleIdentifier == miniProgramBundleID }?.bundleURL?.path
        return Target(pid: wechat.processIdentifier, mainTitle: wechat.localizedName ?? "",
                      wechatPath: path, miniProgramPath: miniPath)
    }

    /// 一次读到的微信窗口。
    struct Snapshot {
        var windows: [AppWindow] = []
        /// 微信最上面那个窗口是小程序（用户最后在用的是小程序而不是主窗口 / 聊天）。
        var miniProgramOnTop = false
    }

    /// 读窗口列表。跨进程，放后台线程调；每次调用设了超时，微信卡住也只等一会儿。
    ///
    /// 小程序在系统眼里不是独立的 App（实测 2026-09-29）：点小程序窗口，切到前台的是**微信**，「小程序」
    /// 进程只在打开时到过前台一次，⌘Tab 里它的位置也不动。所以小程序的时间跟微信走；最后用的是小程序
    /// 还是主窗口，看屏幕上微信哪个窗口在最上面（CGWindowList 从前往后排，按位置大小对上 AX 里的小程序窗口）。
    nonisolated static func read(_ target: Target) -> Snapshot {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return Snapshot() }
        var result: [AppWindow] = []
        var miniFrames: [CGRect] = []
        var seen = Set<String>()   // 同名窗口只列一个：行的 id 按标题拼，重复了列表会乱
        for (order, window) in windows.enumerated() {
            AXUIElementSetMessagingTimeout(window, 0.3)
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            guard let title = (titleValue as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty, title != target.mainTitle else { continue }
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(window, kAXChildrenAttribute as CFString, &count)
            let kind: AppWindow.Kind = count == 0 ? .miniProgram : nonChatTitles.contains(title) ? .other : .chat
            let icon = kind == .miniProgram ? (target.miniProgramPath ?? target.wechatPath) : target.wechatPath
            let entry = AppWindow(title: title, kind: kind, iconPath: icon, order: order)
            guard seen.insert(entry.id).inserted else { continue }
            result.append(entry)
            if kind == .miniProgram, let frame = frame(of: window) { miniFrames.append(frame) }
        }
        return Snapshot(windows: result, miniProgramOnTop: topWindowIsMiniProgram(pid: target.pid, miniFrames: miniFrames))
    }

    private nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
        var point = CGPoint.zero, extent = CGSize.zero
        guard let pos, let size, AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// 屏幕上微信最前面那个普通窗口是不是小程序：CGWindowList 按从前往后排，取微信的第一个，
    /// 按位置大小对 AX 读到的小程序窗口（两边都是左上角原点的全局坐标）。
    private nonisolated static func topWindowIsMiniProgram(pid: pid_t, miniFrames: [CGRect]) -> Bool {
        guard !miniFrames.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            return miniFrames.contains { abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2
                && abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }
        }
        return false
    }

    /// 跳到这个窗口：先把微信切到前台，再把窗口提到最前。顺序反过来的话，激活微信时它会把主窗口重新
    /// 摆到最前、盖住刚提上来的小程序（实测）。激活是异步的，过一会儿再提一次。
    @MainActor static func raise(_ window: AppWindow) {
        guard let wechat = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return }
        wechat.activate()
        let pid = wechat.processIdentifier
        let title = window.title
        func raiseNow() {
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { return }
                for candidate in windows {
                    var titleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &titleValue)
                    guard (titleValue as? String)?.trimmingCharacters(in: .whitespaces) == title else { continue }
                    // 最小化了的先还原：光「提到最前」不会把它从程序坞里弹出来
                    AXUIElementSetAttributeValue(candidate, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(candidate, kAXMainAttribute as CFString, kCFBooleanTrue)
                    return
                }
            }
        }
        raiseNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { raiseNow() }
    }
}
