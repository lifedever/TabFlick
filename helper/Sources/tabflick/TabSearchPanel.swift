import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 行与选中结果

/// 面板列表里的一行。三种来源混排在同一张列表里，游标和 ⌘ 数字按屏上顺序连续编号。
enum SearchRow: Identifiable {
    /// 活着的标签（切换）
    case tab(SwitcherItem)
    /// 已关闭的标签（找回，新标签打开）
    case closed(ClosedTab)
    /// 查询本身像个网址（新标签打开）
    case url(String)
    /// 书签（新标签打开）
    case bookmark(BookmarkInfo)
    /// 浏览器历史（新标签打开）
    case history(HistoryInfo)
    /// 按 Tab 切出来的「操作」（对当前输入做点什么）
    case action(SearchAction)
    /// 收藏的文件夹（回车用上次的方式打开，⌘↩ 选打开方式）
    case folder(FavoriteFolder)
    /// 某个文件夹的一种打开方式（⌘↩ 展开后的列表）
    case opener(OpenerApp, FavoriteFolder)
    /// 已安装的 App（回车启动）
    case app(AppEntry)

    var id: String {
        switch self {
        case .tab(let item):     return item.id
        case .closed(let entry): return "closed#\(entry.id)"
        case .url(let url):      return "url#\(url)"
        case .bookmark(let bm):  return "bm#\(bm.path)#\(bm.url)"
        case .history(let h):    return "history#\(h.url)"
        case .action(let a):     return "action#\(a.id)"
        case .folder(let f):     return "folder#\(f.path)"
        case .opener(let o, let f): return "opener#\(o.id)#\(f.path)"
        case .app(let a):        return "app#\(a.path)"
        }
    }

    /// 图标缓存的键。活标签 / 已关闭用扩展给的 favIconUrl；书签 / 历史没有，按域名
    /// 用 `site:<host>` 当键，缺的由 helper 去问扩展（Chrome 的 _favicon 接口）。
    var favIconUrl: String {
        switch self {
        case .tab(let item):     return item.tab.favIconUrl
        case .closed(let entry): return entry.favIconUrl
        case .bookmark(let bm):  return Self.siteKey(bm.url)
        case .history(let h):    return Self.siteKey(h.url)
        case .action(.siteSearch(let site, _)): return "site:" + site.host
        case .folder(let f):     return "file:" + f.path
        case .opener(let o, _):  return "file:" + o.path
        case .app(let a):        return "file:" + a.path
        case .url, .action:      return ""
        }
    }

    /// 需要向扩展要图标时用的页面地址（书签 / 历史 / 站内搜索）。
    var faviconPageURL: String? {
        switch self {
        case .bookmark(let bm): return bm.url
        case .history(let h):   return h.url
        case .action(.siteSearch(let site, _)): return "https://" + site.host + "/"
        default:                return nil
        }
    }

    static func siteKey(_ url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "" }
        return "site:" + host
    }

    /// 归属浏览器的 bundle id（跨浏览器模式行尾画图标用）。
    var browser: String? {
        switch self {
        case .tab(let item):     return item.browser
        case .closed(let entry): return entry.browser
        default:                 return nil
        }
    }
}

/// 输入内容后按 Tab 出来的操作列表。现在只有「搜索」，以后加一条就是加一个 case：
/// 站内搜索模板、翻译、搜历史记录都往这里放。
enum SearchAction {
    /// 用浏览器默认搜索引擎搜这段文字，新标签打开（扩展侧 chrome.search）。
    case webSearch(String)
    /// 站内搜索：把关键词填进模板，新标签打开。
    case siteSearch(SiteSearch, String)

    var id: String {
        switch self {
        case .webSearch(let text):        return "search#\(text)"
        case .siteSearch(let site, let text): return "site#\(site.id)#\(text)"
        }
    }

    var title: String {
        switch self {
        case .webSearch(let text):        return L10n.t("搜索“\(text)”", "Search “\(text)”")
        case .siteSearch(let site, let text): return L10n.t("在 \(site.name) 搜索“\(text)”", "Search \(site.name) for “\(text)”")
        }
    }

    var subtitle: String {
        switch self {
        case .webSearch:            return L10n.t("浏览器默认搜索引擎，新标签打开", "Browser's default search engine, in a new tab")
        case .siteSearch(let site, _): return site.host
        }
    }

    var symbol: String {
        switch self {
        case .webSearch:  return "magnifyingglass"
        case .siteSearch: return "magnifyingglass.circle"
        }
    }
}

/// 用户在面板里选定了什么。面板已经关掉、键盘焦点已回到浏览器。
enum SearchPick {
    case tab(SwitcherItem)
    case closed(ClosedTab)
    case url(String)
    case bookmark(BookmarkInfo)
    case history(HistoryInfo)
    case action(SearchAction)
    /// 文件夹；opener 为 nil = 用最近用过的方式
    case folder(FavoriteFolder, OpenerApp?)
    case app(AppEntry)
}

// MARK: - 视图模型

