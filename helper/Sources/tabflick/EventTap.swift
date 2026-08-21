import Cocoa
import Carbon.HIToolbox

// MARK: - 回调用的文件级状态
//
// CGEventTap 的回调是 C 函数指针，无法捕获 Swift 上下文，状态只能放文件级。
// 回调本身也必须写成文件级函数、而不是某个 @MainActor 类型里的闭包字面量 ——
// 后者会被 Swift 推断为 MainActor 隔离，编译器在 @convention(c) thunk 里注入
// 执行器检查，在 C 事件重入时可能拿到失效的 executor 记录而崩溃
// （PasteMemo v1.7.13 踩过）。
//
// 这些变量的读写都发生在主线程：run loop source 挂在 main run loop 上，
// NSWorkspace 通知也投递到主队列。

// 支持的浏览器集合在 BrowserSupport 里定义一份，别在这儿再抄
private var gFrontIsBrowser = false

/// 前台的受支持浏览器变化时通知上层（就绪状态/菜单计数要换账本）。
private var gOnActiveBrowserChange: (() -> Void)?

func setActiveBrowserChangeHandler(_ handler: (() -> Void)?) {
    gOnActiveBrowserChange = handler
}

/// 重算「前台是不是受支持浏览器」。除了 App 切换时调用，
/// BrowserSupport.connected 变化后也必须调一次：扩展连上并识别出身份时，
/// 用户可能早已站在那个浏览器里 —— 等下一次 App 切换才生效，
/// 表现就是「第一次按没反应」。
@MainActor
func refreshFrontmostBrowserState() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let previous = ChromeWindowLocator.activeBundleID
    gFrontIsBrowser = BrowserSupport.isSupported(front)
    if gFrontIsBrowser, let front { ChromeWindowLocator.activeBundleID = front }
    if ChromeWindowLocator.activeBundleID != previous { gOnActiveBrowserChange?() }
}

/// 切换器快捷键（默认 ⌃⇥）。修饰键不含 ⇧ —— ⇧ 保留给反向切换。
private var gSwitchKeyCode: Int64 = Int64(kVK_Tab)
private var gSwitchModifiers: CGEventFlags = .maskControl

/// 全局切换器快捷键。未单独设置时与切换器键相同（见 configureGlobalHotkey）。
private var gGlobalKeyCode: Int64 = Int64(kVK_Tab)
private var gGlobalModifiers: CGEventFlags = .maskControl
/// 全局切换器是否开启（设置项，默认关）。关掉时全局键一概不参与匹配。
private var gGlobalEnabled = false

/// 修饰键归一化：剥掉 ⇧（反向语义需要它空着），剥完为空则退回 ⌃。
private func normalizedHotkeyModifiers(_ flags: CGEventFlags) -> CGEventFlags {
    let stripped = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
    return stripped.isEmpty ? .maskControl : stripped
}

/// 切换器快捷键设置变化时由主线程调用。nil = 恢复默认 ⌃⇥。
func configureSwitcherHotkey(keyCode: Int64?, flags: CGEventFlags) {
    gSwitchKeyCode = keyCode ?? Int64(kVK_Tab)
    gSwitchModifiers = normalizedHotkeyModifiers(flags)
}

/// 全局切换器快捷键设置变化时由主线程调用。
/// keyCode 传 nil = 跟随切换器键（此时两者同键，浏览器前台归当前浏览器切换器）。
/// 必须在 configureSwitcherHotkey 之后调用 —— 跟随分支要读它的结果。
func configureGlobalHotkey(keyCode: Int64?, flags: CGEventFlags, enabled: Bool) {
    gGlobalEnabled = enabled
    if let keyCode {
        gGlobalKeyCode = keyCode
        gGlobalModifiers = normalizedHotkeyModifiers(flags)
    } else {
        gGlobalKeyCode = gSwitchKeyCode
        gGlobalModifiers = gSwitchModifiers
    }
}

private var gCycling = false

/// 本轮 cycling 是全局切换器（跨浏览器）还是当前浏览器切换器。
/// 起手那一下就定死，中途前台怎么变都不改 —— 内容已经拍进快照了。
private var gCyclingGlobal = false

/// 本轮 cycling 要盯的修饰键：起手那个快捷键的。
///
/// 不能固定看切换器键 —— 全局键可以是另一套修饰键（⌥⇥），
/// 用切换器的 ⌃ 去测松开时机，⌥ 松开时根本收不到提交信号。
private var gCycleModifiers: CGEventFlags = .maskControl

/// 本轮 cycling 是否为全局模式。MRUController 起手时读它决定拍哪份快照。
var eventTapCyclingIsGlobal: Bool { gCyclingGlobal }

