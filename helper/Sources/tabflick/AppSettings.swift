import AppKit
import Foundation
import ServiceManagement

/// 界面外观。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.t("跟随系统", "System")
        case .light:  return L10n.t("浅色", "Light")
        case .dark:   return L10n.t("深色", "Dark")
        }
    }

    /// nil 表示交还给系统。设在 `NSApp.appearance` 上会一并影响切换器浮层。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// 搜索面板的模式，按 Tab 循环（2026-09-26 用户定的），顺序在设置里可调。
enum SearchMode: String, CaseIterable, Identifiable, Codable {
    /// 混排：活标签在前，有输入时后面挂最近关闭 / 书签 / 历史各几条
    case all
    /// 只搜活着的标签（当前浏览器所有窗口）
    case tabs
    /// 对当前输入的操作：搜索引擎、站内搜索
    case actions
    case history
    case bookmarks
    case closed
    /// 收藏的文件夹（状态栏那份），回车用上次的方式打开、⌘↩ 选打开方式
    case folders
    /// 已安装的 App，回车启动。默认不开 —— 装了 Raycast 的人用不上
    case apps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:       return L10n.t("全部", "All")
        case .tabs:      return L10n.t("标签", "Tabs")
        case .actions:   return L10n.t("搜索", "Search")
        case .history:   return L10n.t("历史记录", "History")
        case .bookmarks: return L10n.t("书签", "Bookmarks")
        case .closed:    return L10n.t("最近关闭", "Recently closed")
        case .folders:   return L10n.t("文件夹", "Folders")
        case .apps:      return L10n.t("应用", "Apps")
        }
    }

    /// 默认进循环的模式。
    static let defaultEnabled: Set<SearchMode> = [.all, .tabs, .actions, .history, .bookmarks, .closed, .folders]
}

/// 切换器浮层的排布方式。
enum SwitcherLayout: String, CaseIterable, Identifiable {
    /// 横向一行，放不下时左右滚动（默认，和 macOS ⌘⇥ 一个形态）。
    case strip
    /// 自动换行的宫格，尽量一屏放下全部标签。
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strip: return L10n.t("横向长条", "Horizontal strip")
        case .grid:  return L10n.t("宫格", "Grid")
        }
    }
}

/// 全局切换器（前台不是浏览器时唤出）的呈现样式。
///
/// 两种都按浏览器分组 —— 人在别的应用里想切标签时，脑子里先定「去哪个
/// 浏览器」，再在里面找标签。合并成一条纯 MRU 反而要多扫一遍。
enum GlobalSwitcherStyle: String, CaseIterable, Identifiable {
    /// Raycast 式纵向列表：一行一个标签，浏览器做分组标题。
    case list
    /// 沿用切换器的缩略图卡片，每个浏览器一段。
    case cards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:  return L10n.t("列表", "List")
        case .cards: return L10n.t("卡片", "Cards")
        }
    }
}

/// 全局切换器的排除项：这个 App 在前台时，全局切换器不接管快捷键。
///
/// 身份是 bundle id（判定只认它，localizedName 在中文系统下对不上）。
/// name 是添加那一刻记下来的显示名，纯展示用 —— App 卸载后 Launch Services
/// 查不到名字，列表总不能摆一串反向域名让用户猜。
struct ExcludedApp: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

/// 站内搜索模板（⌘E 面板按 Tab 后的「在 X 搜索」）。`template` 里的 `%s` 换成关键词。
struct SiteSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var template: String

    /// 默认只给两个（用户 2026-09-26 定的：B 站、掘金不进默认）。设置里可以改、删、加。
    static let defaults: [SiteSearch] = [
        SiteSearch(name: "GitHub", template: "https://github.com/search?q=%s"),
        SiteSearch(name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
    ]

    /// 模板的域名，面板行的副标题用。
    var host: String {
        URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.host ?? template
    }

    /// 把关键词填进模板。只放行 RFC 3986 unreserved 字符，别换成 `URLComponents`——
    /// 它不编码 `+`，对端按空格解（同 OpenerCatalog.claudeCodeURL 那条）。
    func url(for query: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let url = template.replacingOccurrences(of: "%s", with: encoded)
        return url.hasPrefix("http") ? url : nil
    }
}