/// 标签搜索面板的状态。`rows` 是 `all` / `closed` / 查询经 `TabSearch` 过滤后的投影。
@MainActor
final class TabSearchModel: ObservableObject {
    /// 当前浏览器的全部标签，MRU 顺序，index 0 是当前标签。
    @Published private(set) var all: [SwitcherItem] = []
    /// 当前浏览器最近关闭的标签，按关闭时间降序。只在有查询时参与。
    @Published private(set) var closed: [ClosedTab] = []
    /// 当前浏览器的书签。只在有查询时参与。
    @Published private(set) var bookmarks: [BookmarkInfo] = []
    /// 收藏的文件夹（按最近使用排）、打开方式（按最近用过排，第一个是回车默认）、已装 App。
    @Published private(set) var folders: [FavoriteFolder] = []
    @Published private(set) var openers: [OpenerApp] = []
    @Published private(set) var apps: [AppEntry] = []
    /// ⌘↩ 展开了某个文件夹的打开方式列表（子状态，Esc 退回）。
    @Published private(set) var openerPicker: FavoriteFolder?
    /// 「全部」模式没输入时列什么（设置项）。nil = 空着。
    var allEmptyContent: SearchMode? = .tabs
    /// 「全部」模式没输入且设置成文件夹时，文件夹段的行数（画「文件夹」头用）。
    private(set) var folderCount = 0
    var hasFolderSection: Bool { mode == .all && folderCount > 0 }
    /// 站内搜索模板（设置里维护），Tab 操作列表里「搜索」后面的那几条。
    var siteSearches: [SiteSearch] = []
    /// 「搜索」那一行会发给哪个浏览器（bundle id），行首画它的图标。
    @Published var searchBrowser: String?
    /// 浏览器历史：按输入实时问扩展，回来的是**针对某个查询**的结果，
    /// 和当前输入不一致就不画（用户已经接着敲了）。
    private var history: [HistoryInfo] = []
    private var historyQuery = ""
    /// 输入变了（去掉首尾空白后）。MRUController 靠它去问扩展要历史。
    var onQueryChange: ((String) -> Void)?
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            refilter(keepCursorOn: nil)
            onQueryChange?(query.trimmingCharacters(in: .whitespaces))
        }
    }
    /// Tab 循环的模式顺序（设置里可调），以及当前模式。
    @Published var modes: [SearchMode] = SearchMode.allCases
    @Published private(set) var mode: SearchMode = .all
    /// 模式变了（历史记录模式要去问扩展要最近的）。
    var onModeChange: ((SearchMode) -> Void)?
    @Published private(set) var rows: [SearchRow] = [] {
        // 行数 / 分组头变了面板要改高度。放 didSet 而不是订阅 $rows：@Published 在
        // willSet 发出，那时窗口先缩、内容后换，肉眼就是闪一下；didSet 里值已落定，
        // 同步改窗口尺寸时 SwiftUI 会在同一次布局里换上新内容。
        didSet {
            let height = contentHeight
            if height != lastContentHeight {
                lastContentHeight = height
                onContentHeightChange?(height)
            }
            reloadIcons()
        }
    }
    /// 「全部」模式里排在最前的应用行数（用户定的：App 排第一）。活标签从 `liveStart` 开始。
    @Published private(set) var appCount = 0
    var liveStart: Int { appCount }
    var hasAppSection: Bool { mode == .all && appCount > 0 }
    /// 应用段在前时，活标签也要一个「标签」头，否则两段连成一片。
    var hasTabHeader: Bool { hasAppSection && liveCount > 0 }
    /// 活标签行的数量。已关闭那一段从 `liveStart + liveCount` 开始（如果有）。
    @Published private(set) var liveCount = 0
    /// 已关闭行的数量。书签那一段从 `liveCount + closedCount` 开始（如果有）。
    @Published private(set) var closedCount = 0
    /// 历史那一段从这里开始（书签之后）。
    private(set) var historyStart = 0
    private(set) var historyRows = 0
    var hasHistorySection: Bool { mode == .all && historyRows > 0 }
    @Published private(set) var cursor = 0
    /// favicon，按 favIconUrl 索引（活标签和已关闭共用一份）。
    @Published var icons: [String: IconInfo] = [:]
    /// ⌘ 正被按着：行尾显示 ⌘1–⌘9 的角标。
    @Published var commandHeld = false
    /// 跨浏览器且不止一个浏览器：行尾用浏览器图标代替「x 分钟前」认归属。
    @Published var showBrowserBadges = false

    private var lastContentHeight: CGFloat = -1
    var onContentHeightChange: ((CGFloat) -> Void)?

    /// 按行的图标键取已缓存的图标（MRUController 提供）。
    var iconProvider: (([String]) -> [String: IconInfo])?
    /// 这些行还没有图标，去要（参数 key + 页面地址）。
    var onMissingIcons: (([(key: String, url: String)]) -> Void)?

    /// 行变了 / 图标到了：按当前行重新拿一遍图标，缺的报上去。
    func reloadIcons() {
        var keys = rows.map(\.favIconUrl)
        if let opener = openers.first { keys.append("file:" + opener.path) }
        if let provider = iconProvider { icons = provider(keys) }
        let missing = rows.compactMap { row -> (key: String, url: String)? in
            guard let url = row.faviconPageURL, !row.favIconUrl.isEmpty,
                  icons[row.favIconUrl] == nil else { return nil }
            return (row.favIconUrl, url)
        }
        if !missing.isEmpty { onMissingIcons?(missing) }
    }

    /// 游标这次是被谁移动的。只有键盘移动才自动滚动 —— 理由同 SwitcherModel：
    /// hover 改游标 → 滚动 → 鼠标下换了一行 → 又 hover，游标会一路飞到底。
    private(set) var cursorSource: CursorSource = .keyboard

    /// 当前标签的 id（`all` 的首项）。行尾用「当前」代替时间。
    var currentID: String? { all.first?.id }

    /// 已关闭那一段有没有画出来（有匹配的关闭记录时才有）。
    var hasClosedSection: Bool { mode == .all && closedCount > 0 }
    /// 书签那一段有没有画出来。
    var hasBookmarkSection: Bool { mode == .all && bookmarkRows > 0 }
    private var bookmarkRows = 0
    var bookmarkStart: Int { appCount + liveCount + closedCount }

    /// 能不能在面板里关标签：只剩一个标签时不关 —— 关掉浏览器窗口就跟着没了。
    var canCloseTabs: Bool { all.count > 1 }

    var onPick: ((SearchRow) -> Void)?
    /// 要求关掉某个活标签（参数 item.id）。
    var onCloseTab: ((String) -> Void)?

    /// 标题 → 拼音索引的缓存。逐字转拼音不算便宜，标题在两次刷新之间基本不变。
    private var pinyinCache: [String: (full: String, initials: String)] = [:]

    func setCursor(_ index: Int, source: CursorSource) {
        cursorSource = source
        cursor = index
    }

    /// Tab / ⇧Tab：按设置里的顺序循环模式。
    func cycleMode(_ delta: Int) {
        guard let index = modes.firstIndex(of: mode), modes.count > 1 else { return }
        select(modes[(index + delta + modes.count) % modes.count])
    }

    func select(_ next: SearchMode) {
        guard next != mode else { return }
        mode = next
        openerPicker = nil
        refilter(keepCursorOn: nil)
        onModeChange?(next)
    }

    /// 回到顺序里的第一个模式（打开面板时、Esc 时）。返回 true 表示确实切回去了。
    @discardableResult
    func resetMode() -> Bool {
        guard let first = modes.first, first != mode else { return false }
        select(first)
        return true
    }

    /// Esc：打开方式列表展开着就先收起；不在第一个模式就先回去；都不是才关面板（返回 false）。
    func escape() -> Bool {
        if openerPicker != nil {
            openerPicker = nil
            refilter(keepCursorOn: nil)
            return true
        }
        return resetMode()
    }

    /// 换一份数据。面板开着时 MRU 推送也会走这里，游标尽量留在原来那一项上；
    /// 每次打开（`keepCursor: false`）则从头算 —— 面板常驻，上一轮的游标还留在
    /// 模型里，继承它会落到刚切过去的那个标签，也就是现在的「当前」，毫无意义。
    func setItems(_ items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
                  folders: [FavoriteFolder] = [], apps: [AppEntry] = [], openers: [OpenerApp] = [],
                  keepCursor: Bool = true) {
        let keep = keepCursor && rows.indices.contains(cursor) ? rows[cursor].id : nil
        let previousIndex = cursor
        all = items
        self.closed = closed
        self.bookmarks = bookmarks
        self.folders = folders
        self.apps = apps
        self.openers = openers
        if keepCursor {
            refreshInPlace(keep: keep, previousIndex: previousIndex)
        } else {
            refilter(keepCursorOn: nil)
        }
    }

    /// 数据刷新（MRU 推送、面板里关了标签、历史回包）而查询没变：游标留在原处、
    /// **不滚动**。原来那一行没了（刚被关掉的就是游标所在那行——悬停时游标跟着鼠标）
    /// 就落到同一位置的下一行。之前退回第 1 行并按键盘移动处理，列表跳回顶部
    /// （用户 2026-09-26 反馈：标签多时关一个就回到顶上）。
    private func refreshInPlace(keep: String?, previousIndex: Int) {
        refilter(keepCursorOn: nil)
        guard !rows.isEmpty else { return }
        if let keep, let index = rows.firstIndex(where: { $0.id == keep }) {
            setCursor(index, source: .mouse)
        } else {
            setCursor(min(previousIndex, rows.count - 1), source: .mouse)
        }
    }

    /// ⌘↩：展开游标那个文件夹的打开方式。
    func showOpeners(for folder: FavoriteFolder) {
        openerPicker = folder
        refilter(keepCursorOn: nil)
    }

    private func candidate(title: String, url: String) -> SearchCandidate {
        let py: (full: String, initials: String)
        if let cached = pinyinCache[title] {
            py = cached
        } else {
            py = Pinyin.index(title)
            pinyinCache[title] = py
        }
        return SearchCandidate(title: title, url: url, pinyin: py.full, initials: py.initials)
    }

    /// 「全部」模式里应用 / 已关闭 / 书签 / 历史各自最多列这么多条；单独模式放宽到 `soloLimit`。
    static let appLimit = 4
    static let closedLimit = 5
    static let bookmarkLimit = 5
    static let historyLimit = 8
    static let soloLimit = 40

    /// 扩展回了某个查询的历史。查询已经变了就丢掉。
    func setHistory(_ items: [HistoryInfo], for query: String) {
        guard query == self.query.trimmingCharacters(in: .whitespaces) else { return }
        guard !items.isEmpty || !history.isEmpty || historyQuery != query else { return }
        history = items
        historyQuery = query
        let keep = rows.indices.contains(cursor) ? rows[cursor].id : nil
        refreshInPlace(keep: keep, previousIndex: cursor)
    }

    private func refilter(keepCursorOn keep: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        appCount = 0; liveCount = 0; closedCount = 0; bookmarkRows = 0; historyRows = 0; historyStart = 0
        folderCount = 0
        let next = mode == .all ? allRows(trimmed) : modeRows(mode, trimmed)
        rows = next

        if let keep, let index = rows.firstIndex(where: { $0.id == keep }) {
            setCursor(index, source: .keyboard)
        } else if trimmed.isEmpty, rows.count > 1,
                  mode == .tabs || (mode == .all && allEmptyContent == .tabs) {
            // 空查询时首行是当前标签，回车切到它等于没切；游标落到上一个标签，
            // 和 ⌃⇥ 按一下的落点一致（用户 2026-09-26 点名要求）。
            setCursor(1, source: .keyboard)
        } else {
            setCursor(0, source: .keyboard)
        }
    }

    /// 单独模式的行（也给「全部」没输入时按设置借用）。
    private func modeRows(_ mode: SearchMode, _ trimmed: String) -> [SearchRow] {
        var next: [SearchRow] = []
        switch mode {
        case .all:
            break
        case .tabs:
            let liveCandidates = all.map { candidate(title: $0.tab.title, url: $0.tab.url) }
            next = TabSearch.rank(liveCandidates, query: query).map { .tab(all[$0]) }
            liveCount = next.count
        case .actions:
            // 对当前输入的操作。没输入就没有可操作的，列表留空、视图给提示。
            if !trimmed.isEmpty { next = actionRows(trimmed) }
        case .history:
            // 历史记录由扩展按输入实时查（空串 = 最近访问的），helper 不再做二次匹配
            if historyQuery == trimmed {
                var seen = Set<String>()
                for h in history where !seen.contains(Self.historyDedupeKey(h)) {
                    seen.insert(Self.historyDedupeKey(h))
                    next.append(.history(h))
                    if next.count == Self.soloLimit { break }
                }
            }
            historyRows = next.count
        case .bookmarks:
            let candidates = bookmarks.map { candidate(title: $0.title, url: $0.url) }
            var seen = Set<String>()
            for index in TabSearch.rank(candidates, query: trimmed) {
                let bm = bookmarks[index]
                guard !seen.contains(bm.url) else { continue }
                seen.insert(bm.url)
                next.append(.bookmark(bm))
                if next.count == Self.soloLimit { break }
            }
            bookmarkRows = next.count
        case .closed:
            let candidates = closed.map { candidate(title: $0.title, url: $0.url) }
            next = TabSearch.rank(candidates, query: trimmed)
                .map { closed[$0] }
                .sorted { $0.closedAt > $1.closedAt }
                .prefix(Self.soloLimit)
                .map { .closed($0) }
            closedCount = next.count
        case .folders:
            if let picking = openerPicker {
                // ⌘↩ 展开的打开方式列表：同状态栏子菜单那份，按最近用过排
                next = openers.map { .opener($0, picking) }
            } else {
                let candidates = folders.map { candidate(title: $0.name, url: $0.path) }
                next = TabSearch.rank(candidates, query: trimmed).prefix(Self.soloLimit).map { .folder(folders[$0]) }
                folderCount = next.count
            }
        case .apps:
            // 英文原名和 bundle id 放进「网址」栏参与匹配（得分低于标题命中）
            let candidates = apps.map { candidate(title: $0.name, url: [$0.alternateName, $0.bundleID].compactMap { $0 }.joined(separator: " ")) }
            next = TabSearch.rank(candidates, query: trimmed).prefix(Self.soloLimit).map { .app(apps[$0]) }
            appCount = next.count
        }
        return next
    }

    /// 历史记录去重口径：同一域名下标题一样的算一条（论坛帖子的不同页码、带锚点的
    /// 同一页在历史里是一串不同网址，列出来五条一模一样的行，用户截图指出的）。
    /// 没标题的退回按网址。
    private static func historyDedupeKey(_ h: HistoryInfo) -> String {
        guard !h.title.isEmpty, let host = URL(string: h.url)?.host else { return h.url }
        return host + "|" + h.title
    }

    /// 「搜索」模式的行：搜索引擎 + 站内搜索。
    private func actionRows(_ text: String) -> [SearchRow] {
        [.action(.webSearch(text))] + siteSearches.map { .action(.siteSearch($0, text)) }
    }

    /// 「全部」模式：活标签在前，有输入时后面挂最近关闭 / 书签 / 历史各几条，末尾网址直达。
    /// **一条都没命中时直接换成「搜索」那几行**（用户 2026-09-26 定的）：与其给一句
    /// 「没有匹配」，不如让回车就能去搜；像网址的话「在新标签打开」排最前。
    private func allRows(_ trimmed: String) -> [SearchRow] {
        // 没输入：按设置列一种内容（默认标签的 MRU），列表空着也行
        if trimmed.isEmpty {
            guard let content = allEmptyContent else { return [] }
            return modeRows(content, "")
        }
        var next: [SearchRow] = []
        // 应用排第一（用户定的）：有输入时先列命中的 App，最多几条
        if !trimmed.isEmpty {
            let appCandidates = apps.map { candidate(title: $0.name, url: [$0.alternateName, $0.bundleID].compactMap { $0 }.joined(separator: " ")) }
            next = TabSearch.rank(appCandidates, query: trimmed).prefix(Self.appLimit).map { .app(apps[$0]) }
            appCount = next.count
        }
        let liveCandidates = all.map { candidate(title: $0.tab.title, url: $0.tab.url) }
        let liveRows: [SearchRow] = TabSearch.rank(liveCandidates, query: query).map { .tab(all[$0]) }
        liveCount = liveRows.count
        next += liveRows

        // 已关闭：按关闭时间倒序取前几条；和活标签同网址的不列（它已经开着，切过去就是）。
        let liveURLs = Set(all.map(\.tab.url))
        let closedCandidates = closed.map { candidate(title: $0.title, url: $0.url) }
        let matched = TabSearch.rank(closedCandidates, query: query)
            .map { closed[$0] }
            .filter { !liveURLs.contains($0.url) }
            .sorted { $0.closedAt > $1.closedAt }
            .prefix(Self.closedLimit)
        next += matched.map { .closed($0) }
        closedCount = matched.count

        // 书签：按匹配得分排，开着的和已关闭段里有的不重复列；同网址收在多个
        // 文件夹里只列第一个。
        var taken = liveURLs.union(matched.map(\.url))
        let bookmarkCandidates = bookmarks.map { candidate(title: $0.title, url: $0.url) }
        var picked: [BookmarkInfo] = []
        for index in TabSearch.rank(bookmarkCandidates, query: query) {
            let bm = bookmarks[index]
            guard !taken.contains(bm.url) else { continue }
            taken.insert(bm.url)
            picked.append(bm)
            if picked.count == Self.bookmarkLimit { break }
        }
        next += picked.map { .bookmark($0) }
        bookmarkRows = picked.count

        // 历史：Chrome 自己匹配、按最近访问排；和上面几段同网址的不重复列
        historyStart = next.count
        var historyPicked: [HistoryInfo] = []
        if historyQuery == trimmed {
            taken.formUnion(picked.map(\.url))
            var seenTitles = Set<String>()
            for h in history {
                let dedupe = Self.historyDedupeKey(h)
                guard !taken.contains(h.url), !seenTitles.contains(dedupe) else { continue }
                taken.insert(h.url)
                seenTitles.insert(dedupe)
                historyPicked.append(h)
                if historyPicked.count == Self.historyLimit { break }
            }
        }
        next += historyPicked.map { .history($0) }
        historyRows = historyPicked.count

        let urlRow = TabSearch.urlCandidate(query).map { SearchRow.url($0) }
        if next.isEmpty {
            return (urlRow.map { [$0] } ?? []) + actionRows(trimmed)
        }
        // 像网址就在末尾挂一行「在新标签打开」，有匹配时也挂 —— 用户可能就是想开它
        if let urlRow { next.append(urlRow) }
        return next
    }

    /// ↑↓ 移动游标，到头回绕（用户 2026-09-26 点名：到底就按不动太别扭）。
    /// 和切换器浮层的「越界不动」不同：那边是按住修饰键循环、方向键是辅助；
    /// 这里方向键就是主导航，列表短的时候回绕比撞墙顺手。
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (cursor + delta + rows.count) % rows.count
        setCursor(next, source: .keyboard)
    }

    /// 列表区需要的内容高度（不含输入框），面板据此定高、超过上限就滚动。
    /// 视图里分组头和行的尺寸必须和这里用同一组常量，否则面板底部裁掉半行。
    var contentHeight: CGFloat {
        guard !rows.isEmpty else { return kSearchRowHeight + kSearchListInset * 2 }
        let rowsHeight = CGFloat(rows.count) * kSearchRowHeight
            + CGFloat(rows.count - 1) * kSearchRowSpacing
        let headerHeight = kSearchSectionTopSpace + kSearchSectionHeaderHeight + kSearchSectionRuleSpace
        let flags = [hasAppSection, hasTabHeader, hasFolderSection, hasClosedSection, hasBookmarkSection, hasHistorySection]
        let headers = CGFloat(flags.filter { $0 }.count)
        // 第一个分组头顶在列表最上面时不留上空档
        let firstHeaderAtTop: CGFloat = ((hasAppSection || liveCount == 0) && headers > 0) ? kSearchSectionTopSpace : 0
        return rowsHeight + headers * headerHeight - firstHeaderAtTop + kSearchListInset * 2
    }
}

