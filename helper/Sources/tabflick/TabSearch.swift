import Foundation

/// 标签搜索的候选项。只带匹配要用的字段，好脱离 app 编译校验
///（见 checks/tab-search-check.swift）。
struct SearchCandidate {
    let title: String
    let url: String
    /// 标题的全拼（汉字逐字转拼音、去声调、无分隔，拉丁字符原样小写），
    /// 例如「蒙牛集团」→ `mengniujituan`。没有汉字时可以留空。
    let pinyin: String
    /// 标题的拼音首字母（汉字取声母首字母，拉丁字符原样），「蒙牛集团」→ `mnjt`。
    let initials: String

    /// 匹配用的键：先 NFC 归一再转小写的 UTF-8 字节，建候选项时算一次。
    ///
    /// 每次按键都要对全部候选做子串查找。Swift `String.contains` 按字符（字素簇 +
    /// Unicode 等价）逐个比，6700 条要 30ms；比字节 0.7ms（2026-09-27 实测）。
    /// UTF-8 是自同步编码，字节子串就是字符子串；NFC 归一让「é」的两种写法（单码位 /
    /// e + 组合重音，文件名常见后者）对得上。调用方应缓存候选项，别每次按键重建。
    let titleKey: [UInt8]
    let urlKey: [UInt8]
    let pinyinKey: [UInt8]
    let initialsKey: [UInt8]
    /// 英文单词的首字母（驼峰也算一个词头）：GitHub → `gh`、Pull Request #12 → `pr1`。
    /// 中文有拼音首字母，英文原来没有对应的，打 `pr` 找不到 Pull Request。
    let wordInitialsKey: [UInt8]
    /// 这一项是谁（记忆加分按它记账）：网页是网址，App / 文件夹是路径。默认同 url。
    let identity: String
    /// 「整条输入等于名字」比的是它。默认就是标题；App 的标题拼了访达注释，这里单给名字本身。
    let nameKey: [UInt8]

    init(title: String, url: String, pinyin: String = "", initials: String = "", identity: String? = nil,
         name: String? = nil) {
        self.title = title
        self.url = url
        self.pinyin = pinyin
        self.initials = initials
        self.identity = identity ?? url
        titleKey = Self.key(title)
        nameKey = name.map(Self.key) ?? titleKey
        urlKey = Self.key(url)
        pinyinKey = Array(pinyin.utf8)
        initialsKey = Array(initials.utf8)
        wordInitialsKey = Self.wordInitials(title)
    }

    /// 英文词头：前一个不是字母数字（含中文等非 ASCII），或者小写后面跟大写（驼峰）。
    nonisolated static func wordInitials(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var prevAlnum = false
        var prevLower = false
        for scalar in text.unicodeScalars {
            guard scalar.isASCII else { prevAlnum = false; prevLower = false; continue }
            let v = UInt8(scalar.value)
            let upper = v >= 65 && v <= 90
            let lower = v >= 97 && v <= 122
            let alnum = upper || lower || (v >= 48 && v <= 57)
            if alnum && (!prevAlnum || (upper && prevLower)) { out.append(upper ? v + 32 : v) }
            prevAlnum = alnum
            prevLower = lower
        }
        return out
    }

    nonisolated static func key(_ text: String) -> [UInt8] {
        Array(text.precomposedStringWithCanonicalMapping.lowercased().utf8)
    }
}

/// 标签搜索的匹配与排序。纯函数、零依赖。
///
/// 排错了不报错 —— 用户只会觉得「要找的那条老是在下面」，所以判定
/// 写成表放进校验脚本，改这里必跑。
enum TabSearch {

    /// 把查询拆成空白分隔的词，**每个词都要命中**（标题、拼音、网址任一）。
    /// 空查询 = 不过滤，原顺序（MRU）返回。
    ///
    /// 得分（每个词）：标题以词开头 8、标题含词 6、拼音（全拼或首字母）/ 英文词头含词 4、
    /// 只有网址含词 2、模糊命中 1，各词累加；整条输入等于名字（`nameKey`）再加 4 ——
    /// 打「Firefox」时 App「Firefox」要压过标题以 Firefox 开头的网页（用户 2026-09-29 定的）；
    /// 最后加记忆分（`boosts`，按 identity 查）。
    /// 同分保持原顺序 —— 原顺序就是 MRU，最近用过的排前面本身就是一种相关性。
    /// 拼音排在标题子串之后：用户能敲汉字时汉字命中一定更准。
    /// 返回的是**原数组下标**，调用方自己去取项，这样候选项不必带完整的标签结构。
    nonisolated static func rank(_ candidates: [SearchCandidate], query: String,
                                 boosts: [String: Int] = [:]) -> [Int] {
        rankScored(candidates, query: query, boosts: boosts).map(\.index)
    }

