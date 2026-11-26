import Foundation

// JS 插件的 manifest 和联网规则（纯逻辑，checks/plugin-manifest-check.swift 校验）。
//
// manifest.json 是外部输入（从商店下载、或开发时手放进插件目录），每个字段都要验：id 当存盘的键和目录名，
// hosts 是联网白名单 —— 写错了要么插件取不到数据，要么白名单形同虚设。

struct PluginManifest: Equatable {
    enum Contribution: String, CaseIterable {
        /// 状态栏二级菜单
        case menu
        /// 「全部」里的搜索结果
        case search
        /// 一个 Tab 模式（保留，还没用）
        case mode
        /// 搜索面板里一个命令，回车进插件自己的列表（同「结束进程…」）
        case list
        /// App 插件的命令（`"commands": [...]`，数组，单独解析到 `commands`）
        case commands
    }

    enum Problem: Error, Equatable {
        case notJSON
        case missing(String)
        case badID(String)
        case badVersion(String)
        case badHost(String)
        case noName
        case unknownContribution(String)
        case badIcon(String)
        /// `app` 不对：bundle id 不合规、是苹果自己的 App、scheme 不合规
        case badApp(String)
        case badCommand(String)
        /// 固定脚本不合规（名字、长度、或者出现了跳出那个 App 的写法，见 `PluginScriptPolicy`）
        case badScript(String)
    }

    let id: String
    let version: String
    /// 语言代码 → 名字（键按 `L10n.Language` 的 rawValue：zh / zh-Hant / en / ja…；zh-Hans 当 zh）
    let names: [String: String]
    let summaries: [String: String]
    let symbol: String
    /// 图标块底色（red / orange / …，`PluginTint`）
    let tint: String
    let minAppVersion: String?
    /// 插件能联网去的主机，完全匹配；`*.example.com` 认 example.com 下面的任意子域名（不含它自己）——
    /// 给和风天气这种每个账号一个专属域名（xxxx.re.qweatherapi.com）的服务用
    let hosts: [String]
    let contributes: Set<Contribution>
    /// 入口脚本，相对插件目录
    let main: String
    /// 图标，相对插件目录（.svg / .png，正方形、画满，TabFlick 裁圆角）。nil = 用 symbol + tint 画
    var icon: String? = nil
    /// 列表入口命令：名字、搜它用的关键词（拼音、英文别名）、列表里输入框的占位、没内容时那句话
    var listTitles: [String: String] = [:]
    var listKeywords: [String] = []
    var listPlaceholders: [String: String] = [:]
    var listEmpty: [String: String] = [:]
    /// 插件页要不要「涨跌颜色」（`"settings": {"upDownColors": true}`，股票这类有涨跌的才要）
    var usesUpDownColors = false
    /// 插件自己的设置项（`"settings": {"choices": [...]}`）：设置页画成下拉框，插件用 `tabflick.settings.get(key)` 读
    var choices: [PluginChoice] = []
    /// 要用户填的文字（`"settings": {"inputs": [...]}`：和风天气的 API Host、Key），插件同样用 `settings.get` 读
    var inputs: [PluginInput] = []
    /// 设置页里的链接（`"settings": {"links": [...]}`：去哪注册、拿 Key），只许 https
    var links: [PluginLink] = []
    /// App 插件（2026-11-26）：插件对应的第三方 App。声明了才能有命令、打开它的网址、跑固定脚本
    var app: PluginApp? = nil
    /// 搜索面板里的命令（挂在 `app` 下面，App 没装不出现），也是菜单栏二级菜单的内容
    var commands: [PluginCommand] = []

