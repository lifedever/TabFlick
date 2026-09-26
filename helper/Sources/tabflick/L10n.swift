import Foundation

/// 界面文案。
///
/// 调用点写的是中英两份：`L10n.t("已在 \(app) 打开", "Opened in \(app)")`。其他语言按
/// **英文模板**查表（`L10nTables`，一个 Swift 文件，由 `scripts/l10n/` 从翻译 JSON 生成）。
///
/// 刻意不用 `.lproj` + `Localizable.strings`：那需要 SwiftPM 的 `.process` 资源，
/// 会生成 `{Package}_{Target}.bundle` 并让代码依赖 `Bundle.module` —— 那个访问器
/// 只认 `.app` 包根目录和编译机的绝对路径，而签名又要求资源必须在
/// `Contents/Resources`，两个约束天生冲突，稍有不慎就是运行时 SIGTRAP。
///
/// 插值怎么查表：参数类型是 `L10nText`，编译期就把字面量拆成模板 + 参数——
/// `"Opened \(app) in \(x)"` 变成模板 `Opened {0} in {1}` 和参数 `[app, x]`。
/// 译文里 `{n}` 可以换位置。调用点一个都不用改。
enum L10n {

    enum Language: String, CaseIterable, Identifiable {
        case system
        /// 简体中文。raw value 沿用老设置里的 "zh"
        case zh
        case zhHant = "zh-Hant"
        case en
        case ja
        case ko
        case es
        case fr
        case de

        var id: String { rawValue }

        /// 选项名用**目标语言自身**书写：选「English」的人未必读得懂中文标签。
        var label: String {
            switch self {
            case .system: return L10n.t("跟随系统", "Follow System")
            case .zh:     return "简体中文"
            case .zhHant: return "繁體中文"
            case .en:     return "English"
            case .ja:     return "日本語"
            case .ko:     return "한국어"
            case .es:     return "Español"
            case .fr:     return "Français"
            case .de:     return "Deutsch"
            }
        }
    }

    private static let key = "language"

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            guard newValue != language else { return }
            // 界面刷新由 AppSettings.language 的 didSet 驱动（main.swift 的 onLanguageChange）
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    /// 实际生效的语言（「跟随系统」解析成具体一种，认不出的退回英文）。
    ///
    /// 不缓存成 `static let`：用户可以在设置里改语言，缓存会让已有界面
    /// 一直停在旧语言上，直到重启才对。
    static var current: Language {
        guard language == .system else { return language }
        return resolve(Locale.preferredLanguages.first ?? "en")
    }

    /// 系统语言标签 → 支持的语言。`zh-Hant-TW` / `zh-TW` / `zh-HK` / `zh-MO` 算繁体。
    static func resolve(_ tag: String) -> Language {
        let t = tag.lowercased()
        if t.hasPrefix("zh") {
            let hant = t.contains("hant") || t.hasSuffix("-tw") || t.hasSuffix("-hk") || t.hasSuffix("-mo")
            return hant ? .zhHant : .zh
        }
        for lang in [Language.ja, .ko, .es, .fr, .de] where t.hasPrefix(lang.rawValue) { return lang }
        return .en
    }

    /// 内容本身只有中英两份时（GitHub 上的发布说明）取哪份：简繁都看中文那份。
    static var prefersChineseContent: Bool { current == .zh || current == .zhHant }

    /// 并列名字之间的分隔：中日用顿号，其余用逗号。
    static var listSeparator: String {
        switch current {
        case .zh, .zhHant, .ja: return "、"
        default: return ", "
        }
    }

    /// 按当前语言取文案。
    static func t(_ zh: L10nText, _ en: L10nText) -> String {
        render(zh: { zh.rendered }, template: en.template, args: en.args, english: { en.rendered })
    }

    // 只能有这一个重载。试过再加一个 `t(_: String, _: String)` 接变量（标了
    // `@_disfavoredOverload`）：带插值的字面量会被编译器挑去 String 那个，按带实际值的
    // 整句查表，永远查不到（l10n 校验抓到的）。变量调用点写 `L10nText(verbatim:)`。

    private static func render(zh: () -> String, template: String, args: [String],
                               english: () -> String) -> String {
        let lang = current
        switch lang {
        case .zh: return zh()
        case .en, .system: return english()
        default:
            if let translated = L10nTables.table(for: lang)[template] {
                return L10nText.fill(translated, args)
            }
            reportMissing(template, lang)
            // 繁体缺译时拿简体转一下，比掉回英文更像话
            if lang == .zhHant {
                return zh().applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? zh()
            }
            return english()
        }
    }

    /// 缺译只记一次，免得刷日志。切到某种语言把菜单和设置点一遍，日志里就是缺的清单。
    nonisolated(unsafe) private static var reported: Set<String> = []
    private static func reportMissing(_ template: String, _ lang: Language) {
        let key = lang.rawValue + "|" + template
        guard !reported.contains(key) else { return }
        reported.insert(key)
        log("🌐 missing l10n [\(lang.rawValue)]: \(template.prefix(80))")
    }
}

/// 一条文案：模板（插值换成 `{0}` `{1}`…）加参数。见 `L10n` 的说明。
struct L10nText: ExpressibleByStringInterpolation {
    let template: String
    let args: [String]

    init(stringLiteral value: String) {
        template = value
        args = []
    }

    /// 变量里的整句（没有插值），按整句查表。
    init(verbatim value: String) {
        template = value
        args = []
    }

    init(stringInterpolation: Interpolation) {
        template = stringInterpolation.template
        args = stringInterpolation.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var template = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            template.reserveCapacity(literalCapacity + interpolationCount * 3)
        }
        mutating func appendLiteral(_ literal: String) { template += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            template += "{\(args.count)}"
            args.append(String(describing: value))
        }
    }

    var rendered: String { Self.fill(template, args) }

    /// 把 `{n}` 换成第 n 个参数。
    static func fill(_ template: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return template }
        var out = template
        for (i, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: arg)
        }
        return out
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
