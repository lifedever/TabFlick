// SearchMemory 的纯逻辑校验（输入规范化、按对数涨和封顶、前缀打折、衰减）。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/SearchMemory.swift Sources/tabflick/Log.swift \
//          checks/search-memory-check.swift -o /tmp/memorycheck && /tmp/memorycheck

import Foundation

@main
struct SearchMemoryCheck {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        let day = 86_400.0
        let now = 1_000_000_000.0
        typealias M = SearchMemory

        check("规范化：大小写、首尾和中间空白", M.normalize("  GitHub   Pull ") == "github pull")

        var t = M.Table()
        t = M.recording(t, query: "GitHub", identity: "https://a", now: now)
        check("选一次刚好 3 分", M.boosts(t, query: "github", now: now)["https://a"] == 3)
        t = M.recording(t, query: "github", identity: "https://a", now: now)
        check("选两次按对数涨到 5 分（同一个输入大小写不同算一个）", M.boosts(t, query: "github", now: now)["https://a"] == 5)
        check("打短一点也认，按短的占长的几成打折（git / github = 一半）", M.boosts(t, query: "git", now: now)["https://a"] == 2)
        check("打长一点也认，同样打折（github / github pr）", M.boosts(t, query: "github pr", now: now)["https://a"] == 3)
        check("不相干的输入不加分", M.boosts(t, query: "youtube", now: now).isEmpty)
        check("空输入不加分", M.boosts(t, query: "  ", now: now).isEmpty)
        check("30 天后减半（两次 → 一次，3 分）", M.boosts(t, query: "github", now: now + 30 * day)["https://a"] == 3)
        // 打一个字母时，长输入里选过的只拿零头，拿全分的是这个字母自己选过的
        var d = M.Table()
        d = M.recording(d, query: "down", identity: "/fdm", now: now)
        d = M.recording(d, query: "d", identity: "/dingtalk", now: now)
        let dBoosts = M.boosts(d, query: "d", now: now)
        check("「d」：选过「down」的只拿 1 分", dBoosts["/fdm"] == 1, "\(dBoosts)")
        check("「d」：一字不差的拿全分", dBoosts["/dingtalk"] == 3, "\(dBoosts)")
        // 同一个身份多条存的输入都沾边：取最高的那条
        var both = M.Table()
        both = M.recording(both, query: "gi", identity: "x", now: now)
        for _ in 0..<3 { both = M.recording(both, query: "github", identity: "x", now: now) }
        check("多条沾边取最高", M.boosts(both, query: "gi", now: now)["x"] == 3)
        // 再多几条分量不同的（字典遍历顺序每次运行都变，条数多了「取最后一条」才几乎必然露馅）
        var spread = M.Table()
        spread = M.recording(spread, query: "g", identity: "y", now: now)
        for q in ["gi", "git", "gith", "githu", "github", "github x"] {
            spread = M.recording(spread, query: q, identity: "y", now: now - 300 * day)
        }
        check("多条沾边取最高（分量不同的几条）", M.boosts(spread, query: "g", now: now)["y"] == 3)
        for _ in 0..<5 { t = M.recording(t, query: "github", identity: "https://a", now: now) }
        check("选 7 次 9 分", M.boosts(t, query: "github", now: now)["https://a"] == 9)
        var heavy = M.Table()
        for _ in 0..<4 { heavy = M.recording(heavy, query: "ch", identity: "four", now: now) }
        for _ in 0..<28 { heavy = M.recording(heavy, query: "ch", identity: "many", now: now) }
        let heavyBoosts = M.boosts(heavy, query: "ch", now: now)
        check("选 28 次比选 4 次分高（不再 4 次就封顶）",
              (heavyBoosts["many"] ?? 0) > (heavyBoosts["four"] ?? 0), "\(heavyBoosts)")
        for _ in 0..<30 { t = M.recording(t, query: "github", identity: "https://a", now: now) }
        check("封顶 12", M.boosts(t, query: "github", now: now)["https://a"] == 12)

        // 每个输入只留 8 条：留分量大的
        var many = M.Table()
        for i in 0..<9 {
            for _ in 0...i { many = M.recording(many, query: "x", identity: "id\(i)", now: now) }
        }
        check("每个输入最多 8 条", many["x"]?.count == 8)
        check("挤掉的是分量最小的", many["x"]?["id0"] == nil && many["x"]?["id8"] != nil)

        // 输入太多丢最久没用的
        var queries = M.Table()
        for i in 0..<(M.maxQueries + 1) {
            queries = M.recording(queries, query: "q\(i)", identity: "a", now: now + Double(i))
        }
        check("输入最多 \(M.maxQueries) 个", queries.count == M.maxQueries)
        check("丢的是最久没用的", queries["q0"] == nil && queries["q\(M.maxQueries)"] != nil)

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { exit(1) }
    }
}