    /// id：小写字母开头，小写字母、数字、连字符，2–40 个。当目录名和存盘的键用，不能带路径字符。
    nonisolated static func isValidID(_ id: String) -> Bool {
        guard (2...40).contains(id.count), let first = id.unicodeScalars.first,
              ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// 版本：一到四段数字（1.0.0）。
    nonisolated static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// 主机名：小写字母、数字、连字符、点，至少两段，不带协议 / 端口 / 路径 / 通配。
    nonisolated static func isValidHost(_ host: String) -> Bool {
        // `*.` 只许出现在最前面，后面至少两段（`*.com` 这种等于放开整个顶级域，不收）
        if host.hasPrefix("*.") {
            let rest = String(host.dropFirst(2))
            return !rest.contains("*") && rest.split(separator: ".").count >= 2 && isValidHost(rest)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// 入口脚本：插件目录里的一个 .js，不许往上走、不许绝对路径。
    nonisolated static func isValidMain(_ path: String) -> Bool {
        guard path.hasSuffix(".js"), !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    /// 图标：插件目录里的一个 .svg / .png，规矩同入口脚本（不许往上走、不许绝对路径）。
    nonisolated static func isValidIcon(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".svg") || lower.hasSuffix(".png"), !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    nonisolated static func parse(_ data: Data) -> Result<PluginManifest, Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard let id = json["id"] as? String else { return .failure(.missing("id")) }
        guard isValidID(id) else { return .failure(.badID(id)) }
        guard let version = json["version"] as? String else { return .failure(.missing("version")) }
        guard isValidVersion(version) else { return .failure(.badVersion(version)) }
        let names = localized(json["name"])
        guard !names.isEmpty else { return .failure(.noName) }
        let minApp = json["minAppVersion"] as? String
        if let minApp, !isValidVersion(minApp) { return .failure(.badVersion(minApp)) }
        var hosts: [String] = []
        for case let host as String in (json["hosts"] as? [Any]) ?? [] {
            guard isValidHost(host) else { return .failure(.badHost(host)) }
            if !hosts.contains(host) { hosts.append(host) }
        }
        var contributes = Set<Contribution>()
        var listInfo: [String: Any] = [:]
        var commandList: [Any] = []
        if let declared = json["contributes"] as? [String: Any] {
            for (key, value) in declared {
                guard let point = Contribution(rawValue: key) else { return .failure(.unknownContribution(key)) }
                if point == .commands {
                    guard let list = value as? [Any] else { return .failure(.badCommand("commands must be an array")) }
                    commandList = list
                    contributes.insert(point)
                    continue
                }
                // 值是 true，或者是带细节的对象（list 的名字、关键词…）
                if (value as? Bool) == true { contributes.insert(point) }
                if let detail = value as? [String: Any] {
                    contributes.insert(point)
                    if point == .list { listInfo = detail }
                }
            }
        }
        let main = (json["main"] as? String) ?? "main.js"
        guard isValidMain(main) else { return .failure(.missing("main")) }
        // 图标写了就得是合规的路径（写错了要在日志里看得到，而不是悄悄退回符号）；文件读不出来是加载时的事
        var icon: String?
        if let value = json["icon"] {
            guard let path = value as? String, isValidIcon(path) else { return .failure(.badIcon(String(describing: value))) }
            icon = path
        }
        // 关键词：字符串、去空白、去重，最多 20 个，每个最多 30 个字
        var keywords: [String] = []
        for case let word as String in (listInfo["keywords"] as? [Any]) ?? [] {
            let trimmed = String(word.trimmingCharacters(in: .whitespaces).prefix(30))
            if !trimmed.isEmpty, !keywords.contains(trimmed), keywords.count < 20 { keywords.append(trimmed) }
        }
        let settings = json["settings"] as? [String: Any]
        let choices = PluginChoice.parse(settings?["choices"])
        // 文字输入和下拉框共用 settings.get 的键，撞了的话插件读到的是哪个说不清，文字那个丢掉
        let inputs = PluginInput.parse(settings?["inputs"]).filter { input in !choices.contains { $0.key == input.key } }
        // App 插件：app 和 commands 只要有一处写错就整份不认（写错了的命令、脚本悄悄丢掉，插件作者看不出来）
        var app: PluginApp?
        if let value = json["app"] {
            switch PluginApp.parse(value) {
            case .success(let parsed): app = parsed
            case .failure(let problem): return .failure(problem)
            }
        }
        // 能跑脚本的插件不许联网：脚本从 App 里读到的东西（或者用户在 App 里打的字）没有出口
        if let app, !app.scripts.isEmpty, !hosts.isEmpty { return .failure(.badScript("a plugin with scripts can't have hosts")) }
        var commands: [PluginCommand] = []
        if !commandList.isEmpty {
            guard app != nil else { return .failure(.badCommand("commands need an app")) }
            switch PluginCommand.parse(commandList) {
            case .success(let parsed): commands = parsed
            case .failure(let problem): return .failure(problem)
            }
        }
        return .success(PluginManifest(
            id: id, version: version, names: names, summaries: localized(json["summary"]),
            symbol: (json["symbol"] as? String) ?? "puzzlepiece.fill",
            tint: (json["tint"] as? String) ?? "gray",
            minAppVersion: minApp, hosts: hosts, contributes: contributes, main: main, icon: icon,
            listTitles: localized(listInfo["title"]), listKeywords: keywords,
            listPlaceholders: localized(listInfo["placeholder"]), listEmpty: localized(listInfo["empty"]),
            usesUpDownColors: (settings?["upDownColors"] as? Bool) == true,
            choices: choices, inputs: inputs, links: PluginLink.parse(settings?["links"]),
            app: app, commands: commands))
    }

    /// `{"zh-Hans": "股票", "en": "Stocks"}` → 键统一成 `L10n.Language` 的写法；只给了一个字符串当英文。
    nonisolated private static func localized(_ value: Any?) -> [String: String] {
        if let text = value as? String, !text.isEmpty { return ["en": text] }
        guard let table = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in table {
            guard let text = raw as? String, !text.isEmpty else { continue }
            out[key == "zh-Hans" ? "zh" : key] = text
        }
        return out
    }

    /// 按界面语言挑：这种语言 → 繁中退简中 → 英文 → 随便一个（按键排序，结果固定）。
    nonisolated static func pick(_ table: [String: String], language: String) -> String? {
        if let exact = table[language] { return exact }
        if language == "zh-Hant", let simplified = table["zh"] { return simplified }
        if let english = table["en"] { return english }
        return table.keys.sorted().first.flatMap { table[$0] }
    }
}

/// 插件的一个设置项：几个选项挑一个（V2EX 看热议还是最新）。外部输入：key 只许字母数字下划线，
/// 默认值必须是选项之一，最多 5 个设置项、每个最多 10 个选项，认不出的整项丢掉。
struct PluginChoice: Equatable {
    struct Option: Equatable {
        let value: String
        let titles: [String: String]
    }
    let key: String
    let titles: [String: String]
    let defaultValue: String
    let options: [Option]

    nonisolated static func isValidKey(_ key: String) -> Bool {
        (1...30).contains(key.count) && key.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    nonisolated static func parse(_ value: Any?) -> [PluginChoice] {
        var out: [PluginChoice] = []
        for case let item as [String: Any] in ((value as? [Any]) ?? []).prefix(5) {
            guard let key = item["key"] as? String, isValidKey(key), !out.contains(where: { $0.key == key }) else { continue }
            var options: [Option] = []
            for case let o as [String: Any] in ((item["options"] as? [Any]) ?? []).prefix(10) {
                guard let v = o["value"] as? String, isValidKey(v), !options.contains(where: { $0.value == v }) else { continue }
                options.append(Option(value: v, titles: titles(o["title"]) ?? ["en": v]))
            }
            let fallback = options.first?.value ?? ""
            let def = (item["default"] as? String).flatMap { d in options.contains { $0.value == d } ? d : nil } ?? fallback
            guard options.count >= 2, let title = titles(item["title"]) else { continue }
            out.append(PluginChoice(key: key, titles: title, defaultValue: def, options: options))
        }
        return out
    }

    nonisolated static func titles(_ value: Any?) -> [String: String]? {
        if let text = value as? String, !text.isEmpty { return ["en": text] }
        var out: [String: String] = [:]
        for case let (k, text as String) in (value as? [String: Any]) ?? [:] where !text.isEmpty { out[k == "zh-Hans" ? "zh" : k] = text }
        return out.isEmpty ? nil : out
    }
}

/// 插件要用户填的一段文字（API Host、Key）。外部输入：key 同下拉框的规矩、不能和下拉框撞，最多 5 个；
/// `secret` 的设置页画成密码框。值存在 `PluginSettingsStore`（UserDefaults，明文 —— 放的是免费天气服务的 Key 这类，
/// 不是密码；真要存敏感凭据得换钥匙串）。
struct PluginInput: Equatable {
    let key: String
    let titles: [String: String]
    let placeholders: [String: String]
    let notes: [String: String]
    let secret: Bool

    /// 存多长：再长就不是 Key 了
    nonisolated static let maxLength = 300

    nonisolated static func parse(_ value: Any?) -> [PluginInput] {
        var out: [PluginInput] = []
        for case let item as [String: Any] in ((value as? [Any]) ?? []).prefix(5) {
            guard let key = item["key"] as? String, PluginChoice.isValidKey(key), !out.contains(where: { $0.key == key }),
                  let title = PluginChoice.titles(item["title"]) else { continue }
            out.append(PluginInput(key: key, titles: title, placeholders: PluginChoice.titles(item["placeholder"]) ?? [:],
                                   notes: PluginChoice.titles(item["note"]) ?? [:], secret: (item["secret"] as? Bool) == true))
        }
        return out
    }
}

/// 设置页里的一条链接（「去和风天气控制台拿 Key」）。只许 https、不带账号密码，最多 3 条。
struct PluginLink: Equatable {
    let titles: [String: String]
    let url: URL

    nonisolated static func parse(_ value: Any?) -> [PluginLink] {
        var out: [PluginLink] = []
        for case let item as [String: Any] in ((value as? [Any]) ?? []).prefix(3) {
            guard let text = item["url"] as? String, let url = URL(string: text), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil,
                  let title = PluginChoice.titles(item["title"]) else { continue }
            out.append(PluginLink(titles: title, url: url))
        }
        return out
    }
}

/// App 插件对应的那个 App（manifest 的 `"app": {"bundleId", "schemes", "scripts"}`）。外部输入，每一项都要验：
/// 它决定了插件能指挥谁、能打开什么、能跑什么脚本。
///
/// 安全边界（用户 2026-11-26：「商店里面的插件一定要保证安全，防止病毒」）：
/// - 只能是第三方 App：苹果自己的（访达、终端、系统事件…）能力太大，系统层面的事归内置插件。
/// - 网址只认这里声明的 scheme，运行时还要核对确实是那个 App 自己登记的，并且交给它打开。
/// - AppleScript 只能是这里写死的几段（跟着 manifest 一起过 sha256），插件的 JS 只能按名字调，不能现拼；
///   TabFlick 自己包上 `tell application id "<bundleId>"`，正文里不许出现跳出这个 App 的写法（`PluginScriptPolicy`）。
struct PluginApp: Equatable {
    let bundleID: String
    let schemes: [String]
    /// 名字 → 正文（不含外面那层 tell）
    let scripts: [String: String]

    nonisolated static let maxSchemes = 4
    nonisolated static let maxScripts = 20

    /// bundle id：字母、数字、连字符，用点分成至少两段，最长 155。苹果自己的（com.apple.）不收。
    nonisolated static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...155).contains(id.count), parts.count >= 2,
              !id.lowercased().hasPrefix("com.apple.") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// 网址 scheme：小写字母开头，小写字母、数字、+ . -，最长 32。网页、本机文件、系统设置这些不收：
    /// 网页有 `tabflick.openURL`，后两样交给哪个 App 都不该由插件来开。
    nonisolated static func isValidScheme(_ scheme: String) -> Bool {
        guard (2...32).contains(scheme.count), let first = scheme.unicodeScalars.first, ("a"..."z").contains(first),
              scheme.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+.-".unicodeScalars.contains($0) })
        else { return false }
        let denied = ["http", "https", "file", "ftp", "sftp", "smb", "afp", "nfs", "vnc", "ssh", "telnet", "data", "javascript",
                      "mailto", "tel", "sms", "facetime", "itms", "macappstore"]
        return !denied.contains(scheme) && !scheme.hasPrefix("x-apple") && !scheme.hasPrefix("com.apple")
    }

    nonisolated static func parse(_ value: Any) -> Result<PluginApp, PluginManifest.Problem> {
        guard let json = value as? [String: Any], let id = json["bundleId"] as? String, isValidBundleID(id) else {
            return .failure(.badApp(String(describing: (value as? [String: Any])?["bundleId"] ?? value).prefix(80).description))
        }
        var schemes: [String] = []
        for item in (json["schemes"] as? [Any]) ?? [] {
            guard let scheme = item as? String, isValidScheme(scheme), schemes.count < maxSchemes else {
                return .failure(.badApp("scheme \(String(describing: item).prefix(40))"))
            }
            if !schemes.contains(scheme) { schemes.append(scheme) }
        }
        var scripts: [String: String] = [:]
        if let raw = json["scripts"] {
            guard let table = raw as? [String: Any], table.count <= maxScripts else { return .failure(.badScript("scripts")) }
            for (name, body) in table {
                guard PluginChoice.isValidKey(name), let text = body as? String, PluginScriptPolicy.allows(text) else {
                    return .failure(.badScript(name))
                }
                scripts[name] = text
            }
        }
        return .success(PluginApp(bundleID: id, schemes: schemes, scripts: scripts))
    }
}

/// App 插件的一条命令：搜索面板里打字命中、回车执行（交给插件的 `command(id)`），菜单栏二级菜单里点一下执行。
struct PluginCommand: Equatable {
    let id: String
    let titles: [String: String]
    /// 搜它用的词（另一种语言的叫法、别名、拼音首字母），最多 20 个、每个最多 30 个字
    let keywords: [String]
    /// 菜单和设置页里那一行的 SF Symbol（实心的那一版）；nil 画通用的
    let symbol: String?

    nonisolated static let maxCommands = 30

    /// id：小写字母开头，小写字母、数字、连字符，1–40 个（和插件 id 拼成 `<插件>.<命令>`，存关键词、搜索记忆用）。
    nonisolated static func isValidID(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    nonisolated static func parse(_ list: [Any]) -> Result<[PluginCommand], PluginManifest.Problem> {
        guard list.count <= maxCommands else { return .failure(.badCommand("more than \(maxCommands)")) }
        var out: [PluginCommand] = []
        for item in list {
            guard let json = item as? [String: Any], let id = json["id"] as? String, isValidID(id),
                  !out.contains(where: { $0.id == id }) else {
                return .failure(.badCommand(String(describing: (item as? [String: Any])?["id"] ?? "?").prefix(40).description))
            }
            guard let titles = PluginChoice.titles(json["title"]) else { return .failure(.badCommand(id)) }
            var keywords: [String] = []
            for case let word as String in (json["keywords"] as? [Any]) ?? [] {
                let trimmed = String(word.trimmingCharacters(in: .whitespaces).prefix(30))
                if !trimmed.isEmpty, !keywords.contains(trimmed), keywords.count < 20 { keywords.append(trimmed) }
            }
            let symbol = (json["symbol"] as? String).flatMap { $0.isEmpty || $0.count > 60 ? nil : $0 }
            out.append(PluginCommand(id: id, titles: titles, keywords: keywords, symbol: symbol))
        }
        return .success(out)
    }
}

/// App 插件的固定脚本能写什么（manifest 解析、`build-index.py`、执行前三处都按它拦）。
///
/// TabFlick 给正文包上 `tell application id "<声明的 App>"` 再交给 osascript，所以正文只该是那个 App 自己的命令和
/// 简单的流程（if / return）。拦的是能跳出这个 App 的写法：换目标（tell、application、me / my、using terms from、
/// 原始事件「«»」）、在本机执行东西（do shell script、run / load / store script）、碰文件和系统（file、path to、
/// read / write、system attribute、open location）。按词拦，字符串里的也算（宁可误拦）。
/// 能跑脚本的插件不许联网（manifest 解析时拦 `hosts`，运行时 `openURL` 也不给）：脚本读到的东西没有出口。
/// 这是白名单之外的第二道：商店只收官方插件、目录有签名和 sha256。
enum PluginScriptPolicy {
    nonisolated static let maxLength = 2000

    nonisolated static let forbiddenWords: Set<String> = [
        "tell", "application", "app", "current", "me", "my", "using", "terms", "from",
        "script", "scripts", "shell", "do", "run", "load", "store", "osascript", "osax",
        "system", "path", "posix", "file", "files", "folder", "folders", "alias", "disk", "volume",
        "read", "write", "access", "open", "location", "event", "events", "considering", "ignoring",
        "keystroke", "key", "click", "delete", "remove", "move", "duplicate", "quit", "clipboard",
        // 弹框：假冒「输入密码」的对话框，把用户打的字交回给插件
        "display", "dialog", "alert", "choose", "answer", "password", "hidden",
    ]

    nonisolated static func allows(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxLength else { return false }
        // 原始事件码、竖线标识符（|tell| 能把关键字当标识符藏起来）、反斜杠转义（字符串里拼出别的东西）
        guard !text.contains(where: { "«»|\\".contains($0) }) else { return false }
        // 只收 ASCII：全角、同形字母能把关键字伪装成别的字（ｔｅｌｌ）
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }
        return !words.contains { forbiddenWords.contains(String($0)) }
    }

    /// 交给 osascript 的完整脚本（一行一个元素，逐行 -e）
    nonisolated static func wrapped(_ body: String, bundleID: String) -> [String] {
        ["tell application id \"\(bundleID)\""] + body.components(separatedBy: .newlines) + ["end tell"]
    }
}

/// 插件设置项的值（UserDefaults `pluginSettings`：插件 id → key → 选的值）。设置页写，运行时读（插件队列上读，
/// UserDefaults 线程安全）。没设过或者设的值已经不在选项里，用 manifest 的默认值。
enum PluginSettingsStore {
    nonisolated static let key = "pluginSettings"

    nonisolated static func value(_ plugin: String, _ choice: PluginChoice) -> String {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]
        if let v = all?[plugin]?[choice.key], choice.options.contains(where: { $0.value == v }) { return v }
        return choice.defaultValue
    }

    /// 用户填的文字，去掉首尾空白（粘贴 Key 常带空格换行）；没填是空串。
    nonisolated static func text(_ plugin: String, _ input: PluginInput) -> String {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]
        let raw = all?[plugin]?[input.key] ?? ""
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PluginInput.maxLength))
    }

    nonisolated static func set(_ plugin: String, _ key: String, _ value: String) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:]
        all[plugin, default: [:]][key] = value
        UserDefaults.standard.set(all, forKey: Self.key)
    }
}

/// 插件联网的放行规则：只放 https，主机必须和 manifest 里声明的某一个完全一样（不分大小写），
/// 或者落在声明的 `*.example.com` 下面（任意深的子域名，不含 example.com 自己），
/// 不能带账号密码、不能指定端口（防止拿白名单里的主机名去连别的服务）。
enum PluginNetPolicy {
    nonisolated static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil else { return false }
        return hosts.contains { declared in
            let pattern = declared.lowercased()
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
            return pattern == host
        }
    }
}