private var gTap: CFMachPort?

/// 扩展是否已连接、且有至少两个标签页可切。
///
/// 没准备好时**不吞事件**，放行给 Chrome 用它自己的顺序切。否则 helper 崩了
/// 或扩展断了的时候，Ctrl+Tab 会被吞掉又什么都不做 —— 表现为「快捷键彻底
/// 失灵」，用户完全无从判断是哪一层坏了。宁可降级到原生行为。
private var gReady = false

/// 全局切换器的就绪状态：开关打开、有扩展连着、且所有浏览器合起来
/// 至少两个标签。与 gReady 分开算 —— 后者是「当前浏览器（可能还按窗口
/// 过滤）够不够切」，两者的分母根本不是一回事。
private var gGlobalReady = false

/// 已彻底放弃拦截（见 tapDisabledByTimeout 分支）。置位后一律放行。
private var gDisabledPermanently = false

/// 拦截被永久放弃时通知上层（用于提示用户）。
private var gOnGaveUp: (() -> Void)?

/// 运行期间辅助功能权限被撤销。
private var gOnPermissionLost: (() -> Void)?

/// 由 MRUController 在连接状态或标签页数量变化时调用。
func setEventTapReady(_ ready: Bool) {
    gReady = ready
}

/// 全局切换器的就绪状态，同样由 MRUController 维护。
func setEventTapGlobalReady(_ ready: Bool) {
    gGlobalReady = ready
}

/// 鼠标点选已经把这一轮切换提交掉了，清掉 tap 侧的 cycling 标志，
/// 免得用户随后松开 Ctrl 时又触发一次 commit。
func resetEventTapCycling() {
    gCycling = false
}

/// tap 侧当前是否认为正在切换中。看门狗用它判断状态是否卡住。
var eventTapIsCycling: Bool { gCycling }

/// 彻底停用键盘钩子。退出前调用 —— 进程结束时系统本来也会回收，
/// 但显式关掉能让「退出后键盘还怪怪的」这种怀疑彻底不成立。
func stopEventTap() {
    if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: false) }
    gCycling = false
    gReady = false
    gGlobalReady = false
}

/// 用户自定义的「置顶/取消置顶当前标签」快捷键。-1 = 未设置（不吞任何键）。
/// keyCode 来自用户录制而非硬编码，flags 只含 ⌘⌃⌥⇧ 四位、要求精确匹配。
private var gPinHotkeyCode: Int64 = -1
private var gPinHotkeyFlags: CGEventFlags = []
private var gOnPinHotkey: (() -> Void)?

/// 快捷键设置变化时由主线程调用（与其他文件级状态一样，读写都在主线程）。
func configurePinHotkey(keyCode: Int64?, flags: CGEventFlags, handler: (() -> Void)?) {
    gPinHotkeyCode = keyCode ?? -1
    gPinHotkeyFlags = flags
    gOnPinHotkey = handler
}

/// cycling 中按下的方向键。
///
/// 具体含义（走列表 / 跳分组 / 按行移动）由 MRUController 按**当前排布**决定 ——
/// 「哪个轴是列表、哪个轴是分组」只有它知道：纵向列表里 ↑↓ 是上一条下一条，
/// 横向卡片里 ←→ 才是。tap 只负责把方向如实报上去。
enum ArrowDirection { case left, right, up, down }

/// 按下一步。参数为 true 表示反向（Ctrl+Shift+Tab）。
private var gOnStep: ((Bool) -> Void)?
/// cycling 中的方向键。
private var gOnArrow: ((ArrowDirection) -> Void)?
/// Ctrl 松开，提交本轮切换。
private var gOnCommit: (() -> Void)?

/// 连续被系统禁用的次数，以及上一次被禁用的时刻。
///
/// 系统在回调超时时会禁用 tap。偶发一次是正常的（机器忙了一下），
/// 但短时间内反复超时说明我们这边真的有问题 —— 那种情况下继续把 tap
/// 重新挂回去，只会让一个坏掉的钩子继续横在用户的键盘和所有应用之间。
/// 宁可永久放弃这个功能，也不能把键盘拖下水。
private var gTapDisableCount = 0
private var gLastTapDisable: CFAbsoluteTime = 0
private let kMaxRapidDisables = 3
private let kRapidWindow: CFAbsoluteTime = 10

/// 这一下按键该唤出哪个切换器。
private enum SwitchMode {
    /// 当前浏览器的标签（原有行为）。
    case browser
    /// 所有已连接浏览器的标签，按浏览器分组。
    case global
}

