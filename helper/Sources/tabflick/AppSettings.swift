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

    init(url: String, title: String, favIconUrl: String? = nil) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title
        self.favIconUrl = favIconUrl
    }

    /// 旧版本存的数据没有 id 字段（当时以 url 为身份），用 url 补位，
    /// 顺便让旧的 favoriteCurrentUrls（也是按 url 键的）继续对得上。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? url
        favIconUrl = try c.decodeIfPresent(String.self, forKey: .favIconUrl)
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
        return s + character.uppercased()
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

/// 标签存活时间（Arc 式自动清理）：超过时限未使用的标签由扩展自动关闭。
enum TabLifetime: String, CaseIterable, Identifiable {
    case forever
    case h12
    case h24
    case d7

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: return L10n.t("永久", "Forever")
        case .h12:     return L10n.t("12 小时", "12 hours")
        case .h24:     return L10n.t("24 小时", "24 hours")
        case .d7:      return L10n.t("7 天", "7 days")
        }
    }

    /// 推给扩展的小时数；0 = 不清理。
    var hours: Int {
        switch self {
        case .forever: return 0
        case .h12:     return 12
        case .h24:     return 24
        case .d7:      return 168
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

    /// 传给扩展的配置字典。
    var payload: [String: Any] {
        ["type": "settings",
         "scopeToWindow": scopeToWindow,
         "tabLifetimeHours": tabLifetime.hours,
         "favorites": favorites.map {
             ["id": $0.id,
              "url": $0.url,
              "title": $0.title,
              "currentUrl": favoriteCurrentUrls[$0.id] ?? $0.url]
         }]
    }
}
