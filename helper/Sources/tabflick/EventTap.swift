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

// bundle ID 只在 ChromeWindowLocator 里定义一份，别在这儿再抄一个
private var gFrontIsChrome = false
private var gCycling = false
private var gTap: CFMachPort?

/// 扩展是否已连接、且有至少两个标签页可切。
///
/// 没准备好时**不吞事件**，放行给 Chrome 用它自己的顺序切。否则 helper 崩了
/// 或扩展断了的时候，Ctrl+Tab 会被吞掉又什么都不做 —— 表现为「快捷键彻底
/// 失灵」，用户完全无从判断是哪一层坏了。宁可降级到原生行为。
private var gReady = false

/// 由 MRUController 在连接状态或标签页数量变化时调用。
func setEventTapReady(_ ready: Bool) {
    gReady = ready
}

/// 鼠标点选已经把这一轮切换提交掉了，清掉 tap 侧的 cycling 标志，
/// 免得用户随后松开 Ctrl 时又触发一次 commit。
func resetEventTapCycling() {
    gCycling = false
}

/// 按下一步。参数为 true 表示反向（Ctrl+Shift+Tab）。
private var gOnStep: ((Bool) -> Void)?
/// Ctrl 松开，提交本轮切换。
private var gOnCommit: (() -> Void)?

private func tabflickTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // 系统在回调超时或用户输入过载时会禁用 tap，必须自己重新启用，
        // 否则从此刻起所有拦截静默失效。
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil

    case .keyDown:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // 已经在切换中时，左右方向键也移动游标。
        // 只在 gCycling 为真时拦截 —— 平时的方向键必须原样放行给网页。
        if gCycling, code == Int64(kVK_LeftArrow) || code == Int64(kVK_RightArrow) {
            gOnStep?(code == Int64(kVK_LeftArrow))
            return nil
        }

        // Tab 是非字符键，kVK_Tab 在任何键盘布局下都是同一个物理键位，
        // 用 Carbon 常量而不是裸数字。
        guard code == Int64(kVK_Tab),
              flags.contains(.maskControl),
              gFrontIsChrome,
              gReady else { break }

        gCycling = true
        gOnStep?(flags.contains(.maskShift))
        return nil   // 吞掉，Chrome 收不到

    case .flagsChanged:
        if gCycling && !event.flags.contains(.maskControl) {
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
            return """
            Accessibility permission is required.

            Open: System Settings → Privacy & Security → Accessibility
            Enable the app that runs tabflick (Terminal, iTerm, …), then run again.
            """
        case .tapCreationFailed:
            return """
            CGEvent.tapCreate failed.

            Besides Accessibility, macOS sometimes also requires:
              System Settings → Privacy & Security → Input Monitoring
            After changing either, fully quit and reopen the terminal app —
            macOS only reads these permissions at process launch.
            """
        }
    }
}

/// 全局键盘钩子：Chrome 在前台时吞掉 Ctrl+Tab，并在 Ctrl 松开时发出提交信号。
@MainActor
final class EventTap {

    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - onStep: 每次 Ctrl+Tab。参数 true 表示反向。
    ///   - onCommit: Ctrl 松开。
    func start(onStep: @escaping (Bool) -> Void,
               onCommit: @escaping () -> Void) throws {

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw EventTapError.accessibilityDenied
        }

        gOnStep = onStep
        gOnCommit = onCommit

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
    }

    /// 前台 App 用 bundle identifier 判定。
    /// 绝不能用 localizedName —— 那是本地化字符串，中文系统下 Chrome 之外的
    /// 很多 App 名字都不一样，白名单会静默 0 命中。
    private func startTrackingFrontmostApp() {
        gFrontIsChrome = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ChromeWindowLocator.bundleID

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isChrome = app?.bundleIdentifier == ChromeWindowLocator.bundleID
            gFrontIsChrome = isChrome
            // 切走时若还在 cycling，丢弃这一轮，避免状态卡住
            if !isChrome && gCycling {
                gCycling = false
                gOnCommit?()
            }
        }
    }
}