/// 把「按了哪个键 + 前台是不是浏览器」解析成切换器模式，nil = 与我们无关，放行。
///
/// 两条规则：
///   - **不同键**：各归各的。全局键在浏览器前台也生效（想跨浏览器找标签时
///     不必先切出浏览器）；切换器键只在浏览器前台生效。
///   - **同一个键**（默认，两者都是 ⌃⇥）：浏览器在前台 → 当前浏览器切换器
///     优先；前台不是浏览器 → 全局切换器。
///
/// 注意修饰键用 `contains` 而不是相等：⇧ 要能叠上去表示反向，所以 ⌃⇥ 和
/// ⌃⇧⇥ 都算命中同一个键。这也意味着两个键的修饰键互为子集时会双命中
/// （⌃⇥ 与 ⌃⌥⇥），此时按同键规则走 —— 让「浏览器优先」成为唯一的兜底答案，
/// 比按定义顺序碰运气强。
private func resolveSwitchMode(code: Int64, flags: CGEventFlags) -> SwitchMode? {
    let hitsSwitcher = code == gSwitchKeyCode && flags.contains(gSwitchModifiers)
    let hitsGlobal = gGlobalEnabled && code == gGlobalKeyCode && flags.contains(gGlobalModifiers)

    if hitsSwitcher && hitsGlobal { return gFrontIsBrowser ? .browser : .global }
    if hitsGlobal { return .global }
    // 切换器键在非浏览器前台不属于我们 —— 放行给终端/编辑器自己的 ⌃⇥
    if hitsSwitcher { return gFrontIsBrowser ? .browser : nil }
    return nil
}