    /// 同 `rank`，带上得分（「最佳匹配」要跨段比分）。空查询时得分都是 0。
    ///
    /// 严格命中不到 3 条时再跑一遍模糊（漏打 / 打错一个字母），平时零开销；模糊命中垫在
    /// 严格命中后面（分最低），免得打对了的时候被一堆「好像有点像」的挤下去。
    nonisolated static func rankScored(_ candidates: [SearchCandidate], query: String,
                                       boosts: [String: Int] = [:]) -> [(index: Int, score: Int)] {
        let terms = terms(of: query)
        guard !terms.isEmpty else { return candidates.indices.map { ($0, 0) } }
        var scored: [(index: Int, score: Int)] = []
        var matched = Set<Int>()
        for (index, candidate) in candidates.enumerated() {
            if let total = score(candidate, terms) {
                scored.append((index, total + (boosts[candidate.identity] ?? 0)))
                matched.insert(index)
            }
        }
        var ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
        if ranked.count < 3, terms.contains(where: \.fuzzyEligible) {
            var fuzzy: [(index: Int, score: Int)] = []
            for (index, candidate) in candidates.enumerated() where !matched.contains(index) {
                if let total = score(candidate, terms, allowFuzzy: true) {
                    fuzzy.append((index, total + (boosts[candidate.identity] ?? 0)))
                }
            }
            ranked += fuzzy.sorted { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
        }
        return ranked
    }

    /// 单个候选项的得分（含记忆分）；有词没命中返回 nil。只看严格命中。
    nonisolated static func score(_ candidate: SearchCandidate, query: String,
                                  boosts: [String: Int] = [:]) -> Int? {
        score(candidate, terms(of: query)).map { $0 + (boosts[candidate.identity] ?? 0) }
    }

    struct Term {
        let bytes: [UInt8]
        /// 只有纯 ASCII 字母的词才去碰拼音 —— 汉字或数字对着拼音串没有意义。
        let latin: Bool
        /// 模糊只认 3 个字母以上的纯字母词：再短的「像不像」没有意义，全是噪音。
        var fuzzyEligible: Bool { latin && bytes.count >= 3 }
    }

    nonisolated static func terms(of query: String) -> [Term] {
        query.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { Term(bytes: Array($0.utf8), latin: $0.allSatisfy { $0.isASCII && $0.isLetter }) }
    }

    private nonisolated static func score(_ candidate: SearchCandidate, _ terms: [Term],
                                          allowFuzzy: Bool = false) -> Int? {
        guard !terms.isEmpty else { return 0 }
        var total = 0
        var usedFuzzy = false
        var words: [ArraySlice<UInt8>]?
        for term in terms {
            if hasPrefix(candidate.titleKey, term.bytes) {
                total += 8
            } else if contains(candidate.titleKey, term.bytes) {
                total += 6
            } else if term.latin,
                      contains(candidate.initialsKey, term.bytes) || contains(candidate.pinyinKey, term.bytes)
                        || (term.bytes.count >= 2 && initialsMatch(term.bytes, candidate.wordInitialsKey)) {
                total += 4
            } else if contains(candidate.urlKey, term.bytes) {
                total += 2
            } else if allowFuzzy, term.fuzzyEligible,
                      // 预筛：模糊要求某个单词的首字母对上，词头里连这个字母都没有就不拆单词了
                      //（6700 条的模糊一遍 4.9ms → 见 CLAUDE.md 的实测）
                      candidate.wordInitialsKey.contains(term.bytes[0]),
                      fuzzyMatches(term.bytes, words: words ?? { words = asciiWords(candidate.titleKey); return words! }()) {
                total += 1
                usedFuzzy = true
            } else {
                return nil
            }
        }
        // 模糊那一遍只收「至少一个词靠模糊才命中」的，严格命中的第一遍已经收过
        if allowFuzzy { return usedFuzzy ? total : nil }
        return equalsQuery(candidate.nameKey, terms) ? total + 4 : total
    }

    /// 名字是否就是整条输入（各词以单个空格相连）。逐段比，不拼新数组 —— 每个候选都要过一遍。
    private nonisolated static func equalsQuery(_ key: [UInt8], _ terms: [Term]) -> Bool {
        let length = terms.reduce(terms.count - 1) { $0 + $1.bytes.count }
        guard key.count == length else { return false }
        var i = key.startIndex
        for (n, term) in terms.enumerated() {
            if n > 0 {
                guard key[i] == 0x20 else { return false }
                i += 1
            }
            guard key[i..<(i + term.bytes.count)].elementsEqual(term.bytes) else { return false }
            i += term.bytes.count
        }
        return true
    }

    /// 英文词头命中：词头串里连续出现（`pr` ⊂ merge-pull-request 的 `mpr`），或从第一个
    /// 词头起按顺序出现（`gd` → GitHub Desktop 的 `ghd`：驼峰把 GitHub 拆成两个词头，
    /// 用户却按「两个词」打）。只放宽到「从第一个词头起」，不然两个字母满屏乱命中。
    private nonisolated static func initialsMatch(_ term: [UInt8], _ initials: [UInt8]) -> Bool {
        if contains(initials, term) { return true }
        guard initials.first == term.first else { return false }
        var cursor = initials.startIndex
        for byte in term {
            while cursor < initials.endIndex && initials[cursor] != byte { cursor += 1 }
            if cursor == initials.endIndex { return false }
            cursor += 1
        }
        return true
    }

    /// 标题里的英文单词（按非字母数字切；中文等非 ASCII 字节也算分隔）。
    private nonisolated static func asciiWords(_ key: [UInt8]) -> [ArraySlice<UInt8>] {
        key.split { !(($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)) }
    }

    /// 模糊命中某个单词：① 同一个单词里按顺序出现、首字母对上（`gthb` → github，漏打）；
    /// ② 和单词开头只差一个字母 —— 漏打、多打、打错、两个字母对调（`githbu` → github）。
    private nonisolated static func fuzzyMatches(_ term: [UInt8], words: [ArraySlice<UInt8>]) -> Bool {
        for word in words where word.first == term.first {
            // ① 子序列
            var cursor = word.startIndex
            var ok = true
            for byte in term {
                while cursor < word.endIndex && word[cursor] != byte { cursor += 1 }
                if cursor == word.endIndex { ok = false; break }
                cursor += 1
            }
            if ok { return true }
            // ② 编辑距离 ≤ 1（和同长 / 差一个字母长的词头比）
            guard term.count >= 4 else { continue }
            for length in [term.count - 1, term.count, term.count + 1] where length <= word.count {
                if withinOneEdit(term, Array(word.prefix(length))) { return true }
            }
        }
        return false
    }

    /// 两串是否只差一次编辑（插入 / 删除 / 替换 / 相邻对调）。长度差超过 1 直接否。
    private nonisolated static func withinOneEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        if i == a.count && i == b.count { return true }
        if a.count == b.count {
            // 替换一个，或相邻对调
            if Array(a[(i + 1)...]) == Array(b[(i + 1)...]) { return true }
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i]
                && Array(a[(i + 2)...]) == Array(b[(i + 2)...])
        }
        // 长度差 1：长的那个在 i 处多一个字母
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    private nonisolated static func hasPrefix(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for i in 0..<needle.count where hay[i] != needle[i] { return false }
        return true
    }

    private nonisolated static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = hay.count
        guard n > 0 else { return true }
        guard n <= h else { return false }
        let first = needle[0]
        var i = 0
        while i <= h - n {
            if hay[i] == first {
                var j = 1
                while j < n && hay[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// 输入是带协议头的完整网址（http:// 或 https://）。「全部」里据此把「操作」整段挪到
    /// 最前：打全了协议头，来意就是打开它。github.com 这种裸域名不算 —— 多半是在找
    /// 已经开着的那个标签，挪上去容易开出重复标签（2026-09-27 用户定的）。
    nonisolated static func hasScheme(_ query: String) -> Bool {
        let lower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://")) && urlCandidate(query) != nil
    }

    /// `[标题](网址)`。标题里的 \ [ ] 转义，网址里的括号和空格编码 —— 否则标题带方括号、
    /// 网址带括号（维基百科的消歧义页）时链接在渲染里断掉。标题空就拿网址当文字。
    nonisolated static func markdownLink(title: String, url: String) -> String {
        let text = (title.isEmpty ? url : title)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let target = url
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return "[\(text)](\(target))"
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
