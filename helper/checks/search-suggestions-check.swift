// SuggestionStore（快捷搜索首页「推荐」）的纯逻辑校验：记账衰减、够格门槛、时段加权、
// 从搜索记忆搬账、读文件的整理。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/SearchSuggestions.swift Sources/tabflick/SearchMemory.swift \
//          Sources/tabflick/Log.swift checks/search-suggestions-check.swift -o /tmp/suggestcheck && /tmp/suggestcheck
//
// 期望值一律手写。

import Foundation

// SearchSuggestions.swift 收「清除」通知要用到这个名字（正式定义在 AppCatalog.swift，那个文件依赖太多不编进来）
extension Notification.Name {
    static let clearUsageHistory = Notification.Name("TabFlickClearUsageHistory")
}

private typealias S = SuggestionStore
private let now: Double = 1_000_000_000
private let day: Double = 86_400

@main
struct SuggestionCheck {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        func pick(_ t: [String: S.Record], _ id: String, at: Double = now, hour: Int = 9,
                  kind: S.Record.Kind = .app, title: String = "T") -> [String: S.Record] {
            S.recording(t, identity: id, kind: kind, title: title, now: at, hour: hour)
        }

        // 记账
        var t: [String: S.Record] = [:]
        t = pick(t, "/A.app")
        check("第一次记成 1、这个钟点记 1", t["/A.app"]?.count == 1 && t["/A.app"]?.hours[9] == 1)
        t = pick(t, "/A.app", at: now + 14 * day, hour: 10)
        check("先衰减再加一（过一个半衰期 1 → 0.5，加一 1.5）", t["/A.app"]?.count == 1.5, "\(String(describing: t["/A.app"]?.count))")
        check("时段跟着一起衰减", t["/A.app"]?.hours[9] == 0.5 && t["/A.app"]?.hours[10] == 1)
        check("标题跟最新的", pick(t, "/A.app", title: "新名字")["/A.app"]?.title == "新名字")
        check("空标题不覆盖", pick(t, "/A.app", title: "")["/A.app"]?.title == "T")
        check("空身份不记", pick([:], "").isEmpty)
        check("钟点不对不记", S.recording([:], identity: "x", kind: .app, title: "", now: now, hour: 24).isEmpty)

        // 够格门槛：衰减后至少两次
        var once: [String: S.Record] = [:]
        once = pick(once, "/once.app")
        check("只选过一次不推", S.ranked(once, now: now, hour: 9).isEmpty)
        once = pick(once, "/once.app")
        check("选过两次推", S.ranked(once, now: now, hour: 9).map(\.identity) == ["/once.app"])
        check("两次但一个月前的（衰减到 0.45）不推", S.ranked(once, now: now + 30 * day, hour: 9).isEmpty)

        // 时段：早上常开的早上排前面，晚上常开的晚上排前面，挨着的钟点也算
        var daily: [String: S.Record] = [:]
        for _ in 0..<3 { daily = pick(daily, "/morning.app", hour: 9) }
        for _ in 0..<3 { daily = pick(daily, "/night.app", hour: 21) }
        check("早上 9 点：早上那个在前", S.ranked(daily, now: now, hour: 9).first?.identity == "/morning.app")
        check("晚上 9 点：晚上那个在前", S.ranked(daily, now: now, hour: 21).first?.identity == "/night.app")
        check("10 点（挨着 9 点）：早上那个在前", S.ranked(daily, now: now, hour: 10).first?.identity == "/morning.app")
        check("跨零点挨着（23 点选的，0 点算）", {
            var x: [String: S.Record] = [:]
            for _ in 0..<2 { x = pick(x, "/late.app", hour: 23) }
            return S.hourShare(x["/late.app"]!, hour: 0) == 1
        }())
        check("没有时段记录按均匀算", S.hourShare(S.Record(identity: "x", kind: .web, title: "", count: 3, last: now,
                                                           hours: Array(repeating: 0, count: 24)), hour: 5) == 3.0 / 24)
        // 次数多的压过时段：9 点选过 2 次的，比不上别的钟点选过 20 次的
        var heavy: [String: S.Record] = [:]
        for _ in 0..<2 { heavy = pick(heavy, "/rare.app", hour: 9) }
        for _ in 0..<20 { heavy = pick(heavy, "/often.app", hour: 15) }
        check("次数差得多时时段压不过次数", S.ranked(heavy, now: now, hour: 9).first?.identity == "/often.app")

