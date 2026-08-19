#!/usr/bin/env swift
//
// 浮层生命周期探针。
//
// 每 200ms 扫一次窗口服务器，记录 TabFlick 名下所有窗口的位置/透明度/层级，
// 以及当前前台应用。用来回答「浮层到底是没出现、飞出屏幕，还是出现后被隐藏」。
//
// 用法：swift scripts/probe-panel.swift  然后在 15 秒内点「前往授权」
// 输出：/tmp/tabflick-panel-probe.log
//

import Cocoa

let logPath = "/tmp/tabflick-panel-probe.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let handle = FileHandle(forWritingAtPath: logPath)!

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss.SSS"

func emit(_ line: String) {
    let stamped = "[\(formatter.string(from: Date()))] \(line)"
    print(stamped)
    handle.write(Data((stamped + "\n").utf8))
}

let screen = NSScreen.main?.frame ?? .zero
let visible = NSScreen.main?.visibleFrame ?? .zero
emit("screen frame=\(screen)  visibleFrame=\(visible)")
emit("开始扫描，请在 15 秒内点击「前往授权」…")

var lastSignature = ""
var ticks = 0

let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
    ticks += 1

    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return
    }

    // 窗口服务器视角：只有真正在屏的窗口会出现在这个列表里。
    // 一个窗口 orderOut 之后会直接从列表消失 —— 这正是我们要区分的关键。
    var rows: [String] = []
    for entry in list {
        guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == "TabFlick" else { continue }
        let name = (entry[kCGWindowName as String] as? String) ?? ""
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -999
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
        guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
        rows.append(String(
            format: "    win name=%@ layer=%d alpha=%.2f bounds=(%.0f,%.0f %.0fx%.0f)",
            name.isEmpty ? "<无标题>" : name, layer, alpha,
            bounds.minX, bounds.minY, bounds.width, bounds.height
        ))
    }

    // 只在状态变化时输出，避免刷屏
    let signature = frontmost + "|" + rows.joined()
    if signature != lastSignature {
        emit("frontmost=\(frontmost)  TabFlick 窗口数=\(rows.count)")
        rows.forEach { emit($0) }
        lastSignature = signature
    }

    if ticks >= 75 {   // 15 秒
        emit("扫描结束")
        timer.invalidate()
        handle.closeFile()
        exit(0)
    }
}

RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
