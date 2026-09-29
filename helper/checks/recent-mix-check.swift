// RecentMix.order 的校验：浏览器标签和 App 按最近用过合表。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/RecentMix.swift checks/recent-mix-check.swift \
//          -o /tmp/recentcheck && /tmp/recentcheck
//
// 排错了不报错，只会是「上一件事不在第一行」。期望值一律手写。

import Foundation

private typealias App = RecentMix.App

/// 标签：默认单 Profile、连接 0；mru 是它在连接 MRU 里的位置。
private func tab(_ time: Double?, _ browser: String = chrome, mru: Int, client: Int = 0,
                 front: Bool = true) -> RecentMix.Tab {
    RecentMix.Tab(lastAccessed: time, browser: browser, client: client, mruIndex: mru, frontProfile: front)
}

private struct Case {
    let name: String
    let tabs: [RecentMix.Tab]
    let apps: [App]
    let activated: [String: Double]
    let want: [RecentMix.Ref]
}

private let chrome = "com.google.Chrome"
private let quark = "com.quark.desktop"

private let cases: [Case] = [
    Case(name: "按时间交错",
         tabs: [tab(300, mru: 0), tab(100, mru: 1)],
         apps: [App(usedAt: 200, bundleID: "com.microsoft.VSCode")],
         activated: [:],
         want: [.tab(0), .app(0), .tab(1)]),
    // Chrome 看 A（100）→ VS Code（200）→ 回到 Chrome（300，还是 A）→ Slack（400）：
    // A 该排在 VS Code 前面；没在显示的 B 不沾浏览器的时间
    Case(name: "正显示的标签跟着浏览器切到前台的时间走",
         tabs: [tab(100, mru: 0), tab(50, mru: 1)],
         apps: [App(usedAt: 200, bundleID: "com.microsoft.VSCode"),
                App(usedAt: 400, bundleID: "com.tinyspeck.slackmacgap")],
         activated: [chrome: 300],
         want: [.app(1), .tab(0), .app(0), .tab(1)]),
    Case(name: "浏览器切到前台更早时不往回拉",
         tabs: [tab(500, mru: 0)],
         apps: [App(usedAt: 400, bundleID: "com.apple.finder")],
         activated: [chrome: 300],
         want: [.tab(0), .app(0)]),
    Case(name: "有标签的浏览器本身不列，没装扩展的浏览器照列",
         tabs: [tab(100, mru: 0)],
         apps: [App(usedAt: 900, bundleID: chrome),
                App(usedAt: 800, bundleID: "com.apple.Safari")],
         activated: [:],
         want: [.app(1), .tab(0)]),
    Case(name: "另一个浏览器的标签只沾它自己的时间",
         tabs: [tab(100, mru: 0), tab(200, quark, mru: 0, client: 1)],
         apps: [],
         activated: [chrome: 300],
         want: [.tab(0), .tab(1)]),
    Case(name: "没时间的垫底，标签在前",
         tabs: [tab(10, mru: 0), tab(nil, mru: 1)],
         apps: [App(usedAt: nil, bundleID: "a"), App(usedAt: 20, bundleID: "b")],
         activated: [:],
         want: [.app(1), .tab(0), .tab(1), .app(0)]),
    Case(name: "同一时间标签在前",
         tabs: [tab(100, mru: 0)],
         apps: [App(usedAt: 100, bundleID: "a")],
         activated: [:],
         want: [.tab(0), .app(0)]),
    Case(name: "正显示的标签没有自己的时间时用浏览器的",
         tabs: [tab(nil, mru: 0)],
         apps: [App(usedAt: 100, bundleID: "a")],
         activated: [chrome: 200],
         want: [.tab(0), .app(0)]),
    // Chrome 121 以前扩展传 0：和「不知道」一样对待，两个都不知道时间的按连接顺序，不因为 0 排到前面
    Case(name: "时间为 0 当作不知道",
         tabs: [tab(nil, mru: 0, client: 0), tab(0, quark, mru: 0, client: 1)],
         apps: [],
         activated: [:],
         want: [.tab(0), .tab(1)]),
    // 老 Chrome 的标签都没有时间：正显示的那个借浏览器切到前台的时间，其余按 MRU 垫在有时间的 App 后面
    Case(name: "没有时间的浏览器只有正显示的标签能排上来",
         tabs: [tab(0, mru: 0), tab(0, mru: 1)],
         apps: [App(usedAt: 100, bundleID: "a")],
         activated: [chrome: 200],
         want: [.tab(0), .app(0), .tab(1)]),
    // 切窗口时 MRU 变了、lastAccessed 没变：连接内部照 MRU，B 在 A 前；A 的 300 比 App 的 250 新，
    // B 至少和 A 一样新
    Case(name: "同一条连接里照 MRU 排",
         tabs: [tab(300, mru: 1), tab(100, mru: 0)],
         apps: [App(usedAt: 250, bundleID: "a")],
         activated: [:],
         want: [.tab(1), .tab(0), .app(0)]),
    Case(name: "传入顺序打乱时仍按 MRU",
         tabs: [tab(nil, mru: 2), tab(nil, mru: 0), tab(nil, mru: 1)],
         apps: [],
         activated: [:],
         want: [.tab(1), .tab(2), .tab(0)]),
    // 同一个浏览器两个 Profile：不在前台的那个 Profile 的当前标签不沾浏览器切到前台的时间
    Case(name: "不在前台的 Profile 不沾浏览器的时间",
         tabs: [tab(100, mru: 0, client: 0, front: false), tab(150, mru: 0, client: 1, front: true)],
         apps: [App(usedAt: 200, bundleID: "a")],
         activated: [chrome: 300],
         want: [.tab(1), .app(0), .tab(0)]),
]

