import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 行与选中结果

/// 面板列表里的一行。三种来源混排在同一张列表里，游标和 ⌘ 数字按屏上顺序连续编号。
/// 列表的一段：「全部」里每种内容一段、带分组头（吸顶）；其他模式整张表一段、不带头。
struct SearchSection {
    let id: String
    let title: String?
    let range: Range<Int>
    /// 截断后没显示的条数（分组头右边写「还有 N 条」）。
    var hidden = 0
    /// 只知道还有、不知道几条（历史记录：扩展只回前 20 条），头上写「更多」。
    var moreUnknown = false
    /// 截断了且对应模式开着：Tab 跳过去看全部（头上画 ⇥）。
    var jump: SearchMode?
}

/// 「全部」里一段装的是什么：决定分组头的名字，以及截断后 Tab 跳去哪个模式。
enum SearchSectionKind: String {
    case top, ops, apps, folders, tabs, closed, bookmarks, history

    var title: String {
        switch self {
        case .top:       return L10n.t("最佳匹配", "Top Hit")
        case .ops:       return L10n.t("操作", "Actions")
        case .apps:      return L10n.t("应用", "Apps")
        case .folders:   return L10n.t("文件夹", "Folders")
        case .tabs:      return L10n.t("浏览器标签", "Browser tabs")
        case .closed:    return L10n.t("最近关闭", "Recently closed")
        case .bookmarks: return L10n.t("浏览器书签", "Browser bookmarks")
        case .history:   return L10n.t("历史记录", "History")
        }
    }

    var mode: SearchMode? {
        switch self {
        case .top:       return nil
        case .ops:       return .actions
        case .apps:      return .apps
        case .folders:   return .folders
        case .tabs:      return .tabs
        case .closed:    return .closed
        case .bookmarks: return .bookmarks
        case .history:   return .history
        }
    }

