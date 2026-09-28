// TabSearch.rank 的匹配与排序校验。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/TabSearch.swift Sources/tabflick/Pinyin.swift \
//          checks/tab-search-check.swift -o /tmp/tabsearchcheck && /tmp/tabsearchcheck
//
// 排错了不报错，用户只会觉得「要找的那条老在下面」。期望值一律手写，
// 不照着实现再推一遍。

import Foundation

private func cand(_ title: String, _ url: String) -> SearchCandidate {
    let py = Pinyin.index(title)
    return SearchCandidate(title: title, url: url, pinyin: py.full, initials: py.initials)
}

private let tabs: [SearchCandidate] = [
    cand("GitHub - lifedever/TabFlick", "https://github.com/lifedever/TabFlick"),   // 0
    cand("TabFlick 官网", "https://lifedever.github.io/TabFlick/"),                   // 1
    cand("Swift Forums", "https://forums.swift.org/"),                                // 2
    cand("掘金 - Swift 并发", "https://juejin.cn/post/123"),                           // 3
    cand("", "https://example.com/flick"),                                            // 4
    cand("Flick review", "https://example.com/review"),                               // 5
    cand("蒙牛集团堡垒机运维平台", "https://mnjms.mengniu.cn/"),                          // 6
    cand("Meng 的博客", "https://meng.example.org/"),                                   // 7
]

private struct Case {
    let name: String
    let query: String
    let want: [Int]
}

private let cases: [Case] = [
    Case(name: "空查询原顺序全返回", query: "", want: [0, 1, 2, 3, 4, 5, 6, 7]),
    Case(name: "纯空白同空查询", query: "   ", want: [0, 1, 2, 3, 4, 5, 6, 7]),
    // 「flick」：5 标题开头 4 分；0、1 标题含 3 分（同分按 MRU）；4 只有网址 1 分
    Case(name: "标题开头 > 标题含 > 只网址", query: "flick", want: [5, 0, 1, 4]),
    Case(name: "大小写不敏感", query: "FLICK", want: [5, 0, 1, 4]),
    // 「swift」：2 标题开头 4 分；3 标题含 3 分
    Case(name: "同一个词命中不同位置", query: "swift", want: [2, 3]),
    Case(name: "中文子串", query: "并发", want: [3]),
    // 两个词都要命中并累加：0 = github 标题开头 4 + tabflick 标题含 3 = 7；
    // 1 = github 只网址 1 + tabflick 标题开头 4 = 5
    Case(name: "多词全部命中才算，得分累加", query: "github tabflick", want: [0, 1]),
    Case(name: "有一个词没命中就出局", query: "swift tabflick", want: []),
    Case(name: "标题为空时按网址", query: "example", want: [4, 5, 7]),
    Case(name: "没有命中", query: "zzz", want: []),
    // 拼音：首字母「mnjt」只有 6 命中（拼音 2 分）
    Case(name: "拼音首字母", query: "mnjt", want: [6]),
    // 全拼「mengniu」：6 拼音 2 分；7 标题以 meng 开头但不含 mengniu，网址也不含 → 出局
    Case(name: "全拼", query: "mengniu", want: [6]),
    // 「meng」：7 标题开头 4 分 > 6 拼音 2 分 —— 拼音排在标题命中之后
    Case(name: "拼音命中排在标题命中之后", query: "meng", want: [7, 6]),
    // 数字词不碰拼音：「123」只命中 3 的网址
    Case(name: "非字母词不碰拼音", query: "123", want: [3]),
]

private struct URLCase { let query: String; let want: String? }
private let urlCases: [URLCase] = [
    URLCase(query: "example.com", want: "https://example.com"),
    URLCase(query: "  example.com/path?x=1 ", want: "https://example.com/path?x=1"),
    URLCase(query: "http://a.bc", want: "http://a.bc"),
    URLCase(query: "https://github.com/lifedever", want: "https://github.com/lifedever"),
    URLCase(query: "192.168.1.1", want: "https://192.168.1.1"),
    URLCase(query: "v2ex", want: nil),
    URLCase(query: "hello world.com", want: nil),
    URLCase(query: "localhost:3000", want: nil),
    URLCase(query: "a.", want: nil),
    URLCase(query: ".com", want: nil),
    URLCase(query: "蒙牛.集团", want: nil),
    URLCase(query: "", want: nil),
]