// MARK: - 尺寸

private let kSearchPanelWidth: CGFloat = 680
private let kSearchFieldHeight: CGFloat = 54
private let kSearchRowHeight: CGFloat = 44
private let kSearchRowSpacing: CGFloat = 1
private let kSearchListInset: CGFloat = 6
/// 一屏最多显示的行数，超出滚动。
private let kSearchVisibleRows = 10
/// ⌘ 数字直选的行数（⌘1–⌘9）。
let kSearchQuickPickCount = 9
/// 行 favicon 的边长。输入框里的放大镜占同样宽的格子、用同样的间距，
/// 这样占位文字和下面的标题落在同一条竖线上（同切换器列表分组头那条约定）。
private let kSearchRowIconSize: CGFloat = 22
private let kSearchIconGap: CGFloat = 10
private let kSearchRowInset: CGFloat = 10
/// 分组头：照 Raycast，就是一行小字，没有分隔线（用户 2026-09-26 拿 Raycast 对比后定的）。
/// 高度 = 上空档 + 字行 + 下空档；模型算面板高度时用同一组值。
private let kSearchSectionHeaderHeight: CGFloat = 20
private let kSearchSectionRuleSpace: CGFloat = 4
/// 分组头和上面最后一行之间的空档，不留的话两段挤成一坨（用户反馈）。
/// 分组头是列表第一行时（「全部」模式下活标签一条没命中）不留这段。
private let kSearchSectionTopSpace: CGFloat = 12

