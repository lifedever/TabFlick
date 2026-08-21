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
        static let globalSwitcher = "globalSwitcher"
        static let globalSwitcherStyle = "globalSwitcherStyle"
        static let knownBrowsers = "knownBrowsers"
        static let pendingUnpins = "pendingUnpins"
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

    /// 影响 event tap 拦截范围的设置变了（目前只有全局切换器开关）。
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
        globalSwitcher = defaults.bool(forKey: Key.globalSwitcher)   // 未设置即默认 false
        globalSwitcherStyle = GlobalSwitcherStyle(rawValue: defaults.string(forKey: Key.globalSwitcherStyle) ?? "") ?? .list
        knownBrowsers = defaults.stringArray(forKey: Key.knownBrowsers) ?? []
        pendingUnpins = defaults.data(forKey: Key.pendingUnpins)
            .flatMap { try? JSONDecoder().decode([PendingUnpin].self, from: $0) } ?? []
        favoriteCurrentUrls = defaults.dictionary(forKey: Key.favoriteCurrentUrls) as? [String: String] ?? [:]
        updateCheckFrequency = UpdateCheckFrequency(rawValue: defaults.string(forKey: Key.updateCheckFrequency) ?? "") ?? .daily

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
