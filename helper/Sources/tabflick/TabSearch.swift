import Foundation

/// 标签搜索的候选项。只带匹配要用的字段，好脱离 app 编译校验
///（见 checks/tab-search-check.swift）。
struct SearchCandidate {
    let title: String
    let url: String
    /// 标题的全拼（汉字逐字转拼音、去声调、无分隔，拉丁字符原样小写），
    /// 例如「蒙牛集团」→ `mengniujituan`。没有汉字时可以留空。
    var pinyin: String = ""
    /// 标题的拼音首字母（汉字取声母首字母，拉丁字符原样），「蒙牛集团」→ `mnjt`。
    var initials: String = ""
}

/// 标签搜索的匹配与排序。纯函数、零依赖。
///
/// 排错了不报错 —— 用户只会觉得「要找的那条老是在下面」，所以判定
/// 写成表放进校验脚本，改这里必跑。
enum TabSearch {

    /// 把查询拆成空白分隔的词，**每个词都要命中**（标题、拼音、网址任一）。
    /// 空查询 = 不过滤，原顺序（MRU）返回。
    ///
    /// 得分：标题以词开头 4、标题含词 3、拼音（全拼或首字母）含词 2、只有网址含词 1，
    /// 各词累加；同分保持原顺序 —— 原顺序就是 MRU，最近用过的排前面本身就是一种
    /// 相关性。拼音排在标题子串之后：用户能敲汉字时汉字命中一定更准。
    /// 返回的是**原数组下标**，调用方自己去取项，这样候选项不必带完整的标签结构。
    nonisolated static func rank(_ candidates: [SearchCandidate], query: String) -> [Int] {
        let terms = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return Array(candidates.indices) }

        var scored: [(index: Int, score: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            let title = candidate.title.lowercased()
            let url = candidate.url.lowercased()
            var total = 0
            var matched = true
            for term in terms {
                if title.hasPrefix(term) {
                    total += 4
                } else if title.contains(term) {
                    total += 3
                } else if isLatin(term),
                          candidate.initials.contains(term) || candidate.pinyin.contains(term) {
                    total += 2
                } else if url.contains(term) {
                    total += 1
                } else {
                    matched = false
                    break
                }
            }
            if matched { scored.append((index, total)) }
        }

        return scored
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
            .map(\.index)
    }

    /// 只有纯 ASCII 字母的词才去碰拼音 —— 汉字或数字对着拼音串没有意义。
    private nonisolated static func isLatin(_ term: String) -> Bool {
        term.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// 查询像不像一个网址；像就返回可以直接打开的完整地址，否则 nil。
    ///
    /// 判据故意保守：整段没有空白，且要么带 http(s) 协议头，要么是「点号两侧都有内容」
    /// 的主机名（`example.com` / `192.168.1.1` / `a.b/c`）。`v2ex`、`localhost:3000`
    /// 这类不算 —— 宁可让用户多敲个点，也别把普通搜索词当成网址开出一个错页。
    nonisolated static func urlCandidate(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return text.count > 8 ? text : nil
        }
        let host = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // 顶级域：纯 ASCII 字母至少两个字符（端口留在冒号后面不影响）；
        // 或者整个主机是点分数字（IPv4）。中文域名不认 —— 那多半是句子里的句号。
        let last = labels.last!.split(separator: ":").first ?? ""
        let isIPv4 = labels.allSatisfy { label in
            let bare = label.split(separator: ":").first ?? ""
            return !bare.isEmpty && bare.allSatisfy { $0.isASCII && $0.isNumber }
        }
        let isDomain = last.count >= 2 && last.allSatisfy { $0.isASCII && $0.isLetter }
        guard isIPv4 || isDomain else { return nil }
        return "https://" + text
    }
}