/// 列表区高度上限：满 10 行。
private let kSearchListMaxHeight: CGFloat =
    CGFloat(kSearchVisibleRows) * kSearchRowHeight
    + CGFloat(kSearchVisibleRows - 1) * kSearchRowSpacing
    + kSearchListInset * 2

private func listHeight(content: CGFloat) -> CGFloat {
    min(content, kSearchListMaxHeight)
}

private func panelHeight(content: CGFloat) -> CGFloat {
    kSearchFieldHeight + 1 + listHeight(content: content)
}

// MARK: - 输入框

/// 让面板拿得到 SwiftUI 里那个 NSTextField（焦点、输入源都要在面板层做）。
@MainActor
final class SearchFieldHandle {
    weak var field: NSTextField?
    /// 输入法正在组字（field editor 有 marked text）。组字期间不能刷新列表、不能改
    /// 窗口高度 —— 那会把组字打断，上屏的就是拼音（用户 2026-09-26 反馈）。
    var isComposing: Bool {
        (field?.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }
    /// 组字结束、文字真正落定了。面板用它把攒着的尺寸变化补上。
    var onCommit: (() -> Void)?
}

/// 顶部输入框。用 NSTextField 而不是 SwiftUI TextField，为的是两件事：
/// 面板一弹出就能把它设成 first responder（不靠 FocusState 碰运气），
/// 以及 ↑↓ / 回车 / Esc 走 `doCommandBy` —— 中文输入法组字期间这些键归输入法，
/// 系统不会调到这里，天然不会打断组字。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let handle: SearchFieldHandle
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Tab = +1，⇧Tab = -1。
    let onTab: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        // **必须是 NSSearchField，不能是 NSTextField**（2026-09-26 二分出来的）：
        // 普通文本框一建出来，SafariPlatformSupport 就会在本进程里挂一个自动填充
        // 卡片窗口（`SPRoundedWindow`，312×237 的 `NSRemoteView`），正常隐藏，但偶尔
        // 会上屏一帧 —— 就是用户反复报的「输入框下面闪一下小卡片」。关焦点、关掉
        // 全部自动功能、指定 contentType 都压不住；系统对搜索框不挂 AutoFill。
        // 搜索框自带的放大镜 / 取消钮 / 圆角底全部剥掉，外观由 SwiftUI 这边画。
        let field = NSSearchField()
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.isBezeled = false
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 20),
                         .foregroundColor: NSColor.secondaryLabelColor])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // 组字期间文本框里是「你好nih」、模型里是「你好」，这时候任何一次刷新（历史
        // 记录的回包到了、图标到了）都会走到这里；把模型的值写回去等于把组字掐断，
        // 上屏的就是拼音（用户 2026-09-26 报的「打字瞬间输入法出问题」）。
        // 模型只在打开面板时主动清空，其余时候文本框才是事实源。
        if !handle.isComposing, field.stringValue != text { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 20),
                             .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // 组字中的临时文字不算输入：不刷新列表，等上屏了再一起来
            guard !parent.handle.isComposing else { return }
            parent.text = field.stringValue
            parent.handle.onCommit?()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):        parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):          parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):   parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.insertTab(_:)):       parent.onTab(1)
            case #selector(NSResponder.insertBacktab(_:)):   parent.onTab(-1)
            default: return false
            }
            return true
        }
    }
}

