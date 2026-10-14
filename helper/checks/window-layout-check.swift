// WindowLayout（搜索面板里的窗口命令）的校验。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/WindowLayout.swift \
//          checks/window-layout-check.swift -o /tmp/windowcheck && /tmp/windowcheck
//
// 断言写的是「摆完应该满足什么」（左右两半严丝合缝、居中两边留白一样、落在屏幕里），
// 不是把实现再抄一遍：抄一遍的话实现错了期望值跟着错。屏幕用了奇数宽度、负坐标（主屏左边、
// 上面的副屏）、带菜单栏和程序坞偏移的原点，这几样是边界上最容易差一点的。

import CoreGraphics
import Darwin

var cases = 0
var failures = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    cases += 1
    if !ok {
        failures += 1
        if failures <= 20 { print("✗ " + message()) }
    }
}

func isInteger(_ v: CGFloat) -> Bool { v == v.rounded() }

/// AX 坐标（左上原点、y 向下）下的几块屏幕可用区域
let screens: [CGRect] = [
    CGRect(x: 0, y: 25, width: 1512, height: 920),          // 主屏：菜单栏 25，程序坞在下
    CGRect(x: 1512, y: -300, width: 2560, height: 1415),    // 右边的大屏，比主屏高出一截
    CGRect(x: -1081, y: 200, width: 1081, height: 1895),    // 左边竖着的屏，奇数宽度
    CGRect(x: 70, y: 25, width: 1441, height: 945),         // 程序坞在左，奇数宽度
]

let windows: [CGRect] = [
    CGRect(x: 100, y: 100, width: 800, height: 600),
    CGRect(x: 0, y: 0, width: 5000, height: 3000),           // 比哪块屏都大
    CGRect(x: -50, y: 40, width: 333, height: 211),          // 奇数尺寸、一截在屏幕外
    CGRect(x: 1600, y: -200, width: 1200, height: 900),
]

@main
struct Check {
    static func main() {
        placements()
        screenPicking()
        nextScreen()
        movingAcrossScreens()
        centerSizing()
        print(failures == 0 ? "全部通过（\(cases) 项）" : "\(failures) 项失败（共 \(cases) 项）")
        fflush(stdout)  // fatalError 走 abort，不 flush，管道里的输出会丢
        if failures > 0 { fatalError("WindowLayout 校验未通过") }
    }

    static func placements() {
        for visible in screens {
            for window in windows {
                let tag = "screen=\(visible) window=\(window)"
                let left = WindowLayout.frame(.leftHalf, window: window, visible: visible)
                let right = WindowLayout.frame(.rightHalf, window: window, visible: visible)
                check(left.minX == visible.minX && right.maxX == visible.maxX, "左右半没贴到屏幕两边 \(tag)")
                check(left.maxX == right.minX, "左右半之间有缝或重叠：\(left.maxX) vs \(right.minX) \(tag)")
                check(abs(left.width - right.width) <= 1, "左右半宽度差超过 1 \(tag)")
                check(isInteger(left.width) && isInteger(right.width), "半屏宽度不是整数 \(tag)")
                for half in [left, right] {
                    check(half.minY == visible.minY && half.height == visible.height, "半屏没占满高度 \(tag)")
                }

                check(WindowLayout.frame(.maximize, window: window, visible: visible) == visible, "最大化不等于可用区域 \(tag)")

                let center = WindowLayout.frame(.center, window: window, visible: visible)
                check(center.width == min(window.width, visible.width)
                      && center.height == min(window.height, visible.height), "居中改了大小 \(tag)")
                check(visible.contains(center), "居中出了屏幕 \(tag) → \(center)")
                let dx = (center.minX - visible.minX) - (visible.maxX - center.maxX)
                let dy = (center.minY - visible.minY) - (visible.maxY - center.maxY)
                check(abs(dx) <= 1 && abs(dy) <= 1, "居中两边留白不一样（\(dx), \(dy)）\(tag)")
                check(isInteger(center.minX - visible.minX) && isInteger(center.minY - visible.minY),
                      "居中落在半个点上 \(tag)")
            }
        }
    }