    /// 「全部」没输入时按设置列的那种内容。
    init?(content: SearchMode) {
        switch content {
        case .tabs:      self = .tabs
        case .history:   self = .history
        case .bookmarks: self = .bookmarks
        case .closed:    self = .closed
        case .folders:   self = .folders
        case .apps:      self = .apps
        case .all, .actions: return nil
        }
    }
}

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
    /// ⌘↩ 展开的「操作」里的一项：对 target 那一行做什么
    indirect case command(RowCommand, SearchRow)

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
        // 用 rawValue 拼：第一版给 RowCommand 写了 description = String(reflecting: self)，
        // 而 String(reflecting:) 会回头调 description —— 无限递归，打开面板画第一行操作就栈溢出崩溃
        case .command(let c, let target): return "cmd#\(c.rawValue)#\(target.id)"
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
        case .command(.primary, let target): return target.favIconUrl
        case .url, .action, .command: return ""
        }
    }

    /// 需要向扩展要图标时用的页面地址（书签 / 历史 / 站内搜索）。
    var faviconPageURL: String? {
        switch self {
        case .bookmark(let bm): return bm.url
        case .history(let h):   return h.url
        case .action(.siteSearch(let site, _)): return "https://" + site.host + "/"
        case .command(.primary, let target): return target.faviconPageURL
        default:                return nil
        }
    }

    static func siteKey(_ url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "" }
        return "site:" + host
    }

    /// 行上显示的标题。书签 / 历史的标题偶尔带没解码的 HTML 实体，这里一并解掉。
    var displayTitle: String {
        switch self {
        case .tab(let item):     return item.tab.title.isEmpty ? item.tab.url : Self.decodeEntities(item.tab.title)
        case .closed(let entry): return entry.title.isEmpty ? entry.url : Self.decodeEntities(entry.title)
        case .url:               return L10n.t("在新标签打开", "Open in new tab")
        case .bookmark(let bm):  return bm.title.isEmpty ? bm.url : Self.decodeEntities(bm.title)
        case .history(let h):    return h.title.isEmpty ? h.url : Self.decodeEntities(h.title)
        case .action(let a):     return a.title
        case .folder(let f):     return f.name
        case .opener(let o, _):  return o.name
        case .app(let a):        return a.name
        case .command(let c, let target): return c.title(for: target)
        }
    }

    /// 只解常见那几个实体，不走 NSAttributedString 的 HTML 解析（那个要起 WebKit，太重）。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    /// 回车会做的事（底部操作栏右边那句）。文件夹要知道默认打开方式。
    func enterTitle(defaultOpener: OpenerApp?) -> String {
        switch self {
        case .tab:               return L10n.t("切换到标签", "Switch to tab")
        case .closed:            return L10n.t("重新打开", "Reopen")
        case .url, .bookmark, .history: return L10n.t("在新标签打开", "Open in new tab")
        case .action(let a):     return a.title   // 「搜索“xx”」；不借模式名那个「搜索」的键，西法德译的是名词
        case .folder:            return defaultOpener.map { L10n.t("用 \($0.name) 打开", "Open with \($0.name)") }
                                     ?? L10n.t("打开", "Open")
        case .opener(let o, _):  return L10n.t("用 \(o.name) 打开", "Open with \(o.name)")
        case .app:               return L10n.t("打开应用", "Open application")
        case .command(let c, let target): return c.title(for: target)
        }
    }

    /// 记忆里按什么认这一行（和 `SearchCandidate.identity` 同一个口径）：网页是网址，
    /// 文件夹 / App 是路径。搜索、站内搜索这类一次性操作不记。
    var memoryIdentity: String? {
        switch self {
        case .tab(let item):     return item.tab.url
        case .closed(let entry): return entry.url
        case .bookmark(let bm):  return bm.url
        case .history(let h):    return h.url
        case .url(let url):      return url
        case .folder(let f):     return f.path
        case .opener(_, let f):  return f.path
        case .app(let a):        return a.path
        case .command(.primary, let target): return target.memoryIdentity
        case .action, .command:  return nil
        }
    }

    /// 网页类行的地址 / 标题（拷贝用）；本机类行的路径。
    var pageURL: String? {
        switch self {
        case .tab(let item):     return item.tab.url
        case .closed(let entry): return entry.url
        case .bookmark(let bm):  return bm.url
        case .history(let h):    return h.url
        case .url(let url):      return url
        default:                 return nil
        }
    }

    var filePath: String? {
        switch self {
        case .folder(let f): return f.path
        case .app(let a):    return a.path
        default:             return nil
        }
    }

    /// 某个拷贝操作要拷的文字。
    func copyText(for command: RowCommand) -> String? {
        switch command {
        case .copyURL:      return pageURL
        case .copyTitle:    return pageURL == nil ? nil : displayTitle
        case .copyMarkdown: return pageURL.map { TabSearch.markdownLink(title: displayTitle, url: $0) }
        case .copyPath:     return filePath
        default:            return nil
        }
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
        // 「在浏览器搜索」：和下面几行「在 GitHub 搜索」同一个句式（用户 2026-09-27 改的）
        case .webSearch(let text):        return L10n.t("在浏览器搜索“\(text)”", "Search “\(text)” in the browser")
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

/// ⌘↩ 展开的「操作」里的一项（2026-09-27 照 Raycast 加的，快捷键用户定为 ⌘↩）。
/// 搜索 / 网址直达那几行本身就是一次性操作，没有二级（用户定的）。
/// 列表顺序：默认动作 → 拷贝类 → 删除类（标红、垫底，误按 ⌘1 也删不掉东西）。
enum RowCommand: String {
    /// 回车那个默认动作（切换 / 打开 / 重新打开）
    case primary
    case reloadTab
    case copyURL, copyTitle, copyMarkdown, copyPath
    case revealInFinder
    case closeTab
    /// 关掉和它同网址的其余标签（同一个浏览器 / Profile），留下它自己
    case closeDuplicates
    case removeClosed
    case deleteHistory
    case unfavorite
    case quitApp

    /// 关闭 / 删除类：标红。
    var isDestructive: Bool {
        switch self {
        case .closeTab, .closeDuplicates, .removeClosed, .deleteHistory, .unfavorite, .quitApp: return true
        default: return false
        }
    }

    /// 执行完不关面板、退回主列表，列表原地收缩（同悬停 ✕ 关标签）——
    /// 清理几条历史 / 关几个标签不用反复开面板。退出 App 例外：关面板，退没退看 Dock。
    var staysInPanel: Bool { isDestructive && self != .quitApp }

    func title(for target: SearchRow) -> String {
        switch self {
        case .primary:        return target.enterTitle(defaultOpener: nil)
        case .reloadTab:      return L10n.t("重新加载", "Reload")
        case .copyURL:        return L10n.t("拷贝网址", "Copy URL")
        case .copyTitle:      return L10n.t("拷贝标题", "Copy title")
        case .copyMarkdown:   return L10n.t("拷贝 Markdown 链接", "Copy Markdown link")
        case .copyPath:       return L10n.t("拷贝路径", "Copy path")
        case .revealInFinder: return L10n.t("在访达中显示", "Show in Finder")
        case .closeTab:       return L10n.t("关闭标签", "Close tab")
        case .closeDuplicates: return L10n.t("关闭其余重复的标签", "Close other duplicate tabs")
        case .removeClosed:   return L10n.t("从最近关闭中移除", "Remove from recently closed")
        case .deleteHistory:  return L10n.t("从历史记录中删除", "Delete from history")
        case .unfavorite:     return L10n.t("取消收藏", "Remove from Favorites")
        case .quitApp:
            if case .app(let a) = target { return L10n.t("退出 \(a.name)", "Quit \(a.name)") }
            return L10n.t("退出", "Quit")
        }
    }

    func symbol(for target: SearchRow) -> String {
        switch self {
        case .primary:
            switch target {
            case .tab:    return "arrow.right.square"
            case .closed: return "arrow.uturn.backward"
            case .app:    return "arrow.up.forward.app"
            default:      return "plus.square.on.square"
            }
        case .reloadTab:      return "arrow.clockwise"
        // 拷贝类共用一个图标、靠字区分（Raycast / Alfred 都这样）：四个各画各的图，
        // 列表里就是四种形状抢眼，反而看不出它们是一类
        case .copyURL, .copyTitle, .copyMarkdown, .copyPath: return "doc.on.doc"
        case .revealInFinder: return "folder"
        case .closeTab:       return "xmark"
        case .closeDuplicates: return "square.on.square.dashed"
        case .removeClosed, .deleteHistory: return "trash"
        case .unfavorite:     return "star.slash"
        case .quitApp:        return "power"
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
    /// ⌘↩ 展开了某一行的「操作」（子状态，Esc 退回原列表）。列表换成对它能做的事，
    /// 输入框用来过滤操作；文件夹的「打开方式」也在这里（原来单独一个子状态）。
    @Published private(set) var actionTarget: SearchRow?
    /// 展开操作前的输入和游标所在行：退回时原样恢复。
    private var savedQuery = ""
    private var savedCursorID: String?
    private var savedCursorIndex = 0
    /// 程序自己改输入（进出操作列表）：不重算、不去问历史，调用方自己 refilter。
    private var settingQueryQuietly = false
    /// 「全部」模式没输入时列什么（设置项）。nil = 空着。
    var allEmptyContent: SearchMode? = .tabs
    /// 「全部」模式下列表由哪几段拼成（按顺序），`sections` 据此切段。其他模式为空。
    private struct SectionSpec {
        let kind: SearchSectionKind
        let count: Int
        var hidden = 0
        var moreUnknown = false
    }
    private var layout: [SectionSpec] = []
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
            guard oldValue != query, !settingQueryQuietly else { return }
            refilter(keepCursorOn: nil)
            // 操作列表里的输入只是在过滤操作，不去问历史记录
            guard actionTarget == nil else { return }
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
    @Published private(set) var cursor = 0
    /// favicon，按 favIconUrl 索引（活标签和已关闭共用一份）。
    @Published var icons: [String: IconInfo] = [:]
    /// ⌘ 正被按着：行尾显示 ⌘1–⌘9 的角标。
    @Published var commandHeld = false
    /// 跨浏览器且不止一条连接（多个浏览器，或同一个浏览器多个 Profile）：行尾用浏览器图标
    /// （和 Profile 名）代替「x 分钟前」认归属。
    @Published var showBrowserBadges = false
    /// 行尾归属标记只有一条规则（用户 2026-09-27：图标、名字时有时无看不懂）：浏览器图标
    /// 只在真有多个浏览器时画，回答「在哪个浏览器」；Profile 名只在同一个浏览器开了多个
    /// Profile 时写，回答「在哪个 Profile」。每种行（标签、最近关闭、书签、历史）都一样。
    var showBrowserIcons = false
    /// 要用到的扩展该更新了（MRUController 打开面板时算好）：底栏左边给一个提示胶囊。
    @Published var extensionOutdated = false
    /// 点了那个提示胶囊。
    var onExtensionUpdateTap: (() -> Void)?
    /// 某一行属于哪个浏览器、哪个 Profile（Profile 名只在需要区分时有值），MRUController 提供。
    var badgeProvider: ((SearchRow) -> (browser: String?, profile: String?))?

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


    /// 列表按段切开。「全部」里每种内容一段、带头：分组头的有无**不能**看「前面有没有别的段」——
    /// 2026-09-27 用户截图：活标签排在最前时没有头，下面的「历史记录」有，读起来标签是无名的一段。
    /// 段序和 `allRows` 拼行的顺序一致：（操作）→ 应用 → 文件夹 → 活标签 → 已关闭 → 书签 → 历史 →（操作）。
    /// 操作段在前还是垫底见 `allRows` 末尾。操作子状态下整张表一段、不带头。视图按它画 Section，版面（`layoutWalk`）按它排。
    var sections: [SearchSection] {
        guard !rows.isEmpty else { return [] }
        guard mode == .all, actionTarget == nil, !layout.isEmpty else {
            return [SearchSection(id: "rows", title: nil, range: rows.indices)]
        }
        var out: [SearchSection] = []
        var start = 0
        for spec in layout {
            let end = min(start + spec.count, rows.count)
            guard end > start else { continue }
            let truncated = spec.hidden > 0 || spec.moreUnknown
            let jump = truncated ? spec.kind.mode.flatMap { modes.contains($0) ? $0 : nil } : nil
            out.append(SearchSection(id: spec.kind.rawValue, title: spec.kind.title, range: start..<end,
                                     hidden: spec.hidden, moreUnknown: spec.moreUnknown, jump: jump))
            start = end
        }
        if start < rows.count { out.append(SearchSection(id: "rest", title: nil, range: start..<rows.count)) }
        return out
    }

    /// 重复标签：同一条连接（浏览器 / Profile）里网址**完全相同**的有几个。数据换了算一次，
    /// 画行时只查表。不去掉 # 再比：Gmail、单页应用靠 # 区分页面（`#inbox` 和
    /// `#inbox/某封邮件`），去掉就会把两封不同的邮件当成重复、一键关掉 —— 关标签是破坏性
    /// 动作，宁可少认几个也不能误关。
    private var duplicateCounts: [String: Int] = [:]

    nonisolated static func duplicateKey(_ item: SwitcherItem) -> String {
        item.clientID.uuidString + "|" + item.tab.url
    }

    func duplicateCount(of item: SwitcherItem) -> Int { duplicateCounts[Self.duplicateKey(item)] ?? 1 }

    /// 能不能在面板里关标签：只剩一个标签时不关 —— 关掉浏览器窗口就跟着没了。
    var canCloseTabs: Bool { all.count > 1 }

    var onPick: ((SearchRow) -> Void)?
    /// 要求关掉某个活标签（参数 item.id）。
    var onCloseTab: ((String) -> Void)?

    /// 标题 → 拼音索引的缓存。逐字转拼音不算便宜，标题在两次刷新之间基本不变。
    private var pinyinCache: [String: (full: String, initials: String)] = [:]
    /// 「标题 + 网址」→ 候选项。候选项建的时候就把匹配用的小写字节算好（见 SearchCandidate），
    /// 每次按键只查字典、不再重算。标题会变（标签加载中），攒太多就整个清掉重来。
    private var candidateCache: [String: SearchCandidate] = [:]

    func setCursor(_ index: Int, source: CursorSource) {
        cursorSource = source
        cursor = index
    }

    /// Tab / ⇧Tab：按设置里的顺序循环模式。
    func cycleMode(_ delta: Int) {
        // 操作列表里 Tab 不切模式（先 Esc 退回去）
        guard actionTarget == nil, let index = modes.firstIndex(of: mode), modes.count > 1 else { return }
        select(modes[(index + delta + modes.count) % modes.count])
    }

    func select(_ next: SearchMode, keepCursorOn keep: String? = nil) {
        guard next != mode else { return }
        mode = next
        refilter(keepCursorOn: keep)
        onModeChange?(next)
    }

    /// 输入框里按了 Tab / ⇧Tab。「全部」里游标所在那段被截断了（分组头写着「还有 N 条 ⇥」）
    /// 时 Tab 直接进那一类看全部，游标留在同一条上；其余照常按顺序切模式。
    /// 点模式标签不走这里（那是明确的「切下一个」）。
    func tabPressed(_ delta: Int) {
        if delta > 0, actionTarget == nil, mode == .all,
           let jump = sections.first(where: { $0.range.contains(cursor) })?.jump {
            select(jump, keepCursorOn: selectedRow?.id)
            return
        }
        cycleMode(delta)
    }

    /// 回到顺序里的第一个模式（打开面板时、Esc 时）。返回 true 表示确实切回去了。
    @discardableResult
    func resetMode() -> Bool {
        guard let first = modes.first, first != mode else { return false }
        select(first)
        return true
    }

    /// Esc 一层层往回退（照 Raycast；用户 2026-09-27：带着输入按 Esc 整个面板没了太突然）：
    /// 操作列表展开着就先退回 → 有输入就清空、回到这个模式的首页 → 不在第一个模式就回去 →
    /// 都不是才关面板（返回 false）。组字中的 Esc 归输入法，走不到这里。
    func escape() -> Bool {
        if actionTarget != nil {
            leaveActions()
            return true
        }
        if !query.isEmpty {
            query = ""
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
        var counts: [String: Int] = [:]
        for item in items where item.tab.url.hasPrefix("http") { counts[Self.duplicateKey(item), default: 0] += 1 }
        duplicateCounts = counts
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

    /// 游标所在的那一行（没有行时 nil）。
    var selectedRow: SearchRow? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    /// 主列表层面的输入和选中项：在操作列表里就取展开前的那份（恢复现场用）。
    var baseQuery: String { actionTarget != nil ? savedQuery : query }
    var baseCursorID: String? { actionTarget != nil ? savedCursorID : selectedRow?.id }

    /// ⌘↩：展开游标那一行的操作。这一行没有二级（搜索、网址直达、操作本身）就什么都不做。
    @discardableResult
    func showActions() -> Bool {
        guard actionTarget == nil, let target = selectedRow, hasActions(target) else { return false }
        savedQuery = query
        savedCursorID = target.id
        savedCursorIndex = cursor
        actionTarget = target
        setQueryQuietly("")
        refilter(keepCursorOn: nil)
        return true
    }

    /// 退回原列表：输入和游标都恢复。执行完「关闭 / 移除」这类操作也走这里 ——
    /// 先退回（游标回到那一行），数据随后刷新时那一行没了，游标落在同一位置的下一行。
    func leaveActions() {
        guard actionTarget != nil else { return }
        actionTarget = nil
        setQueryQuietly(savedQuery)
        refilter(keepCursorOn: savedCursorID)
        if let savedCursorID, rows.firstIndex(where: { $0.id == savedCursorID }) == nil, !rows.isEmpty {
            setCursor(min(savedCursorIndex, rows.count - 1), source: .keyboard)
        }
    }

    /// 面板收起 / 重新打开：丢掉操作子状态，不恢复什么。
    func clearActions() {
        actionTarget = nil
    }

    private func setQueryQuietly(_ text: String) {
        settingQueryQuietly = true
        query = text
        settingQueryQuietly = false
    }

    func hasActions(_ row: SearchRow) -> Bool { !commandRows(for: row).isEmpty }

    /// 某一行的操作列表。第一项是回车的默认动作（文件夹是默认打开方式，后面跟其他打开方式）。
    func commandRows(for target: SearchRow) -> [SearchRow] {
        let copies: [RowCommand] = [.copyURL, .copyTitle, .copyMarkdown]
        let commands: [RowCommand]
        switch target {
        case .tab:
            // 只剩一个标签不给关：浏览器窗口会跟着没（同悬停 ✕）
            let dupes: [RowCommand] = { if case .tab(let item) = target, duplicateCount(of: item) > 1 { return [.closeDuplicates] } else { return [] } }()
            commands = [.primary, .reloadTab] + copies + dupes + (canCloseTabs ? [.closeTab] : [])
        case .closed:
            commands = [.primary] + copies + [.removeClosed]
        case .bookmark:
            // 不给删书签：删了找不回来，一个按键就执行的面板里误触代价太大（用户定的）
            commands = [.primary] + copies
        case .history:
            commands = [.primary] + copies + [.deleteHistory]
        case .folder(let folder):
            return openers.map { .opener($0, folder) }
                + [RowCommand.copyPath, .revealInFinder, .unfavorite].map { .command($0, target) }
        case .app(let app):
            commands = [.primary, .revealInFinder, .copyPath] + (app.isRunning ? [.quitApp] : [])
        case .url, .action, .opener, .command:
            return []
        }
        return commands.map { .command($0, target) }
    }

    /// 面板里删了一条历史：本地先摘掉（扩展删完不会推送），游标留在原位。
    func removeHistory(url: String) {
        history.removeAll { $0.url == url }
        let keep = selectedRow?.id
        refreshInPlace(keep: keep, previousIndex: cursor)
    }

    private func candidate(title: String, url: String, identity: String? = nil) -> SearchCandidate {
        let cacheKey = title + "\u{1F}" + url + "\u{1F}" + (identity ?? "")
        if let hit = candidateCache[cacheKey] { return hit }
        let py: (full: String, initials: String)
        if let cached = pinyinCache[title] {
            py = cached
        } else {
            py = Pinyin.index(title)
            pinyinCache[title] = py
        }
        let made = SearchCandidate(title: title, url: url, pinyin: py.full, initials: py.initials, identity: identity)
        // 上限按「标签 + 最近关闭 + 书签 + 应用 + 历史」的量级留余量；到了整个清掉重来，
        // 别让标题不断变化的标签把它越攒越大（一条带字节键约 0.5KB）
        if candidateCache.count > 10_000 { candidateCache.removeAll(keepingCapacity: true) }
        candidateCache[cacheKey] = made
        return made
    }

    /// 「全部」模式里各段最多列这么多条（截掉的写在分组头上）；单独模式放宽到 `soloLimit`。
    static let appLimit = 4
    static let tabLimit = 8
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

    /// 「搜什么选了什么」的记忆（面板注入 `SearchMemory.shared`）。
    var memory: SearchMemory?
    /// 这一轮输入的记忆加分（身份 → 分），`refilter` 开头取一次，各段排序共用。
    private var boosts: [String: Int] = [:]

    /// 有记忆加分的往前浮、其余保持原顺序（最近关闭 / 历史本来按时间排，不按匹配分）。
    private func floatBoosted<T>(_ items: [T], identity: (T) -> String) -> [T] {
        guard !boosts.isEmpty else { return items }
        return items.enumerated().sorted { a, b in
            let x = boosts[identity(a.element)] ?? 0, y = boosts[identity(b.element)] ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    private func refilter(keepCursorOn keep: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        boosts = trimmed.isEmpty || actionTarget != nil ? [:] : (memory?.boosts(for: trimmed) ?? [:])
        layout = []
        let next: [SearchRow]
        if let target = actionTarget {
            // 操作列表：输入过滤操作名（同样认拼音）
            let all = commandRows(for: target)
            let candidates = all.map { candidate(title: $0.displayTitle, url: "") }
            next = TabSearch.rank(candidates, query: trimmed).map { all[$0] }
        } else {
            next = mode == .all ? allRows(trimmed) : modeRows(mode, trimmed)
        }
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
            next = TabSearch.rank(liveCandidates, query: query, boosts: boosts).map { .tab(all[$0]) }
        case .actions:
            // 对当前输入的操作。没输入就没有可操作的，列表留空、视图给提示。
            if !trimmed.isEmpty { next = actionRows(trimmed) }
        case .history:
            // 历史记录由扩展按输入实时查（空串 = 最近访问的），helper 不再做二次匹配
            if historyQuery == trimmed {
                var seen = Set<String>()
                for h in floatBoosted(history, identity: \.url) where !seen.contains(Self.historyDedupeKey(h)) {
                    seen.insert(Self.historyDedupeKey(h))
                    next.append(.history(h))
                    if next.count == Self.soloLimit { break }
                }
            }
        case .bookmarks:
            let candidates = bookmarks.map { candidate(title: $0.title, url: $0.url) }
            var seen = Set<String>()
            for index in TabSearch.rank(candidates, query: trimmed, boosts: boosts) {
                let bm = bookmarks[index]
                guard !seen.contains(bm.url) else { continue }
                seen.insert(bm.url)
                next.append(.bookmark(bm))
                if next.count == Self.soloLimit { break }
            }
        case .closed:
            let candidates = closed.map { candidate(title: $0.title, url: $0.url) }
            next = floatBoosted(TabSearch.rank(candidates, query: trimmed)
                .map { closed[$0] }
                .sorted { $0.closedAt > $1.closedAt }, identity: \.url)
                .prefix(Self.soloLimit)
                .map { .closed($0) }
        case .folders:
            let candidates = folders.map { candidate(title: $0.name, url: $0.path) }
            next = TabSearch.rank(candidates, query: trimmed, boosts: boosts).prefix(Self.soloLimit).map { .folder(folders[$0]) }
        case .apps:
            // 英文原名和 bundle id 放进「网址」栏参与匹配（得分低于标题命中）
            let candidates = apps.map { appCandidate($0) }
            next = TabSearch.rank(candidates, query: trimmed, boosts: boosts).prefix(Self.soloLimit).map { .app(apps[$0]) }
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

    /// 「全部」模式：最佳匹配、应用、活标签、最近关闭、书签、历史各几条，再加「操作」段。
    private func allRows(_ trimmed: String) -> [SearchRow] {
        // 没输入：按设置列一种内容（默认标签的 MRU），列表空着也行
        if trimmed.isEmpty {
            guard let content = allEmptyContent else { return [] }
            let rows = modeRows(content, "")
            if let kind = SearchSectionKind(content: content), !rows.isEmpty {
                layout = [SectionSpec(kind: kind, count: rows.count)]
            }
            return rows
        }

        // 各段先拿全量命中（段内排好序），最后统一截断：截掉几条要写在分组头上，
        // 「最佳匹配」也得在截断前挑。
        let appCandidates = apps.map { appCandidate($0) }
        var appHits = TabSearch.rank(appCandidates, query: trimmed, boosts: boosts).map { SearchRow.app(apps[$0]) }
        let liveCandidates = all.map { candidate(title: $0.tab.title, url: $0.tab.url) }
        var liveHits = TabSearch.rank(liveCandidates, query: trimmed, boosts: boosts).map { SearchRow.tab(all[$0]) }

        // 已关闭：按关闭时间倒序；和活标签同网址的不列（它已经开着，切过去就是）
        let liveURLs = Set(all.map(\.tab.url))
        let closedCandidates = closed.map { candidate(title: $0.title, url: $0.url) }
        let closedMatched = floatBoosted(TabSearch.rank(closedCandidates, query: trimmed)
            .map { closed[$0] }
            .filter { !liveURLs.contains($0.url) }
            .sorted { $0.closedAt > $1.closedAt }, identity: \.url)
        var closedHits = closedMatched.map { SearchRow.closed($0) }

        // 书签：按得分排，开着的和已关闭里有的不重复列；同网址收在多个文件夹里只列第一个
        var taken = liveURLs.union(closedMatched.map(\.url))
        let bookmarkCandidates = bookmarks.map { candidate(title: $0.title, url: $0.url) }
        var bookmarkHits: [SearchRow] = []
        for index in TabSearch.rank(bookmarkCandidates, query: trimmed, boosts: boosts) {
            let bm = bookmarks[index]
            guard !taken.contains(bm.url) else { continue }
            taken.insert(bm.url)
            bookmarkHits.append(.bookmark(bm))
        }

        // 历史：Chrome 自己匹配、按最近访问排；和上面几段同网址的不重复列
        var historyHits: [SearchRow] = []
        if historyQuery == trimmed {
            var seenTitles = Set<String>()
            for h in floatBoosted(history, identity: \.url) {
                let dedupe = Self.historyDedupeKey(h)
                guard !taken.contains(h.url), !seenTitles.contains(dedupe) else { continue }
                taken.insert(h.url)
                seenTitles.insert(dedupe)
                historyHits.append(.history(h))
            }
        }

        // 「最佳匹配」（2026-09-27 用户要的，Spotlight 的 Top Hit）：段的顺序是固定的，
        // 标题完全命中的书签会排在一串只有网址沾边的标签后面。各段段首（段内已排好）
        // 比一次分，最高的那条比现在排最前的那条分高，就单独提到最前；同分不动。
        // 只比段首：历史段按最近访问排，拿它段里第 5 条出来会让人看不懂为什么是它。
        // 输入完整网址时不挑（「操作」段在最前，回车就是打开它）。
        var topHit: SearchRow?
        if !TabSearch.hasScheme(trimmed) {
            let leaders = [appHits, liveHits, closedHits, bookmarkHits, historyHits].enumerated()
                .compactMap { group, rows -> (group: Int, row: SearchRow, score: Int)? in
                    guard let row = rows.first, let score = score(of: row, query: trimmed) else { return nil }
                    return (group, row, score)
                }
            if let first = leaders.first {
                var best = first
                for leader in leaders where leader.score > best.score { best = leader }
                if best.score > first.score {
                    topHit = best.row
                    switch best.group {
                    case 0: appHits.removeFirst()
                    case 1: liveHits.removeFirst()
                    case 2: closedHits.removeFirst()
                    case 3: bookmarkHits.removeFirst()
                    default: historyHits.removeFirst()
                    }
                }
            }
        }

        // 截断（用户 2026-09-27 要的）：标签命中二十个时后面的书签、历史、操作全被挤到底。
        // 每段有上限，截掉的写在分组头上「还有 N 条 ⇥」，Tab 进那一类看全部。
        var specs: [SectionSpec] = []
        var body: [SearchRow] = []
        func cut(_ kind: SearchSectionKind, _ hits: [SearchRow], _ limit: Int, countKnown: Bool = true) {
            let shown = hits.prefix(limit)
            guard !shown.isEmpty else { return }
            let hidden = hits.count - shown.count
            specs.append(SectionSpec(kind: kind, count: shown.count,
                                     hidden: countKnown ? hidden : 0, moreUnknown: !countKnown && hidden > 0))
            body += shown
        }
        if let topHit { cut(.top, [topHit], 1) }
        cut(.apps, appHits, Self.appLimit)
        cut(.tabs, liveHits, Self.tabLimit)
        cut(.closed, closedHits, Self.closedLimit)
        cut(.bookmarks, bookmarkHits, Self.bookmarkLimit)
        // 历史只拿到扩展回的前 20 条，截掉的「还有几条」不是真数，只说「更多」
        cut(.history, historyHits, Self.historyLimit, countKnown: false)

        // 「操作」段：像网址就先给「在新标签打开」，再是搜索引擎、站内搜索。有输入就一直在
        //（2026-09-27 用户截图：搜「张雪」只命中一条历史，想上网搜却没有入口）。
        // 位置：输入带协议头的完整网址时整段挪到最前（来意就是打开它，回车直接开）；
        // 其余垫底，回车给命中的第一条，想去网上搜往下走。一条都没命中时只有这一段。
        let urlRow = TabSearch.urlCandidate(trimmed).map { SearchRow.url($0) }
        let ops = (urlRow.map { [$0] } ?? []) + actionRows(trimmed)
        let opsSpec = SectionSpec(kind: .ops, count: ops.count)
        if body.isEmpty || TabSearch.hasScheme(trimmed) {
            layout = [opsSpec] + specs
            return ops + body
        }
        layout = specs + [opsSpec]
        return body + ops
    }

    private func appCandidate(_ app: AppEntry) -> SearchCandidate {
        // 英文原名和 bundle id 放进「网址」栏参与匹配（得分低于标题命中）
        candidate(title: app.name, url: [app.alternateName, app.bundleID].compactMap { $0 }.joined(separator: " "),
                  identity: app.path)
    }

    /// 某一行对当前输入的得分（「最佳匹配」跨段比分用）。
    private func score(of row: SearchRow, query: String) -> Int? {
        let c: SearchCandidate
        switch row {
        case .app(let a):        c = appCandidate(a)
        case .tab(let item):     c = candidate(title: item.tab.title, url: item.tab.url)
        case .closed(let entry): c = candidate(title: entry.title, url: entry.url)
        case .bookmark(let bm):  c = candidate(title: bm.title, url: bm.url)
        case .history(let h):    c = candidate(title: h.title, url: h.url)
        default:                 return nil
        }
        return TabSearch.score(c, query: query, boosts: boosts)
    }

    /// ↑↓ 移动游标，到头回绕（用户 2026-09-26 点名：到底就按不动太别扭）。
    /// 和切换器浮层的「越界不动」不同：那边是按住修饰键循环、方向键是辅助；
    /// 这里方向键就是主导航，列表短的时候回绕比撞墙顺手。
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (cursor + delta + rows.count) % rows.count
        setCursor(next, source: .keyboard)
    }

    /// 当前的行高：操作列表是紧凑单行，其余是两行。
    var rowHeight: CGFloat { actionTarget != nil ? kSearchCompactRowHeight : kSearchRowHeight }

    /// 列表区需要的内容高度（不含输入框和底栏），面板据此定高、超过上限就滚动。
    var contentHeight: CGFloat {
        guard !rows.isEmpty else { return kSearchRowHeight + kSearchListInset * 2 }
        return layoutWalk { _, _, _, _ in }
    }

    /// 某一行在列表内容里的位置：行顶的 y（含列表内边距），以及它是不是段里第一行、
    /// 所在段有没有吸顶的分组头。键盘滚动定位用。
    func placement(of index: Int) -> (top: CGFloat, first: Bool, titled: Bool)? {
        var found: (top: CGFloat, first: Bool, titled: Bool)?
        _ = layoutWalk { i, top, first, titled in
            if i == index { found = (top, first, titled) }
        }
        return found
    }

    /// 列表的版面：每段依次是分组头、行（行间 `kSearchRowSpacing`）、到下一段的空档。
    /// 返回总高度。视图（`TabSearchView` 的 Section 结构）按同一组常量画，
    /// `contentHeight` 和键盘滚动定位都从这里取 —— 三处不一致，面板底部就裁掉半行、
    /// 滚动就停错位置。
    private func layoutWalk(_ visit: (_ index: Int, _ top: CGFloat, _ first: Bool, _ titled: Bool) -> Void) -> CGFloat {
        let sections = self.sections
        var y = kSearchListInset
        for (position, section) in sections.enumerated() {
            if section.title != nil { y += kSearchStickyHeaderHeight }
            for index in section.range {
                let first = index == section.range.lowerBound
                if !first { y += kSearchRowSpacing }
                visit(index, y, first, section.title != nil)
                y += rowHeight
            }
            if position + 1 < sections.count { y += searchSectionGap(before: sections[position + 1]) }
        }
        return y + kSearchListInset
    }
}

// MARK: - 尺寸

private let kSearchPanelWidth: CGFloat = 680
private let kSearchFieldHeight: CGFloat = 54
/// 主列表的行：标题 + 域名两行。不压（2026-09-27 评估过）：网页标题长、同站标签标题相近，
/// 认标签靠第二行的域名；中文字形也比英文更吃行距，压到 40 就挤。
private let kSearchRowHeight: CGFloat = 44
/// ⌘↩ 操作列表的行：只有动作名，本质是菜单，单行紧凑。
private let kSearchCompactRowHeight: CGFloat = 34
/// 选中底的圆角 = 面板圆角 14 − 列表内边距 6：同心圆角（Liquid Glass 的基本规则），
/// 不同心时选中底的四角和面板的四角看着是两套东西。
private let kSearchHighlightRadius: CGFloat = 8
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
/// 高度 = 字行 + 下空档；吸顶时它就是视口最上面那条带子的高度（`PinnedHeaderClip` 按它裁行）。
private let kSearchSectionHeaderHeight: CGFloat = 20
private let kSearchSectionRuleSpace: CGFloat = 4
private let kSearchStickyHeaderHeight = kSearchSectionHeaderHeight + kSearchSectionRuleSpace
/// 分组头和上一段最后一行之间的空档，不留的话两段挤成一坨（用户反馈）。
/// 放在上一段的末尾而不是分组头的上边距里：头吸顶时整个头（含边距）都钉在顶上，
/// 上边距会变成顶上一条空白。第一段前面没有上一段，自然不留。
private let kSearchSectionTopSpace: CGFloat = 12

/// 两段之间的空档：下一段有分组头就留 `kSearchSectionTopSpace`，没有（网址直达那一行）就是普通行距。
private func searchSectionGap(before next: SearchSection) -> CGFloat {
    next.title != nil ? kSearchSectionTopSpace : kSearchRowSpacing
}

/// 列表滚动区的坐标空间名：吸顶裁剪和滚动偏移都在这里量。
private let kSearchScrollSpace = "tabSearchScroll"

/// 列表区高度上限：满 10 行。
private let kSearchListMaxHeight: CGFloat =
    CGFloat(kSearchVisibleRows) * kSearchRowHeight
    + CGFloat(kSearchVisibleRows - 1) * kSearchRowSpacing
    + kSearchListInset * 2

private func listHeight(content: CGFloat) -> CGFloat {
    min(content, kSearchListMaxHeight)
}

/// 底栏那条带子的高度：胶囊浮在列表底部上面（照 Raycast，用户 2026-09-27 要的：
/// Liquid Glass 胶囊 + 列表渐隐，不要横线、不要整条实底）。列表内容底部垫同样高，
/// 滚到底时最后一行停在胶囊上方。
private let kSearchFooterZone: CGFloat = 48
private let kSearchCapsuleHeight: CGFloat = 30

private func panelHeight(content: CGFloat) -> CGFloat {
    kSearchFieldHeight + 1 + listHeight(content: content) + kSearchFooterZone
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
    /// 找到列表底下那个 NSScrollView 的探针（键盘滚动定位用）。
    @State private var scroll = SearchScrollState()

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
                            onTab: { model.tabPressed($0) })
                    .frame(maxWidth: .infinity)

                modeIndicator
            }
            .padding(.horizontal, kSearchListInset + kSearchRowInset)
            .frame(height: kSearchFieldHeight)

            Divider().opacity(0.6)

            // 列表一直铺到面板底，底栏胶囊浮在它上面；列表在底部那条带子里渐隐
            //（照 Raycast：不画横线、不铺整条实底）
            ZStack(alignment: .bottom) {
                Group {
                    if model.rows.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: listHeight(content: model.contentHeight))
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        list
                    }
                }
                .frame(height: listHeight(content: model.contentHeight) + kSearchFooterZone)
                .mask(footerFade)

                footer
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

    private func rowView(_ row: SearchRow, index: Int) -> some View {
        SearchRowView(
            row: row,
            icon: model.icons[row.favIconUrl],
            selected: index == model.cursor,
            isCurrent: row.id == model.currentID,
            quickKey: model.commandHeld && index < kSearchQuickPickCount ? index + 1 : nil,
            closable: model.canCloseTabs,
            browserBadge: model.showBrowserIcons ? model.badgeProvider?(row).browser : nil,
            profileBadge: model.showBrowserBadges ? model.badgeProvider?(row).profile : nil,
            searchBrowser: model.searchBrowser,
            defaultOpener: model.openers.first,
            defaultOpenerIcon: model.openers.first.flatMap { model.icons["file:" + $0.path] },
            compact: model.actionTarget != nil,
            duplicates: { if case .tab(let item) = row { return model.duplicateCount(of: item) } else { return 1 } }(),
            onHover: { model.setCursor(index, source: .mouse) },
            onPick: { model.onPick?(row) },
            onClose: { model.onCloseTab?(row.id) })
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let sections = model.sections
            // 「全部」里分组头吸顶（用户 2026-09-27 要的）。其他模式只有一段、没有头。
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { position, section in
                    Section {
                        ForEach(Array(model.rows[section.range].enumerated()), id: \.element.id) { offset, row in
                            rowView(row, index: section.range.lowerBound + offset)
                                .modifier(PinnedHeaderClip(active: section.title != nil))
                                .padding(.top, offset == 0 ? 0 : kSearchRowSpacing)
                                .id(row.id)
                        }
                        if position + 1 < sections.count {
                            Color.clear.frame(height: searchSectionGap(before: sections[position + 1]))
                        }
                    } header: {
                        if section.title != nil { sectionHeader(section) }
                    }
                }
            }
            .padding(kSearchListInset)
            // 底栏胶囊那条带子：内容垫同样高，滚到底时最后一行停在胶囊上方
            .padding(.bottom, kSearchFooterZone)
            .background(ScrollViewProbe(state: scroll))
        }
        .coordinateSpace(name: kSearchScrollSpace)
        // 输入变了（包括 Esc 清空）列表回到顶：最相关的在最上面，鼠标滚下去之后接着打字
        // 的话游标落在第一行、视野却停在下面
        .onChange(of: model.query) { _, _ in
            guard let scrollView = scroll.probe?.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        .onChange(of: model.cursor) { _, cursor in
            guard model.cursorSource == .keyboard,
                  model.rows.indices.contains(cursor) else { return }
            reveal(cursor)
        }
    }

    /// 列表在底栏那条带子里渐隐：上沿全显、到面板底边全透明。滚过去的行淡进玻璃里，
    /// 胶囊浮在上面不压一条实底。
    private var footerFade: some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: kSearchFooterZone)
        }
    }

    /// 键盘移动游标后把那一行滚进视野。吸顶的分组头盖着视口最上面一条，往上滚时行要停在
    /// 分组头下面：`scrollTo(anchor: nil)` 会把行贴着视口顶放，正好被头压住。
    ///
    /// 偏移直接读、直接设底层的 NSScrollView，目标位置按版面（`placement`）算。**别换回
    /// GeometryReader + preference 读偏移**：macOS 上 ScrollView 滚动时，内容整块的 frame
    /// 在滚动坐标系里不更新（2026-09-27 独立 demo 实测：真实偏移 155 / 300，读到的一直是 0），
    /// 于是「往上走到视口外」永远判成「看得见」、不滚 —— 用户报的「方向键走着走着选中项看不见了」。
    /// 行、分组头各自的 frame 是会更新的，`PinnedHeaderClip` 不受影响。
    private func reveal(_ index: Int) {
        guard let place = model.placement(of: index),
              let scrollView = scroll.probe?.enclosingScrollView,
              let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let offset = clip.bounds.minY          // 文档视图是翻转的：y 就是离顶的距离
        // 底栏那条带子里的行是渐隐、被胶囊压着的，不算看得见
        let viewport = clip.bounds.height - kSearchFooterZone
        let rowHeight = model.rowHeight
        let cover = place.titled ? kSearchStickyHeaderHeight : 0
        // 最后一行连底部内边距一起露出来
        let bottom = place.top + rowHeight + (index == model.rows.count - 1 ? kSearchListInset : 0)
        let target: CGFloat
        if place.top < offset + cover {
            // 段里第一行：减掉头的高度正好是头顶，头和行一起露出来；
            // 离顶只剩列表内边距那点距离时直接回到顶，别把内边距藏掉
            target = place.top - cover <= kSearchListInset ? 0 : place.top - cover
        } else if bottom > offset + viewport {
            target = bottom - viewport
        } else {
            return
        }
        let clamped = min(max(0, target), max(0, document.frame.height - clip.bounds.height))
        guard clamped != offset else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 输入框右侧的当前模式：模式名 + ⇥ 提示，点一下切到下一个（用户不要单独一行胶囊）。
    private var modeIndicator: some View {
        HStack(spacing: 6) {
            // 胶囊，和底栏同一种形状语言
            Text(model.mode.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08)))
            Keycap(label: "⇥")
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { model.cycleMode(1) }
        .help(L10n.t("Tab 切换：\(model.modes.map(\.label).joined(separator: " → "))",
                     "Tab cycles: \(model.modes.map(\.label).joined(separator: " → "))"))
    }

    /// 输入框占位跟着模式走（用户点名：写死「搜索标签」和列表对不上）。
    private var placeholder: String {
        if let target = model.actionTarget {
            let name = target.displayTitle
            let short = name.count > 30 ? String(name.prefix(29)) + "…" : name
            return L10n.t("「\(short)」的操作", "Actions for “\(short)”")
        }
        switch model.mode {
        case .all:       return L10n.t("搜索全部", "Search everything")
        case .tabs:      return L10n.t("搜索浏览器标签", "Search browser tabs")
        case .actions:   return L10n.t("搜索互联网内容", "Search the web")
        case .history:   return L10n.t("搜索历史记录", "Search history")
        case .bookmarks: return L10n.t("搜索浏览器书签", "Search browser bookmarks")
        case .closed:    return L10n.t("搜索最近关闭的标签", "Search recently closed tabs")
        case .folders:   return L10n.t("搜索收藏的文件夹", "Search favorite folders")
        case .apps:      return L10n.t("搜索应用", "Search apps")
        }
    }

    /// 列表空着时那句话，按模式说清「为什么空」。
    private var emptyText: String {
        let noQuery = model.query.trimmingCharacters(in: .whitespaces).isEmpty
        if model.actionTarget != nil { return L10n.t("没有匹配的操作", "No matching actions") }
        switch model.mode {
        case .all, .tabs: return model.all.isEmpty ? L10n.t("还没有浏览器标签", "No browser tabs yet") : L10n.t("没有匹配的浏览器标签", "No matching browser tabs")
        case .actions:   return L10n.t("输入要搜的内容", "Type something to search for")
        case .history:   return noQuery ? L10n.t("还没有历史记录", "No history yet") : L10n.t("没有匹配的历史记录", "No matching history")
        case .bookmarks: return noQuery ? L10n.t("还没有浏览器书签", "No browser bookmarks yet") : L10n.t("没有匹配的浏览器书签", "No matching browser bookmarks")
        case .closed:    return noQuery ? L10n.t("还没有关闭过标签", "Nothing closed yet") : L10n.t("没有匹配的已关闭标签", "No matching closed tabs")
        case .folders:   return model.folders.isEmpty ? L10n.t("还没有收藏文件夹。状态栏菜单里可以添加。", "No favorite folders yet. Add one from the menu bar.") : L10n.t("没有匹配的文件夹", "No matching folders")
        case .apps:      return model.apps.isEmpty ? L10n.t("正在读取应用列表", "Loading apps") : L10n.t("没有匹配的应用", "No matching apps")
        }
    }

    /// 底栏（照 Raycast 的 Liquid Glass 胶囊，浮在列表渐隐的底部上）：右边胶囊写
    /// 「回车做什么 ↵ ｜ 操作 ⌘↩」；展开操作后左边多一个胶囊写在对谁操作（带它自己的图标：
    /// App 是 App 图标、网页是站点图标，用户点名），右边变成「执行 ↵ ｜ 返回 esc」。每一项都能点。
    /// 胶囊的左右边和选中底的左右边对齐（都缩进 `kSearchListInset`）。
    private var footer: some View {
        HStack(spacing: 8) {
            if model.actionTarget == nil, model.extensionOutdated {
                // 扩展要更新：不打断，只在底栏左边挂一个（用户 2026-09-27 要的），点了看升级说明
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text(L10n.t("扩展需要更新", "Extension update required"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                }
                .modifier(GlassCapsule())
                .fixedSize()
                .contentShape(Capsule())
                .onTapGesture { model.onExtensionUpdateTap?() }
                .help(L10n.t("下载最新的扩展包替换原文件夹，再到 chrome://extensions 重新加载。",
                             "Download the latest extension zip, replace the folder, then reload it in chrome://extensions."))
            }
            if let target = model.actionTarget {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.45))
                    SearchRowIcon(row: target, icon: model.icons[target.favIconUrl],
                                  searchBrowser: model.searchBrowser, box: 16, compact: true)
                    Text(target.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .modifier(GlassCapsule())
                .contentShape(Capsule())
                .onTapGesture { _ = model.escape() }
                .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if model.selectedRow != nil || model.actionTarget != nil {
                HStack(spacing: 10) {
                    if let row = model.selectedRow {
                        footerAction(row.enterTitle(defaultOpener: model.openers.first), keys: ["↩"], primary: true) {
                            model.onPick?(row)
                        }
                    }
                    if model.actionTarget != nil {
                        if model.selectedRow != nil { footerSeparator }
                        footerAction(L10n.t("返回", "Back"), keys: ["esc"]) { _ = model.escape() }
                    } else if let row = model.selectedRow, model.hasActions(row) {
                        footerSeparator
                        footerAction(L10n.t("操作", "Actions"), keys: ["⌘", "↩"]) { model.showActions() }
                    }
                }
                .modifier(GlassCapsule())
                .fixedSize()
            }
        }
        .padding(.horizontal, kSearchListInset)
        .frame(height: kSearchFooterZone)
    }

    private var footerSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: 14)
    }

    private func footerAction(_ title: String, keys: [String], primary: Bool = false,
                              action: @escaping () -> Void) -> some View {
        // 胶囊里的字和键帽统一亮色（用户 2026-09-27 点名：「操作」不要专门压灰），
        // 主次只靠字重分
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { Keycap(label: $0, bright: true) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    /// 分组头：一行小字，和下面行的标题左对齐，没有分隔线（Raycast 的样子）。
    /// 吸顶时不垫底色（垫了就是玻璃上横着一条色带），滚上去的行由 `PinnedHeaderClip` 在它下沿裁掉。
    /// 头自己接住 hover：吸顶时底下压着被裁掉的行，不接的话鼠标停在头上会选中一行看不见的。
    /// 截断的段右边写「还有 N 条」（历史写「更多」），能跳时后面跟 ⇥、点一下也跳。
    private func sectionHeader(_ section: SearchSection) -> some View {
        HStack(spacing: 0) {
            Text(section.title ?? "")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.5))
                .padding(.leading, kSearchRowIconSize + kSearchIconGap)
            Spacer(minLength: 8)
            if section.hidden > 0 || section.moreUnknown {
                HStack(spacing: 5) {
                    Text(section.moreUnknown ? L10n.t("更多", "More")
                                             : L10n.t("还有 \(section.hidden) 条", "\(section.hidden) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.4))
                    if section.jump != nil { Keycap(label: "⇥", small: true) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let jump = section.jump { model.select(jump) }
                }
            }
        }
        .frame(height: kSearchSectionHeaderHeight)
        .padding(.bottom, kSearchSectionRuleSpace)
        .padding(.horizontal, kSearchRowInset)
        .contentShape(Rectangle())
        .onHover { _ in }
    }
}

/// 列表内容里埋的一个空 NSView，经它的 `enclosingScrollView` 拿到 SwiftUI ScrollView
/// 底下真正的 NSScrollView。引用类型，存进去不触发重绘。
private final class SearchScrollState {
    weak var probe: NSView?
}

private struct ScrollViewProbe: NSViewRepresentable {
    let state: SearchScrollState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        state.probe = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { state.probe = view }
}

/// 有吸顶分组头的段里的行：滚进视口最上面那条带子（分组头钉着的位置）的部分裁掉。
/// 分组头不垫底色，不裁的话滚上去的行和头上的字叠在一起。行只有在头吸顶时才会进这条带子
/// （没吸顶时行总在自己的头下面），所以不用判断头吸没吸顶。
private struct PinnedHeaderClip: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.mask {
                GeometryReader { geo in
                    let top = geo.frame(in: .named(kSearchScrollSpace)).minY
                    Rectangle().padding(.top, min(geo.size.height, max(0, kSearchStickyHeaderHeight - top)))
                }
            }
        } else {
            content
        }
    }
}

