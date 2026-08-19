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