@main
struct RecentMixCheck {
    static func main() {
        var failures = 0
        for c in cases {
            let got = RecentMix.order(tabs: c.tabs, apps: c.apps, browserActivatedAt: c.activated).map(\.ref)
            if got != c.want {
                failures += 1
                print("✗ \(c.name)：期望 \(c.want)，实际 \(got)")
            }
        }
        // 离开时间（行尾「x 前」）：有记下来的用记下来的，没有的按时间线推 = 表里比它新的那一项切进去的时间
        typealias E = RecentMix.Entry
        let leftCases: [(String, [RecentMix.Tab], [App], [String: Double], [String: Double], [E])] = [
            ("按时间线推：离开它 = 切到下一样东西",
             [tab(300, mru: 0), tab(100, mru: 1)], [App(usedAt: 200, bundleID: "vscode")], [:], [:],
             [E(ref: .tab(0), leftAt: 300), E(ref: .app(0), leftAt: 300), E(ref: .tab(1), leftAt: 200)]),
            // 10:00 切进微信（100）、聊到 10:29 切走（290）、切到 Claude（290）：微信写离开多久，不是切进去多久
            ("App 有记下来的切走时间就用它",
             [], [App(usedAt: 100, leftAt: 290, bundleID: "wechat"), App(usedAt: 290, bundleID: "claude")], [:], [:],
             [E(ref: .app(1), leftAt: 290), E(ref: .app(0), leftAt: 290)]),
            ("比切进去还早的切走记录是更早一次的，不用",
             [], [App(usedAt: 200, leftAt: 150, bundleID: "a"), App(usedAt: 300, bundleID: "b")], [:], [:],
             [E(ref: .app(1), leftAt: 300), E(ref: .app(0), leftAt: 300)]),
            ("浏览器切走的时间给它正显示的那个标签",
             [tab(100, mru: 0), tab(50, mru: 1)], [App(usedAt: 180, bundleID: "slack")],
             [chrome: 150], [chrome: 170],
             [E(ref: .app(0), leftAt: 180), E(ref: .tab(0), leftAt: 170), E(ref: .tab(1), leftAt: 150)]),
            ("没有时间的只看记下来的",
             [], [App(usedAt: nil, leftAt: 40, bundleID: "a"), App(usedAt: nil, bundleID: "b")], [:], [:],
             [E(ref: .app(0), leftAt: 40), E(ref: .app(1), leftAt: nil)]),
        ]
        for (name, tabs, apps, activated, deactivated, want) in leftCases {
            let got = RecentMix.order(tabs: tabs, apps: apps, browserActivatedAt: activated,
                                      browserDeactivatedAt: deactivated)
            if got != want {
                failures += 1
                print("✗ \(name)：期望 \(want)，实际 \(got)")
            }
        }

        let total = cases.count + leftCases.count
        print(failures == 0 ? "全部通过（\(total) 组）" : "\(failures) 项失败（共 \(total) 组）")
        if failures > 0 { fatalError("RecentMix 校验未通过") }
    }
}