// MARK: - SwiftUI 内容

private struct TabSearchView: View {
    @ObservedObject var model: TabSearchModel
    let fieldHandle: SearchFieldHandle
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: kSearchIconGap) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: kSearchRowIconSize)
                SearchField(text: $model.query,
                            placeholder: placeholder,
                            handle: fieldHandle,
                            onMove: { model.move($0) },
                            onSubmit: {
                                guard model.rows.indices.contains(model.cursor) else { return }
                                model.onPick?(model.rows[model.cursor])
                            },
                            onCancel: { if !model.escape() { onCancel() } },
                            onTab: { model.cycleMode($0) })
                    .frame(maxWidth: .infinity)

                modeIndicator
            }
            .padding(.horizontal, kSearchListInset + kSearchRowInset)
            .frame(height: kSearchFieldHeight)

            Divider().opacity(0.6)

            if model.rows.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: listHeight(content: model.contentHeight))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: kSearchRowSpacing) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                VStack(spacing: 0) {
                                    if index == 0, model.hasAppSection {
                                        sectionHeader(L10n.t("应用", "Apps"), first: true)
                                    }
                                    if index == 0, model.hasFolderSection {
                                        sectionHeader(L10n.t("文件夹", "Folders"), first: true)
                                    }
                                    if index == model.liveStart, model.hasTabHeader {
                                        sectionHeader(L10n.t("标签", "Tabs"), first: false)
                                    }
                                    if index == model.liveStart + model.liveCount, model.hasClosedSection {
                                        sectionHeader(L10n.t("最近关闭", "Recently closed"), first: index == 0)
                                    }
                                    if index == model.bookmarkStart, model.hasBookmarkSection {
                                        sectionHeader(L10n.t("书签", "Bookmarks"), first: index == 0)
                                    }
                                    if index == model.historyStart, model.hasHistorySection {
                                        sectionHeader(L10n.t("历史记录", "History"), first: index == 0)
                                    }
                                    SearchRowView(
                                        row: row,
                                        icon: model.icons[row.favIconUrl],
                                        selected: index == model.cursor,
                                        isCurrent: row.id == model.currentID,
                                        quickKey: model.commandHeld && index < kSearchQuickPickCount
                                                  ? index + 1 : nil,
                                        closable: model.canCloseTabs,
                                        browserBadge: model.showBrowserBadges ? row.browser : nil,
                                        searchBrowser: model.searchBrowser,
                                        defaultOpener: model.openers.first,
                                        defaultOpenerIcon: model.openers.first.flatMap { model.icons["file:" + $0.path] },
                                        onHover: { model.setCursor(index, source: .mouse) },
                                        onPick: { model.onPick?(row) },
                                        onClose: { model.onCloseTab?(row.id) })
                                }
                                .id(row.id)
                            }
                        }
                        .padding(kSearchListInset)
                    }
                    .frame(height: listHeight(content: model.contentHeight))
                    .onChange(of: model.cursor) { _, cursor in
                        guard model.cursorSource == .keyboard,
                              model.rows.indices.contains(cursor) else { return }
                        proxy.scrollTo(model.rows[cursor].id, anchor: nil)
                    }
                }
            }
        }
        .frame(width: kSearchPanelWidth)
        // 玻璃和内容之间垫一层色。玻璃的明暗由背后的网页决定（`tintColor` 只偏色相、
        // 不改明度，PasteMemo 那轮屏上量过），深色外观浮在白底网页上就是一块浑浊的
        // 中灰（用户 2026-09-26 截图）。深色压黑、浅色提白，保留一点透感即可 ——
        // 判据是「它可能出现在哪些背景上」：浏览器里多数是白底页。
        .background(scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.35))
        // 窗口是 titled（见 present 里的说明），隐藏了的标题栏仍算安全区，
        // 不忽略的话输入框上方会空出一条标题栏高度
        .ignoresSafeArea()
    }

    /// 输入框右侧的当前模式：模式名 + ⇥ 提示，点一下切到下一个（用户不要单独一行胶囊）。
    private var modeIndicator: some View {
        HStack(spacing: 6) {
            Text(model.mode.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.16 : 0.09)))
            Text("⇥")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.40))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.10)))
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { model.cycleMode(1) }
        .help(L10n.t("Tab 切换：\(model.modes.map(\.label).joined(separator: " → "))",
                     "Tab cycles: \(model.modes.map(\.label).joined(separator: " → "))"))
    }

    /// 输入框占位跟着模式走（用户点名：写死「搜索标签」和列表对不上）。
    private var placeholder: String {
        switch model.mode {
        case .all:       return L10n.t("搜索全部", "Search everything")
        case .tabs:      return L10n.t("搜索标签", "Search tabs")
        case .actions:   return L10n.t("搜索互联网内容", "Search the web")
        case .history:   return L10n.t("搜索历史记录", "Search history")
        case .bookmarks: return L10n.t("搜索书签", "Search bookmarks")
        case .closed:    return L10n.t("搜索最近关闭的标签", "Search recently closed tabs")
        case .folders:   return model.openerPicker.map { L10n.t("用哪个打开「\($0.name)」", "Open “\($0.name)” with…") }
                             ?? L10n.t("搜索收藏的文件夹", "Search favorite folders")
        case .apps:      return L10n.t("搜索应用", "Search apps")
        }
    }

    /// 列表空着时那句话，按模式说清「为什么空」。
    private var emptyText: String {
        let noQuery = model.query.trimmingCharacters(in: .whitespaces).isEmpty
        switch model.mode {
        case .all, .tabs: return model.all.isEmpty ? L10n.t("还没有标签", "No tabs yet") : L10n.t("没有匹配的标签", "No matching tabs")
        case .actions:   return L10n.t("输入要搜的内容", "Type something to search for")
        case .history:   return noQuery ? L10n.t("还没有历史记录", "No history yet") : L10n.t("没有匹配的历史记录", "No matching history")
        case .bookmarks: return noQuery ? L10n.t("还没有书签", "No bookmarks yet") : L10n.t("没有匹配的书签", "No matching bookmarks")
        case .closed:    return noQuery ? L10n.t("还没有关闭过标签", "Nothing closed yet") : L10n.t("没有匹配的已关闭标签", "No matching closed tabs")
        case .folders:   return model.folders.isEmpty ? L10n.t("还没有收藏文件夹。状态栏菜单里可以添加。", "No favorite folders yet. Add one from the menu bar.") : L10n.t("没有匹配的文件夹", "No matching folders")
        case .apps:      return model.apps.isEmpty ? L10n.t("正在读取应用列表", "Loading apps") : L10n.t("没有匹配的应用", "No matching apps")
        }
    }

    /// 分组头：一行小字，和下面行的标题左对齐，没有分隔线（Raycast 的样子）。
    /// `first` = 它是列表第一行，上面不留空档。
    private func sectionHeader(_ title: String, first: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.5))
                .padding(.leading, kSearchRowIconSize + kSearchIconGap)
            Spacer(minLength: 8)
        }
        .frame(height: kSearchSectionHeaderHeight)
        .padding(.top, first ? 0 : kSearchSectionTopSpace)
        .padding(.bottom, kSearchSectionRuleSpace)
        .padding(.horizontal, kSearchRowInset)
    }
}