/// 收藏的标签：浏览器每次连上都保证它存在且置顶（Arc 收藏位的 Chrome 版）。
///
/// 识别按**域名**而不是完整 URL —— 置顶型标签（Gmail、Notion 这类 webapp）
/// 会在站内不断跳转，按完整 URL 匹配会导致每次核对都再开一个重复标签。
struct FavoriteTab: Codable, Identifiable, Equatable {
    /// 独立身份（UUID）。URL 只是属性不是身份 —— 同一地址置顶两份、
    /// 或标签漂移到任何地方，这条记录都还是它自己。
    let id: String
    let url: String
    let title: String
    /// 站点图标地址（置顶时的 tab.favIconUrl），设置列表展示用。
    let favIconUrl: String?
    /// 归属浏览器的 bundle id。浏览器是物理隔离的主体：置顶列表按浏览器
    /// 分账，恢复/取消只作用于自己的浏览器。
    let browser: String

    init(url: String, title: String, favIconUrl: String? = nil, browser: String) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title
        self.favIconUrl = favIconUrl
        self.browser = browser
    }

    /// 旧版本存的数据没有 id 字段（当时以 url 为身份），用 url 补位，
    /// 顺便让旧的 favoriteCurrentUrls（也是按 url 键的）继续对得上。
    /// browser 字段之前也不存在 —— 旧数据只可能来自 Chrome。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? url
        favIconUrl = try c.decodeIfPresent(String.self, forKey: .favIconUrl)
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? "com.google.Chrome"
    }
}

/// 用户录制的快捷键。keyCode 供 event tap 匹配（物理键位），
/// character 供菜单 keyEquivalent 显示（跟随键盘布局）。
struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue，只保留 ⌘⌃⌥⇧ 四位。
    let modifiers: UInt
    let character: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .control, .option, .shift])
    }

    /// 「⌃⇧P」这类显示串，修饰键按 macOS 惯例排序。
    var display: String {
        var s = ""
        let mods = modifierFlags
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch character {
        case "\t":     return s + "⇥"
        case " ":      return s + "Space"
        case "\r":     return s + "↩"
        default:       return s + character.uppercased()
        }
    }

    /// 设置页胶囊里的写法：修饰键和主键之间留一个空格（「⌘ Space」），
    /// 照 Raycast 的样子。菜单和说明文字仍用 `display`。
    var displaySpaced: String {
        let d = display
        let mods = d.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = d.dropFirst(mods.count)
        return mods.isEmpty ? String(key) : "\(mods) \(key)"
    }

    /// event tap 匹配用的 CGEventFlags。
    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        let mods = modifierFlags
        if mods.contains(.control) { f.insert(.maskControl) }
        if mods.contains(.option) { f.insert(.maskAlternate) }
        if mods.contains(.shift) { f.insert(.maskShift) }
        if mods.contains(.command) { f.insert(.maskCommand) }
        return f
    }
}

/// 待补做的取消置顶：删除置顶记录时目标浏览器不在线，命令无处可发。
///
/// 不记账的话：浏览器下次启动会由**它自己的会话恢复**把置顶标签带回来，
/// 而扩展的收编扫描分不清「用户新置顶的」和「刚被删掉、没来得及取消的」，
/// 于是又把它加回列表 —— 用户看到的就是「关着浏览器删掉，重开又回来」。
struct PendingUnpin: Codable, Equatable {
    let browser: String
    let host: String
}

/// 标签存活时间（Arc 式自动清理）：超过时限未使用的标签由扩展自动关闭。
enum TabLifetime: String, CaseIterable, Identifiable {
    case forever
    case h12
    case h24
    case d7
    case m1
    case m3
    case m6
    case y1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: return L10n.t("永久", "Forever")
        case .h12:     return L10n.t("12 小时", "12 hours")
        case .h24:     return L10n.t("24 小时", "24 hours")
        case .d7:      return L10n.t("7 天", "7 days")
        case .m1:      return L10n.t("1 个月", "1 month")
        case .m3:      return L10n.t("3 个月", "3 months")
        case .m6:      return L10n.t("半年", "6 months")
        case .y1:      return L10n.t("1 年", "1 year")
        }
    }

    /// 推给扩展的小时数；0 = 不清理。月按 30 天、年按 365 天算。
    var hours: Int {
        switch self {
        case .forever: return 0
        case .h12:     return 12
        case .h24:     return 24
        case .d7:      return 24 * 7
        case .m1:      return 24 * 30
        case .m3:      return 24 * 90
        case .m6:      return 24 * 180
        case .y1:      return 24 * 365
        }
    }
}

