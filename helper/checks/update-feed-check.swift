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

// 真实样本：v0.27.4 的发布说明原文，和 releases.atom 里 GitHub 渲染出来的 HTML（2026-11-25 取的）
let notes0274Markdown = #"""
## 更新内容

- **有新版本时发系统通知，不再弹窗** — 自动检查查到新版本，发一条系统通知，写着这一版改了哪几项，点开进设置 → 关于。每一版只通知一次，「跳过此版本」去掉了。第一次会问是否允许 TabFlick 发通知
- **更新窗口写着改了什么** — 在「关于」里点「更新到 x…」，窗口里列出当前版本之后每一版的更新内容，点「立即更新」下载安装，装完自动重启。菜单栏的「检查更新…」查到新版本也直接打开这个窗口
- **从更新窗口装完不再弹「更新内容」** — 重启后屏幕底部提示一句「已更新到 x」

> 这一版还是用原来的方式更新上来的，从下一版开始改成通知。扩展没有改动，不用重新加载。

## What's New

- **Updates arrive as a notification, not a pop-up** — When the automatic check finds a new version, a notification lists what changed; clicking it opens Settings → About. Each version is announced once, so "Skip This Version" is gone. macOS asks once whether TabFlick may send notifications
- **The update window shows what changed** — Click "Update to x…" in About to see the notes of every version after the one installed. "Update Now" downloads and installs it, then TabFlick restarts. "Check for Updates…" in the menu bar opens the same window when there's a new version
- **No What's New window after updating from there** — After the restart, a short "Updated to x" message appears at the bottom of the screen instead

> This version still installs the old way; notifications start with the next update. The extension is unchanged; no need to reload it.

系统要求 macOS 14+、Chromium 系浏览器 116+。Requires macOS 14+ and a Chromium-based browser 116+.

