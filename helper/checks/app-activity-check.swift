// AppActivity 的校验：App 切到前台记录的存盘整理。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/AppActivity.swift checks/app-activity-check.swift \
//          -o /tmp/activitycheck && /tmp/activitycheck
//
// 期望值一律手写。

import Foundation

private typealias Record = AppActivity.Record

private func rec(_ key: String, _ at: Double, path: String? = nil, name: String = "App") -> Record {
    Record(key: key, at: at, path: path ?? "/Applications/\(key).app", name: name, bundleID: key)
}

private let now: Double = 1_000_000_000
private let day: Double = 86_400

@main
struct AppActivityCheck {
    static func main() {
        var failures = 0
        func expect(_ name: String, _ got: [Record], _ want: [Record]) {
            if got != want {
                failures += 1
                print("✗ \(name)：期望 \(want.map { "\($0.key)@\($0.at)" })，实际 \(got.map { "\($0.key)@\($0.at)" })")
            }
        }

        expect("同一个 key 留最新的",
               AppActivity.pruned([rec("a", now - 100), rec("a", now - 10), rec("a", now - 50)], now: now),
               [rec("a", now - 10)])
        expect("按时间新的在前",
               AppActivity.pruned([rec("a", now - 300), rec("b", now - 100), rec("c", now - 200)], now: now),
               [rec("b", now - 100), rec("c", now - 200), rec("a", now - 300)])
        expect("一周前的丢掉",
               AppActivity.pruned([rec("a", now - 7 * day - 1), rec("b", now - 6 * day)], now: now),
               [rec("b", now - 6 * day)])
        expect("将来的夹到现在",
               AppActivity.pruned([rec("a", now + 3600)], now: now),
               [rec("a", now)])
        expect("看着不对的丢掉",
               AppActivity.pruned([rec("", now - 1), rec("b", now - 1, path: "relative/b.app"),
                                   rec("c", now - 1, name: ""), rec("d", .nan), rec("e", now - 1)], now: now),
               [rec("e", now - 1)])
        let many = (0..<250).map { rec("k\($0)", now - Double($0)) }
        let capped = AppActivity.pruned(many, now: now)
        if capped.count != AppActivity.maxRecords || capped.first?.key != "k0" || capped.last?.key != "k199" {
            failures += 1
            print("✗ 截到上限：条数 \(capped.count)，首 \(capped.first?.key ?? "-")，尾 \(capped.last?.key ?? "-")")
        }
        expect("解不开当没有", AppActivity.decode(Data("not json".utf8), now: now), [])
        expect("没有文件当没有", AppActivity.decode(nil, now: now), [])
        let roundTrip = try! JSONEncoder().encode([rec("a", now - 5), rec("b", now - 7 * day - 5)])
        expect("读回来也整理", AppActivity.decode(roundTrip, now: now), [rec("a", now - 5)])

        // 切走的时间（left）：老文件里没有这个字段照常读；在将来的夹到现在；不是有效数字的丢掉
        let legacy = Data(#"[{"key":"a","at":\#(now - 5),"path":"/Applications/a.app","name":"A","bundleID":"a"}]"#.utf8)
        let legacyRead = AppActivity.decode(legacy, now: now)
        if legacyRead.count != 1 || legacyRead.first?.left != nil {
            failures += 1
            print("✗ 老文件没有 left：读到 \(legacyRead)")
        }
        var future = rec("a", now - 10); future.left = now + 999
        if AppActivity.pruned([future], now: now).first?.left != now {
            failures += 1
            print("✗ left 在将来没夹到现在")
        }
        var bogus = rec("a", now - 10); bogus.left = .infinity
        if AppActivity.pruned([bogus], now: now).first.map({ $0.left != nil }) != false {
            failures += 1
            print("✗ left 不是有效数字没丢掉")
        }

        let total = 12
        print(failures == 0 ? "全部通过（\(total) 组）" : "\(failures) 项失败（共 \(total) 组）")
        if failures > 0 { fatalError("AppActivity 校验未通过") }
    }
}