    static func screenPicking() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let pair = [a, b]
        check(WindowLayout.screenIndex(of: CGRect(x: 1200, y: 100, width: 300, height: 300), in: pair) == 1,
              "整个在右屏的窗口没认成右屏")
        // 跨两块屏：哪边占得多算哪边（不是「第一块挨着的」）
        check(WindowLayout.screenIndex(of: CGRect(x: 900, y: 100, width: 400, height: 300), in: pair) == 1,
              "跨屏窗口没按重叠面积认（右边占 300、左边占 100）")
        check(WindowLayout.screenIndex(of: CGRect(x: 700, y: 100, width: 400, height: 300), in: pair) == 0,
              "跨屏窗口没按重叠面积认（左边占 300、右边占 100）")
        // 整个拖到屏幕外：取最近的
        check(WindowLayout.screenIndex(of: CGRect(x: 2500, y: 100, width: 100, height: 100), in: pair) == 1,
              "屏幕外的窗口没取最近那块")
        check(WindowLayout.screenIndex(of: CGRect(x: -800, y: 100, width: 100, height: 100), in: pair) == 0,
              "屏幕外的窗口没取最近那块（左边）")
        check(WindowLayout.screenIndex(of: a, in: []) == nil, "没有屏幕时应返回 nil")
    }

    static func nextScreen() {
        // 故意不按位置给，而且空间顺序不是下标顺序的轮换（三块屏的话任何摆法都是轮换或倒序，
        // 「下标 +1」可能碰巧对）：从左到右是 1、0、3、2
        let shuffled = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: -1000, y: 0, width: 1000, height: 800),
            CGRect(x: 2000, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1000, height: 800),
        ]
        for (from, to) in [(1, 0), (0, 3), (3, 2), (2, 1)] {
            check(WindowLayout.nextScreenIndex(after: from, in: shuffled) == to, "屏幕 \(from) 的下一个应是 \(to)")
        }
        // 左边对齐的（上下摆的）按从上到下
        //（三块：两块的话下一个永远是另一块，测不出方向）
        let stacked = [CGRect(x: 0, y: 900, width: 1000, height: 800), CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 0, y: 1800, width: 1000, height: 800)]
        for (from, to) in [(1, 0), (0, 2), (2, 1)] {
            check(WindowLayout.nextScreenIndex(after: from, in: stacked) == to, "上下摆的屏幕 \(from) 的下一个应是 \(to)")
        }
        // 走一圈每块都到过、回到起点
        for start in screens.indices {
            var seen = Set<Int>()
            var index = start
            for _ in screens.indices {
                seen.insert(index)
                index = WindowLayout.nextScreenIndex(after: index, in: screens)
            }
            check(seen.count == screens.count && index == start, "从 \(start) 走一圈没走遍或没回来")
        }
        check(WindowLayout.nextScreenIndex(after: 0, in: [screens[0]]) == 0, "只有一块屏时应是它自己")
    }

    static func centerSizing() {
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        for placement in [WindowLayout.Placement.leftHalf, .rightHalf, .maximize] {
            let snapped = WindowLayout.frame(placement, window: original, visible: visible)
            // 还停在我们摆的半屏 / 最大化上：回到挪之前的大小
            check(WindowLayout.centerSize(current: snapped, original: original, applied: snapped) == original.size,
                  "从 \(placement) 居中没回到原来的大小")
            // 摆完用户自己又调过大小：按现在的
            let resized = CGRect(x: snapped.minX, y: snapped.minY, width: snapped.width - 120, height: snapped.height - 80)
            check(WindowLayout.centerSize(current: resized, original: original, applied: snapped) == resized.size,
                  "从 \(placement) 摆完用户自己调过大小，居中却换回了原来的大小")
        }
        // 没有记录（系统平铺摆的半屏）：按现在的
        let tiled = WindowLayout.frame(.leftHalf, window: original, visible: visible)
        check(WindowLayout.centerSize(current: tiled, original: nil, applied: nil) == tiled.size, "没有记录时居中改了大小")
        // 终端读回来差一两个点也算还停在原处
        var landed = tiled
        landed.size.width -= 1
        check(WindowLayout.centerSize(current: landed, original: original, applied: tiled) == original.size,
              "差一个点就不认是我们摆的了")
    }

    static func movingAcrossScreens() {
        for source in screens {
            for target in screens where target != source {
                let tag = "\(source) → \(target)"
                // 摆好的三种到那边还是那种
                for placement in [WindowLayout.Placement.maximize, .leftHalf, .rightHalf] {
                    let there = WindowLayout.frame(placement, window: .zero, visible: source)
                    check(WindowLayout.moved(there, from: source, to: target)
                          == WindowLayout.frame(placement, window: .zero, visible: target),
                          "\(placement) 移过去不再是 \(placement) \(tag)")
                }
                // 终端按字符格取整，左半差几个点也认
                var nearlyLeft = WindowLayout.frame(.leftHalf, window: .zero, visible: source)
                nearlyLeft.size.width -= 7
                nearlyLeft.size.height -= 13
                check(WindowLayout.moved(nearlyLeft, from: source, to: target)
                      == WindowLayout.frame(.leftHalf, window: .zero, visible: target),
                      "差几个点的左半没认出来 \(tag)")

                for window in windows {
                    let moved = WindowLayout.moved(window, from: source, to: target)
                    check(target.contains(moved), "移过去出了屏幕 \(tag) window=\(window) → \(moved)")
                    check(moved.width == min(window.width, target.width)
                          && moved.height == min(window.height, target.height),
                          "移过去改了放得下的窗口的大小 \(tag) window=\(window) → \(moved)")
                }
                // 居中的到那边还是居中
                let small = CGRect(x: 0, y: 0, width: 600, height: 400)
                let centered = WindowLayout.frame(.center, window: small, visible: source)
                let movedCenter = WindowLayout.moved(centered, from: source, to: target)
                check(movedCenter == WindowLayout.frame(.center, window: small, visible: target),
                      "居中的窗口移过去不居中 \(tag) → \(movedCenter)")
            }
        }
        // 普通窗口不能被误认成半屏而改大小
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let other = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let plain = CGRect(x: 0, y: 25, width: 700, height: 600)
        check(WindowLayout.moved(plain, from: screen, to: other).size == plain.size, "贴左上角的普通窗口被当成了左半屏")
    }
}
