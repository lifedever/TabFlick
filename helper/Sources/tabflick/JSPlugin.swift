import AppKit
import SwiftUI

// 从商店装的 JS 插件接到 `Plugin` 协议上（运行时见 JSPluginRuntime.swift，manifest 见 PluginManifest.swift）。
//
// 装在 ~/Library/Application Support/TabFlick/Plugins/<id>/（manifest.json + 入口脚本），插件自己存的数据在
// PluginData/<id>.json —— 和代码分开放，更新插件（整个目录换掉）不丢数据。开发时把仓库里的 plugins/<id>
// 软链接过去就行（见 CLAUDE.md「插件」）。

enum PluginPaths {
    nonisolated static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
    }
    nonisolated static var installed: URL { root.appendingPathComponent("Plugins", isDirectory: true) }
    nonisolated static func dataFile(_ id: String) -> URL {
        root.appendingPathComponent("PluginData", isDirectory: true).appendingPathComponent(id + ".json")
    }
}

@MainActor
final class JSPlugin: Plugin {
    let manifest: PluginManifest
    let runtime: JSPluginRuntime
    /// 菜单：App 插件有命令的，菜单就是这些命令（原生现画，不调 `menu()`）；别的调插件的 `menu()`
    private lazy var pluginMenu: PluginMenu? = {
        guard manifest.contributes.contains(.menu) else { return nil }
        if manifest.app != nil, !manifest.commands.isEmpty { return PluginCommandMenu(plugin: self) }
        return JSPluginMenu(runtime: runtime)
    }()

    /// manifest 里的图标。App 插件在 App 装着时画 App 自己的图标（`icon`）
    private let manifestIcon: NSImage?
    private var appIcon: NSImage?

    init(manifest: PluginManifest, runtime: JSPluginRuntime, icon: NSImage? = nil) {
        self.manifest = manifest
        self.runtime = runtime
        self.manifestIcon = icon
    }