### Download
| File | For |
|------|-----|
| TabFlick-0.27.4-arm64.dmg | Apple Silicon (M1/M2/M3/M4) |
| TabFlick-0.27.4-x86_64.dmg | Intel |
| TabFlick-Extension.zip | 浏览器扩展 / Browser extension（0.25.2） |
"""#

let notes0274AtomHTML = #"""
<h2>更新内容</h2>
<ul>
<li><strong>有新版本时发系统通知，不再弹窗</strong> — 自动检查查到新版本，发一条系统通知，写着这一版改了哪几项，点开进设置 → 关于。每一版只通知一次，「跳过此版本」去掉了。第一次会问是否允许 TabFlick 发通知</li>
<li><strong>更新窗口写着改了什么</strong> — 在「关于」里点「更新到 x…」，窗口里列出当前版本之后每一版的更新内容，点「立即更新」下载安装，装完自动重启。菜单栏的「检查更新…」查到新版本也直接打开这个窗口</li>
<li><strong>从更新窗口装完不再弹「更新内容」</strong> — 重启后屏幕底部提示一句「已更新到 x」</li>
</ul>
<blockquote>
<p>这一版还是用原来的方式更新上来的，从下一版开始改成通知。扩展没有改动，不用重新加载。</p>
</blockquote>
<h2>What's New</h2>
<ul>
<li><strong>Updates arrive as a notification, not a pop-up</strong> — When the automatic check finds a new version, a notification lists what changed; clicking it opens Settings → About. Each version is announced once, so "Skip This Version" is gone. macOS asks once whether TabFlick may send notifications</li>
<li><strong>The update window shows what changed</strong> — Click "Update to x…" in About to see the notes of every version after the one installed. "Update Now" downloads and installs it, then TabFlick restarts. "Check for Updates…" in the menu bar opens the same window when there's a new version</li>
<li><strong>No What's New window after updating from there</strong> — After the restart, a short "Updated to x" message appears at the bottom of the screen instead</li>
</ul>
<blockquote>
<p>This version still installs the old way; notifications start with the next update. The extension is unchanged; no need to reload it.</p>
</blockquote>
<p>系统要求 macOS 14+、Chromium 系浏览器 116+。Requires macOS 14+ and a Chromium-based browser 116+.</p>
<h3>Download</h3>
<table>
<thead>
<tr>
<th>File</th>
<th>For</th>
</tr>
</thead>
<tbody>
<tr>
<td>TabFlick-0.27.4-arm64.dmg</td>
<td>Apple Silicon (M1/M2/M3/M4)</td>
</tr>
<tr>
<td>TabFlick-0.27.4-x86_64.dmg</td>
<td>Intel</td>
</tr>
<tr>
<td>TabFlick-Extension.zip</td>
<td>浏览器扩展 / Browser extension（0.25.2）</td>
</tr>
</tbody>
</table>
"""#

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

        print("网页侧（API 被限流时）：GitHub 渲染的 HTML 转回 markdown")
        for heading in ["更新内容", "What's New"] {
            let fromHTML = ReleaseNotesParser.blocks(from: ReleaseNotesParser.section(
                from: UpdateFeed.markdown(fromReleaseHTML: notes0274AtomHTML), heading: heading))
            let fromMarkdown = ReleaseNotesParser.blocks(from: ReleaseNotesParser.section(
                from: notes0274Markdown, heading: heading))
            check("「\(heading)」切出来的块和原文一模一样（\(fromMarkdown.count) 块）",
                  fromHTML == fromMarkdown && !fromMarkdown.isEmpty,
                  "\n    HTML: \(fromHTML)\n    原文: \(fromMarkdown)")
        }
        check("通知摘要两条路一样",
              UpdateFeed.summary(of: UpdateFeed.markdown(fromReleaseHTML: notes0274AtomHTML), heading: "更新内容")
                  == UpdateFeed.summary(of: notes0274Markdown, heading: "更新内容"))
        let converted = UpdateFeed.markdown(fromReleaseHTML: notes0274AtomHTML)
        check("下载表格丢掉", !converted.contains("arm64.dmg") && !converted.contains("<"), converted)
        let link = UpdateFeed.markdown(fromReleaseHTML:
            #"<ul><li><strong>插件开发文档</strong> — 想写插件，看 <a href="https://github.com/lifedever/TabFlick/blob/main/plugins/README.md">plugins/README.md</a>：manifest、API</li></ul>"#)
        check("链接转回 [文字](地址)",
              link == "- **插件开发文档** — 想写插件，看 [plugins/README.md](https://github.com/lifedever/TabFlick/blob/main/plugins/README.md)：manifest、API",
              link.debugDescription)
        let code = UpdateFeed.markdown(fromReleaseHTML:
            "<ul>\n<li><strong>打开方式</strong> — 没有 App 认领的文件（比如 <code>.mdd</code>）列出能打开纯文本的 App</li>\n</ul>")
        check("行内代码转回反引号", code == "- **打开方式** — 没有 App 认领的文件（比如 `.mdd`）列出能打开纯文本的 App",
              code.debugDescription)
        let entities = UpdateFeed.markdown(fromReleaseHTML: "<p>&quot;Later&quot; &amp; it&#39;s &#x2014; a &amp;lt;b&amp;gt;</p>")
        check("实体解开，&amp; 最后解（&amp;lt; 是字面的 &lt;）", entities == "\"Later\" & it's — a &lt;b&gt;",
              entities.debugDescription)
        let multi = UpdateFeed.markdown(fromReleaseHTML: "<blockquote>\n<p>第一段</p>\n<p>第二段</p>\n</blockquote>\n<li>跨\n行</li>")
        check("引用里的多段各自成行、列表项里的换行并成空格", multi == "> 第一段\n> 第二段\n\n- 跨 行", multi.debugDescription)

        print("网页侧：atom、跳转地址、拼出更新")
        let atom = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>随便起的名字</title>
            <link rel="alternate" type="text/html" href="https://github.com/lifedever/TabFlick/releases/tag/v0.27.4"/>
            <link rel="related" href="https://github.com/lifedever/TabFlick/releases/tag/v0.1.0"/>
            <content type="html">&lt;h2&gt;更新内容&lt;/h2&gt;
        &lt;ul&gt;
        &lt;li&gt;&lt;strong&gt;甲&lt;/strong&gt; — 说明&lt;/li&gt;
        &lt;/ul&gt;</content>
          </entry>
          <entry>
            <title>v0.27.3</title>
            <link rel="alternate" type="text/html" href="https://github.com/lifedever/TabFlick/releases/tag/v0.27.3"/>
            <content type="html"><![CDATA[<h2>更新内容</h2><ul><li><strong>乙</strong></li></ul>]]></content>
          </entry>
          <entry>
            <title>不是 release 的条目</title>
            <link rel="alternate" type="text/html" href="https://github.com/lifedever/TabFlick/commits"/>
            <content type="html">x</content>
          </entry>
        </feed>
        """
        let atomNotes = UpdateFeed.atomNotes(from: Data(atom.utf8))
        check("版本取链接里的 tag 不取标题，认不出的条目跳过",
              atomNotes.map(\.version) == ["0.27.4", "0.27.3"], "实际 \(atomNotes.map(\.version))")
        check("XML 转义和 CDATA 都解开成 markdown",
              atomNotes.first?.body == "## 更新内容\n\n- **甲** — 说明" && atomNotes.last?.body == "## 更新内容\n\n- **乙**",
              "实际 \(atomNotes.map(\.body))")
        check("坏 XML 给空", UpdateFeed.atomNotes(from: Data("<feed><entry>".utf8)).isEmpty)

        let base = "https://github.com/lifedever/TabFlick/releases/"
        check("跳转地址取 tag", UpdateFeed.tag(fromReleaseURL: URL(string: base + "tag/v0.27.4")!) == "v0.27.4")
        check("跳到发布列表 / 登录页不算",
              UpdateFeed.tag(fromReleaseURL: URL(string: base)!) == nil
                  && UpdateFeed.tag(fromReleaseURL: URL(string: "https://github.com/login?return_to=x")!) == nil)
        check("路径里有 tag 但不在 releases 下不算",
              UpdateFeed.tag(fromReleaseURL: URL(string: "https://github.com/topics/tag/v1.0")!) == nil)
        check("tag 里有怪字符不收（要拼进下载地址）",
              UpdateFeed.tag(fromReleaseURL: URL(string: base + "tag/v1%22%3Bx")!) == nil)

        let webNotes = [ReleaseNote(version: "0.27.2", body: "B"), ReleaseNote(version: "0.27.4", body: "D"),
                        ReleaseNote(version: "0.28.0", body: "预发布"), ReleaseNote(version: "0.27.3", body: "C"),
                        ReleaseNote(version: "0.27.1", body: "A")]
        let web = UpdateFeed.offer(latestTag: "v0.27.4", notes: webNotes, current: "0.27.1", arch: "arm64",
                                   repo: "lifedever/TabFlick")
        check("按契约拼安装包地址、大小未知",
              web?.assetURL?.absoluteString == "https://github.com/lifedever/TabFlick/releases/download/v0.27.4/TabFlick-0.27.4-arm64.dmg"
                  && web?.assetSize == 0, "实际 \(web?.assetURL?.absoluteString ?? "nil")")
        check("说明只要当前之后、最新那版及以前的，新的在前",
              web?.notes.map(\.version) == ["0.27.4", "0.27.3", "0.27.2"], "实际 \(web?.notes.map(\.version) ?? [])")
        check("已是最新返回 nil", UpdateFeed.offer(latestTag: "v0.27.4", notes: webNotes, current: "0.27.4",
                                              arch: "arm64", repo: "lifedever/TabFlick") == nil)
        check("怪 tag 返回 nil（版本号照样比得出来更新）",
              UpdateFeed.offer(latestTag: "v9.0.0\"$(x)", notes: [], current: "0.1.0",
                               arch: "arm64", repo: "lifedever/TabFlick") == nil)
        let manyWeb = (1...15).map { ReleaseNote(version: "1.0.\($0)", body: "") }
        check("网页侧也最多 \(UpdateFeed.maxNotes) 版",
              UpdateFeed.offer(latestTag: "v1.0.15", notes: manyWeb, current: "0.9.0", arch: "arm64",
                               repo: "x/y")?.notes.count == UpdateFeed.maxNotes)

        print(failures == 0 ? "\n全部通过（\(cases) 条）" : "\n\(failures) 项失败（共 \(cases) 条）")
        if failures > 0 { fatalError("更新检查校验未通过") }
    }
}