private func tabflickTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let now = CFAbsoluteTimeGetCurrent()
        gTapDisableCount = (now - gLastTapDisable) < kRapidWindow ? gTapDisableCount + 1 : 1
        gLastTapDisable = now

        guard gTapDisableCount <= kMaxRapidDisables else {
            // 自我放逐：不再重新启用。⌃⇥ 从此回落到 Chrome 原生行为，
            // 但用户的键盘绝对不会被我们卡住。
            gDisabledPermanently = true
            gCycling = false
            gOnGaveUp?()
            return nil
        }

        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil

    case .keyDown:
        // 总闸：放弃状态下一个键都不碰
        if gDisabledPermanently { break }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // 自愈：本轮的修饰键已经不在按下状态，cycling 却还挂着 —— 说明我们
        // 漏收了那次 flagsChanged（tap 被系统 timeout 禁用、按住时切走再松手、
        // 系统弹窗抢焦点，都会造成事件丢失）。这里必须清掉，否则下面的方向键
        // 分支会把网页里所有 ←/→ 一直吞掉，表现为「键盘坏了」。
        if gCycling && !flags.contains(gCycleModifiers) {
            gCycling = false
            gOnCommit?()
        }

        // 切换过程中的方向键。四个方向一律吞掉再上报，哪怕当前排布对某个
        // 方向没有动作 —— ⌃↑/⌃↓ 是系统调度中心（Mission Control）的快捷键，
        // 切换到一半整个桌面飞走，比「按了没反应」糟糕得多。
        //
        // 必须同时要求修饰键仍按着：只看 gCycling 的话，一旦状态残留就会
        // 无差别吞掉方向键，而这个标志是靠一个可能丢失的事件来清零的。
        if gCycling, flags.contains(gCycleModifiers) {
            switch code {
            case Int64(kVK_LeftArrow):  gOnArrow?(.left);  return nil
            case Int64(kVK_RightArrow): gOnArrow?(.right); return nil
            case Int64(kVK_UpArrow):    gOnArrow?(.up);    return nil
            case Int64(kVK_DownArrow):  gOnArrow?(.down);  return nil
            default: break
            }
        }

        // 用户自定义的置顶快捷键。未设置时 gPinHotkeyCode 为 -1，永不命中；
        // 只在受支持浏览器前台时吞键，其余场合原样放行。
        if gPinHotkeyCode >= 0,
           code == gPinHotkeyCode,
           gFrontIsBrowser,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == gPinHotkeyFlags {
            gOnPinHotkey?()
            return nil
        }

        // 切换器 / 全局切换器快捷键（默认都是 ⌃⇥，可在设置中各自定义）。
        // keyCode 是用户录制或 Carbon 常量，不是裸数字。加 ⇧ 表示反向。
        guard let mode = resolveSwitchMode(code: code, flags: flags) else { break }

        // 就绪判定按模式分开：没就绪时**不吞**，放行给前台应用自己处理
        // （在浏览器里就是 Chrome 原生切换，在别的应用里就是它自家的 ⌃⇥）。
        // 写成布尔而不是嵌套 switch —— 那里的 break 只跳内层 switch，
        // 未就绪反而会继续往下走。
        guard (mode == .global) ? gGlobalReady : gReady else { break }

        if !gCycling {
            gCyclingGlobal = (mode == .global)
            gCycleModifiers = (mode == .global) ? gGlobalModifiers : gSwitchModifiers
        }
        gCycling = true
        gOnStep?(flags.contains(.maskShift))
        return nil   // 吞掉，前台应用收不到

    case .flagsChanged:
        if gCycling && !event.flags.contains(gCycleModifiers) {
            gCycling = false
            gOnCommit?()
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 对外封装

enum EventTapError: Error, CustomStringConvertible {
    case accessibilityDenied
    case tapCreationFailed

    var description: String {
        switch self {
        case .accessibilityDenied:
            return L10n.t(
                """
                需要「辅助功能」权限。

                前往：系统设置 → 隐私与安全性 → 辅助功能，
                打开 TabFlick（或运行它的终端应用），然后重新启动。
                """,
                """
                Accessibility permission is required.

                Open: System Settings → Privacy & Security → Accessibility
                Enable TabFlick (or the terminal app running it), then start again.
                """
            )
        case .tapCreationFailed:
            return L10n.t(
                """
                CGEvent.tapCreate 失败。

                除了「辅助功能」，macOS 有时还要求：
                  系统设置 → 隐私与安全性 → 输入监控
                改完任一项后必须完全退出应用再打开 —— 权限只在进程启动时读取。
                """,
                """
                CGEvent.tapCreate failed.

                Besides Accessibility, macOS sometimes also requires:
                  System Settings → Privacy & Security → Input Monitoring
                After changing either, fully quit and reopen the app —
                macOS only reads these permissions at process launch.
                """
            )
        }
    }
}

/// 全局键盘钩子：Chrome 在前台时吞掉 Ctrl+Tab，并在 Ctrl 松开时发出提交信号。
@MainActor
final class EventTap {

    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?

    /// - Parameters:
    ///   - onStep: 每次按切换键。参数 true 表示反向。
    ///   - onArrow: 切换中按方向键；含义由调用方按当前排布决定。
    ///   - onCommit: 修饰键松开。
    /// - Parameters:
    ///   - onGaveUp: 钩子因反复超时被永久放弃时调用。
    ///   - onPermissionLost: 运行期间辅助功能权限被撤销时调用。
    func start(onStep: @escaping (Bool) -> Void,
               onArrow: @escaping (ArrowDirection) -> Void,
               onCommit: @escaping () -> Void,
               onGaveUp: @escaping () -> Void,
               onPermissionLost: @escaping () -> Void) throws {

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw EventTapError.accessibilityDenied
        }

        gOnStep = onStep
        gOnArrow = onArrow
        gOnCommit = onCommit
        gOnGaveUp = onGaveUp
        gOnPermissionLost = onPermissionLost

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: tabflickTapCallback,
                                          userInfo: nil) else {
            throw EventTapError.tapCreationFailed
        }
        gTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source

        startTrackingFrontmostApp()
        startPermissionWatch()
    }

    /// 盯着辅助功能权限。
    ///
    /// 用户可以在 app 运行期间直接把权限从系统设置里删掉。此时系统会禁用
    /// 这个 tap，而禁用通知的默认处理是「重新挂回去」—— 在没有权限的状态下
    /// 反复重挂，会把键盘事件流拖进异常。所以一旦发现权限没了，立刻彻底停用，
    /// 绝不试图恢复。
    private func startPermissionWatch() {
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            guard !gDisabledPermanently, !AXIsProcessTrusted() else { return }
            gDisabledPermanently = true
            stopEventTap()
            Task { @MainActor in gOnPermissionLost?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// 前台 App 用 bundle identifier 判定（BrowserSupport 集合）。
    /// 绝不能用 localizedName —— 那是本地化字符串，中文系统下 Chrome 之外的
    /// 很多 App 名字都不一样，白名单会静默 0 命中。
    private func startTrackingFrontmostApp() {
        refreshFrontmostBrowserState()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                refreshFrontmostBrowserState()
                // 从浏览器切走时若还在 cycling，丢弃这一轮，避免状态卡住。
                // 全局切换器不受这条约束 —— 它起手时前台本来就不是浏览器，
                // 按这个条件判会被自己的起手状态当场判死。
                if !gFrontIsBrowser && gCycling && !gCyclingGlobal {
                    gCycling = false
                    gOnCommit?()
                }
            }
        }
    }
}