    var icon: NSImage? {
        guard let app = manifest.app else { return manifestIcon }
        if appIcon == nil, let url = PluginAppSupport.appURL(app.bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        return appIcon ?? manifestIcon
    }

    var id: String { manifest.id }
    var title: String { PluginManifest.pick(manifest.names, language: L10n.current.rawValue) ?? manifest.id }
    var summary: String { PluginManifest.pick(manifest.summaries, language: L10n.current.rawValue) ?? "" }
    var symbol: String {
        NSImage(systemSymbolName: manifest.symbol, accessibilityDescription: nil) == nil ? "puzzlepiece.fill" : manifest.symbol
    }
    var tint: Color { PluginTint.color(manifest.tint) }
    var origin: PluginOrigin { .official(version: manifest.version) }
    var menu: PluginMenu? { pluginMenu }

    private func pick(_ table: [String: String]) -> String? {
        PluginManifest.pick(table, language: L10n.current.rawValue)
    }

    /// 搜索面板里进列表的命令：名字后面带「…」（回车不执行、而是进一层，同「结束进程…」「打开方式…」）。
    /// 关键词带上插件各语言的名字：界面是英文时打「股票」也要能找到。副标题给空串：标题就是插件名，
    /// 分组头又写着「插件」，原来写的「插件」两个字是重复（用户 2026-11-23）。
    var listCommand: AppCommand? {
        guard manifest.contributes.contains(.list) else { return nil }
        let name = pick(manifest.listTitles) ?? title
        return AppCommand(id: "plugin." + id, bundleID: nil, title: name + "…",
                          keywords: manifest.listKeywords + Array(manifest.names.values) + Array(manifest.listTitles.values),
                          symbol: symbol, subtitle: "", tint: tint, icon: icon, action: .pluginList(id))
    }
    var listPlaceholder: String? { pick(manifest.listPlaceholders) }
    var hasOwnSettings: Bool { !manifest.choices.isEmpty || !manifest.inputs.isEmpty || manifest.usesUpDownColors }
    var usesNetwork: Bool { !manifest.hosts.isEmpty }
    /// 插件页「在搜索面板里」那一段：列表入口命令，加 App 插件的命令（每条都能设关键词）。
    var panelCommands: [PluginCommandInfo] {
        (listCommand.map { [PluginCommandInfo(id: $0.id, title: $0.title, symbol: $0.symbol)] } ?? [])
            + manifest.commands.map { PluginCommandInfo(id: commandID($0), title: commandTitle($0), symbol: commandSymbol($0)) }
    }

    // MARK: App 插件的命令

    /// 存关键词、搜索记忆按它：`<插件>.<命令>`（amphetamine.start，和挪到商店之前的内置命令同一个 id，用户设的关键词还在）
    func commandID(_ command: PluginCommand) -> String { id + "." + command.id }
    func commandTitle(_ command: PluginCommand) -> String { pick(command.titles) ?? command.id }
    func commandSymbol(_ command: PluginCommand) -> String {
        command.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "command"
    }

    /// 搜索面板的命令：挂在声明的 App 下面（App 没装时面板不列，App 的 ⌘↩ 里也有），回车交给插件的 `command(id)`。
    /// 关键词带上命令各语言的名字：界面是中文时打「capture」也要能找到。
    func commands(_ context: PluginContext) -> [AppCommand] {
        guard let app = manifest.app else { return [] }
        return manifest.commands.map { command in
            AppCommand(id: commandID(command), bundleID: app.bundleID, title: commandTitle(command),
                       keywords: command.keywords + Array(command.titles.values), symbol: commandSymbol(command),
                       action: .native { [weak self] in self?.runCommand(command.id) })
        }
    }

    func runCommand(_ commandID: String) {
        log("🧩 [\(id)] command \(commandID)")
        runtime.call("command", [commandID]) { _ in }
    }
    var listEmptyText: String? { pick(manifest.listEmpty) }

    func list(_ query: String, scope: String?, _ done: @escaping @MainActor ([PluginRow]?) -> Void) {
        let id = self.id
        // 首页不传第二个参数（插件那边是 undefined），老插件只认一个参数也照样能用
        runtime.call("list", scope.map { [query, $0] } ?? [query]) { value in
            MainActor.assumeIsolated { done((value as? [Any]).map { JSPluginRows.parse($0, pluginID: id) }) }
        }
    }

    func perform(_ action: String, on row: PluginRow, scope: String?, _ done: @escaping @MainActor () -> Void) {
        runtime.call("perform", [action, row.id] + (scope.map { [$0] } ?? [])) { _ in MainActor.assumeIsolated { done() } }
    }

    /// 设置页的「测试」：用填好的设置真去试一次（天气：拿 API Host + Key 搜一次城市）。
    /// 插件没注册 `test`、抛错、回的不是 `{ok, title, detail}` 都回 nil。
    func runTest(_ done: @escaping @MainActor (PluginTestResult?) -> Void) {
        runtime.call("test") { value in
            MainActor.assumeIsolated { done(PluginTestResult(value)) }
        }
    }
}

/// 插件 `test()` 回的结果。外部输入：标题必须有，文字截短。
struct PluginTestResult: Equatable {
    let ok: Bool
    let title: String
    let detail: String?

    init(ok: Bool, title: String, detail: String?) {
        self.ok = ok
        self.title = title
        self.detail = detail
    }

    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let ok = object["ok"] as? Bool,
              let title = object["title"] as? String, !title.isEmpty else { return nil }
        self.ok = ok
        self.title = String(title.prefix(120))
        self.detail = (object["detail"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
    }
}

/// 插件 `list()` 回的数组 → 列表行。外部输入：每个字段都可能缺、类型都可能错，认不出的丢掉。
///   `{id, title, badge, subtitle, value, detail, tone, spark: [数字], icon: {text, tint}, clock: "时区",
///     actions: [{id, title, symbol, destructive, stay, clear, enter, placeholder, empty}]}`
enum JSPluginRows {
    static let maxRows = 60
    static let maxText = 120

