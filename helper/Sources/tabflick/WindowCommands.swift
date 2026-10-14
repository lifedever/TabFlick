import AppKit

/// 搜索面板里的窗口命令（2026-10-14 用户要的，照 Raycast 的 Window Management 挑了常用的 8 条）。
///
/// 对的是**打开面板那一刻的前台 App** 的焦点窗口：面板是 nonactivating 的，打开它不会把前台换成
/// TabFlick，所以要动哪个窗口就是前台 App 的 `kAXFocusedWindow`，不用猜。走 AX 直接设位置和尺寸
/// （辅助功能权限是键盘钩子的前提，本来就有）；不去点各 App 的「窗口 → 移动与调整大小」菜单：
/// 菜单名跟着系统语言变，Electron 这类 App 还不一定有。
///
/// 和锁屏一样是系统命令：只在有输入且命中时出现，列在「应用」段末尾；二级（⌘↩）里没有。
enum WindowAction: String, CaseIterable {
    case center, maximize, leftHalf, rightHalf, restore, nextDisplay, minimize, fullScreen

    var title: String {
        switch self {
        case .center:      return L10n.t("居中", "Center")
        case .maximize:    return L10n.t("最大化", "Maximize")
        case .leftHalf:    return L10n.t("左半屏", "Left Half")
        case .rightHalf:   return L10n.t("右半屏", "Right Half")
        case .restore:     return L10n.t("恢复原位", "Restore")
        case .nextDisplay: return L10n.t("移到下一个显示器", "Move to Next Display")
        case .minimize:    return L10n.t("最小化", "Minimize")
        case .fullScreen:  return L10n.t("切换全屏", "Toggle Full Screen")
        }
    }

    /// 另一种语言的名字和别名：界面是什么语言都要能用中英文搜到（同 `AppCommand.keywords`）。
    /// 标题的拼音面板自己会认，这里只补标题里没有的说法。
    var keywords: [String] {
        switch self {
        case .center:      return ["Center", "居中", "centre", "middle", "中间"]
        // macOS 自己的「移动与调整大小」里叫「填充」
        case .maximize:    return ["Maximize", "最大化", "fill", "填充", "铺满"]
        case .leftHalf:    return ["Left Half", "左半屏", "left", "左半", "左边"]
        case .rightHalf:   return ["Right Half", "右半屏", "right", "右半", "右边"]
        case .restore:     return ["Restore", "恢复原位", "恢复", "还原", "huanyuan"]
        case .nextDisplay: return ["Move to Next Display", "移到下一个显示器", "display", "screen", "monitor",
                                   "显示器", "屏幕", "xianshiqi"]
        case .minimize:    return ["Minimize", "最小化"]
        case .fullScreen:  return ["Toggle Full Screen", "切换全屏", "fullscreen", "全屏", "quanping"]
        }
    }

    var symbol: String {
        switch self {
        case .center:      return "rectangle.center.inset.filled"
        case .maximize:    return "rectangle.inset.filled"
        case .leftHalf:    return "rectangle.lefthalf.inset.filled"
        case .rightHalf:   return "rectangle.righthalf.inset.filled"
        case .restore:     return "arrow.uturn.backward"
        case .nextDisplay: return "display.2"
        case .minimize:    return "minus.rectangle"
        case .fullScreen:  return "arrow.up.left.and.arrow.down.right"
        }
    }

    var placement: WindowLayout.Placement? {
        switch self {
        case .center:    return .center
        case .maximize:  return .maximize
        case .leftHalf:  return .leftHalf
        case .rightHalf: return .rightHalf
        default:         return nil
        }
    }
}

/// 面板打开那一刻的前台 App（窗口命令的对象）。
struct WindowTarget {
    let pid: pid_t
    let name: String
    /// 这个 App 有调整过、还能恢复的窗口：没有就不列「恢复原位」
    let canRestore: Bool
    /// 接了几块显示器：只有一块时不列「移到下一个显示器」
    let displayCount: Int

