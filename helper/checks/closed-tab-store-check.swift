// ClosedTabStore.merging 的规则校验。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/ClosedTabStore.swift \
//          Sources/tabflick/L10n.swift Sources/tabflick/Log.swift \
//          checks/closed-tab-store-check.swift -o /tmp/closedcheck && /tmp/closedcheck
//
// 为什么单独校验：合并要同时满足四条互相交织的规则 —— 降序、同（浏览器+URL）
// 去重保留最新、丢过期、截上限。任何一条写错都是**静默**的：列表里少几条、
// 或者旧的顶掉新的，没有任何报错。
//
// 只测静态纯函数 `merging`，绝不实例化 ClosedTabStore —— 那会直接读写用户
// 真实的 ~/Library/Application Support/TabFlick/closed-tabs.json。

import Foundation

let NOW: Double = 1_700_000_000_000     // 固定基准，不依赖真实时钟
let DAY: Double = 86_400 * 1000
let MAX_AGE: TimeInterval = 30 * 86_400
let MAX_ENTRIES = 1000

func tab(_ url: String, _ browser: String = "chrome",
         daysAgo: Double = 0, title: String = "") -> ClosedTab {
    ClosedTab(url: url, title: title.isEmpty ? url : title, favIconUrl: "",
              browser: browser, reason: .manual, closedAt: NOW - daysAgo * DAY)
}

func merge(_ existing: [ClosedTab], _ incoming: [ClosedTab],
           maxEntries: Int = MAX_ENTRIES) -> [ClosedTab] {
    ClosedTabStore.merging(existing: existing, incoming: incoming,
                           now: NOW, maxAge: MAX_AGE, maxEntries: maxEntries)
}

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  ✗ \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

@main
struct Check {
static func main() {

// ── 降序 ────────────────────────────────────────────────────────────────
print("结果按关闭时间降序")
do {
    let out = merge([], [tab("https://old/", daysAgo: 5),
                         tab("https://new/", daysAgo: 1),
                         tab("https://mid/", daysAgo: 3)])
    check("最新的在最前", out.first?.url == "https://new/", "得到 \(out.map(\.url))")
    check("最旧的在最后", out.last?.url == "https://old/")
    check("一条不少", out.count == 3)
}

// ── 去重 ────────────────────────────────────────────────────────────────
print("同一浏览器下同 URL 只留最新的一条")
do {
    let out = merge([tab("https://a/", daysAgo: 5, title: "旧的")],
                    [tab("https://a/", daysAgo: 1, title: "新的")])
    check("只剩一条", out.count == 1, "得到 \(out.count) 条")
    check("留下的是新的", out.first?.title == "新的", "留下了 \(out.first?.title ?? "?")")
}

print("送进来的比库里的还旧时，留库里那条（时钟回拨也不该让旧的顶掉新的）")
do {
    let out = merge([tab("https://a/", daysAgo: 1, title: "新的")],
                    [tab("https://a/", daysAgo: 5, title: "旧的")])
    check("留下的仍是新的", out.first?.title == "新的", "留下了 \(out.first?.title ?? "?")")
}

print("同一批里就有重复时也只留最新（顺序不影响结果）")
do {
    let forward = merge([], [tab("https://a/", daysAgo: 5, title: "旧的"),
                             tab("https://a/", daysAgo: 1, title: "新的")])
    let reverse = merge([], [tab("https://a/", daysAgo: 1, title: "新的"),
                             tab("https://a/", daysAgo: 5, title: "旧的")])
    check("正序：留新的", forward.first?.title == "新的")
    check("逆序：也留新的", reverse.first?.title == "新的",
          "逆序留下了 \(reverse.first?.title ?? "?")")
}

print("不同浏览器的同一个 URL 是两条，各记各的（浏览器物理隔离）")
do {
    let out = merge([], [tab("https://a/", "chrome", daysAgo: 1),
                         tab("https://a/", "quark", daysAgo: 2)])
    check("两条都在", out.count == 2, "得到 \(out.count) 条")
}

// ── 过期 ────────────────────────────────────────────────────────────────
print("超过 30 天的丢掉")
do {
    let out = merge([tab("https://ancient/", daysAgo: 31)],
                    [tab("https://fresh/", daysAgo: 29)])
    check("31 天前的没了", !out.contains { $0.url == "https://ancient/" }, "得到 \(out.map(\.url))")
    check("29 天前的还在", out.contains { $0.url == "https://fresh/" })
}

print("过期的挡在中间时，后面更新的不会被连坐（降序 + break 的边界）")
do {
    // 故意把过期那条排在输入的最前面 —— 排序没做对的话 break 会砍掉后面全部
    let out = merge([], [tab("https://ancient/", daysAgo: 40),
                         tab("https://fresh/", daysAgo: 1)])
    check("新的活下来了", out.contains { $0.url == "https://fresh/" }, "得到 \(out.map(\.url))")
    check("旧的被丢掉", out.count == 1, "得到 \(out.count) 条")
}

// ── 上限 ────────────────────────────────────────────────────────────────
print("超出上限时砍掉最旧的那些")
do {
    let many = (0..<50).map { tab("https://s\($0)/", daysAgo: Double($0) * 0.1) }
    let out = merge([], many, maxEntries: 10)
    check("正好 10 条", out.count == 10, "得到 \(out.count) 条")
    check("留下的是最新的 10 条", out.allSatisfy { url in
        (0..<10).map { "https://s\($0)/" }.contains(url.url)
    }, "得到 \(out.map(\.url))")
    check("最旧的被砍掉", !out.contains { $0.url == "https://s49/" })
}

print("新来的一条能把库里最旧的挤出去（不是「满了就不收」）")
do {
    let full = (0..<10).map { tab("https://s\($0)/", daysAgo: Double($0 + 1)) }
    let out = merge(full, [tab("https://brand-new/", daysAgo: 0)], maxEntries: 10)
    check("仍是 10 条", out.count == 10, "得到 \(out.count) 条")
    check("新的在最前", out.first?.url == "https://brand-new/", "首条是 \(out.first?.url ?? "?")")
    check("最旧的被挤出", !out.contains { $0.url == "https://s9/" }, "得到 \(out.map(\.url))")
}

// ── 字段规范化 ──────────────────────────────────────────────────────────
print("超长标题在构造时就被截断（title 完全由网页控制）")
do {
    let long = String(repeating: "标", count: 5000)
    let t = ClosedTab(url: "https://a/", title: long, favIconUrl: "",
                      browser: "chrome", reason: .manual, closedAt: NOW)
    check("截到上限", t.title.count == ClosedTab.maxTitleLength, "长度 \(t.title.count)")
}

print("认不出的 reason 解码成 manual，不让整份存档陪葬")
do {
    let json = """
    [{"id":"x","url":"https://a/","title":"t","favIconUrl":"","browser":"chrome",\
    "reason":"from-the-future","closedAt":\(NOW)}]
    """
    let decoded = try? JSONDecoder().decode([ClosedTab].self, from: Data(json.utf8))
    check("整份没解码失败", decoded?.count == 1, "得到 \(decoded?.count ?? -1) 条")
    check("原因退回 manual", decoded?.first?.reason == .manual)
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
}
}
