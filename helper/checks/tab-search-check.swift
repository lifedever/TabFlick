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
        let py = Pinyin.index("掘金 - Swift 并发")
        if py.full != "juejin-swiftbingfa" || py.initials != "jj-swiftbf" {
            failures += 1
            print("✗ 拼音索引：\(py)")
        }
        let total = cases.count + urlCases.count + 1
        print(failures == 0
              ? "全部通过（\(total) 组）"
              : "\(failures) 项失败（共 \(total) 组）")
        if failures > 0 { fatalError("TabSearch 排序校验未通过") }
    }
}
