// 更新检查的纯逻辑验证：挑哪一版、收哪几版的说明、认哪个包、通知正文怎么摘。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/UpdateFeed.swift Sources/tabflick/ReleaseNotesParser.swift \
//          checks/update-feed-check.swift -o /tmp/updatefeedcheck && /tmp/updatefeedcheck
//
// 这里错了都不报错：挑错版本是装错包，漏挑是「有新版却说已是最新」，说明挑多了
// 更新窗口里列出早就装过的改动，摘要摘错了通知里是半句话。样本取自真实发布过的说明。

import Foundation

let body0273 = """
## 更新内容

- **新插件：黄金** — 伦敦金（美元/盎司，也折成元/克）、上金所 Au99.99 和 Au(T+D)，可以放进菜单栏。在设置 → 插件 →「可安装」里装
- **在插件列表里就能更新插件** — 插件有新版本时，底栏插件名旁边出现「更新到 x」，点了就地装好
- **按住 ⌥ 看 App 版本号** — 快捷搜索里按住 ⌥，App 那一行第二行末尾写版本号，松开就收起

## What's New

- **New plugin: Gold** — Live prices for London gold (USD/oz, also in CNY/g), SGE Au99.99 and Au(T+D). Can live in the menu bar
- **Update a plugin from its list** — When a plugin has a new version, an "Update to x" button appears next to the plugin name
- **Hold ⌥ to see app versions** — In Quick Search, holding ⌥ adds the version to the end of each app's second line

系统要求 macOS 14+、Chromium 系浏览器 116+。Requires macOS 14+ and a Chromium-based browser 116+.

### Download
| File | For |
|------|-----|
| TabFlick-0.27.3-arm64.dmg | Apple Silicon (M1/M2/M3/M4) |
"""

let body0262 = """
## 更新内容

- **插件有了自己的图标** — 每个插件一个图标
- **开发工具箱 1.2.0** — 打开先列出全部工具
- **世界时钟 1.2.0** — 列表里的时间显示到秒，一直在走
- **官方插件都有新版本** — 在设置 → 插件里点「全部更新」
- **插件开发文档** — 想写插件，看 [plugins/README.md](https://github.com/lifedever/TabFlick/blob/main/plugins/README.md)：manifest、API

## What's New

- **Plugins have their own icons** — Each plugin has one icon
"""

func release(_ tag: String, body: String = "", draft: Bool = false, prerelease: Bool = false,
             assets: [String] = ["arm64", "x86_64"]) -> [String: Any] {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return [
        "tag_name": tag, "body": body, "draft": draft, "prerelease": prerelease,
        "assets": assets.map { arch -> [String: Any] in
            ["name": "TabFlick-\(version)-\(arch).dmg",
             "browser_download_url": "https://example.com/\(tag)/TabFlick-\(version)-\(arch).dmg",
             "size": NSNumber(value: arch == "arm64" ? 1000 : 2000)]
        } + [["name": "TabFlick-Extension.zip",
              "browser_download_url": "https://example.com/\(tag)/TabFlick-Extension.zip",
              "size": NSNumber(value: 50)]],
    ]
}

var cases = 0
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)  \(detail())")
    }
}