/// 行首图标（主列表、操作列表、底栏左边的胶囊共用一份）。`box` 是格子边长 —— 格子宽度
/// 不随图标种类变，文字列才能在全面板落在同一条竖线上。
private struct SearchRowIcon: View {
    let row: SearchRow
    let icon: IconInfo?
    var searchBrowser: String? = nil
    var box: CGFloat = kSearchRowIconSize
    /// 紧凑（操作列表 / 底栏）：App 图标不放大、符号小一号。
    var compact = false

    var body: some View {
        content.frame(width: box, height: box)
    }

    /// App 图标自带一圈透明边距，按 favicon 的格子画会显小：两行的行里放大到 28/22 画，
    /// 格子不变、文字不动；紧凑行里行高只有 34，放大就顶到上下边了，按格子画。
    private var appSide: CGFloat { compact ? imageSide * 1.15 : box * 28 / 22 }
    private var symbolSize: CGFloat { box * (compact ? 0.62 : 0.68) }
    /// 站点图标画多大。紧凑行里别撑满格子：旁边几行是 14pt 的线性符号，满格的彩色图标
    /// 显大一圈（用户 2026-09-27 截图）；缩到 16，格子宽度不变、文字不动。
    private var imageSide: CGFloat { compact ? min(box, 16) : box }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .command(let command, let target):
            if command == .primary {
                // 默认动作用对象自己的图标：动作和对象在视觉上连在一起（Raycast 的做法）
                SearchRowIcon(row: target, icon: icon, searchBrowser: searchBrowser, box: box, compact: compact)
            } else {
                Image(systemName: command.symbol(for: target))
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(command.isDestructive ? Color(nsColor: .systemRed) : Color.primary.opacity(0.7))
            }
        case .url:
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: symbolSize + 2, weight: .regular))
                .foregroundStyle(.secondary)
        case .bookmark, .history:
            // 图标由 helper 按域名向扩展要（Chrome 缓存的），还没到就先用类型图标占位
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: imageSide, height: imageSide)
            } else {
                Image(systemName: { if case .bookmark = row { return "bookmark" } else { return "clock" } }())
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        case .folder, .opener, .app:
            // 本机文件 / App 的图标由 iconProvider 同步取（`file:` 键）
            if let icon {
                let isApp: Bool = { if case .folder = row { return false } else { return true } }()
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: isApp ? appSide : imageSide + 2, height: isApp ? appSide : imageSide + 2)
            } else {
                Image(systemName: { if case .folder = row { return "folder" } else { return "app" } }())
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        case .action(.webSearch):
            // 默认搜索引擎那行用要执行搜索的那个浏览器的 App 图标（用户点名）
            if let searchBrowser, let appIcon = BrowserSupport.icon(searchBrowser) {
                Image(nsImage: appIcon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: appSide, height: appSide)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .action(let a):
            // 站内搜索用那个站的 favicon（和书签行同一条路取），没到之前用类型图标
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: imageSide, height: imageSide)
            } else {
                Image(systemName: a.symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .tab, .closed:
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: imageSide, height: imageSide)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 键帽：底栏、⌘ 数字角标、⇥ 提示共用这一款（圆角方块 + 细描边），全面板只有一种按键长相。
private struct Keycap: View {
    let label: String
    var small = false
    /// 底栏胶囊里用亮色；列表里的角标、⇥ 仍是次级色，别和标题抢
    var bright = false

    var body: some View {
        // 18 / 15：20 的版本在胶囊里显得顶（用户 2026-09-27 要小一号）
        let side: CGFloat = small ? 15 : 18
        Text(label)
            .font(.system(size: small ? 9.5 : 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(bright ? 0.9 : 0.65))
            .padding(.horizontal, label.count > 1 ? (small ? 4 : 5) : 0)
            .frame(minWidth: side, minHeight: side)
            .background(RoundedRectangle(cornerRadius: small ? 3.5 : 4.5, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: small ? 3.5 : 4.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
    }
}

/// 底栏的胶囊：macOS 26 起是系统的 Liquid Glass（`.glassEffect`，折射的是底下渐隐的列表），
/// 之前的系统退回磨砂材质 + 细描边。
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        let shaped = content
            .padding(.horizontal, 12)
            .frame(height: kSearchCapsuleHeight)
        if #available(macOS 26.0, *) {
            shaped.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            shaped
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
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
    /// 跨浏览器搜索、同一个浏览器开了多个 Profile：行尾写是哪个 Profile 的。
    var profileBadge: String? = nil
    /// 「搜索」操作行行首画的浏览器（搜索会发给它）。
    let searchBrowser: String?
    /// 文件夹行：回车默认用的打开方式及其图标。
    let defaultOpener: OpenerApp?
    let defaultOpenerIcon: IconInfo?
    /// 操作列表里的行：单行、矮一截，不画副标题。
    var compact = false
    /// 活标签：同网址的一共几个（>1 行尾标「重复」）。
    var duplicates = 1
    let onHover: () -> Void
    let onPick: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var lastMouseScreenPoint: CGPoint?
    @State private var hovering = false

    private var title: String { row.displayTitle }

    /// 删除类操作：图标和字标红。
    private var destructive: Bool {
        if case .command(let command, _) = row { return command.isDestructive }
        return false
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
        case .command:           return ""
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
            SearchRowIcon(row: row, icon: icon, searchBrowser: searchBrowser, compact: compact)
                .opacity(dimmed ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: compact ? 13 : 13.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(destructive ? Color(nsColor: .systemRed)
                                         : dimmed ? Color.primary.opacity(0.55)
                                         : (selected ? Color.primary : Color.primary.opacity(0.85)))
                    if case .tab(let item) = row, item.tab.pinned == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
                    }
                }
                if !compact, !subtitle.isEmpty {
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
        .frame(height: compact ? kSearchCompactRowHeight : kSearchRowHeight)
        .background {
            RoundedRectangle(cornerRadius: kSearchHighlightRadius, style: .continuous)
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
    private var trailing: some View {
        if let quickKey {
            Keycap(label: "⌘\(quickKey)")
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
        } else if profileBadge != nil || browserBadge.flatMap(BrowserSupport.icon) != nil {
            HStack(spacing: 5) {
                if let profileBadge {
                    Text(profileBadge)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                }
                if let browserBadge, let icon = BrowserSupport.icon(browserBadge) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .opacity(0.85)
                        .help(BrowserSupport.displayName(browserBadge))
                }
            }
        } else {
            switch row {
            case .tab(let item):
                if duplicates > 1 {
                    Text(L10n.t("重复", "Duplicate"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .help(L10n.t("还开着 \(duplicates - 1) 个同样的页面，⌘↩ 可以一起关掉",
                                     "\(duplicates - 1) more tab(s) with this page are open; ⌘↩ closes them"))
                }
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
                Text(L10n.t("浏览器书签", "Browser bookmark"))
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
                // 回车会用哪个 App 开：画它的图标（换一个走 ⌘↩，底栏写着）
                if let opener = defaultOpener, let appIcon = defaultOpenerIcon {
                    Image(nsImage: appIcon.image).resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .help(opener.name)
                }
            case .app(let a):
                if a.isRunning { RunningDot() }
            case .command:
                EmptyView()
            }
        }
    }
}

/// 运行中的 App 行尾：呼吸的绿点 + 「运行中」（用户 2026-09-27 定的；只放点不放字被否了，
/// 光一个点看不出是什么意思）。系统开了「减少动态效果」就是静止的点。
///
/// 动画交给 Core Animation 的 repeatForever，不用 TimelineView —— 后者每帧重算一遍视图，
/// 几个运行中的 App 就是几份每秒 60 次的 SwiftUI 更新。代价是各行 onAppear 的时刻不同、
/// 呼吸会错拍，所以起步前先等到时钟对齐一个整周期，几颗点同起同落。
private struct RunningDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    private static let halfCycle: TimeInterval = 1.2

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(nsColor: .systemGreen))
                .frame(width: 7, height: 7)
                .opacity(dim ? 0.3 : 1)
                .scaleEffect(dim ? 0.8 : 1)
                .animation(.easeInOut(duration: Self.halfCycle).repeatForever(autoreverses: true), value: dim)
            Text(L10n.t("运行中", "Running"))
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.30))
        }
        .onAppear {
                guard !reduceMotion else { return }
                let cycle = Self.halfCycle * 2
                let wait = cycle - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { dim = true }
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
/// 拖面板时离对齐位置多近就吸过去。
private let kSearchSnapDistance: CGFloat = 8

/// 拖面板时的对齐辅助线：一个不接鼠标的透明窗口，铺在基准（浏览器窗口 / 屏幕）上、
/// 压在面板下面，只在吸住的那一刻画线。
@MainActor
private final class SearchPanelGuides {
    private var window: NSPanel?
    private let lines = GuideLinesView()

    func show(verticalX: CGFloat?, horizontalY: CGFloat?, in area: NSRect, below panel: NSWindow) {
        guard verticalX != nil || horizontalY != nil else { hide(); return }
        let window = self.window ?? make()
        if window.frame != area { window.setFrame(area, display: false) }
        lines.verticalX = verticalX.map { $0 - area.minX }
        lines.horizontalY = horizontalY.map { $0 - area.minY }
        lines.needsDisplay = true
        window.order(.below, relativeTo: panel.windowNumber)
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = lines
        self.window = window
        return window
    }
}

private final class GuideLinesView: NSView {
    var verticalX: CGFloat?
    var horizontalY: CGFloat?

    /// 灰色 1.5pt 虚线，照 PasteMemo 快捷面板的吸附线（用户 2026-09-27 点名；第一版是 1pt 强调色实线）。
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        if let x = verticalX {
            ctx.move(to: CGPoint(x: x, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
            ctx.strokePath()
        }
        if let y = horizontalY {
            ctx.move(to: CGPoint(x: bounds.minX, y: y))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            ctx.strokePath()
        }
    }
}

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
    /// 本轮定位的基准（浏览器窗口，跨浏览器时是屏幕）和默认顶边。拖动时的辅助线就画在
    /// 「基准的水平中线」和「默认顶边」这两条上 —— 对上了就是回到默认位置。
    private var anchorFrame = NSRect.zero

    /// 上一轮关面板时的现场。90 秒内、上次没选任何东西就关的（Esc、点到别处、再按一次
    /// 快捷键），重开时回到原来的输入、模式、选中项、滚动位置，输入整段选中（接着找就按
    /// 方向键，重新搜直接打字覆盖）；选定了东西 / 执行了操作才关的、或超过 90 秒的，从头开始
    ///（照 Raycast 的「回到根」，用户 2026-09-27 定的）。⌘E 和 ⌥Space 各算各的。
    private struct Session {
        let closedAt: Date
        let completed: Bool
        let global: Bool
        let query: String
        let mode: SearchMode
        let cursorID: String?
        let scrollY: CGFloat
    }
    private var lastSession: Session?
    private var closingAfterPick = false
    private static let restoreWindow: TimeInterval = 90
    private var defaultTopY: CGFloat = 0
    private let guides = SearchPanelGuides()

    var isVisible: Bool { shown }

    /// 面板关掉了（无论哪种方式）。event tap 靠它收回「键盘归面板」的标志。
    var onClose: (() -> Void)?

    /// 用户选定了一项。面板已关。
    var pickHandler: ((SearchPick) -> Void)?
    /// 用户要在面板里关掉一个活标签（参数 item.id）。面板不关。
    var closeHandler: ((String) -> Void)?
    /// 「操作」列表里选了一项（默认动作除外，那个走 pickHandler）。`staysInPanel` 的
    /// 那几项调用时面板还开着、已退回原列表；其余面板已关。
    var commandHandler: ((RowCommand, SearchRow) -> Void)?
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
            guard let self else { return }
            // 操作列表里的一项：默认动作等于选定那一行本身；删除类留在面板里（先退回
            // 原列表再执行，数据刷新后列表原地收缩）；其余关面板再执行。
            if case .command(let command, let target) = row {
                if command == .primary { self.model.onPick?(target); return }
                if command.staysInPanel {
                    self.model.leaveActions()
                    self.commandHandler?(command, target)
                } else {
                    let handler = self.commandHandler
                    self.closingAfterPick = true
                    self.close()
                    handler?(command, target)
                }
                return
            }
            // 记住「这个输入选了它」，下次同样的输入它往前排
            if let identity = row.memoryIdentity {
                SearchMemory.shared.record(query: self.model.baseQuery, identity: identity)
            }
            // 先关面板再切：关面板会把 key 还给浏览器，切换命令随后到达时
            // 焦点已经在它那边了。
            let pick = self.pickHandler
            self.closingAfterPick = true
            self.close()
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
            case .command:           break   // 上面已处理
            }
        }
        model.memory = SearchMemory.shared
        model.onCloseTab = { [weak self] itemID in self?.closeHandler?(itemID) }
        model.onExtensionUpdateTap = { [weak self] in
            self?.closingAfterPick = true
            self?.close()
            NSWorkspace.shared.open(URL(string: "https://www.lifedever.com/TabFlick/install-extension.html")!)
        }
        model.onContentHeightChange = { [weak self] height in self?.resizeToContent(height) }
        fieldHandle.onCommit = { [weak self] in
            guard let self, let pending = self.pendingContentHeight else { return }
            self.resizeToContent(pending)
        }
    }

    /// 列表底下的 NSScrollView（SwiftUI ScrollView 的实体）。
    private var listScrollView: NSScrollView? {
        guard let root = hostingView else { return nil }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView { return scrollView }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func setListScrollOffset(_ y: CGFloat) {
        guard let scrollView = listScrollView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
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
        let restore = lastSession.flatMap { session -> Session? in
            guard !session.completed, session.global == global,
                  Date().timeIntervalSince(session.closedAt) < Self.restoreWindow else { return nil }
            return session
        }
        lastSession = nil
        model.clearActions()   // 上一轮停在操作列表里就关了的话，这次从主列表开始
        model.query = ""
        model.resetMode()   // 上一轮停在别的模式的话回到第一个
        if let restore {
            if modes.contains(restore.mode) { model.select(restore.mode) }
            model.query = restore.query
        }
        model.icons = icons
        model.setItems(items, closed: closed, bookmarks: bookmarks,
                       folders: folders, apps: apps, openers: openers, keepCursor: false)
        if let restore, let id = restore.cursorID,
           let index = model.rows.firstIndex(where: { $0.id == id }) {
            model.setCursor(index, source: .mouse)   // 不触发自动滚动，滚动位置下面单独还原
        }
        // 面板常驻，列表底下那个 NSScrollView 还停在上一轮滚到的位置；游标重算后若刚好和
        // 上一轮同一个下标（都是第 1 行），「游标变了才滚」那条不触发，选中项就在视野外
        setListScrollOffset(restore?.scrollY ?? 0)
        // ⌘E 唤出时 ⌘ 多半还按着，角标要立刻出现，不等下一次 flagsChanged
        model.commandHeld = NSEvent.modifierFlags.contains(.command)
        present(inputSource: inputSource)
        if let restore {
            // 输入整段选中：接着找按方向键，重新搜直接打字就覆盖掉
            if !restore.query.isEmpty, let field = fieldHandle.field {
                field.stringValue = restore.query
                field.currentEditor()?.selectAll(nil)
            }
            // 新数据的行要等下一轮布局才排好，滚动位置那时再还原一次
            let y = restore.scrollY
            DispatchQueue.main.async { [weak self] in self?.setListScrollOffset(y) }
        }
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
        lastSession = Session(closedAt: Date(), completed: closingAfterPick, global: isGlobal,
                              query: model.baseQuery, mode: model.mode,
                              cursorID: model.baseCursorID,
                              scrollY: listScrollView?.contentView.bounds.minY ?? 0)
        closingAfterPick = false
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
        anchorFrame = anchor
        defaultTopY = anchor.maxY - anchor.height * 0.16
        // 用户拖过就按拖到的位置（相对默认位置的偏移）；出界由 frame(for:) 夹回屏幕里
        let offset = Self.savedOffset
        topY = defaultTopY + offset.height

        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: model.contentHeight))
        panel.setFrame(frame(for: size, midX: anchor.midX + offset.width), display: true)

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
            // ⌘↩：展开游标那一行的操作（组字中不动，那时回车归输入法）
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                if !self.fieldHandle.isComposing { self.model.showActions() }
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

        // 拖动面板：输入框左边的放大镜、输入框里文字右边的空白（Raycast 的样子）。
        // 点在文字上照常放光标、拖选；双击放给输入框（选词）。
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, event.clickCount == 1,
                  self.isDragHandle(event.locationInWindow) else { return event }
            if !self.trackDrag(), let editor = self.fieldHandle.field?.currentEditor() as? NSTextView,
               !editor.hasMarkedText() {
                // 只是点了一下：和点在输入框空白处一样，光标放到末尾
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
            return nil
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

    /// 这一下按在能拖面板的地方吗：输入框那一行里，输入框左边（放大镜），或者输入框里
    /// 已输入文字的右边。输入框右边是模式标签（点它切模式），不算。
    private func isDragHandle(_ point: NSPoint) -> Bool {
        guard let panel, let content = panel.contentView, let field = fieldHandle.field else { return false }
        let inWindow = content.convert(content.bounds, to: nil)
        guard point.y >= inWindow.maxY - kSearchFieldHeight, point.y <= inWindow.maxY else { return false }
        let fieldRect = field.convert(field.bounds, to: nil)
        if point.x < fieldRect.minX { return true }
        return point.x <= fieldRect.maxX && point.x > textEnd(of: field) + 6
    }

    /// 输入框里文字（含组字中的）末尾的 x，窗口坐标。没字时就是输入框左边。
    private func textEnd(of field: NSTextField) -> CGFloat {
        guard let editor = field.currentEditor() as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            return field.convert(field.bounds, to: nil).minX
        }
        let used = layout.usedRect(for: container)
        return editor.convert(NSPoint(x: used.maxX + editor.textContainerOrigin.x, y: 0), to: nil).x
    }

    /// 跟着鼠标拖面板，直到松手。返回是不是真的拖了（没过 3pt 算单击）。
    ///
    /// 面板中线靠近基准的水平中线、顶边靠近默认高度时吸过去：画辅助线 + 触控板轻震一下
    /// （照 Raycast）。两条都对上就是默认位置，所以「拖回辅助线」就是恢复默认，不另设按钮。
    /// 松手记下相对默认位置的偏移，下次打开照用（浏览器内按浏览器窗口、跨浏览器按屏幕算）。
    private func trackDrag() -> Bool {
        guard let panel else { return false }
        let start = NSEvent.mouseLocation
        let startFrame = panel.frame
        let centeredX = anchorFrame.midX - startFrame.width / 2
        var moved = false
        var snappedX = false
        var snappedY = false
        while let event = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              event.type == .leftMouseDragged {
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            if !moved, hypot(dx, dy) < 3 { continue }
            moved = true
            var x = startFrame.minX + dx
            var top = startFrame.maxY + dy
            let snapX = abs(x - centeredX) <= kSearchSnapDistance
            let snapY = abs(top - defaultTopY) <= kSearchSnapDistance
            if snapX { x = centeredX }
            if snapY { top = defaultTopY }
            if (snapX && !snappedX) || (snapY && !snappedY) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            snappedX = snapX
            snappedY = snapY
            panel.setFrameOrigin(NSPoint(x: x, y: top - startFrame.height))
            guides.show(verticalX: snapX ? anchorFrame.midX : nil,
                        horizontalY: snapY ? defaultTopY : nil,
                        in: anchorFrame, below: panel)
        }
        guides.hide()
        guard moved else { return false }
        topY = panel.frame.maxY
        if let screen = panel.screen { visibleFrame = screen.visibleFrame }
        Self.savedOffset = CGSize(width: snappedX ? 0 : panel.frame.midX - anchorFrame.midX,
                                  height: snappedY ? 0 : panel.frame.maxY - defaultTopY)
        return true
    }

    /// 用户拖出来的位置：相对默认位置（基准水平居中、顶边在默认高度）的偏移。没拖过是 0。
    private static var savedOffset: CGSize {
        get {
            guard let pair = UserDefaults.standard.array(forKey: "searchPanelOffset") as? [Double],
                  pair.count == 2, pair.allSatisfy(\.isFinite) else { return .zero }
            return CGSize(width: pair[0], height: pair[1])
        }
        set {
            if newValue == .zero {
                UserDefaults.standard.removeObject(forKey: "searchPanelOffset")
            } else {
                UserDefaults.standard.set([Double(newValue.width), Double(newValue.height)], forKey: "searchPanelOffset")
            }
        }
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
