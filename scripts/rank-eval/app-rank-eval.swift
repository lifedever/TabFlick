// App 排序的回放评测（2026-10-26）：拿本机搜索记忆里「打了什么 → 选了哪个 App」逐条回放，
// 每条先从记忆里扣掉这一次（近似「选之前那一刻」），看新旧两套排序里选中的那个排第几。
// 调 AppRanking / SearchMemory 的参数时跑一遍，比靠感觉准。只读本机数据，不写任何东西。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/TabSearch.swift Sources/tabflick/Pinyin.swift \
//     Sources/tabflick/SearchMemory.swift Sources/tabflick/AppRanking.swift Sources/tabflick/Log.swift \
//     ../scripts/rank-eval/app-rank-eval.swift \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker ../scripts/rank-eval/Info.plist \
//     -o /tmp/rankeval && CFFIXED_USER_HOME=/tmp/rankeval-home /tmp/rankeval [-v] [-letters]
//
// 嵌一份 Info.plist 是为了让 App 名按简体中文显示（和真实面板一致）；命令行程序默认按英文。
// 局限：记忆本身是旧排序下攒出来的（旧排序没排出来的那次选择根本不会发生），「运行中」取的是此刻
// 而不是当时；自己记的前台次数（新加的）还没攒，只有 Spotlight 那一半常用度。

import AppKit
import CoreServices

private struct App {
    let name: String, alias: String?, path: String, bundleID: String?, comment: String?
    let lastUsed: Date?, useCount: Int?
}

@main
struct AppRankEval {
    static func main() {
        let verbose = CommandLine.arguments.contains("-v")
        let home = "/Users/" + NSUserName()
        let support = home + "/Library/Application Support/TabFlick/"
        let apps = scan(home: home)
        let now = Date().timeIntervalSince1970

        var activated: [String: Double] = [:]
        var sessions: [String: (Double, Double)] = [:]
        if let data = FileManager.default.contents(atPath: support + "app-activity.json"),
           let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for r in records {
                guard let key = r["key"] as? String, let at = r["at"] as? Double else { continue }
                activated[key] = at
                if let uses = r["uses"] as? Double, let usesAt = r["usesAt"] as? Double { sessions[key] = (uses, usesAt) }
            }
        }
        guard let memoryData = FileManager.default.contents(atPath: support + "search-memory.json"),
              let table = try? JSONDecoder().decode(SearchMemory.Table.self, from: memoryData) else {
            print("读不到 search-memory.json"); return
        }
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        func isRunning(_ a: App) -> Bool { a.bundleID.map { runningIDs.contains($0) } ?? runningPaths.contains(a.path) }
        func used(_ a: App) -> Double? {
            [activated[a.bundleID ?? a.path], a.lastUsed?.timeIntervalSince1970].compactMap { $0 }.max()
        }
        func prior(_ a: App) -> Int {
            let s = sessions[a.bundleID ?? a.path]
            return AppRanking.prior(level: AppRanking.level(sessions: s?.0, sessionsAt: s?.1, spotlightUses: a.useCount,
                                                            spotlightLastUsed: a.lastUsed?.timeIntervalSince1970, now: now))
        }

