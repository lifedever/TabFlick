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
        ["type": "settings", "scopeToWindow": scopeToWindow]
    }
}
