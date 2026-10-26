import Foundation

/// App 的常用度（2026-10-26 用户要的）：搜索面板给 App 排序时，除了匹配分和搜索记忆，再看你平时
/// 用它用得多不多。没有这一层时，同一档匹配里（打一个字母，十几个 App 都是「名字开头」）谁在前
/// 只看最近一次用过的时间，从没开过的 App 和天天用的分不出来。
///
/// 两个来源取大的：
/// - 自己记的「切到前台待了 `minSession` 秒以上」的次数，按 `sessionHalfLife` 衰减（`AppCatalog` 记、
///   `AppActivity` 存盘）。最准，但要攒几天才有。
/// - Spotlight 的打开次数（`kMDItemUseCount`），按上次打开的时间衰减：装上 TabFlick 第一天就有，
///   但它是装上以来的总数，几个月没开的老 App 不该靠当年的次数排前面。
///
/// 换算成 0–2 三档，**只在匹配分相同的 App 之间排先后**（`byPrior`），不加到分上。试过加分（+2 / +1）：
/// 打一个字母时「名字里含这个字母」就有 6 分，+2 正好追平「名字以它开头」的 8 分，结果天天开着的
/// 微信、Chrome、钉钉打哪个字母都挤进前四（打「n」第一个是钉钉），等于换个名字的「运行中优先」。
/// 回放评测（scripts/rank-eval）里加分和只排同分两种的命中率一样，后者不会跨档，选它。
///
/// 纯函数、零依赖，校验见 checks/app-ranking-check.swift。
enum AppRanking {
    nonisolated static let sessionHalfLife: Double = 14 * 86_400
    nonisolated static let spotlightHalfLife: Double = 30 * 86_400
    /// 在前台待够这么久才算用了一次：⌘Tab 一路按过去经过的 App 不算。
    nonisolated static let minSession: Double = 5
    /// 常用度（以 2 为底的对数）到这两档分别加 1、2 分。
    nonisolated static let levelForOne: Double = 4
    nonisolated static let levelForTwo: Double = 8

    /// value 在 since 时刻的值衰减到 now。时间倒流（系统时间往回调过）按没过时间算。
    nonisolated static func decayed(_ value: Double, since: Double, now: Double, halfLife: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value * pow(0.5, max(0, now - since) / halfLife)
    }

    /// 一次切到前台结束了（切走那一刻调）：待够 `minSession` 秒就把次数衰减到现在再加一。
    /// 返回 nil = 这次不算（太短，或者时间不对）。
    nonisolated static func recordingSession(uses: Double?, usesAt: Double?, activatedAt: Double, now: Double)
        -> (uses: Double, at: Double)? {
        guard activatedAt.isFinite, now - activatedAt >= minSession else { return nil }
        let previous = decayed(uses ?? 0, since: usesAt ?? now, now: now, halfLife: sessionHalfLife)
        return (previous + 1, now)
    }

    /// 常用度：两个来源各自衰减到现在、取对数后取大的。
    nonisolated static func level(sessions: Double?, sessionsAt: Double?,
                                  spotlightUses: Int?, spotlightLastUsed: Double?, now: Double) -> Double {
        let own = decayed(sessions ?? 0, since: sessionsAt ?? now, now: now, halfLife: sessionHalfLife)
        // 没有上次打开的时间就不信这个次数（Spotlight 偶尔只有一半的元数据）
        let spot = spotlightLastUsed.map {
            decayed(Double(max(0, spotlightUses ?? 0)), since: $0, now: now, halfLife: spotlightHalfLife)
        } ?? 0
        return log2(1 + max(own, spot))
    }

    nonisolated static func prior(level: Double) -> Int {
        level >= levelForTwo ? 2 : level >= levelForOne ? 1 : 0
    }

    /// 按常用度稳定重排（高的在前，同档保持原来的顺序）。有输入时拿它去排：`TabSearch.rank` 是稳定排序，
    /// 同分的就按这个顺序 —— 先看常用度，再看最近用过。
    nonisolated static func byPrior<T>(_ items: [T], prior: (T) -> Int) -> [T] {
        items.enumerated().sorted { a, b in
            let x = prior(a.element), y = prior(b.element)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// 面板里 App 的默认顺序：最近用过的在前（切到前台和 Spotlight 上次打开取新的），一样新的
    /// 看常用度，都没有记录的按名字。有输入时 `TabSearch.rank` 先按匹配度、同分保持这个顺序。
    ///
    /// 运行中的不再整组排前面（2026-10-26 用户定的）：开机自启的菜单栏工具一直在跑、十天没碰过，
    /// 也会占掉「应用」段只有四条的名额。正在用的 App 最近切到过前台，按时间本来就在前面。
    nonisolated static func precedes(usedA: Double?, priorA: Int, nameA: String,
                                     usedB: Double?, priorB: Int, nameB: String) -> Bool {
        switch (usedA, usedB) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if priorA != priorB { return priorA > priorB }
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
    }
}