@main
enum UpdateFeedCheck {
    static func main() {
        // 失败走 fatalError → abort()，不 flush stdio；管道模式全缓冲会把详情吞掉
        setvbuf(stdout, nil, _IONBF, 0)

        print("版本号比较")
        check("0.10.0 比 0.9.0 新（不能按字符串比）", UpdateFeed.isNewer("0.10.0", than: "0.9.0"))
        check("0.9.0 不比 0.10.0 新", !UpdateFeed.isNewer("0.9.0", than: "0.10.0"))
        check("1.0 和 1.0.0 一样，不算新", !UpdateFeed.isNewer("1.0", than: "1.0.0"))
        check("同版本不算新", !UpdateFeed.isNewer("0.27.3", than: "0.27.3"))
        check("tag 去掉 v", UpdateFeed.version(fromTag: "v0.27.3") == "0.27.3")
        check("没有 v 的 tag 原样", UpdateFeed.version(fromTag: "0.27.3") == "0.27.3")

        print("挑哪一版")
        let list: [[String: Any]] = [
            release("v0.28.0-beta.1", prerelease: true),
            release("v0.29.0", draft: true),
            release("v0.27.1", body: "0.27.1 的说明"),      // 补发的旧版本排在前面
            release("v0.27.3", body: body0273),
            release("v0.27.2", body: "0.27.2 的说明"),
            release("v0.27.0", body: "0.27.0 的说明"),
            release("v0.26.2", body: body0262),
        ]
        let offer = UpdateFeed.offer(from: list, current: "0.27.0", arch: "arm64")
        check("挑版本号最大的，不按列表顺序", offer?.version == "0.27.3", "实际 \(offer?.version ?? "nil")")
        check("预发布、草稿不算", offer?.version != "0.28.0-beta.1" && offer?.version != "0.29.0")
        check("已是最新返回 nil", UpdateFeed.offer(from: list, current: "0.27.3", arch: "arm64") == nil)
        check("装的比线上还新（开发版）返回 nil，不降级",
              UpdateFeed.offer(from: list, current: "0.30.0", arch: "arm64") == nil)
        check("一个 release 都没有返回 nil", UpdateFeed.offer(from: [], current: "0.1.0", arch: "arm64") == nil)
        let onlyPre = UpdateFeed.offer(from: [release("v9.0.0", prerelease: true)], current: "0.1.0", arch: "arm64")
        check("只有预发布时不提示更新", onlyPre == nil)

        print("收哪几版的说明")
        let versions = offer?.notes.map(\.version) ?? []
        check("只收比当前新的、新的在前", versions == ["0.27.3", "0.27.2", "0.27.1"], "实际 \(versions)")
        check("说明原样带上", offer?.notes.first?.body == body0273)
        let many = (1...15).map { release("v1.0.\($0)") }
        let capped = UpdateFeed.offer(from: many, current: "0.9.0", arch: "arm64")
        check("最多 \(UpdateFeed.maxNotes) 版，留最新的",
              capped?.notes.count == UpdateFeed.maxNotes && capped?.notes.first?.version == "1.0.15"
                  && capped?.notes.last?.version == "1.0.6",
              "实际 \(capped?.notes.map(\.version) ?? [])")
        let dup = UpdateFeed.offer(from: [release("v0.2.0", body: "A"), release("0.2.0", body: "B")],
                                   current: "0.1.0", arch: "arm64")
        check("同一版本出现两次只列一次", dup?.notes.count == 1)

        print("认哪个包")
        check("Apple 芯片拿 arm64 的 DMG",
              offer?.assetURL?.lastPathComponent == "TabFlick-0.27.3-arm64.dmg" && offer?.assetSize == 1000,
              "实际 \(offer?.assetURL?.lastPathComponent ?? "nil")")
        let intel = UpdateFeed.offer(from: list, current: "0.27.0", arch: "x86_64")
        check("Intel 拿 x86_64 的 DMG",
              intel?.assetURL?.lastPathComponent == "TabFlick-0.27.3-x86_64.dmg" && intel?.assetSize == 2000)
        let noIntel = UpdateFeed.offer(from: [release("v0.27.3", assets: ["arm64"])], current: "0.27.0", arch: "x86_64")
        check("这一版漏传了这个架构的包：照样提示，包是 nil（退回发布页）",
              noIntel?.version == "0.27.3" && noIntel?.assetURL == nil && noIntel?.assetSize == 0)

        print("通知正文")
        let zh = UpdateFeed.summary(of: body0273, heading: "更新内容")
        check("取每条开头加粗的小标题，一行一条",
              zh == "新插件：黄金\n在插件列表里就能更新插件\n按住 ⌥ 看 App 版本号", "实际 \(zh.debugDescription)")
        let en = UpdateFeed.summary(of: body0273, heading: "What's New")
        check("英文只拿英文那段，不混进中文和系统要求",
              en == "New plugin: Gold\nUpdate a plugin from its list\nHold ⌥ to see app versions",
              "实际 \(en.debugDescription)")
        let five = UpdateFeed.summary(of: body0262, heading: "更新内容")
        check("最多 4 条", five.components(separatedBy: "\n").count == 4 && !five.contains("插件开发文档"),
              "实际 \(five.debugDescription)")
        let loose = UpdateFeed.summary(of: "## 更新内容\n\n- 修了 **置顶** 偶尔丢失，见 [#12](https://x.y/12)\n", heading: "更新内容")
        check("没有加粗开头的取整条纯文本（去掉 ** 和链接地址）",
              loose == "修了 置顶 偶尔丢失，见 #12", "实际 \(loose.debugDescription)")
        let para = UpdateFeed.summary(of: "## 更新内容\n\n修了一个崩溃。\n\n第二段\n", heading: "更新内容")
        check("没有列表项时取第一段", para == "修了一个崩溃。", "实际 \(para.debugDescription)")
        check("空说明给空串", UpdateFeed.summary(of: "", heading: "更新内容").isEmpty)

        print(failures == 0 ? "\n全部通过（\(cases) 条）" : "\n\(failures) 项失败（共 \(cases) 条）")
        if failures > 0 { fatalError("更新检查校验未通过") }
    }
}