    /// 前台是 TabFlick 自己（设置窗口开着）时 nil：AX 回头问自己的进程会卡在主线程上。
    @MainActor static func front() -> WindowTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
        return WindowTarget(pid: app.processIdentifier, name: name,
                            canRestore: WindowMover.canRestore(pid: app.processIdentifier),
                            displayCount: NSScreen.screens.count)
    }
}

enum WindowCommands {
    /// 这一轮面板里能用的窗口命令。前台没有可动的 App 时一条都没有。
    @MainActor static func commands(for target: WindowTarget?) -> [AppCommand] {
        guard let target else { return [] }
        let subtitle = L10n.t("窗口", "Window") + " · " + target.name
        return WindowAction.allCases.compactMap { action in
            if action == .restore && !target.canRestore { return nil }
            if action == .nextDisplay && target.displayCount < 2 { return nil }
            return AppCommand(id: "window." + action.rawValue, bundleID: nil,
                              title: action.title, keywords: action.keywords,
                              symbol: action.symbol, subtitle: subtitle,
                              action: .window(action, target))
        }
    }
}

/// 用 AX 挪窗口。AX 调用全在后台串行队列上（App 卡住时最多等 1 秒，不拖面板和键盘钩子），
/// 结果回主线程只在有话要说时给 toast —— 挪成功了窗口自己会动，再弹一句是重复。
enum WindowMover {
    private static let queue = DispatchQueue(label: "tabflick.window-mover", qos: .userInitiated)

    /// 「恢复原位」的账：每个调整过的窗口记它被我们第一次挪之前在哪、最后一次被我们摆在哪。
    /// 只存内存（重启就忘），最多 30 个窗口。窗口身份用 AXUIElement 的 CFEqual。
    private struct Saved {
        let window: AXUIElement
        let pid: pid_t
        var original: CGRect
        var applied: CGRect
    }
    nonisolated(unsafe) private static var saved: [Saved] = []
    private static let lock = NSLock()
    private static let savedLimit = 30

    private enum Outcome {
        case done, noWindow, fullScreen, nothingToRestore, singleDisplay, cannotFullScreen, failed(AXError)
    }

    static func canRestore(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return saved.contains { $0.pid == pid }
    }

    @MainActor static func perform(_ action: WindowAction, on target: WindowTarget) {
        let screens = axVisibleFrames()
        let pid = target.pid
        let name = target.name
        queue.async {
            let outcome = apply(action, pid: pid, screens: screens)
            log("🪟 \(action.rawValue) → \(outcome)")
            Task { @MainActor in report(outcome, appName: name) }
        }
    }

    @MainActor private static func report(_ outcome: Outcome, appName: String) {
        switch outcome {
        case .done:
            return
        case .noWindow:
            Toast.show(L10n.t("没有可调整的窗口", "No window to move"), detail: appName, kind: .info)
        case .fullScreen:
            Toast.show(L10n.t("全屏的窗口没法调整", "Full-screen windows can't be moved"), detail: appName, kind: .info)
        case .nothingToRestore:
            Toast.show(L10n.t("这个窗口没调整过", "This window hasn't been moved"), detail: appName, kind: .info)
        case .singleDisplay:
            Toast.show(L10n.t("只接了一个显示器", "Only one display is connected"), kind: .info)
        case .cannotFullScreen:
            Toast.show(L10n.t("这个窗口不能全屏", "This window can't go full screen"), detail: appName, kind: .info)
        case .failed:
            Toast.show(L10n.t("没能调整窗口", "Couldn't move the window"), detail: appName, kind: .failure)
        }
    }

