// 「是不是刚升级」的启动判定验证（刚升级 → 给个「已更新到 x」）。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/ReleaseNotes.swift \
//          Sources/tabflick/ReleaseNotesParser.swift Sources/tabflick/GitHubReleases.swift Sources/tabflick/UpdateFeed.swift \
//          Sources/tabflick/L10n.swift Sources/tabflick/L10nTables.swift Sources/tabflick/Log.swift \
//          checks/release-notes-decision-check.swift -o /tmp/notesdecide && /tmp/notesdecide
//
// 这几条错了都不报错：全新安装弹「已更新」、升级了却没有提示，要等下一次真实升级才看得见。
// 升级后原来还会自动弹说明窗口（取不到留 pending 下次再试），2026-11-25 撤了，这里只剩判定本身。

import Foundation

@MainActor
func checkDecisions() {
    var cases = 0
    var failures = 0

    func expect(_ name: String, lastRun: String?, everChecked: Bool, current: String, want: Bool) {
        cases += 1
        let got = ReleaseNotes.justUpgraded(lastRun: lastRun, everChecked: everChecked, current: current)
        if got == want {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)：期望 \(want)，实际 \(got)")
        }
    }

    print("全新安装：第一次启动那一刻还没查过更新，不算升级")
    expect("干净的机器", lastRun: nil, everChecked: false, current: "0.13.0", want: false)

    print("从还没有 lastRun 记录的老版本升上来：查过更新（升级就是这么来的）")
    expect("老用户升级", lastRun: nil, everChecked: true, current: "0.13.0", want: true)

    print("常规升级")
    expect("0.27.4 → 0.27.5", lastRun: "0.27.4", everChecked: true, current: "0.27.5", want: true)
    expect("lastRun 有记录时不看旁证", lastRun: "0.27.4", everChecked: false, current: "0.27.5", want: true)

    print("同一个版本重启：不提示")
    expect("普通重启", lastRun: "0.27.5", everChecked: true, current: "0.27.5", want: false)

    print("降级也算版本变了")
    expect("0.27.5 → 0.27.4", lastRun: "0.27.5", everChecked: true, current: "0.27.4", want: true)

    print(failures == 0
          ? "\n全部通过（\(cases) 条）"
          : "\n\(failures) 项失败（共 \(cases) 条）")
    if failures > 0 { fatalError("升级判定校验未通过") }
}

@main
enum ReleaseNotesDecisionCheck {
    static func main() {
        // 失败走 fatalError → abort()，不 flush stdio；管道模式全缓冲会把详情吞掉
        setvbuf(stdout, nil, _IONBF, 0)
        MainActor.assumeIsolated { checkDecisions() }
    }
}