    @MainActor static func parse(_ items: [Any], pluginID: String) -> [PluginRow] {
        func text(_ value: Any?, limit: Int = maxText) -> String? {
            let raw: String?
            switch value {
            case let string as String: raw = string
            case let number as NSNumber: raw = number.stringValue
            default: raw = nil
            }
            guard let raw, !raw.isEmpty else { return nil }
            return raw.count > limit ? String(raw.prefix(limit - 1)) + "…" : raw
        }
        var seen = Set<String>()
        var rows: [PluginRow] = []
        for case let item as [String: Any] in items.prefix(maxRows) {
            guard let id = text(item["id"], limit: 200), let title = text(item["title"]), !seen.contains(id) else { continue }
            seen.insert(id)
            let tone: PluginMenuTone
            switch item["tone"] as? String {
            case "up": tone = .up
            case "down": tone = .down
            case "plain": tone = .plain
            default: tone = .secondary
            }
            let icon = item["icon"] as? [String: Any]
            var actions: [PluginRowAction] = []
            for case let a as [String: Any] in ((item["actions"] as? [Any]) ?? []).prefix(10) {
                guard let actionID = text(a["id"], limit: 60), let actionTitle = text(a["title"], limit: 60) else { continue }
                let symbol = (a["symbol"] as? String).flatMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 }
                actions.append(PluginRowAction(id: actionID, title: actionTitle, symbol: symbol,
                                               destructive: (a["destructive"] as? Bool) == true,
                                               stays: (a["stay"] as? Bool) == true,
                                               clearsQuery: (a["clear"] as? Bool) == true,
                                               enters: (a["enter"] as? Bool) == true,
                                               enterPlaceholder: text(a["placeholder"], limit: 80),
                                               enterEmpty: text(a["empty"])))
            }
            rows.append(PluginRow(
                pluginID: pluginID, id: id, title: title, badge: text(item["badge"], limit: 12),
                subtitle: text(item["subtitle"]), value: text(item["value"], limit: 20),
                detail: text(item["detail"], limit: 20), tone: tone,
                spark: downsample(((item["spark"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
                    .filter(\.isFinite)),
                iconText: text(icon?["text"], limit: 2), iconTint: icon?["tint"] as? String,
                actions: actions,
                // IANA 时区名（Asia/Tokyo）；认不出的当没写，退回 value
                clock: (item["clock"] as? String).flatMap { $0.count <= 64 ? TimeZone(identifier: $0) : nil }))
        }
        return rows
    }

    /// 走势线最多画 `PluginRow.maxSpark` 个点（分时一天 242 个点，画在 56pt 宽里没有区别）。
    static func downsample(_ points: [Double]) -> [Double] {
        let limit = PluginRow.maxSpark
        guard points.count > limit else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }
}

/// JS 插件的状态栏二级菜单：调插件的 `menu()`，把它回的数组翻成菜单行。
///
/// 插件回的每一项（外部输入，字段都可能缺、类型都可能错）：
///   `{type: "header", text}` / `{type: "note", text}` / `{type: "separator"}` /
///   `{title, badge, value, detail, tone: "up"|"down"|"secondary"|"plain", symbol, action}`
/// `action` 是一个字符串，点了就调插件的 `action(那个字符串)`。
@MainActor
final class JSPluginMenu: PluginMenu {
    private let runtime: JSPluginRuntime
    private(set) var snapshot: [PluginMenuRow]?

    /// 一个菜单最多画这么多行、每段文字最多这么长（插件回了一大堆也不会把菜单撑出屏幕）。
    static let maxRows = 40
    static let maxText = 80

    init(runtime: JSPluginRuntime) { self.runtime = runtime }

    func refresh(_ done: @escaping @MainActor ([PluginMenuRow]) -> Void) {
        let runtime = self.runtime
        runtime.call("menu") { [weak self] value in
            MainActor.assumeIsolated {
                // 出错（nil、不是数组）就不回调：菜单留着上次的快照，到时间写「数据未更新」
                guard let self, let items = value as? [Any] else { return }
                let rows = Self.rows(items) { id in runtime.call("action", [id]) { _ in } }
                self.snapshot = rows
                done(rows)
            }
        }
    }

    static func rows(_ items: [Any], action run: @escaping @MainActor (String) -> Void) -> [PluginMenuRow] {
        func text(_ value: Any?) -> String? {
            let raw: String?
            switch value {
            case let string as String: raw = string
            case let number as NSNumber: raw = number.stringValue
            default: raw = nil
            }
            guard let raw, !raw.isEmpty else { return nil }
            return raw.count > maxText ? String(raw.prefix(maxText - 1)) + "…" : raw
        }
        var rows: [PluginMenuRow] = []
        for case let item as [String: Any] in items.prefix(maxRows) {
            switch item["type"] as? String {
            case "header": if let t = text(item["text"]) { rows.append(.header(t)) }
            case "note": if let t = text(item["text"]) { rows.append(.note(t)) }
            case "separator": rows.append(.separator)
            default:
                guard let title = text(item["title"]) else { continue }
                let tone: PluginMenuTone
                switch item["tone"] as? String {
                case "up": tone = .up
                case "down": tone = .down
                case "plain": tone = .plain
                default: tone = .secondary
                }
                let actionID = item["action"] as? String
                rows.append(.item(PluginMenuItem(
                    title: title, badge: text(item["badge"]), value: text(item["value"]),
                    detail: text(item["detail"]), detailTone: tone,
                    symbol: (item["symbol"] as? String).flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 },
                    action: actionID.map { id in { run(id) } })))
            }
        }
        return rows
    }
}

/// App 插件的状态栏二级菜单：就是它的命令，点一下执行（同搜索面板里回车）。原生现画，不调插件、不用等。
@MainActor
final class PluginCommandMenu: PluginMenu {
    private weak var plugin: JSPlugin?

