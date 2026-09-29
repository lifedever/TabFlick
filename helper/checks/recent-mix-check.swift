// RecentMix.order 的校验：浏览器标签和 App 按最近用过合表。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/RecentMix.swift checks/recent-mix-check.swift \
//          -o /tmp/recentcheck && /tmp/recentcheck
//
// 排错了不报错，只会是「上一件事不在第一行」。期望值一律手写。

import Foundation

private typealias Tab = RecentMix.Tab
private typealias App = RecentMix.App

private struct Case {
    let name: String
    let tabs: [Tab]
    let apps: [App]
    let activated: [String: Double]
    let want: [RecentMix.Ref]
}

private let chrome = "com.google.Chrome"
private let quark = "com.quark.desktop"

private let cases: [Case] = [
    Case(name: "按时间交错",
         tabs: [Tab(lastAccessed: 300, browser: chrome, showing: true),
                Tab(lastAccessed: 100, browser: chrome, showing: false)],
         apps: [App(usedAt: 200, bundleID: "com.microsoft.VSCode")],
         activated: [:],
         want: [.tab(0), .app(0), .tab(1)]),
    // Chrome 看 A（100）→ VS Code（200）→ 回到 Chrome（300，还是 A）→ Slack（400）：
    // A 该排在 VS Code 前面；没在显示的 B 不沾浏览器的时间
    Case(name: "正显示的标签跟着浏览器切到前台的时间走",
         tabs: [Tab(lastAccessed: 100, browser: chrome, showing: true),
                Tab(lastAccessed: 50, browser: chrome, showing: false)],
         apps: [App(usedAt: 200, bundleID: "com.microsoft.VSCode"),
                App(usedAt: 400, bundleID: "com.tinyspeck.slackmacgap")],
         activated: [chrome: 300],
         want: [.app(1), .tab(0), .app(0), .tab(1)]),
    Case(name: "浏览器切到前台更早时不往回拉",
         tabs: [Tab(lastAccessed: 500, browser: chrome, showing: true)],
         apps: [App(usedAt: 400, bundleID: "com.apple.finder")],
         activated: [chrome: 300],
         want: [.tab(0), .app(0)]),
    Case(name: "有标签的浏览器本身不列，没装扩展的浏览器照列",
         tabs: [Tab(lastAccessed: 100, browser: chrome, showing: true)],
         apps: [App(usedAt: 900, bundleID: chrome),
                App(usedAt: 800, bundleID: "com.apple.Safari")],
         activated: [:],
         want: [.app(1), .tab(0)]),
    Case(name: "另一个浏览器的标签只沾它自己的时间",
         tabs: [Tab(lastAccessed: 100, browser: chrome, showing: true),
                Tab(lastAccessed: 200, browser: quark, showing: true)],
         apps: [],
         activated: [chrome: 300],
         want: [.tab(0), .tab(1)]),
    Case(name: "没时间的垫底、保持原顺序，标签在前",
         tabs: [Tab(lastAccessed: nil, browser: chrome, showing: false),
                Tab(lastAccessed: 10, browser: chrome, showing: false)],
         apps: [App(usedAt: nil, bundleID: "a"), App(usedAt: 20, bundleID: "b")],
         activated: [:],
         want: [.app(1), .tab(1), .tab(0), .app(0)]),
    Case(name: "同一时间标签在前",
         tabs: [Tab(lastAccessed: 100, browser: chrome, showing: false)],
         apps: [App(usedAt: 100, bundleID: "a")],
         activated: [:],
         want: [.tab(0), .app(0)]),
    Case(name: "正显示的标签没有自己的时间时用浏览器的",
         tabs: [Tab(lastAccessed: nil, browser: chrome, showing: true)],
         apps: [App(usedAt: 100, bundleID: "a")],
         activated: [chrome: 200],
         want: [.tab(0), .app(0)]),
]

@main
struct RecentMixCheck {
    static func main() {
        var failures = 0
        for c in cases {
            let got = RecentMix.order(tabs: c.tabs, apps: c.apps, browserActivatedAt: c.activated)
            if got != c.want {
                failures += 1
                print("✗ \(c.name)：期望 \(c.want)，实际 \(got)")
            }
        }
        print(failures == 0 ? "全部通过（\(cases.count) 组）" : "\(failures) 项失败（共 \(cases.count) 组）")
        if failures > 0 { fatalError("RecentMix 校验未通过") }
    }
}