/// 列表里的一行：favicon、标题、域名；行尾按住 ⌘ 时是 ⌘n 角标，hover 时（活标签）
/// 是 ✕（关标签的唯一入口，⌘⌫ 留给删输入），否则是「多久之前」（当前标签写「当前」，已关闭写「x 前关闭」）。
private struct SearchRowView: View {
    let row: SearchRow
    let icon: IconInfo?
    let selected: Bool
    let isCurrent: Bool
    let quickKey: Int?
    let closable: Bool
    /// 非 nil 时行尾画这个浏览器的图标（跨浏览器搜索、多浏览器）。
    let browserBadge: String?
    /// 「搜索」操作行行首画的浏览器（搜索会发给它）。
    let searchBrowser: String?
    /// 文件夹行：回车默认用的打开方式及其图标。
    let defaultOpener: OpenerApp?
    let defaultOpenerIcon: IconInfo?
    let onHover: () -> Void
    let onPick: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var lastMouseScreenPoint: CGPoint?
    @State private var hovering = false

    private var title: String {
        switch row {
        case .tab(let item):     return item.tab.title.isEmpty ? item.tab.url : Self.decodeEntities(item.tab.title)
        case .closed(let entry): return entry.title.isEmpty ? entry.url : Self.decodeEntities(entry.title)
        case .url:               return L10n.t("在新标签打开", "Open in new tab")
        case .bookmark(let bm):  return bm.title.isEmpty ? bm.url : Self.decodeEntities(bm.title)
        case .history(let h):    return h.title.isEmpty ? h.url : Self.decodeEntities(h.title)
        case .action(let a):     return a.title
        case .folder(let f):     return f.name
        case .opener(let o, _):  return o.name
        case .app(let a):        return a.name
        }
    }

    /// 书签 / 历史的标题偶尔带着没解码的 HTML 实体（`&#x27;s`），只解常见那几个，
    /// 不走 NSAttributedString 的 HTML 解析（那个要起 WebKit，太重）。
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    /// 书签的副标题是「文件夹 · 完整地址」（用户要看到地址；放不下末尾省略），根下的只有地址。
    private var subtitle: String {
        switch row {
        case .tab(let item):     return Self.host(of: item.tab.url)
        case .closed(let entry): return Self.host(of: entry.url)
        case .url(let url):      return url
        case .bookmark(let bm):  return bm.path.isEmpty ? bm.url : "\(bm.path) · \(bm.url)"
        case .history(let h):    return Self.host(of: h.url)
        case .action(let a):     return a.subtitle
        case .folder(let f):     return (f.path as NSString).abbreviatingWithTildeInPath
        case .opener(_, let f):  return L10n.t("打开「\(f.name)」", "Open “\(f.name)”")
        case .app(let a):        return (a.path as NSString).deletingLastPathComponent
        }
    }

    /// 曾把已关闭 / 历史的行压成灰字以示「找回」；有了模式标签和分组头之后是双重标记，
    /// 只剩可读性变差，2026-09-26 和其他行统一。留着这个开关是为了以后要区分时有地方改。
    private var dimmed: Bool { false }

    private var isTab: Bool {
        if case .tab = row { return true }
        return false
    }

    private static func host(of url: String) -> String {
        guard var host = URL(string: url)?.host else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.count > 40 ? "…" + host.suffix(38) : host
    }

