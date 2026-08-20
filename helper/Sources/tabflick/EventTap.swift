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

/// 切换器快捷键设置变化时由主线程调用。nil = 恢复默认 ⌃⇥。
/// flags 会剥掉 ⇧（反向语义需要它空着），剥完为空则退回 ⌃。
func configureSwitcherHotkey(keyCode: Int64?, flags: CGEventFlags) {
    gSwitchKeyCode = keyCode ?? Int64(kVK_Tab)
    let stripped = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
    gSwitchModifiers = stripped.isEmpty ? .maskControl : stripped
}
private var gCycling = false
private var gTap: CFMachPort?

/// 扩展是否已连接、且有至少两个标签页可切。
///
/// 没准备好时**不吞事件**，放行给 Chrome 用它自己的顺序切。否则 helper 崩了
/// 或扩展断了的时候，Ctrl+Tab 会被吞掉又什么都不做 —— 表现为「快捷键彻底
/// 失灵」，用户完全无从判断是哪一层坏了。宁可降级到原生行为。
private var gReady = false

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

/// 按下一步。参数为 true 表示反向（Ctrl+Shift+Tab）。
private var gOnStep: ((Bool) -> Void)?
/// 上下方向键按行移动（宫格布局用）。参数为 true 表示向上。
private var gOnRowStep: ((Bool) -> Void)?
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

        // 自愈：切换键的修饰键已经不在按下状态，cycling 却还挂着 —— 说明我们
        // 漏收了那次 flagsChanged（tap 被系统 timeout 禁用、按住时切走再松手、
        // 系统弹窗抢焦点，都会造成事件丢失）。这里必须清掉，否则下面的方向键
        // 分支会把网页里所有 ←/→ 一直吞掉，表现为「键盘坏了」。
        if gCycling && !flags.contains(gSwitchModifiers) {
            gCycling = false
            gOnCommit?()
        }

        // 切换过程中，左右方向键也移动游标。
        // 必须同时要求修饰键仍按着：只看 gCycling 的话，一旦状态残留就会
        // 无差别吞掉方向键，而这个标志是靠一个可能丢失的事件来清零的。
        if gCycling,
           flags.contains(gSwitchModifiers),
           code == Int64(kVK_LeftArrow) || code == Int64(kVK_RightArrow) {
            gOnStep?(code == Int64(kVK_LeftArrow))
            return nil
        }

        // 上下方向键：宫格布局按行移动。长条布局下没有动作，但同样要吞 ——
        // ⌃↑/⌃↓ 是系统调度中心（Mission Control）的快捷键，切换到一半
        // 整个桌面飞走，比「按了没反应」糟糕得多。
        if gCycling,
           flags.contains(gSwitchModifiers),
           code == Int64(kVK_UpArrow) || code == Int64(kVK_DownArrow) {
            gOnRowStep?(code == Int64(kVK_UpArrow))
            return nil
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

        // 切换器快捷键（默认 ⌃⇥，可在设置中自定义）。keyCode 是用户录制或
        // Carbon 常量，不是裸数字。加 ⇧ 表示反向。
        guard code == gSwitchKeyCode,
              flags.contains(gSwitchModifiers),
              gFrontIsBrowser,
              gReady else { break }

        gCycling = true
        gOnStep?(flags.contains(.maskShift))
        return nil   // 吞掉，Chrome 收不到

    case .flagsChanged:
        if gCycling && !event.flags.contains(gSwitchModifiers) {
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
    ///   - onStep: 每次 Ctrl+Tab。参数 true 表示反向。
    ///   - onRowStep: 切换中按 ⌃↑/⌃↓。参数 true 表示向上（宫格布局按行移动）。
    ///   - onCommit: Ctrl 松开。
    /// - Parameters:
    ///   - onGaveUp: 钩子因反复超时被永久放弃时调用。
    ///   - onPermissionLost: 运行期间辅助功能权限被撤销时调用。
    func start(onStep: @escaping (Bool) -> Void,
               onRowStep: @escaping (Bool) -> Void,
               onCommit: @escaping () -> Void,
               onGaveUp: @escaping () -> Void,
               onPermissionLost: @escaping () -> Void) throws {

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw EventTapError.accessibilityDenied
        }

        gOnStep = onStep
        gOnRowStep = onRowStep
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
                // 切走时若还在 cycling，丢弃这一轮，避免状态卡住
                if !gFrontIsBrowser && gCycling {
                    gCycling = false
                    gOnCommit?()
                }
            }
        }
    }
}
