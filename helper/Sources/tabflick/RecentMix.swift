import Foundation

/// 「最近使用」：浏览器标签和运行中的 App 按最近用过合成一张表（跨浏览器面板没输入时可选，
/// 用户 2026-09-29 要的）。纯函数、零依赖，校验见 checks/recent-mix-check.swift。
enum RecentMix {
    struct Tab {
        /// 浏览器记的最近激活时间（毫秒）。
        let lastAccessed: Double?
        /// 归属浏览器的 bundle id。
        let browser: String?
        /// 它那个浏览器此刻正显示的标签（多 Profile 时只算最近在前台的那个 Profile）。
        let showing: Bool
    }

    struct App {
        /// 最近用过的时间（毫秒）：切到前台、上次打开、启动，取最新的。
        let usedAt: Double?
        let bundleID: String?
    }

    enum Ref: Equatable {
        case tab(Int)
        case app(Int)
    }

    /// 时间新的在前；没有时间的垫底；同一时间保持传入顺序、标签在前。
    ///
    /// 浏览器切换标签才更新 `lastAccessed`，从别的 App 切回浏览器窗口不算：「Chrome 看 A →
    /// VS Code → 回到 Chrome（还是 A）→ Slack」之后，A 的时间比 VS Code 旧，其实却是更近看的。
    /// 所以每个浏览器正显示的那个标签，时间取它自己的和浏览器最近切到前台的里新的那个。
    /// 有标签的浏览器本身不列：它的标签已经代表了它，再列一行浏览器是重复。
    static func order(tabs: [Tab], apps: [App], browserActivatedAt: [String: Double]) -> [Ref] {
        var keyed: [(ref: Ref, time: Double?, seq: Int)] = []
        for (i, tab) in tabs.enumerated() {
            var time = tab.lastAccessed
            if tab.showing, let browser = tab.browser, let active = browserActivatedAt[browser] {
                time = max(time ?? active, active)
            }
            keyed.append((.tab(i), time, i))
        }
        let browsers = Set(tabs.compactMap(\.browser))
        for (i, app) in apps.enumerated() {
            if let id = app.bundleID, browsers.contains(id) { continue }
            keyed.append((.app(i), app.usedAt, tabs.count + i))
        }
        return keyed.sorted { a, b in
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.seq < b.seq
            }
        }.map(\.ref)
    }
}
