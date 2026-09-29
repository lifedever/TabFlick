import Foundation

/// 「最近使用」：浏览器标签和 App 按最近用过合成一张表（跨浏览器面板没输入时的默认，
/// 用户 2026-09-29 要的）。纯函数、零依赖，校验见 checks/recent-mix-check.swift。
enum RecentMix {
    struct Tab {
        /// 浏览器记的最近激活时间（毫秒）。Chrome 121 以前没有，扩展传 0 —— 当成不知道。
        let lastAccessed: Double?
        /// 归属浏览器的 bundle id。
        let browser: String?
        /// 属于哪条连接（一个浏览器 Profile 一条），以及在那条连接的 MRU 里排第几（0 = 正显示的）。
        let client: Int
        let mruIndex: Int
        /// 这条连接是它那个浏览器最近在前台的 Profile（只有一个 Profile 时就是它）。
        let frontProfile: Bool
    }

    struct App {
        /// 最近用过的时间（毫秒）：切到前台、上次打开、启动，取最新的。排序按它。
        let usedAt: Double?
        /// 最近一次从前台切走（毫秒），有记录的话。
        var leftAt: Double? = nil
        let bundleID: String?
    }

    enum Ref: Equatable {
        case tab(Int)
        case app(Int)
    }

    struct Entry: Equatable {
        let ref: Ref
        /// 离开它的时间（毫秒）：行尾「x 前」写的是离开多久了，不是切到它多久了。
        let leftAt: Double?
    }

    /// 时间新的在前；没有时间的垫底；同一时间标签按各自的 MRU、再到 App，保持传入顺序。
    ///
    /// 两处校正，都是浏览器给的 `lastAccessed` 不够准：
    /// ① **同一条连接里 MRU 说了算**：扩展的 MRU 在切窗口时也会更新，`lastAccessed` 只在切标签时更新，
    ///   两者可能打架（B 所在的窗口刚被切到前台，B 的 `lastAccessed` 却比 A 旧）。所以沿 MRU 从旧往新走，
    ///   每个标签的时间不低于比它旧的那个 —— 连接内部顺序照 MRU，时间只用来和别的来源穿插。
    /// ② **正显示的标签跟着浏览器切到前台的时间走**：从别的 App 切回浏览器窗口不算切标签，「Chrome 看 A →
    ///   VS Code → 回到 Chrome（还是 A）→ Slack」之后 A 的时间比 VS Code 旧，其实却是更近看的。
    /// 有标签的浏览器本身不列：它的标签已经代表了它，再列一行浏览器是重复。
    ///
    /// 排序按「切到它」的时间，行尾显示「离开它」的时间（两者先后一致：一次只有一样东西在前台，
    /// 先切进去的也先切出来）。离开时间优先用记下来的：App 切走的那一刻、浏览器切走时它正显示的那个
    /// 标签；没有的（其余标签、没记录的 App）按时间线推：离开它 = 切到下一样东西（表里比它新的那一项）。
    /// 中间看过又关掉的标签不在表里，推出来的会比实际近一点。记下来的比切进去还早说明那是更早一次的，
    /// 不用。最新的那一项没有「下一样」，就用它自己的时间（它多半就是当前，行尾写「当前」）。
    static func order(tabs: [Tab], apps: [App], browserActivatedAt: [String: Double],
                      browserDeactivatedAt: [String: Double] = [:]) -> [Entry] {
        var effective = [Double?](repeating: nil, count: tabs.count)
        var byMRU: [Int] = []
        for client in Set(tabs.map(\.client)).sorted() {
            let members = tabs.indices.filter { tabs[$0].client == client }
                .sorted { tabs[$0].mruIndex < tabs[$1].mruIndex }
            byMRU += members
            var floor: Double?
            for i in members.reversed() {
                let tab = tabs[i]
                var time = tab.lastAccessed.flatMap { $0 > 0 ? $0 : nil }
                if tab.mruIndex == 0, tab.frontProfile, let browser = tab.browser,
                   let active = browserActivatedAt[browser] {
                    time = max(time ?? active, active)
                }
                if let lower = floor { time = max(time ?? lower, lower) }
                effective[i] = time
                floor = time
            }
        }

        var keyed: [(ref: Ref, time: Double?, seq: Int, left: Double?)] = []
        for (seq, i) in byMRU.enumerated() {
            let tab = tabs[i]
            let left = tab.mruIndex == 0 && tab.frontProfile ? tab.browser.flatMap { browserDeactivatedAt[$0] } : nil
            keyed.append((.tab(i), effective[i], seq, left))
        }
        let browsers = Set(tabs.compactMap(\.browser))
        for (i, app) in apps.enumerated() {
            if let id = app.bundleID, browsers.contains(id) { continue }
            keyed.append((.app(i), app.usedAt, tabs.count + i, app.leftAt))
        }
        let sorted = keyed.sorted { a, b in
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.seq < b.seq
            }
        }
        return sorted.enumerated().map { j, item in
            var left: Double?
            if let recorded = item.left, recorded >= (item.time ?? -.infinity) {
                left = recorded
            } else if let time = item.time {
                left = j > 0 ? max(sorted[j - 1].time ?? time, time) : time
            }
            return Entry(ref: item.ref, leftAt: left)
        }
    }
}
