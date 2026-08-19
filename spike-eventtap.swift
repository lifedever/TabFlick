#!/usr/bin/env swift
//
//  spike-eventtap.swift
//
//  可行性验证：CGEventTap 能否稳定拦下 Chrome 的 Ctrl+Tab 并吞掉，
//  以及能否拿到 Ctrl 键的释放时机（Arc 式切换器的核心时序）。
//
//  跑法：  swift spike-eventtap.swift
//  停止：  Ctrl+C
//

import Cocoa
import Carbon.HIToolbox

// MARK: - 全局状态
// CGEventTap 的回调是 C 函数指针，无法捕获 Swift 上下文，状态只能放全局。

private let kChromeBundleID = "com.google.Chrome"

/// 前台是否为 Chrome。由 NSWorkspace 通知在主线程维护，回调里只读。
/// 不在回调里直接查 frontmostApplication —— 那是跨进程调用，会拖慢 tap 回调
/// 进而触发系统的 tapDisabledByTimeout。
private var gFrontIsChrome = false

private var gCycling = false
private var gCycleSteps = 0
private var gTap: CFMachPort?

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private func log(_ msg: String) {
    print("[\(logFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

// MARK: - Event tap 回调

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let reason = (type == .tapDisabledByTimeout) ? "回调超时" : "用户输入"
        log("⚠️  event tap 被系统禁用（\(reason)）→ 重新启用")
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil

    case .keyDown:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // Tab 是非字符键，kVK_Tab 在所有键盘布局下都是同一个物理键位，
        // 这里用 Carbon 常量而非裸数字。
        guard code == Int64(kVK_Tab),
              flags.contains(.maskControl),
              gFrontIsChrome else { break }

        let backward = flags.contains(.maskShift)
        gCycling = true
        gCycleSteps += 1
        log("⌃\(backward ? "⇧" : "")⇥  已拦截并吞掉  ← 第 \(gCycleSteps) 步（\(backward ? "反向" : "正向")）")
        return nil   // 吞掉：Chrome 收不到这个事件

    case .flagsChanged:
        if gCycling && !event.flags.contains(.maskControl) {
            log("⌃ 释放 → 此刻提交切换（本轮 \(gCycleSteps) 步）")
            print("")
            gCycling = false
            gCycleSteps = 0
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 启动

// CGEventTap 以 .defaultTap 模式修改/吞掉键盘事件，需要「辅助功能」权限。
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOptions) else {
    print("""
    ❌ 缺少「辅助功能」权限。

    刚才应该弹了授权窗口。请到：
      系统设置 → 隐私与安全性 → 辅助功能
    把你运行这个脚本的终端 App 打开，然后重新运行。
    """)
    exit(1)
}

let eventMask = (1 << CGEventType.keyDown.rawValue)
              | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: CGEventMask(eventMask),
                                  callback: tapCallback,
                                  userInfo: nil) else {
    print("""
    ❌ CGEvent.tapCreate 失败。

    通常还是权限问题。macOS 15+ 有时除了「辅助功能」还要：
      系统设置 → 隐私与安全性 → 输入监控
    也把终端 App 打开。改完权限后终端要完全退出重开才生效。
    """)
    exit(1)
}
gTap = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// 前台 App 跟踪：用 bundle identifier，不用 localizedName（后者是本地化字符串）
let workspace = NSWorkspace.shared
gFrontIsChrome = workspace.frontmostApplication?.bundleIdentifier == kChromeBundleID
workspace.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    let bid = app?.bundleIdentifier ?? "(unknown)"
    gFrontIsChrome = (bid == kChromeBundleID)
    log("前台 → \(bid)\(gFrontIsChrome ? "   ✅ 开始拦截" : "   （放行）")")
}

print("""

╭──────────────────────────────────────────────────────────╮
│  TabFlick — CGEventTap 可行性验证                        │
╰──────────────────────────────────────────────────────────╯

当前前台：\(workspace.frontmostApplication?.bundleIdentifier ?? "?")\(gFrontIsChrome ? "  ✅" : "")

请按顺序测这 4 项：

  1. 打开 Chrome，开 3~4 个标签页
  2. 按住 Ctrl 连点 Tab 三下，再松开 Ctrl
       期望：日志出现 3 行「已拦截并吞掉」+ 1 行「⌃ 释放」
       期望：Chrome 的标签页【完全没有切换】← 这条最关键
  3. 试 Ctrl+Shift+Tab
       期望：日志标记「反向」
  4. 切到别的 App（比如 Finder）再按 Ctrl+Tab
       期望：日志只有「前台 →」，没有拦截（放行给别的 App）

留意有没有「⚠️ event tap 被系统禁用」——偶发一次正常，
频繁出现说明回调太慢，正式版要再优化。

Ctrl+C 退出。
──────────────────────────────────────────────────────────

""")
fflush(stdout)

CFRunLoopRun()