    init(plugin: JSPlugin) { self.plugin = plugin }

    var snapshot: [PluginMenuRow]? { rows() }

    func refresh(_ done: @escaping @MainActor ([PluginMenuRow]) -> Void) { done(rows()) }

    private func rows() -> [PluginMenuRow] {
        guard let plugin, let app = plugin.manifest.app else { return [] }
        guard PluginAppSupport.appURL(app.bundleID) != nil else {
            return [.note(L10n.t("没有安装 \(plugin.title)", "\(plugin.title) isn't installed"))]
        }
        return plugin.manifest.commands.map { command in
            .item(PluginMenuItem(title: plugin.commandTitle(command), symbol: plugin.commandSymbol(command),
                                 action: { [weak plugin] in plugin?.runCommand(command.id) }))
        }
    }
}

/// App 插件碰 App 的那几样：找到装着的那份、核对网址是它自己登记的、交给它打开、没授权时指路。
@MainActor
enum PluginAppSupport {
    /// 装着的那份。同一个 bundle id 装了几份时（「下载」里留着旧副本）优先 /Applications、~/Applications 里的。
    /// 记 30 秒：设置页、商店、菜单每画一次都要问，App 没装时每次都是一趟 Launch Services
    static func appURL(_ bundleID: String) -> URL? {
        if let cached = lookups[bundleID], Date().timeIntervalSince(cached.at) < 30 { return cached.url }
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = ["/Applications/", home + "/Applications/"]
        let url = all.first { url in preferred.contains { url.path.hasPrefix($0) } } ?? all.first
        lookups[bundleID] = (url, Date())
        return url
    }
    private static var lookups: [String: (url: URL?, at: Date)] = [:]

    /// App 自己在 Info.plist 里登记的网址 scheme（小写）。直接读文件：`Bundle(url:)` 按路径缓存，App 更新后读到旧的
    static func registeredSchemes(_ appURL: URL) -> Set<String> {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() })
    }

    /// 把网址交给那个 App。scheme 不是它自己登记的不开（manifest 声明了别人家的 scheme，等于借它的名义开别的 App）。
    /// 成功不弹 toast（截图框、窗口自己会出来），失败才说。
    static func open(_ url: URL, in bundleID: String, activate: Bool) {
        let name = appName(bundleID)
        guard let appURL = appURL(bundleID) else {
            Toast.show(L10n.t("没能执行「\(name)」", "Couldn't run “\(name)”"),
                       detail: L10n.t("没有安装 \(name)", "\(name) isn't installed"), kind: .failure)
            return
        }
        guard let scheme = url.scheme?.lowercased(), registeredSchemes(appURL).contains(scheme) else {
            // 插件和 App 对不上（App 改了 scheme、或者插件写错了）：照实说没做成，不悄悄没反应
            log("🧩 app.open refused: \(url.scheme ?? "?") isn't registered by \(bundleID)")
            Toast.show(L10n.t("没能执行「\(name)」", "Couldn't run “\(name)”"), kind: .failure)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            log("🧩 app.open \(url.scheme ?? "?") in \(bundleID) failed: \(error.localizedDescription)")
            Task { @MainActor in
                Toast.show(L10n.t("没能执行「\(name)」", "Couldn't run “\(name)”"),
                           detail: error.localizedDescription, kind: .failure)
            }
        }
    }

