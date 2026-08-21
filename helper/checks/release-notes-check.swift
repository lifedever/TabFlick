// ReleaseNotes 解析的验证。
//
// 跑法（在 helper/ 下，需要网络）：
//   swiftc -parse-as-library Sources/tabflick/ReleaseNotesParser.swift \
//          checks/release-notes-check.swift -o /tmp/notescheck && /tmp/notescheck
//
// 为什么单独验：解析的输入是**手写的 markdown**，不是结构化数据。挑错段落
// 用户会看到另一种语言，挑漏了会看到一个空窗 —— 两种都不报错。所以拿真实
// 发布过的说明当样本，而不是自己编一份「格式一定对」的假数据。

func check(_ name: String, _ ok: Bool, _ detail: String = "") -> Int {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    return ok ? 0 : 1
}

/// v0.6.0 线上发布说明的真实结构（节选，保留全部结构特征：
/// 双语小标题、粗体、引用块、行内链接、末尾的下载表格）。
let realBody = """
## 更新内容

- **全局切换器（新）** — 在浏览器之外的任何应用里按下快捷键，列出**所有**已连接浏览器的标签
- **标签存活时间新增长周期** — 增加 **1 个月 / 3 个月 / 半年 / 1 年**
- **修复** 在浏览器关闭状态下删除置顶记录，重开浏览器后置顶会复活

> 本次扩展有更新：下载下方 TabFlick-Extension.zip，替换后重新加载。首次安装见[扩展安装说明](https://www.lifedever.com/TabFlick/install-extension.html)。

## What's New

- **Global switcher (new)** — press the shortcut from any app outside your browsers
- **Longer tab lifetimes** — you can now pick **1 month / 3 months / 6 months / 1 year**
- **Fixed** deleting a pinned entry while its browser was closed

> The extension changed in this release: download TabFlick-Extension.zip below and reload it.

系统要求 macOS 14+、Chromium 系浏览器 116+。Requires macOS 14+ and a Chromium-based browser 116+.

### Download
| File | For |
|------|-----|
| TabFlick-0.6.0-arm64.dmg | Apple Silicon (M1/M2/M3/M4) |
| TabFlick-Extension.zip | 浏览器扩展 / Browser extension |
"""

@main
struct Check {
    static func main() {
        var failures = 0

        // —— 中文段 ——
        let zh = ReleaseNotesParser.section(from: realBody, heading: "更新内容")
        failures += check("中文段含中文条目", zh.contains("全局切换器（新）"))
        failures += check("中文段不含英文条目", !zh.contains("Global switcher"),
                          "挑错段落 = 用户看到另一种语言")
        failures += check("中文段不含下载表格", !zh.contains("arm64.dmg"))

        // —— 英文段 ——
        let en = ReleaseNotesParser.section(from: realBody, heading: "What's New")
        failures += check("英文段含英文条目", en.contains("Global switcher (new)"))
        failures += check("英文段不含中文条目", !en.contains("全局切换器（新）"))
        failures += check("英文段不含下载表格", !en.contains("| File |"))

        // —— 弯引号（说明是手写的，撇号随时会变成 ’）——
        //
        // 断言必须是「只拿到英文段」而不是「结果里有英文」：归一化一旦失效，
        // 小标题匹配不上会掉进「整篇兜底」，兜底结果里当然也有英文 ——
        // 只查 contains 的话这条用例会被兜底蒙混过去（第一版就是这样，
        // 变异测试才发现它是空跑的）。
        let curly = realBody.replacingOccurrences(of: "What's New", with: "What\u{2019}s New")
        let curlySection = ReleaseNotesParser.section(from: curly, heading: "What's New")
        failures += check("弯引号小标题仍能命中", curlySection.contains("Global switcher"))
        failures += check("弯引号命中的是英文段本身、不是整篇兜底",
                          !curlySection.contains("全局切换器（新）"),
                          "掉进兜底了")

        // 大小写：说明是在 GitHub 网页上可以随手改的，别因为改成全大写就失灵
        let upper = realBody.replacingOccurrences(of: "## What's New", with: "## WHAT'S NEW")
        let upperSection = ReleaseNotesParser.section(from: upper, heading: "What's New")
        failures += check("小标题大小写变了仍命中英文段",
                          upperSection.contains("Global switcher") && !upperSection.contains("全局切换器（新）"))

        // —— 认不出结构时的兜底：不能给出空段 ——
        let weird = "Just a plain changelog line.\n- some bullet\n\n### Download\n| a | b |"
        let fallback = ReleaseNotesParser.section(from: weird, heading: "更新内容")
        failures += check("无小标题时退回整篇", fallback.contains("some bullet"))
        failures += check("兜底也砍掉下载表格", !fallback.contains("| a | b |"))
        failures += check("完全空的输入返回空", ReleaseNotesParser.section(from: "", heading: "更新内容").isEmpty)

        // —— 分块 ——
        let blocks = ReleaseNotesParser.blocks(from: zh)
        let bullets = blocks.filter { if case .bullet = $0 { return true }; return false }
        let callouts = blocks.filter { if case .callout = $0 { return true }; return false }
        failures += check("三个条目都解析成 bullet", bullets.count == 3, "实际 \(bullets.count)")
        failures += check("引用块解析成 callout", callouts.count == 1, "实际 \(callouts.count)")
        failures += check("bullet 去掉了行首的「- 」",
                          bullets.contains { if case .bullet(let t) = $0 { return t.hasPrefix("**全局切换器") }; return false })
        failures += check("不产生空块", !blocks.contains { block in
            switch block {
            case .bullet(let t), .callout(let t), .paragraph(let t):
                return t.trimmingCharacters(in: .whitespaces).isEmpty
            }
        })

        // 表格行即使漏进来也不渲染
        let tableLeak = ReleaseNotesParser.blocks(from: "| File | For |\n|---|---|\n- real bullet")
        failures += check("表格行不渲染", tableLeak.count == 1, "实际 \(tableLeak.count)")

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        if failures > 0 { fatalError("ReleaseNotes 解析校验未通过") }
    }
}