        // 同分最近选过的在前：两条都「在将来」（衰减按没过时间算）、次数一样 → 分数精确相等，只差 last；
        // 名字故意让字母序和正确答案相反
        let zeros = Array(repeating: 0.0, count: 24)
        let tie: [String: S.Record] = [
            "/a-old.app": S.Record(identity: "/a-old.app", kind: .app, title: "", count: 2, last: now + 5, hours: zeros),
            "/b-new.app": S.Record(identity: "/b-new.app", kind: .app, title: "", count: 2, last: now + 10, hours: zeros),
        ]
        check("同分最近选过的在前", S.ranked(tie, now: now, hour: 9).first?.identity == "/b-new.app")

        // 上限
        var many: [String: S.Record] = [:]
        for i in 0...S.maxRecords { many = pick(many, "/a\(i).app", at: now + Double(i)) }
        check("最多 \(S.maxRecords) 条", many.count == S.maxRecords)

        // 从搜索记忆搬
        var memory = SearchMemory.Table()
        memory = SearchMemory.recording(memory, query: "ch", identity: "/Choice.app", now: now - 30 * day)
        memory = SearchMemory.recording(memory, query: "choice", identity: "/Choice.app", now: now)
        memory = SearchMemory.recording(memory, query: "gh", identity: "https://github.com/", now: now)
        memory = SearchMemory.recording(memory, query: "amp", identity: "appcmd:amphetamine.start", now: now)
        memory = SearchMemory.recording(memory, query: "proj", identity: "/Users/me/proj", now: now)
        memory = SearchMemory.recording(memory, query: "w", identity: "window#xyz", now: now)
        let seeded = S.seeded(from: memory, now: now)
        check("搬账：几个输入的次数衰减后相加（0.5 + 1）", seeded["/Choice.app"]?.count == 1.5,
              "\(String(describing: seeded["/Choice.app"]?.count))")
        check("搬账：记账时刻是现在（不再衰减第二遍）", seeded["/Choice.app"]?.last == now)
        var stale = SearchMemory.Table()
        stale = SearchMemory.recording(stale, query: "old", identity: "/Old.app", now: now - 30 * day)
        let staleSeeded = S.seeded(from: stale, now: now)
        check("搬账：只在一个月前选过的，次数已衰减成 0.5、记账时刻也是现在",
              staleSeeded["/Old.app"]?.count == 0.5 && staleSeeded["/Old.app"]?.last == now
              && S.effective(staleSeeded["/Old.app"]!, now: now) == 0.5)
        check("搬账：认出类别", seeded["/Choice.app"]?.kind == .app && seeded["https://github.com/"]?.kind == .web
              && seeded["/Users/me/proj"]?.kind == .folder)
        check("搬账：认不出的、内置命令不要", seeded["window#xyz"] == nil && seeded["appcmd:amphetamine.start"] == nil
              && seeded.count == 3)

        // 读文件
        check("解不开当没有", S.decode(Data("nope".utf8), now: now).isEmpty)
        let bad: [S.Record] = [
            S.Record(identity: "", kind: .app, title: "", count: 1, last: now, hours: Array(repeating: 0, count: 24)),
            S.Record(identity: "/neg.app", kind: .app, title: "", count: -1, last: now, hours: Array(repeating: 0, count: 24)),
            S.Record(identity: "/future.app", kind: .app, title: String(repeating: "长", count: 500), count: 2,
                     last: now + 999, hours: [1, 2]),
            // JSON 里写不出 NaN，拿负数代表「不是正常的数」
            S.Record(identity: "/nan.app", kind: .app, title: "", count: 2, last: now,
                     hours: [-1] + Array(repeating: 1, count: 23)),
        ]
        let read = S.decode(try! JSONEncoder().encode(bad), now: now)
        check("空身份、负次数丢掉", read["" ] == nil && read["/neg.app"] == nil)
        check("将来的时间夹到现在", read["/future.app"]?.last == now)
        check("标题截到 300 字", read["/future.app"]?.title.count == 300)
        check("时段不是 24 个正常数清零", read["/future.app"]?.hours == Array(repeating: 0, count: 24)
              && read["/nan.app"]?.hours == Array(repeating: 0, count: 24))

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("SuggestionStore 校验未通过") }
    }
}