    static func reportScriptDenied(_ bundleID: String) {
        let name = appName(bundleID)
        Toast.show(L10n.t("没能执行「\(name)」", "Couldn't run “\(name)”"),
                   detail: L10n.t("系统设置 → 隐私与安全性 → 自动化里允许 TabFlick 控制「\(name)」。",
                                  "Allow TabFlick to control \(name) in System Settings → Privacy & Security → Automation."),
                   kind: .failure)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = appURL(bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

extension PluginRegistry {
    /// app 里用的这一份：内置插件在前，装了的 JS 插件按 id 排在后面。
    static let shared: PluginRegistry = {
        let builtins = BuiltinPlugins.all()
        let installed = JSPluginLoader.installed(reserved: Set(builtins.map(\.id)))
        return PluginRegistry(defaults: .standard, plugins: builtins + installed)
    }()
}

extension PluginRegistry {
    /// 商店装、更新、卸载之后：内置的不动，JS 插件重新扫一遍（新的实例，旧的跑完手上的调用就释放）。
    func reloadInstalled() {
        let builtins = plugins.filter { $0.origin == .builtin }
        replace(builtins + JSPluginLoader.installed(reserved: Set(builtins.map(\.id))))
    }
}

enum JSPluginLoader {
    /// 扫插件目录，把能用的插件建出来（运行时用到时才真正跑脚本）。坏的跳过、写日志：
    /// manifest 解析不过、目录名和 id 对不上、和内置插件撞 id、要求的 app 版本比现在的新。
    @MainActor static func installed(reserved: Set<String>) -> [JSPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: PluginPaths.installed, includingPropertiesForKeys: nil) else {
            return []
        }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        var out: [JSPlugin] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = dir.lastPathComponent
            guard !name.hasPrefix("."),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { continue }
            let manifest: PluginManifest
            switch PluginManifest.parse(data) {
            case .success(let parsed): manifest = parsed
            case .failure(let problem):
                log("🧩 skip plugin \(name): \(problem)")
                continue
            }
            guard manifest.id == name else { log("🧩 skip plugin \(name): id is \(manifest.id)"); continue }
            guard !reserved.contains(manifest.id), !out.contains(where: { $0.id == manifest.id }) else {
                log("🧩 skip plugin \(name): id taken"); continue
            }
            // 开发版（swift run）没有版本号，不拦
            if let need = manifest.minAppVersion, let appVersion, ExtensionFolder.isNewer(need, than: appVersion) {
                log("🧩 skip plugin \(name): needs TabFlick \(need), this is \(appVersion)")
                continue
            }
            let runtime = JSPluginRuntime(
                manifest: manifest, directory: dir, storageFile: PluginPaths.dataFile(manifest.id),
                language: L10n.current.rawValue,
                bridge: .init(
                    toast: { text, detail in Toast.show(text, detail: detail, kind: .info) },
                    copy: { text in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    },
                    openURL: { url in NSWorkspace.shared.open(url) },
                    openSettings: { [id = manifest.id] in MainActor.assumeIsolated { PluginMenuHost.openSettings?(id) } },
                    openAppURL: { [app = manifest.app] url, activate in
                        guard let app else { return }
                        MainActor.assumeIsolated { PluginAppSupport.open(url, in: app.bundleID, activate: activate) }
                    },
                    scriptDenied: { [app = manifest.app] in
                        guard let app else { return }
                        MainActor.assumeIsolated { PluginAppSupport.reportScriptDenied(app.bundleID) }
                    }))
            // 图标读不出来不影响插件本身，退回符号、写一行日志
            let icon = manifest.icon.flatMap { path -> NSImage? in
                let image = PluginIconLoader.load(dir.appendingPathComponent(path))
                if image == nil { log("🧩 plugin \(name): icon \(path) unreadable, using symbol") }
                return image
            }
            out.append(JSPlugin(manifest: manifest, runtime: runtime, icon: icon))
            log("🧩 found plugin \(manifest.id) v\(manifest.version)")
        }
        return out
    }
}
