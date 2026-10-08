import Foundation

// 关掉的置顶记录暂存（⌘Z 恢复时原样放回去）。改 ClosedPinStash 必跑：
//   cd helper && swiftc -parse-as-library Sources/tabflick/ClosedPinStash.swift \
//     checks/closed-pin-stash-check.swift -o /tmp/pinstashcheck && /tmp/pinstashcheck
@main
struct ClosedPinStashCheck {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("✓ \(name)") } else { failures += 1; print("✗ \(name) \(detail())") }
        }
        let chrome = "com.google.Chrome|p1"
        let otherProfile = "com.google.Chrome|p2"

        do {
            var stash = ClosedPinStash<String>()
            stash.remember("gmail", index: 2, urls: ["https://mail.google.com/", "https://mail.google.com/#inbox/abc"], owner: chrome)
            let byCurrent = stash.take(url: "https://mail.google.com/#inbox/abc", owner: chrome)
            check("按最后访问的地址认得出", byCurrent?.pin == "gmail" && byCurrent?.index == 2, "\(String(describing: byCurrent))")
            check("取出即删，同一条不会放回两次", stash.take(url: "https://mail.google.com/#inbox/abc", owner: chrome) == nil)
        }

        do {
            var stash = ClosedPinStash<String>()
            stash.remember("gmail", index: 0, urls: ["https://mail.google.com/", "https://mail.google.com/#inbox/abc"], owner: chrome)
            check("按原始置顶地址也认得出", stash.take(url: "https://mail.google.com/", owner: chrome)?.pin == "gmail")
        }

        do {
            var stash = ClosedPinStash<String>()
            stash.remember("gmail", index: 0, urls: ["https://mail.google.com/"], owner: chrome)
            check("别的 Profile 里同网址的不认", stash.take(url: "https://mail.google.com/", owner: otherProfile) == nil)
            check("网址对不上的不认", stash.take(url: "https://mail.google.com/other", owner: chrome) == nil)
            check("没认领的还留着", stash.entries.count == 1)
        }

        do {
            var stash = ClosedPinStash<String>()
            stash.remember("older", index: 1, urls: ["https://a.example/"], owner: chrome)
            stash.remember("newer", index: 3, urls: ["https://a.example/"], owner: chrome)
            check("同网址关过两个：先还最近关的", stash.take(url: "https://a.example/", owner: chrome)?.pin == "newer")
            check("再还早的", stash.take(url: "https://a.example/", owner: chrome)?.pin == "older")
        }

        do {
            var stash = ClosedPinStash<Int>()
            for i in 0..<(ClosedPinStash<Int>.limit + 5) {
                stash.remember(i, index: i, urls: ["https://s\(i).example/"], owner: chrome)
            }
            check("有上限", stash.entries.count == ClosedPinStash<Int>.limit, "count=\(stash.entries.count)")
            check("挤掉的是最早的", stash.take(url: "https://s0.example/", owner: chrome) == nil
                  && stash.take(url: "https://s24.example/", owner: chrome)?.pin == 24)
        }

        do {
            var stash = ClosedPinStash<String>()
            stash.remember("x", index: 0, urls: ["", "https://x.example/"], owner: chrome)
            check("空地址不进匹配表", stash.take(url: "", owner: chrome) == nil)
        }

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("ClosedPinStash 校验未通过") }
    }
}