        // 旧：运行中的整组在前，再按最近用过、名字
        let oldOrder = apps.sorted { a, b in
            if isRunning(a) != isRunning(b) { return isRunning(a) }
            switch (used(a), used(b)) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let priors = Dictionary(uniqueKeysWithValues: apps.map { ($0.path, prior($0)) })
        // 新：AppRanking.precedes 是没输入时的顺序；有输入时再按常用度稳定重排（同模型里的 appsByPrior）
        let newOrder = AppRanking.byPrior(apps.sorted { a, b in
            AppRanking.precedes(usedA: used(a), priorA: priors[a.path]!, nameA: a.name,
                                usedB: used(b), priorB: priors[b.path]!, nameB: b.name)
        }, prior: { priors[$0.path]! })
        func candidates(_ list: [App]) -> [SearchCandidate] {
            list.map { a in
                let title = [a.name, a.comment].compactMap { $0 }.joined(separator: " ")
                let py = Pinyin.index(title)
                return SearchCandidate(title: title, url: a.bundleID ?? "", pinyin: py.full, initials: py.initials,
                                       identity: a.path, name: a.name, alias: a.alias, abbreviations: true)
            }
        }
        let oldCandidates = candidates(oldOrder), newCandidates = candidates(newOrder)

        // 旧的记忆加分：线性、4 次封顶、前缀不打折
        func oldBoosts(_ t: SearchMemory.Table, _ query: String) -> [String: Int] {
            let key = SearchMemory.normalize(query)
            var out: [String: Int] = [:]
            for (stored, entries) in t where stored.hasPrefix(key) || key.hasPrefix(stored) {
                for (id, e) in entries {
                    let v = Int((min(SearchMemory.effective(e, now: now), 4) * 3).rounded())
                    if v > (out[id] ?? 0) { out[id] = v }
                }
            }
            return out
        }
        func rank(_ cands: [SearchCandidate], _ list: [App], _ q: String, _ boosts: [String: Int], target: String) -> Int? {
            let order = TabSearch.rankScored(cands, query: q, boosts: boosts)
            return order.firstIndex { list[$0.index].path == target }.map { $0 + 1 }
        }
        func top(_ cands: [SearchCandidate], _ list: [App], _ q: String, _ boosts: [String: Int]) -> String {
            TabSearch.rankScored(cands, query: q, boosts: boosts).prefix(4).map { list[$0.index].name }.joined(separator: " / ")
        }

        let paths = Set(apps.map(\.path))
        var cases = 0
        var oldTop1 = 0, newTop1 = 0, oldTop4 = 0, newTop4 = 0
        var oldRR = 0.0, newRR = 0.0
        var changed: [String] = []
        for (query, entries) in table.sorted(by: { $0.key < $1.key }) {
            for (identity, entry) in entries.sorted(by: { $0.key < $1.key }) where paths.contains(identity) {
                var t = table
                if entry.count > 1 {
                    t[query]?[identity] = SearchMemory.Entry(count: entry.count - 1, last: entry.last)
                } else {
                    t[query]?[identity] = nil
                }
                let newBoosts = SearchMemory.boosts(t, query: query, now: now)
                let o = rank(oldCandidates, oldOrder, query, oldBoosts(t, query), target: identity)
                let n = rank(newCandidates, newOrder, query, newBoosts, target: identity)
                cases += 1
                if o == 1 { oldTop1 += 1 }; if n == 1 { newTop1 += 1 }
                if (o ?? 99) <= 4 { oldTop4 += 1 }; if (n ?? 99) <= 4 { newTop4 += 1 }
                oldRR += o.map { 1 / Double($0) } ?? 0
                newRR += n.map { 1 / Double($0) } ?? 0
                if o != n {
                    let name = apps.first { $0.path == identity }!.name
                    var line = "「\(query)」→ \(name)：第 \(o.map(String.init) ?? "-") → 第 \(n.map(String.init) ?? "-")"
                    if verbose {
                        line += "\n    旧：\(top(oldCandidates, oldOrder, query, oldBoosts(t, query)))"
                        line += "\n    新：\(top(newCandidates, newOrder, query, newBoosts))"
                    }
                    changed.append(line)
                }
            }
        }
        func pct(_ x: Int) -> String { String(format: "%.0f%%", 100 * Double(x) / Double(max(cases, 1))) }
        print("回放 \(cases) 条「输入 → 选中的 App」（\(apps.count) 个 App，\(priors.values.filter { $0 > 0 }.count) 个有常用度）")
        print("          排第一   前四（「全部」里看得到）   MRR")
        print(String(format: "旧排序    %@      %@                       %.3f", pct(oldTop1), pct(oldTop4), oldRR / Double(max(cases, 1))))
        print(String(format: "新排序    %@      %@                       %.3f", pct(newTop1), pct(newTop4), newRR / Double(max(cases, 1))))
        print("\n名次有变化的 \(changed.count) 条：")
        changed.forEach { print("  " + $0) }

        // 单个字母的前四（「全部」里「应用」段的样子）：回放只能评已经发生过的选择，
        // 「打 d 该出钉钉却出了下载工具」这种没被选过的看不到，所以把前四直接列出来对照
        if CommandLine.arguments.contains("-letters") {
            print("\n单个字母的前四（旧 → 新，只列有变化的）：")
            for letter in "abcdefghijklmnopqrstuvwxyz".map(String.init) {
                let nb = SearchMemory.boosts(table, query: letter, now: now)
                let o = top(oldCandidates, oldOrder, letter, oldBoosts(table, letter))
                let n = top(newCandidates, newOrder, letter, nb)
                if o != n { print("  \(letter)  \(o)\n     \(n)") }
            }
        }
    }

    /// 同 AppCatalog.scan（那个是 @MainActor 的类，带一堆依赖，这里抄一份最小的）。
    private static func scan(home: String) -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [App] = []
        for dir in ["/Applications", "/Applications/Utilities", home + "/Applications",
                    "/System/Applications", "/System/Applications/Utilities"] {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                var name = fm.displayName(atPath: path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                let info = Bundle(url: url)?.infoDictionary ?? [:]
                let raw = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
                let comment = item.flatMap { MDItemCopyAttribute($0, kMDItemFinderComment) as? String }
                out.append(App(name: name, alias: raw == name ? nil : raw, path: path,
                               bundleID: Bundle(url: url)?.bundleIdentifier,
                               comment: comment?.isEmpty == false ? comment : nil,
                               lastUsed: item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date },
                               useCount: item.flatMap { (MDItemCopyAttribute($0, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue }))
            }
        }
        return out
    }
}