@main
struct TabSearchCheck {
    static func main() {
        var failures = 0
        for c in cases {
            let got = TabSearch.rank(tabs, query: c.query)
            if got != c.want {
                failures += 1
                print("✗ \(c.name)：期望 \(c.want)，实际 \(got)")
            }
        }
        for c in urlCases {
            let got = TabSearch.urlCandidate(c.query)
            if got != c.want {
                failures += 1
                print("✗ url「\(c.query)」：期望 \(c.want ?? "nil")，实际 \(got ?? "nil")")
            }
        }
        // 完整网址才算「带协议头」；裸域名、只有协议头、中间有空格的都不算
        let schemeCases: [(String, Bool)] = [
            ("http://www.baidu.com", true), ("HTTPS://github.com/x", true), ("  https://a.io  ", true),
            ("github.com", false), ("http://", false), ("https://a b.com", false), ("张雪", false),
        ]
        for (query, want) in schemeCases where TabSearch.hasScheme(query) != want {
            failures += 1
            print("✗ hasScheme「\(query)」：期望 \(want)")
        }
        // Markdown 链接：方括号 / 反斜杠转义、括号和空格编码、空标题用网址
        let mdCases: [(String, String, String)] = [
            ("GitHub", "https://github.com", "[GitHub](https://github.com)"),
            ("陈平 (汉朝) - 维基百科", "https://zh.wikipedia.org/wiki/陈平_(汉朝)",
             "[陈平 (汉朝) - 维基百科](https://zh.wikipedia.org/wiki/陈平_%28汉朝%29)"),
            ("[Swift] a\\b", "https://x.io/a b", "[\\[Swift\\] a\\\\b](https://x.io/a%20b)"),
            ("", "https://x.io", "[https://x.io](https://x.io)"),
        ]
        for (title, url, want) in mdCases {
            let got = TabSearch.markdownLink(title: title, url: url)
            if got != want {
                failures += 1
                print("✗ markdownLink「\(title)」：期望 \(want)，实际 \(got)")
            }
        }
        // Unicode 归一：标题是分解写法（e + U+0301，文件名常见），查询是合成写法，也要命中
        let nfd = [SearchCandidate(title: "Cafe\u{301} Notes", url: "")]
        if TabSearch.rank(nfd, query: "café") != [0] || TabSearch.rank(nfd, query: "CAFÉ n") != [0] {
            failures += 1
            print("✗ NFC 归一：分解写法的标题没被合成写法的查询命中")
        }
        // 英文词头 / 模糊 / 记忆加分（另一组候选，不动上面那组的下标）
        let extra: [SearchCandidate] = [
            cand("Pull Request #12 · org/repo", "https://github.com/org/repo/pull/12"),   // 0
            cand("GitHub Desktop", "app:/Applications/GitHub Desktop.app"),              // 1
            cand("Preview", "app:/System/Applications/Preview.app"),                    // 2
        ]
        let extraCases: [(String, String, [String: Int], [Int])] = [
            // 「pr」：2 标题开头（8）> 0 英文词头（4）
            ("英文词头 pr → Pull Request", "pr", [:], [2, 0]),
            ("驼峰词头 gd → GitHub Desktop", "gd", [:], [1]),
            ("漏打字母 gthb → github", "gthb", [:], [1]),
            ("相邻对调 githbu → github", "githbu", [:], [1]),
            ("相邻对调 gihtub → github", "gihtub", [:], [1]),
            ("打错一个 deskfop → desktop", "deskfop", [:], [1]),
            ("没有像的就是没有", "xyz", [:], []),
            ("太短的不模糊", "gt", [:], []),
            // 记忆加分：「p」本来 0、2 都是标题开头（8，同分按原顺序）；给 2 记 10 分 → 2 在前。
            // 1 只有路径里的 app 含 p（网址档 2 分）垫底
            ("记忆加分能改顺序", "p", ["app:/System/Applications/Preview.app": 10], [2, 0, 1]),
            ("没记忆时原顺序", "p", [:], [0, 2, 1]),
        ]
        for (name, query, boosts, want) in extraCases {
            let got = TabSearch.rank(extra, query: query, boosts: boosts)
            if got != want {
                failures += 1
                print("✗ \(name)：期望 \(want)，实际 \(got)")
            }
        }
        let py = Pinyin.index("掘金 - Swift 并发")
        if py.full != "juejin-swiftbingfa" || py.initials != "jj-swiftbf" {
            failures += 1
            print("✗ 拼音索引：\(py)")
        }
        let total = cases.count + urlCases.count + schemeCases.count + mdCases.count + 2 + extraCases.count
        print(failures == 0
              ? "全部通过（\(total) 组）"
              : "\(failures) 项失败（共 \(total) 组）")
        if failures > 0 { fatalError("TabSearch 排序校验未通过") }
    }
}
