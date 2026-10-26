// AppRanking 的校验：常用度（衰减、记一次的门槛、两个来源取大）换算成 0–2 分，以及 App 的默认顺序。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/AppRanking.swift checks/app-ranking-check.swift \
//          -o /tmp/rankingcheck && /tmp/rankingcheck
//
// 期望值一律手写。

import Foundation

private typealias R = AppRanking
private let now: Double = 1_000_000_000
private let day: Double = 86_400

@main
struct AppRankingCheck {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }

        // 衰减
        check("半衰期过一次减半", R.decayed(8, since: now - 14 * day, now: now, halfLife: 14 * day) == 4)
        check("时间倒流按没过时间算", R.decayed(8, since: now + 100, now: now, halfLife: 14 * day) == 8)
        check("负数和非数字当 0", R.decayed(-3, since: now, now: now, halfLife: 1) == 0
              && R.decayed(.nan, since: now, now: now, halfLife: 1) == 0)

        // 记一次的门槛
        check("待不够 5 秒不算", R.recordingSession(uses: 2, usesAt: now, activatedAt: now - 4.9, now: now) == nil)
        let first = R.recordingSession(uses: nil, usesAt: nil, activatedAt: now - 5, now: now)
        check("第一次记成 1", first?.uses == 1 && first?.at == now)
        let later = R.recordingSession(uses: 4, usesAt: now - 14 * day, activatedAt: now - 60, now: now)
        check("先衰减再加一（4 过了一个半衰期是 2，加一是 3）", later?.uses == 3 && later?.at == now)
        check("切进去的时间不是数不算", R.recordingSession(uses: 1, usesAt: now, activatedAt: .nan, now: now) == nil)

        // 常用度换算成分
        func prior(sessions: Double? = nil, at: Double? = now, spot: Int? = nil, spotAt: Double? = now) -> Int {
            R.prior(level: R.level(sessions: sessions, sessionsAt: at, spotlightUses: spot, spotlightLastUsed: spotAt, now: now))
        }
        check("什么都没有 0 分", prior() == 0)
        check("用过几次 0 分（7 次，log2(8) = 3）", prior(sessions: 7) == 0)
        check("15 次 1 分（log2(16) = 4）", prior(sessions: 15) == 1)
        check("255 次 2 分（log2(256) = 8）", prior(sessions: 255) == 2)
        check("两个来源取大的：自己记的少、Spotlight 多", prior(sessions: 1, spot: 2547) == 2)
        check("两个来源取大的：Spotlight 没有、自己记的多", prior(sessions: 300, spot: nil) == 2)
        check("Spotlight 的次数按上次打开衰减：半年前开过 2547 次也只剩零头",
              prior(spot: 2547, spotAt: now - 180 * day) == 1)
        check("Spotlight 没有上次打开的时间就不信次数", prior(spot: 9999, spotAt: nil) == 0)
        check("两个来源取大的，不相加（各 150 次是 1 分，加起来 300 次会变 2 分）", prior(sessions: 150, spot: 150) == 1)
        check("自己记的也衰减：两个月前的 300 次只剩 1 分", prior(sessions: 300, at: now - 60 * day) == 1)

        // 默认顺序：最近用过的在前，不看运行没运行（这里根本没有这个参数）；一样新的看常用度；都没有按名字
        func before(_ a: (Double?, Int, String), _ b: (Double?, Int, String)) -> Bool {
            R.precedes(usedA: a.0, priorA: a.1, nameA: a.2, usedB: b.0, priorB: b.1, nameB: b.2)
        }
        check("最近用过的在前", before((now - 10, 0, "B"), (now - 100, 2, "A")))
        check("有记录的在没记录的前面", before((now - 999, 0, "Z"), (nil, 2, "A")))
        check("一样新的看常用度", before((now, 2, "Z"), (now, 0, "A")))
        check("都没记录时常用度高的在前", before((nil, 1, "Z"), (nil, 0, "A")))
        check("什么都一样按名字", before((nil, 0, "Alpha"), (nil, 0, "beta")) && !before((nil, 0, "beta"), (nil, 0, "Alpha")))
        check("名字按数字自然排（App 2 在 App 10 前）", before((nil, 0, "App 2"), (nil, 0, "App 10")))

        // 同分按常用度：高的在前，同档保持原顺序（原顺序是最近用过的在前）
        let tie = R.byPrior([("old-0", 0), ("a-2", 2), ("b-1", 1), ("c-2", 2), ("d-0", 0)], prior: \.1).map(\.0)
        check("按常用度稳定重排", tie == ["a-2", "c-2", "b-1", "old-0", "d-0"], "\(tie)")

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("AppRanking 校验未通过") }
    }
}
