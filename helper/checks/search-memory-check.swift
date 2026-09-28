// SearchMemory 的纯逻辑校验（输入规范化、记账封顶、前缀匹配、衰减）。
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
        check("选两次 6 分（同一个输入大小写不同算一个）", M.boosts(t, query: "github", now: now)["https://a"] == 6)
        check("打短一点也认（存的是 github，现在打 git）", M.boosts(t, query: "git", now: now)["https://a"] == 6)
        check("打长一点也认（存的是 github，现在打 github pr）", M.boosts(t, query: "github pr", now: now)["https://a"] == 6)
        check("不相干的输入不加分", M.boosts(t, query: "youtube", now: now).isEmpty)
        check("空输入不加分", M.boosts(t, query: "  ", now: now).isEmpty)
        check("30 天后减半", M.boosts(t, query: "github", now: now + 30 * day)["https://a"] == 3)
        for _ in 0..<10 { t = M.recording(t, query: "github", identity: "https://a", now: now) }
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