/// 自动检查更新的频率。
enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:  return L10n.t("每天", "Daily")
        case .weekly: return L10n.t("每周", "Weekly")
        case .never:  return L10n.t("从不", "Never")
        }
    }

    /// nil 表示不自动检查。
    var interval: TimeInterval? {
        switch self {
        case .daily:  return 86_400
        case .weekly: return 604_800
        case .never:  return nil
        }
    }
}

/// app 设置。
///
/// 事实源放在 app 这边而不是扩展的 `chrome.storage`：MV3 的 service worker
/// 随时会被回收，而 helper 进程一直活着；更重要的是，两边各存一份迟早会出现
/// 「界面显示 A、实际生效 B」（HealthTick #31/#32 都是这个形状的 bug）。
/// 扩展只负责执行，连接建立时由 app 把当前配置推过去。
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let scopeToWindow = "scopeToWindow"
        static let appearance = "appearance"
        static let switcherLayout = "switcherLayout"
        static let updateCheckFrequency = "updateCheckFrequency"
        static let allowTabClose = "allowTabClose"
        static let tabLifetime = "tabLifetime"
        static let favorites = "favoriteTabs"
        static let favoriteCurrentUrls = "favoriteCurrentUrls"
        static let pinHotkey = "pinHotkey"
        static let switcherHotkey = "switcherHotkey"
        static let globalHotkey = "globalHotkey"
        static let searchHotkey = "searchHotkey"
        static let globalSearchHotkey = "globalSearchHotkey"
        static let tabSearch = "tabSearch"
        static let siteSearches = "siteSearches"
        static let searchModeOrder = "searchModeOrder"
        static let searchModesEnabled = "searchModesEnabled"
        static let allEmptyContent = "allEmptyContent"
        static let globalSwitcher = "globalSwitcher"
        static let globalSwitcherStyle = "globalSwitcherStyle"
        static let globalExcludedApps = "globalExcludedApps"
        static let knownBrowsers = "knownBrowsers"
        static let pendingUnpins = "pendingUnpins"
        static let inlineFolderLimit = "inlineFolderLimit"
    }

    /// 状态栏平铺文件夹数量的取值范围。下限 1：0 等于「全部收进更多」，
    /// 那和没有平铺区没区别；上限 20：再多主菜单就比屏幕还高了。
    static let inlineFolderLimitRange = 1...20
    static let defaultInlineFolderLimit = 5

    /// 设置页下拉的档位。当前值不在档位里时插进去，保证下拉总有一项对得上。
    static func inlineFolderLimitChoices(including current: Int) -> [Int] {
        var choices = [3, 5, 8, 10, 15, 20]
        if !choices.contains(current) { choices.append(current); choices.sort() }
        return choices
    }

    /// 切换器相关配置变化时通知外部（用来推给扩展）。
    var onChange: (() -> Void)?

    /// 语言变化后需要重建已渲染的界面。
    var onLanguageChange: (() -> Void)?

    /// 界面语言。真正的存储在 L10n，这里只是给 UI 一个可绑定的入口。
    @Published var language: L10n.Language = L10n.language {
        didSet {
            guard oldValue != language else { return }
            L10n.language = language
            onLanguageChange?()
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            guard oldValue != appearance else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }

    /// 启动时把已保存的外观应用上去。
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// 切换器是否只列出当前 Chrome 窗口的标签。
    @Published var scopeToWindow: Bool {
        didSet {
            guard oldValue != scopeToWindow else { return }
            UserDefaults.standard.set(scopeToWindow, forKey: Key.scopeToWindow)
            onChange?()
        }
    }

    /// 切换器浮层的排布。纯 helper 侧的展示配置，浮层每次弹出时读取，
    /// 不需要推给扩展，也就不走 `onChange`。
    @Published var switcherLayout: SwitcherLayout {
        didSet {
            guard oldValue != switcherLayout else { return }
            UserDefaults.standard.set(switcherLayout.rawValue, forKey: Key.switcherLayout)
        }
    }

    /// 悬停切换器卡片时是否显示 ✕（点击直接关闭标签）。
    /// 默认关闭 —— 切换器的本职是切换，误点关掉标签的代价比多开一次设置高。
    /// 纯 helper 侧行为开关，浮层每次弹出时读取，不需要推给扩展。
    @Published var allowTabClose: Bool {
        didSet {
            guard oldValue != allowTabClose else { return }
            UserDefaults.standard.set(allowTabClose, forKey: Key.allowTabClose)
        }
    }

    /// 全局切换器：前台不是浏览器时也能唤出，列出**所有**已连接浏览器的标签。
    ///
    /// 默认关闭 —— 打开就意味着在终端、编辑器这些自己也用 ⌃⇥ 切标签的应用里
    /// 把键抢过来，得由用户自己决定这笔交易划不划算。纯 helper 侧行为，
    /// 不推给扩展；但它决定 event tap 要不要在非浏览器前台拦键，
    /// 所以要立刻重算就绪状态。
    @Published var globalSwitcher: Bool {
        didSet {
            guard oldValue != globalSwitcher else { return }
            UserDefaults.standard.set(globalSwitcher, forKey: Key.globalSwitcher)
            onInterceptScopeChange?()
        }
    }

    /// 全局切换器的呈现样式。浮层每次弹出时读取。
    @Published var globalSwitcherStyle: GlobalSwitcherStyle {
        didSet {
            guard oldValue != globalSwitcherStyle else { return }
            UserDefaults.standard.set(globalSwitcherStyle.rawValue, forKey: Key.globalSwitcherStyle)
        }
    }

    /// 全局切换器的排除名单：这些 App 在前台时不接管快捷键。
    ///
    /// 默认空。这是用户手里唯一能解开「⌃⇥ 被抢走」的扳手 —— 自己也用 ⌃⇥ 的
    /// App（终端、编辑器、Safari / Firefox）我们既探测不到、也不该替用户决定
    /// 谁赢。纯 helper 侧，但改的是拦截范围，走 onInterceptScopeChange。
    @Published var globalExcludedApps: [ExcludedApp] {
        didSet {
            guard oldValue != globalExcludedApps else { return }
            if let data = try? JSONEncoder().encode(globalExcludedApps) {
                UserDefaults.standard.set(data, forKey: Key.globalExcludedApps)
            }
            onInterceptScopeChange?()
        }
    }

    /// 影响 event tap 拦截范围的设置变了（全局切换器开关、排除名单）。
    /// 不走 onChange —— 那是推给扩展用的，这条纯 helper 侧。
    var onInterceptScopeChange: (() -> Void)?

    /// 有收藏被移除（菜单取消收藏、设置页删除都走这里）。
    /// 消费方要把对应标签的置顶撤销 —— 核对逻辑只会「补齐」，不会「撤销」。
    var onFavoritesRemoved: (([FavoriteTab]) -> Void)?

    /// 快捷键配置变化（重新挂 event tap 匹配 + 刷新菜单显示）。
    var onHotkeyChange: (() -> Void)?

    /// 「置顶/取消置顶当前标签」的快捷键。nil = 未设置（不吞任何按键）。
    @Published var pinHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != pinHotkey else { return }
            if let hk = pinHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.pinHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.pinHotkey)
            }
            onHotkeyChange?()
        }
    }

    /// 切换器的触发键。nil = 默认 ⌃⇥。修饰键里的 ⇧ 会被忽略（留给反向切换）。
    @Published var switcherHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != switcherHotkey else { return }
            if let hk = switcherHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.switcherHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.switcherHotkey)
            }
            onHotkeyChange?()
        }
    }

    /// 全局切换器的触发键。nil = 跟随切换器快捷键。
    ///
    /// 和切换器**不同键**时，浏览器在前台也能用它唤出全局切换器（想跨浏览器
    /// 找标签时不必先切出浏览器）；**同一个键**时，浏览器在前台归当前浏览器
    /// 切换器，只有前台不是浏览器才落到全局。⇧ 同样被忽略（留给反向切换）。
    @Published var globalHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != globalHotkey else { return }
            if let hk = globalHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.globalHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.globalHotkey)
            }
            onHotkeyChange?()
        }
    }

    /// 搜索面板 Tab 循环的顺序。存的是 rawValue 数组；解出来缺的补在末尾、多的丢掉，
    /// 这样以后加模式老设置照样能用。
    @Published var searchModeOrder: [SearchMode] {
        didSet {
            guard oldValue != searchModeOrder else { return }
            UserDefaults.standard.set(searchModeOrder.map(\.rawValue), forKey: Key.searchModeOrder)
        }
    }

    /// 哪些模式进 Tab 循环（设置里勾选）。至少留一个，全去掉就退回「全部」。
    @Published var searchModesEnabled: Set<SearchMode> {
        didSet {
            guard oldValue != searchModesEnabled else { return }
            UserDefaults.standard.set(searchModesEnabled.map(\.rawValue).sorted(), forKey: Key.searchModesEnabled)
        }
    }

    /// 「全部」模式没输入时列什么。nil = 空着。默认标签（用户 2026-09-26 定的）。
    @Published var allEmptyContent: SearchMode? {
        didSet {
            guard oldValue != allEmptyContent else { return }
            UserDefaults.standard.set(allEmptyContent?.rawValue ?? "none", forKey: Key.allEmptyContent)
        }
    }
    /// 可以选的项（「全部」和「搜索」本身没有「没输入时的内容」）。
    static let allEmptyChoices: [SearchMode] = [.tabs, .history, .bookmarks, .closed, .folders, .apps]

    /// 按顺序、只取勾选的；一个都没勾就退回「全部」。
    var activeSearchModes: [SearchMode] {
        let active = searchModeOrder.filter { searchModesEnabled.contains($0) }
        return active.isEmpty ? [.all] : active
    }

    static func normalizedModeOrder(_ raw: [String]?) -> [SearchMode] {
        var order = (raw ?? []).compactMap(SearchMode.init(rawValue:))
        // 「标签」是后加的（2026-09-26），老设置里没有它时插在「全部」后面而不是末尾
        if !order.contains(.tabs), let allIndex = order.firstIndex(of: .all) {
            order.insert(.tabs, at: allIndex + 1)
        }
        for mode in SearchMode.allCases where !order.contains(mode) { order.append(mode) }
        return order
    }

    /// 站内搜索模板（⌘E 面板 Tab 操作里的「在 X 搜索」）。未设置时用默认那几个。
    /// 纯 helper 侧，面板每次打开时读。
    @Published var siteSearches: [SiteSearch] {
        didSet {
            guard oldValue != siteSearches else { return }
            if let data = try? JSONEncoder().encode(siteSearches) {
                UserDefaults.standard.set(data, forKey: Key.siteSearches)
            }
        }
    }

    /// 标签搜索面板的开关。默认开。纯 helper 侧，改的是拦截范围，走 onHotkeyChange
    /// 一并重挂（它和搜索键在 event tap 里是同一组状态）。
    @Published var tabSearch: Bool {
        didSet {
            guard oldValue != tabSearch else { return }
            UserDefaults.standard.set(tabSearch, forKey: Key.tabSearch)
            onHotkeyChange?()
        }
    }

    /// 浏览器之外的搜索键。nil = 默认 ⌥Space。任何 App 前台都生效（排除名单除外），
    /// 弹出跨浏览器的搜索。
    @Published var globalSearchHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != globalSearchHotkey else { return }
            if let hk = globalSearchHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.globalSearchHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.globalSearchHotkey)
            }
            onHotkeyChange?()
        }
    }

    /// 标签搜索面板的触发键。nil = 默认 ⌘E。
    @Published var searchHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != searchHotkey else { return }
            if let hk = searchHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.searchHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.searchHotkey)
            }
            onHotkeyChange?()
        }
    }

    /// 待补做的取消置顶。目标浏览器下次连上时随设置下发，执行完即清除。
    /// 不触发 onChange —— 它跟着 settings payload 走，不需要额外推送。
    @Published var pendingUnpins: [PendingUnpin] {
        didSet {
            guard oldValue != pendingUnpins else { return }
            if let data = try? JSONEncoder().encode(pendingUnpins) {
                UserDefaults.standard.set(data, forKey: Key.pendingUnpins)
            }
        }
    }

    /// 连接过的浏览器（bundle id）。设置页的浏览器状态列表用 ——
    /// 没连着的浏览器我们无从探测，只能记住见过谁。
    @Published var knownBrowsers: [String] {
        didSet {
            guard oldValue != knownBrowsers else { return }
            UserDefaults.standard.set(knownBrowsers, forKey: Key.knownBrowsers)
        }
    }

    /// 收藏的标签。变更即持久化并推给扩展（扩展收到后立即核对补齐）。
    @Published var favorites: [FavoriteTab] {
        didSet {
            guard oldValue != favorites else { return }
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: Key.favorites)
            }
            // 顺序有讲究：先发 unpin、后推新配置。扩展按序处理消息，
            // 收编扫描（ensureFavorites 末尾）跑到时置顶已被撤掉；
            // 反过来的话「取消置顶 → 收编又把它加回来」成环（实测）。
            let removed = oldValue.filter { old in !favorites.contains(where: { $0.id == old.id }) }
            if !removed.isEmpty { onFavoritesRemoved?(removed) }
            onChange?()
            // 最后才清「最后访问」—— 上面的 unpin 要靠它定位漂移后的域名
            for fav in removed { favoriteCurrentUrls.removeValue(forKey: fav.id) }
        }
    }

    /// 收藏标签的「最后访问 URL」（favorite.id → 当前 URL）。
    /// 收藏是一个「标签位」：置顶标签会在站内外漂移，恢复必须以最后
    /// 访问为准，按原始 URL 重开会堆出重复置顶。单独存放且**不触发
    /// onChange** —— 它随每次导航更新，跟着推送会造成核对风暴；
    /// 扩展在连接时拿到的 settings 里自然带最新值。
    @Published var favoriteCurrentUrls: [String: String] {
        didSet {
            guard oldValue != favoriteCurrentUrls else { return }
            UserDefaults.standard.set(favoriteCurrentUrls, forKey: Key.favoriteCurrentUrls)
        }
    }

    /// 标签存活时间。默认「永久」（不清理）—— 自动关标签是破坏性动作，
    /// 必须用户主动打开。清理由扩展执行，走 onChange 推送。
    @Published var tabLifetime: TabLifetime {
        didSet {
            guard oldValue != tabLifetime else { return }
            UserDefaults.standard.set(tabLifetime.rawValue, forKey: Key.tabLifetime)
            onChange?()
        }
    }

    /// 状态栏菜单里平铺的收藏文件夹数量，超出的收进「更多 ▸」。
    /// 纯 helper 侧展示配置，菜单每次打开时现读，不需要推给扩展。
    @Published var inlineFolderLimit: Int {
        didSet {
            guard oldValue != inlineFolderLimit else { return }
            UserDefaults.standard.set(inlineFolderLimit, forKey: Key.inlineFolderLimit)
        }
    }

    /// 自动检查更新的频率。UpdateChecker 到点对账时现读，改动立即生效。
    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            guard oldValue != updateCheckFrequency else { return }
            UserDefaults.standard.set(updateCheckFrequency.rawValue, forKey: Key.updateCheckFrequency)
        }
    }

    /// 开机自启。
    ///
    /// 这是**镜像**而非事实源 —— 真值在 `SMAppService`，用户随时可能在系统设置里
    /// 改掉它。绑定一个不可观察的外部状态会让开关在重渲染的间隙自由漂移
    /// （HealthTick #32：表现为「开关随机回跳」）。所以：初始化读一次，
    /// 每次操作后回读真实值写回，窗口重新激活时再刷新。
    @Published private(set) var launchAtLogin: Bool

    /// 已注册但等待用户在系统设置里批准（macOS 13+）。
    /// 这种状态必须和「关闭」区分开，否则用户会对着一个关着的开关反复点。
    @Published private(set) var launchNeedsApproval: Bool

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.scopeToWindow: true])
        scopeToWindow = defaults.bool(forKey: Key.scopeToWindow)
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        switcherLayout = SwitcherLayout(rawValue: defaults.string(forKey: Key.switcherLayout) ?? "") ?? .strip
        allowTabClose = defaults.bool(forKey: Key.allowTabClose)   // 未设置时即默认 false
        tabLifetime = TabLifetime(rawValue: defaults.string(forKey: Key.tabLifetime) ?? "") ?? .forever
        favorites = defaults.data(forKey: Key.favorites)
            .flatMap { try? JSONDecoder().decode([FavoriteTab].self, from: $0) } ?? []
        pinHotkey = defaults.data(forKey: Key.pinHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        switcherHotkey = defaults.data(forKey: Key.switcherHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        globalHotkey = defaults.data(forKey: Key.globalHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        searchHotkey = defaults.data(forKey: Key.searchHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        globalSearchHotkey = defaults.data(forKey: Key.globalSearchHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        tabSearch = defaults.object(forKey: Key.tabSearch) == nil ? true : defaults.bool(forKey: Key.tabSearch)
        siteSearches = defaults.data(forKey: Key.siteSearches)
            .flatMap { try? JSONDecoder().decode([SiteSearch].self, from: $0) } ?? SiteSearch.defaults
        searchModeOrder = Self.normalizedModeOrder(defaults.stringArray(forKey: Key.searchModeOrder))
        searchModesEnabled = defaults.stringArray(forKey: Key.searchModesEnabled)
            .map { Set($0.compactMap(SearchMode.init(rawValue:))) } ?? SearchMode.defaultEnabled
        allEmptyContent = defaults.string(forKey: Key.allEmptyContent).map { SearchMode(rawValue: $0) } ?? .tabs
        globalSwitcher = defaults.bool(forKey: Key.globalSwitcher)   // 未设置即默认 false
        globalSwitcherStyle = GlobalSwitcherStyle(rawValue: defaults.string(forKey: Key.globalSwitcherStyle) ?? "") ?? .list
        globalExcludedApps = defaults.data(forKey: Key.globalExcludedApps)
            .flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
        knownBrowsers = defaults.stringArray(forKey: Key.knownBrowsers) ?? []
        pendingUnpins = defaults.data(forKey: Key.pendingUnpins)
            .flatMap { try? JSONDecoder().decode([PendingUnpin].self, from: $0) } ?? []
        favoriteCurrentUrls = defaults.dictionary(forKey: Key.favoriteCurrentUrls) as? [String: String] ?? [:]
        updateCheckFrequency = UpdateCheckFrequency(rawValue: defaults.string(forKey: Key.updateCheckFrequency) ?? "") ?? .daily
        // 没存过（0）或手改成越界值都回到范围内，菜单那边不用再防
        let storedLimit = defaults.integer(forKey: Key.inlineFolderLimit)
        inlineFolderLimit = Self.inlineFolderLimitRange.contains(storedLimit)
            ? storedLimit : Self.defaultInlineFolderLimit

        let state = LoginItem.state
        launchAtLogin = state == .enabled
        launchNeedsApproval = state == .requiresApproval
    }

    /// 从系统回读登录项真实状态。
    func refreshLaunchAtLogin() {
        let state = LoginItem.state
        launchAtLogin = state == .enabled
        launchNeedsApproval = state == .requiresApproval
    }

    /// 切换开机自启，然后回读真实结果 —— 不假设操作成功。
    func toggleLaunchAtLogin() {
        let result = LoginItem.toggle()
        launchAtLogin = result == .enabled
        launchNeedsApproval = result == .requiresApproval
        if launchNeedsApproval {
            LoginItem.openSystemSettings()
        }
    }

    /// 传给某个客户端的配置字典。收藏只下发**它自己浏览器**的那份 ——
    /// 浏览器是隔离主体，别的浏览器的置顶不该在这里恢复。
    ///
    /// browser 传 nil（身份还没识别出来）时**不携带**收藏/待办字段：
    /// 扩展见不到 favorites 键就不会跑核对。按猜测的浏览器下发过一次，
    /// 结果是把 Chrome 的置顶恢复进了夸克（重载扩展后多出重复置顶）。
    func payload(favoritesFor browser: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "settings",
            "scopeToWindow": scopeToWindow,
            "tabLifetimeHours": tabLifetime.hours,
        ]
        if let browser {
            // 离线期间攒下的取消置顶，由扩展在核对前补做
            payload["pendingUnpinHosts"] = pendingUnpins.filter { $0.browser == browser }.map(\.host)
            payload["favorites"] = favorites.filter { $0.browser == browser }.map {
                ["id": $0.id,
                 "url": $0.url,
                 "title": $0.title,
                 "currentUrl": favoriteCurrentUrls[$0.id] ?? $0.url]
            }
        }
        return payload
    }
}
