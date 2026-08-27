import Foundation

/// 中英双语文案。
///
/// 刻意不用 `.lproj` + `Localizable.strings`：那需要 SwiftPM 的 `.process` 资源，
/// 会生成 `{Package}_{Target}.bundle` 并让代码依赖 `Bundle.module` —— 那个访问器
/// 只认 `.app` 包根目录和编译机的绝对路径，而签名又要求资源必须在
/// `Contents/Resources`，两个约束天生冲突，稍有不慎就是运行时 SIGTRAP。
///
/// 只有两种语言、几十条文案，直接写在代码里更稳，也让译文和用处待在同一行。
enum L10n {

    enum Language: String, CaseIterable, Identifiable {
        case system
        case zh
        case en

        var id: String { rawValue }

        /// 选项名用**目标语言自身**书写：选「English」的人未必读得懂中文标签。
        var label: String {
            switch self {
            case .system: return L10n.t("跟随系统", "Follow System")
            case .zh:     return "简体中文"
            case .en:     return "English"
            }
        }
    }

    private static let key = "language"

    /// 语言变化后需要重建已经渲染好的界面（菜单栏标题是创建时写死的）。
    nonisolated(unsafe) static var onChange: (() -> Void)?

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            guard newValue != language else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            onChange?()
        }
    }

    /// 当前是否使用中文。
    ///
    /// 不缓存成 `static let`：用户可以在设置里改语言，缓存会让已有界面
    /// 一直停在旧语言上，直到重启才对。
    static var isChinese: Bool {
        switch language {
        case .zh: return true
        case .en: return false
        case .system:
            guard let tag = Locale.preferredLanguages.first else { return false }
            return tag.lowercased().hasPrefix("zh")
        }
    }

    /// 按当前语言取文案。
    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

/// 「X 分钟前」。ms epoch 拿不到（旧扩展 / 旧 Chrome）或是未来时刻时返回 nil，
/// 调用方就不显示这一栏。
///
/// 状态栏菜单的活标签（`TabInfo.lastAccessed`）、已关闭标签
/// （`ClosedTab.closedAt`）、全局切换器的列表共用这一份 —— 同样的东西
/// 写两遍，迟早在其中一处漏改（这个项目栽过好几次）。
func relativeTime(msEpoch: Double?) -> String? {
    guard let msEpoch, msEpoch > 0 else { return nil }
    let seconds = Date().timeIntervalSince1970 - msEpoch / 1000
    guard seconds >= 0 else { return nil }
    if seconds < 60 { return L10n.t("刚刚", "just now") }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return L10n.t("\(minutes) 分钟前", "\(minutes)m ago") }
    let hours = Int(seconds / 3600)
    if hours < 24 { return L10n.t("\(hours) 小时前", "\(hours)h ago") }
    return L10n.t("\(Int(seconds / 86400)) 天前", "\(Int(seconds / 86400))d ago")
}