    var body: some View {
        HStack(spacing: kSearchIconGap) {
            leadingIcon
                .frame(width: kSearchRowIconSize, height: kSearchRowIconSize)
                .opacity(dimmed ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(dimmed ? Color.primary.opacity(0.55)
                                                : (selected ? Color.primary : Color.primary.opacity(0.85)))
                    if case .tab(let item) = row, item.tab.pinned == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(dimmed ? 0.32 : 0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, kSearchRowInset)
        .frame(height: kSearchRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.20)
                                                  : Color.black.opacity(0.10))
                               : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                let point = NSEvent.mouseLocation
                if let last = lastMouseScreenPoint,
                   abs(point.x - last.x) > 1 || abs(point.y - last.y) > 1 {
                    onHover()
                }
                lastMouseScreenPoint = point
            case .ended:
                hovering = false
                lastMouseScreenPoint = nil
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch row {
        case .url:
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
        case .bookmark, .history:
            // 图标由 helper 按域名向扩展要（Chrome 缓存的），还没到就先用类型图标占位
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: { if case .bookmark = row { return "bookmark" } else { return "clock" } }())
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        case .folder, .opener, .app:
            // 本机文件 / App 的图标由 iconProvider 同步取（`file:` 键）；App 图标自带透明边距，放大画
            if let icon {
                let isApp: Bool = { if case .folder = row { return false } else { return true } }()
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: kSearchRowIconSize + (isApp ? 6 : 2), height: kSearchRowIconSize + (isApp ? 6 : 2))
            } else {
                Image(systemName: { if case .folder = row { return "folder" } else { return "app" } }())
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        case .action(.webSearch):
            // 默认搜索引擎那行用要执行搜索的那个浏览器的 App 图标（用户点名）
            if let searchBrowser, let appIcon = BrowserSupport.icon(searchBrowser) {
                // App 图标自带一圈透明边距，按 favicon 的格子画会显小：放大到 28pt 居中，
                // 外层 22pt 的格子不变，文字位置不动
                Image(nsImage: appIcon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: kSearchRowIconSize + 6, height: kSearchRowIconSize + 6)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .action(let a):
            // 站内搜索用那个站的 favicon（和书签行同一条路取），没到之前用类型图标
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: a.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        default:
            Group {
                if let icon {
                    Image(nsImage: icon.image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let quickKey {
            Text("⌘\(quickKey)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.10)))
        } else if hovering, isTab, closable {
            // hover 到活标签：行尾的时间换成 ✕，点它关掉这个标签，面板不关
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help(L10n.t("关闭标签", "Close tab"))
        } else if let browserBadge, let icon = BrowserSupport.icon(browserBadge) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .opacity(0.85)
                .help(BrowserSupport.displayName(browserBadge))
        } else {
            switch row {
            case .tab(let item):
                if isCurrent {
                    Text(L10n.t("当前", "Current"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                } else if let ago = item.tab.relativeLastAccessed {
                    Text(ago)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .closed(let entry):
                if let ago = relativeTime(msEpoch: entry.closedAt) {
                    Text(L10n.t("\(ago)关闭", "closed \(ago)"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .url:
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.30))
            case .bookmark:
                Text(L10n.t("书签", "Bookmark"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.30))
            case .history(let h):
                if let ago = relativeTime(msEpoch: h.lastVisitTime) {
                    Text(L10n.t("\(ago)访问", "visited \(ago)"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .action, .opener:
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.30))
            case .folder:
                // 回车会用哪个 App 开：画它的图标；旁边提示 ⌘↩ 可以换
                HStack(spacing: 6) {
                    if let opener = defaultOpener, let appIcon = defaultOpenerIcon {
                        Image(nsImage: appIcon.image).resizable().scaledToFit()
                            .frame(width: 18, height: 18)
                            .help(opener.name)
                    }
                    Text("⌘↩")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .app(let a):
                if a.isRunning {
                    Text(L10n.t("运行中", "Running"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            }
        }
    }
}

// MARK: - 承载面板

/// 能拿 key 但**不激活 App** 的面板。
///
/// 和切换器浮层的红线不冲突：那条红线是为了测 Ctrl 松开的时机，而搜索面板由
/// 一次性快捷键唤出，没有「按住」这回事。`.nonactivatingPanel` + canBecomeKey 让
/// 键盘输入进面板、浏览器仍是前台 App —— 菜单栏不会切成我们的、浏览器窗口
/// 也不会退到后面，关掉面板键盘焦点自动回到浏览器。
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TabSearchPanel {

    let model = TabSearchModel()

    /// 面板**常驻**，启动时就建好（`warmUp`），之后每次 show 复用。
    ///
    /// 照 PasteMemo 快捷面板的做法：SwiftUI 首次布局、玻璃首次实例化、输入框首次
    /// 建 field editor 这些一次性开销和抖动全在启动时的离屏预热里发生，用户按 ⌘E
    /// 看到的永远是「第二次」。第一版每次 show 新建、close 销毁，首次打开输入框下方
    /// 会闪一块空白（2026-09-26 用户反馈），demo 复现不出，改成常驻后消失。
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TabSearchView>?
    private let fieldHandle = SearchFieldHandle()
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// 面板顶边的屏幕 y。行数变了面板只从底部伸缩，顶边不动。
    private var topY: CGFloat = 0
    private var visibleFrame = NSRect.zero
    private var shown = false
    /// 本轮是跨浏览器搜索：贴屏幕居中偏上，不再依赖浏览器窗口定位。
    private var isGlobal = false

    var isVisible: Bool { shown }

    /// 面板关掉了（无论哪种方式）。event tap 靠它收回「键盘归面板」的标志。
    var onClose: (() -> Void)?

    /// 用户选定了一项。面板已关。
    var pickHandler: ((SearchPick) -> Void)?
    /// 用户要在面板里关掉一个活标签（参数 item.id）。面板不关。
    var closeHandler: ((String) -> Void)?
    /// 面板里按了 ⌘,：面板已关，去开设置。
    var openSettingsHandler: (() -> Void)?
    /// 输入变了（已去首尾空白）。MRUController 拿它去问扩展要历史记录。
    var queryHandler: ((String) -> Void)? {
        didSet { model.onQueryChange = queryHandler }
    }
    /// 模式切换了。历史记录模式要去问扩展要最近的。
    var modeHandler: ((SearchMode) -> Void)? {
        didSet { model.onModeChange = modeHandler }
    }
    var currentMode: SearchMode { model.mode }

    /// 扩展回了某个查询的历史记录。
    func setHistory(_ items: [HistoryInfo], for query: String) {
        guard shown else { return }
        model.setHistory(items, for: query)
    }

    init() {
        model.onPick = { [weak self] row in
            // 先关面板再切：关面板会把 key 还给浏览器，切换命令随后到达时
            // 焦点已经在它那边了。
            let pick = self?.pickHandler
            self?.close()
            switch row {
            case .tab(let item):     pick?(.tab(item))
            case .closed(let entry): pick?(.closed(entry))
            case .url(let url):      pick?(.url(url))
            case .bookmark(let bm):  pick?(.bookmark(bm))
            case .history(let h):    pick?(.history(h))
            case .action(let a):     pick?(.action(a))
            case .folder(let f):     pick?(.folder(f, nil))
            case .opener(let o, let f): pick?(.folder(f, o))
            case .app(let a):        pick?(.app(a))
            }
        }
        model.onCloseTab = { [weak self] itemID in self?.closeHandler?(itemID) }
        model.onContentHeightChange = { [weak self] height in self?.resizeToContent(height) }
        fieldHandle.onCommit = { [weak self] in
            guard let self, let pending = self.pendingContentHeight else { return }
            self.resizeToContent(pending)
        }
    }

    /// 启动时调用：在屏幕外把面板整棵建出来并画一遍，然后收起。
    func warmUp() {
        guard panel == nil else { return }
        let panel = buildPanel()
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
        log("🔍 tab search panel warmed up")
    }

    func show(items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
              folders: [FavoriteFolder] = [], apps: [AppEntry] = [], openers: [OpenerApp] = [],
              siteSearches: [SiteSearch], modes: [SearchMode], allEmptyContent: SearchMode? = .tabs,
              icons: [String: IconInfo],
              global: Bool = false, showBrowserBadges: Bool = false, searchBrowser: String? = nil) {
        if shown { close() }
        isGlobal = global
        model.siteSearches = siteSearches
        model.allEmptyContent = allEmptyContent
        model.modes = modes
        model.showBrowserBadges = showBrowserBadges
        model.searchBrowser = searchBrowser
        // 此刻浏览器还是前台、还没有任何我们的窗口拿 key，读到的就是用户正在用的输入源
        let inputSource = Self.currentInputSourceID()
        model.query = ""
        model.resetMode()   // 上一轮停在别的模式的话回到第一个
        model.icons = icons
        model.setItems(items, closed: closed, bookmarks: bookmarks,
                       folders: folders, apps: apps, openers: openers, keepCursor: false)
        // ⌘E 唤出时 ⌘ 多半还按着，角标要立刻出现，不等下一次 flagsChanged
        model.commandHeld = NSEvent.modifierFlags.contains(.command)
        present(inputSource: inputSource)
    }

    /// 面板开着时数据变了（MRU 推送 / 在面板里关了标签）。
    /// `animated` 给关标签用：那一行淡出、下面的行滑上来。
    func update(items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
                folders: [FavoriteFolder] = [], apps: [AppEntry] = [], openers: [OpenerApp] = [],
                icons: [String: IconInfo], animated: Bool = false) {
        guard shown else { return }
        model.icons = icons
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                model.setItems(items, closed: closed, bookmarks: bookmarks,
                               folders: folders, apps: apps, openers: openers)
            }
        } else {
            model.setItems(items, closed: closed, bookmarks: bookmarks,
                           folders: folders, apps: apps, openers: openers)
        }
    }

    func close() {
        guard shown, let panel else { return }
        shown = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
        onClose?()
    }

    private func present(inputSource: String?) {
        if panel == nil { warmUp() }
        guard let panel else { return }

        // 贴着浏览器窗口水平居中、偏上（Spotlight 的位置）；拿不到窗口或跨浏览器时按屏幕。
        let defaultScreen = NSScreen.main ?? NSScreen.screens[0]
        let anchor = (isGlobal ? nil : ChromeWindowLocator.frontmostWindowFrame()) ?? defaultScreen.visibleFrame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? defaultScreen
        visibleFrame = screen.visibleFrame
        topY = anchor.maxY - anchor.height * 0.16

        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: model.contentHeight))
        panel.setFrame(frame(for: size, midX: anchor.midX), display: true)

        shown = true
        installMonitors(for: panel)
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel, inputSource: inputSource)
        if !OverlayPanel.usesGlassBackdrop { WindowShadow.applyStandardWindowShadow(to: panel) }
    }

    /// 把焦点交给输入框。输入源要在 makeFirstResponder **之前**钉成前台 App 正在用的
    /// 那个：系统开着「自动切换到文稿的输入法」时每个进程各记各的输入源，我们进程
    /// 第一次激活文本输入会被分配一个默认的，和浏览器里那个不一致就切一次，光标下
    /// 弹一下输入源指示器。
    private func focusField(in panel: NSPanel, inputSource: String?) {
        guard let field = fieldHandle.field else { return }
        if let editor = panel.fieldEditor(true, for: field) as? NSTextView {
            if let inputSource { editor.inputContext?.selectedKeyboardInputSource = inputSource }
            // 搜索框不需要 Writing Tools / 自动补全
            if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
            editor.isAutomaticTextCompletionEnabled = false
        }
        panel.makeFirstResponder(field)
    }

    private func buildPanel() -> NSPanel {
        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: model.contentHeight))
        let hosting = NSHostingView(rootView: TabSearchView(model: model, fieldHandle: fieldHandle,
                                                            onCancel: { [weak self] in
            self?.close()
        }))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        hosting.safeAreaRegions = []   // 标题栏不占内容空间（见下面 titled 的说明）
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.cornerRadius = OverlayPanel.panelCornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        // **必须是 .titled 而不是 .borderless**（2026-09-26 demo 逐个试过）：borderless
        // 面板一拿 key，WindowServer 就按整块矩形给它画 key 窗口的阴影 rim —— 屏上是
        // 四个直角 + 一圈深色描边 + 没有软阴影。`invalidateShadow`、先 orderFront 再
        // makeKey、orderOut 再上屏，全都没用。titled 窗口会登记自己的圆角形状，
        // 阴影就跟着圆角走；标题栏透明 + 隐藏 + fullSizeContentView 之后看不出区别。
        // 切换器浮层不受影响 —— 它永远不拿 key。
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // titled 之后顶部那条（隐形的）标题栏区域默认可拖，面板不该被拖走
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = OverlayPanel.makeBackdrop(size: size, content: hosting)

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    private func installMonitors(for panel: NSPanel) {
        // ⌘ 按下 / 松开 → 行尾角标显隐
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.model.commandHeld = event.modifierFlags.contains(.command)
            return event
        }!)

        // ⌘1–⌘9 直选。↑↓ / 回车 / Esc 归输入框的 doCommandBy
        //（见 SearchField），这里只管带 ⌘ 的键 —— 输入法组字期间不会有这些组合。
        //
        // ⌘Q / ⌘W / ⌘, 也要在这里截住：面板是 key window，这些 key equivalent 会
        // 路由到**我们自己的**主菜单 —— 用户想退的是浏览器，退掉的却是 TabFlick。
        // 一律当作「关掉面板」，键本身吞掉，用户再按一次就到浏览器了。
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘⌫ 不接管：那是删掉整段输入的键（用户 2026-09-26 点名），关标签只留 hover ✕
            guard mods == .command else { return event }
            // ⌘↩：文件夹行展开打开方式
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                if self.model.rows.indices.contains(self.model.cursor),
                   case .folder(let folder) = self.model.rows[self.model.cursor] {
                    self.model.showOpeners(for: folder)
                }
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            if let n = Int(chars), (1...kSearchQuickPickCount).contains(n) {
                if self.model.rows.indices.contains(n - 1) {
                    self.model.onPick?(self.model.rows[n - 1])
                }
                return nil
            }
            if chars == "," {
                // ⌘,：关面板、开设置（用户 2026-09-26 要的）
                self.close()
                self.openSettingsHandler?()
                return nil
            }
            if ["q", "w"].contains(chars.lowercased()) {
                self.close()
                return nil
            }
            return event
        }!)

        // 点到别处 / 切走 App：面板失去 key 就收起。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// 内容高度变了：从底部伸缩，顶边和水平位置不动。
    ///
    /// **不做动画**：窗口 frame 动画期间每一帧都重新布局，输入框和列表跟着
    /// 整块抖（用户原话「整个框在抖动」）。Spotlight / Alfred 都是瞬时改高度，
    /// 观感就是「输入框下面的内容少了一截」。
    private var pendingContentHeight: CGFloat?

    private func resizeToContent(_ contentHeight: CGFloat) {
        guard let panel else { return }
        // 组字期间不动窗口（历史记录的回包这时候也可能到）：攒着，上屏后补
        if fieldHandle.isComposing { pendingContentHeight = contentHeight; return }
        pendingContentHeight = nil
        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: contentHeight))
        guard size != panel.frame.size else { return }
        panel.setFrame(frame(for: size, midX: panel.frame.midX), display: true)
    }

    /// 当前选中的键盘输入源 id（如 com.tencent.inputmethod.wetype.pinyin）。
    private static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private func frame(for size: NSSize, midX: CGFloat) -> NSRect {
        var frame = NSRect(x: midX - size.width / 2, y: topY - size.height,
                           width: size.width, height: size.height)
        if frame.maxX > visibleFrame.maxX { frame.origin.x = visibleFrame.maxX - frame.width }
        if frame.minX < visibleFrame.minX { frame.origin.x = visibleFrame.minX }
        if frame.maxY > visibleFrame.maxY { frame.origin.y = visibleFrame.maxY - frame.height }
        if frame.minY < visibleFrame.minY { frame.origin.y = visibleFrame.minY }
        return frame
    }
}