    /// 各块屏幕去掉菜单栏和程序坞之后的区域，换算到 AX 坐标（主屏左上角原点、y 向下）。
    @MainActor private static func axVisibleFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first?.frame else { return [] }
        return NSScreen.screens.map { screen in
            let f = screen.visibleFrame
            return CGRect(x: f.minX, y: primary.maxY - f.maxY, width: f.width, height: f.height)
        }
    }

    private static func apply(_ action: WindowAction, pid: pid_t, screens: [CGRect]) -> Outcome {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        else { return .noWindow }
        // 超时不会从 App 元素传到窗口元素上，得各设各的（读菜单那轮踩过）
        AXUIElementSetMessagingTimeout(window, 1)
        let isFullScreen = bool(window, "AXFullScreen") == true

        switch action {
        case .minimize:
            let error = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return error == .success ? .done : .failed(error)
        case .fullScreen:
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success,
                  settable.boolValue else { return .cannotFullScreen }
            let error = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString,
                                                     isFullScreen ? kCFBooleanFalse : kCFBooleanTrue)
            return error == .success ? .done : .failed(error)
        default:
            break
        }

        // 全屏的窗口自己占一个桌面，设位置不报错也不动
        guard !isFullScreen else { return .fullScreen }
        guard let current = frame(of: window), let screen = WindowLayout.screenIndex(of: current, in: screens)
        else { return .failed(.cannotComplete) }

        let goal: CGRect
        if action == .restore {
            guard let original = saved(of: window)?.original else { return .nothingToRestore }
            goal = original
        } else if action == .nextDisplay {
            guard screens.count > 1 else { return .singleDisplay }
            let next = WindowLayout.nextScreenIndex(after: screen, in: screens)
            goal = WindowLayout.moved(current, from: screens[screen], to: screens[next])
        } else if let placement = action.placement {
            var basis = current
            if placement == .center {
                let entry = saved(of: window)
                basis.size = WindowLayout.centerSize(current: current, original: entry?.original, applied: entry?.applied)
            }
            goal = WindowLayout.frame(placement, window: basis, visible: screens[screen])
        } else {
            return .done
        }

        if let error = setFrame(goal, of: window, app: app) { return .failed(error) }
        let landed = frame(of: window) ?? goal
        if action == .restore {
            forget(window)
        } else {
            remember(window, pid: pid, before: current, after: landed)
        }
        return .done
    }

    /// 设位置和尺寸。顺序照 Rectangle：先尺寸、再位置、再尺寸 —— 跨屏时新尺寸可能被旧屏幕卡住，
    /// 挪过去之后再设一次才对。只要位置和尺寸有一样设成了就算成功（固定尺寸的窗口只能挪）。
    private static func setFrame(_ goal: CGRect, of window: AXUIElement, app: AXUIElement) -> AXError? {
        // 开着这个标记的 App（给读屏用的「增强界面」），用 AX 改尺寸会带动画、落点也不准：
        // 改之前临时关掉，改完还原（Rectangle 的做法）
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        var size = goal.size
        var origin = goal.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin)
        else { return .failure }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return moved == .success || resized == .success ? nil : moved
    }

    // MARK: 恢复原位的账

    /// 挪之前的位置。用户在两次命令之间自己挪过（现在的位置不是我们上次摆的），就从现在这里重新记起。
    private static func remember(_ window: AXUIElement, pid: pid_t, before: CGRect, after: CGRect) {
        lock.lock(); defer { lock.unlock() }
        if let index = saved.firstIndex(where: { CFEqual($0.window, window) }) {
            var entry = saved.remove(at: index)
            if !WindowLayout.same(entry.applied, before) { entry.original = before }
            entry.applied = after
            saved.append(entry)
        } else {
            saved.append(Saved(window: window, pid: pid, original: before, applied: after))
        }
        if saved.count > savedLimit { saved.removeFirst(saved.count - savedLimit) }
    }

    private static func saved(of window: AXUIElement) -> (original: CGRect, applied: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        return saved.first { CFEqual($0.window, window) }.map { ($0.original, $0.applied) }
    }

    private static func forget(_ window: AXUIElement) {
        lock.lock(); defer { lock.unlock() }
        saved.removeAll { CFEqual($0.window, window) }
    }

    // MARK: AX 取值

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
