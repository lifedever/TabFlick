// 「更新内容」窗口该不该弹的启动决策验证。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/ReleaseNotes.swift \
//          Sources/tabflick/ReleaseNotesParser.swift Sources/tabflick/GitHubReleases.swift Sources/tabflick/UpdateFeed.swift \
//          Sources/tabflick/L10n.swift Sources/tabflick/L10nTables.swift Sources/tabflick/Log.swift \
//          checks/release-notes-decision-check.swift -o /tmp/notesdecide && /tmp/notesdecide
//
// 为什么要有这个：这几条分支错了**都不报错**，只会「该弹的不弹」或者「弹了一个
// 早就过时的版本的说明」，而且要等下一次真实升级才看得见。0.12.1 那次就是取说明
// 超时、标记却已经消费掉，这一版的说明从此永久不再弹 —— 拆成 lastRun / pending
// 两个标记之后，规则的组合数上来了，必须穷举着测。
//
// 断言写的是**两个标记的落点 + 要不要取**三件事，不是只看 shouldFetch：
// pending 该留的没留下来，下次启动就接不上；该丢的没丢掉，就会弹过时的说明。

import Foundation

@MainActor
func checkDecisions() {
    var cases = 0
    var failures = 0

    func expect(_ name: String,
                lastRun: String?, pending: String?, everChecked: Bool, current: String,
                seen: String? = nil,
                wantPending: String?, wantFetch: Bool, wantUpgraded: Bool) {
        cases += 1
        let got = ReleaseNotes.decide(lastRun: lastRun, pending: pending,
                                      everChecked: everChecked, current: current,
                                      seenBeforeInstall: seen)
        var problems: [String] = []
        if got.lastRun != current {
            problems.append("lastRun 应写成 \(current)，实际 \(got.lastRun)")
        }
        if got.pending != wantPending {
            problems.append("pending 期望 \(wantPending ?? "nil")，实际 \(got.pending ?? "nil")")
        }
        if got.shouldFetch != wantFetch {
            problems.append("shouldFetch 期望 \(wantFetch)，实际 \(got.shouldFetch)")
        }
        if got.justUpgraded != wantUpgraded {
            problems.append("justUpgraded 期望 \(wantUpgraded)，实际 \(got.justUpgraded)")
        }
        if problems.isEmpty {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)：\(problems.joined(separator: "；"))")
        }
    }

    print("全新安装：第一次启动那一刻还没查过更新，不该弹")
    expect("干净的机器", lastRun: nil, pending: nil, everChecked: false, current: "0.13.0",
           wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("从还没有这个功能的老版本升上来：没有 lastRun，但查过更新（升级就是这么来的）")
    expect("老用户升级", lastRun: nil, pending: nil, everChecked: true, current: "0.13.0",
           wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("常规升级")
    expect("0.12.1 → 0.13.0", lastRun: "0.12.1", pending: nil, everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("同一个版本重启：不该反复弹")
    expect("普通重启", lastRun: "0.13.0", pending: nil, everChecked: true, current: "0.13.0",
           wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("上次没取到说明（网络抖了）：pending 留着，下次启动接着试 —— 0.12.1 那次的修复")
    expect("欠着的说明，重启后继续", lastRun: "0.13.0", pending: "0.13.0", everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: false)

    print("欠着的说明还没弹成，又升了一版：旧的那份已经过时，别弹")
    expect("pending 被新版本顶掉", lastRun: "0.13.0", pending: "0.13.0", everChecked: true,
           current: "0.14.0", wantPending: "0.14.0", wantFetch: true, wantUpgraded: true)

    print("pending 是个对不上的版本（手工改过 / 装回了别的包）：丢掉，不弹过时的")
    expect("pending 过时", lastRun: "0.14.0", pending: "0.13.0", everChecked: true,
           current: "0.14.0", wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("降级也算「版本变了」：弹的是降下去那一版的说明，不是残留的那份")
    expect("0.14.0 → 0.13.0", lastRun: "0.14.0", pending: "0.14.0", everChecked: true,
           current: "0.13.0", wantPending: "0.13.0", wantFetch: true, wantUpgraded: true)

    print("全新安装但 pending 有残留（同机器装过、清过 lastRun）：没升级就不弹")
    expect("只剩 pending 且对不上", lastRun: nil, pending: "0.12.0", everChecked: false,
           current: "0.13.0", wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("从更新窗口点「立即更新」装上来的：说明在那里看过了，不取不弹，但仍算刚升级（给 toast）")
    expect("看过 0.13.0 的说明再装", lastRun: "0.12.1", pending: nil, everChecked: true,
           current: "0.13.0", seen: "0.13.0", wantPending: nil, wantFetch: false, wantUpgraded: true)
    expect("看过的说明盖掉了欠着的旧 pending", lastRun: "0.12.1", pending: "0.12.1", everChecked: true,
           current: "0.13.0", seen: "0.13.0", wantPending: nil, wantFetch: false, wantUpgraded: true)

    print("看过的是别的版本（之后手动拖 DMG 装了另一版）：照常弹")
    expect("看过 0.13.0、装上的是 0.14.0", lastRun: "0.12.1", pending: nil, everChecked: true,
           current: "0.14.0", seen: "0.13.0", wantPending: "0.14.0", wantFetch: true, wantUpgraded: true)

    print("替换失败、旧版本又起来了：没升级，标记不该让它弹任何东西")
    expect("看过 0.13.0、还是 0.12.1", lastRun: "0.12.1", pending: nil, everChecked: true,
           current: "0.12.1", seen: "0.13.0", wantPending: nil, wantFetch: false, wantUpgraded: false)

    print("决策必须是纯的：同样的入参跑两次结果一致（不能偷偷依赖外部状态）")
    cases += 1
    let a = ReleaseNotes.decide(lastRun: "0.13.0", pending: "0.13.0",
                                everChecked: true, current: "0.13.0")
    let b = ReleaseNotes.decide(lastRun: "0.13.0", pending: "0.13.0",
                                everChecked: true, current: "0.13.0")
    if a == b {
        print("  ✓ 同入参同结果")
    } else {
        failures += 1
        print("  ✗ 同入参给出了不同结果：\(a) / \(b)")
    }

    print(failures == 0
          ? "\n全部通过（\(cases) 条）"
          : "\n\(failures) 项失败（共 \(cases) 条）")
    if failures > 0 { fatalError("更新说明启动决策校验未通过") }
}

@main
enum ReleaseNotesDecisionCheck {
    static func main() {
        // 失败走 fatalError → abort()，不 flush stdio；管道模式全缓冲会把详情吞掉
        setvbuf(stdout, nil, _IONBF, 0)
        MainActor.assumeIsolated { checkDecisions() }
    }
}
