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
    private lazy var jsMenu: JSPluginMenu? =
        manifest.contributes.contains(.menu) ? JSPluginMenu(runtime: runtime) : nil

    init(manifest: PluginManifest, runtime: JSPluginRuntime) {
        self.manifest = manifest
        self.runtime = runtime
    }

    var id: String { manifest.id }
    var title: String { PluginManifest.pick(manifest.names, language: L10n.current.rawValue) ?? manifest.id }
    var summary: String { PluginManifest.pick(manifest.summaries, language: L10n.current.rawValue) ?? "" }
    var symbol: String {
        NSImage(systemSymbolName: manifest.symbol, accessibilityDescription: nil) == nil ? "puzzlepiece.fill" : manifest.symbol
    }
    var tint: Color { PluginTint.color(manifest.tint) }
    var origin: PluginOrigin { .official(version: manifest.version) }
    var menu: PluginMenu? { jsMenu }

    private func pick(_ table: [String: String]) -> String? {
        PluginManifest.pick(table, language: L10n.current.rawValue)
    }

    /// 搜索面板里进列表的命令：名字后面带「…」（回车不执行、而是进一层，同「结束进程…」「打开方式…」）。
    /// 关键词带上插件各语言的名字：界面是英文时打「股票」也要能找到。
    var listCommand: AppCommand? {
        guard manifest.contributes.contains(.list) else { return nil }
        let name = pick(manifest.listTitles) ?? title
        return AppCommand(id: "plugin." + id, bundleID: nil, title: name + "…",
                          keywords: manifest.listKeywords + Array(manifest.names.values) + Array(manifest.listTitles.values),
                          symbol: symbol, subtitle: L10n.t("插件", "Plugins"), tint: tint, action: .pluginList(id))
    }
    var listPlaceholder: String? { pick(manifest.listPlaceholders) }
    var hasOwnSettings: Bool { !manifest.choices.isEmpty || !manifest.inputs.isEmpty || manifest.usesUpDownColors }
    var usesNetwork: Bool { !manifest.hosts.isEmpty }
    /// 插件页「在搜索面板里」那一段：列表入口命令。
    var panelCommands: [PluginCommandInfo] {
        listCommand.map { [PluginCommandInfo(id: $0.id, title: $0.title, symbol: $0.symbol)] } ?? []
    }
    var listEmptyText: String? { pick(manifest.listEmpty) }

    func list(_ query: String, _ done: @escaping @MainActor ([PluginRow]?) -> Void) {
        let id = self.id
        runtime.call("list", [query]) { value in
            MainActor.assumeIsolated { done((value as? [Any]).map { JSPluginRows.parse($0, pluginID: id) }) }
        }
    }

    func perform(_ action: String, on row: PluginRow, _ done: @escaping @MainActor () -> Void) {
        runtime.call("perform", [action, row.id]) { _ in MainActor.assumeIsolated { done() } }
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
///   `{id, title, badge, subtitle, value, detail, tone, spark: [数字], icon: {text, tint},
///     actions: [{id, title, symbol, destructive, stay}]}`
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
                                               clearsQuery: (a["clear"] as? Bool) == true))
            }
            rows.append(PluginRow(
                pluginID: pluginID, id: id, title: title, badge: text(item["badge"], limit: 12),
                subtitle: text(item["subtitle"]), value: text(item["value"], limit: 20),
                detail: text(item["detail"], limit: 20), tone: tone,
                spark: downsample(((item["spark"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
                    .filter(\.isFinite)),
                iconText: text(icon?["text"], limit: 2), iconTint: icon?["tint"] as? String,
                actions: actions))
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
                    openSettings: { [id = manifest.id] in MainActor.assumeIsolated { PluginMenuHost.openSettings?(id) } }))
            out.append(JSPlugin(manifest: manifest, runtime: runtime))
            log("🧩 found plugin \(manifest.id) v\(manifest.version)")
        }
        return out
    }
}
