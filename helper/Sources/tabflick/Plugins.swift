import AppKit
import SwiftUI

// 插件这一层（2026-11-06 插件化，见 CLAUDE.md「插件」）。
//
// 分工：原生只管画和交互，插件只管数据。插件把「要显示什么」描述出来（搜索面板的命令和行、状态栏
// 二级菜单的行），原生按统一的样子画；插件碰不到 NSMenu / 面板，原生也不知道插件里装的是什么。
// 内置插件用 Swift 直接实现这份协议（`BuiltinPlugins.swift`）；以后从商店装的 JS 插件由宿主包一层
// 实现同一份协议。

enum PluginOrigin: Equatable {
    /// 跟着 app 发版，不能卸载，只能关
    case builtin
    /// 从商店装的官方插件
    case official(version: String)
}

/// 调插件时给它的现场。
struct PluginContext {
    /// 打开搜索面板那一刻的前台 App：窗口命令动它的窗口，计算结果能粘贴给它。
    var windowTarget: WindowTarget? = nil
}

@MainActor
protocol Plugin: AnyObject {
    /// 固定标识：存启用状态、菜单开关都按它。改了等于换了一个插件。
    var id: String { get }
    var title: String { get }
    /// 插件页、总览页上那一句说明。
    var summary: String { get }
    /// 侧边栏图标块里的白色符号（实心的那一版）和底色。
    var symbol: String { get }
    var tint: Color { get }
    var origin: PluginOrigin { get }
    /// 插件页「在搜索面板里」那一段列的命令（每条能设关键词）。空 = 不列这一段。
    var panelCommands: [PluginCommandInfo] { get }

    /// 搜索面板的命令（和原来的内置命令一样排进「应用」段、App 的 ⌘↩）。
    func commands(_ context: PluginContext) -> [AppCommand]
    /// 整条输入直接给出的结果，顶在「全部」最前面（计算器）。
    func instantRows(_ query: String, _ context: PluginContext) -> [SearchRow]
    /// 状态栏二级菜单；nil = 这个插件不往菜单里放东西。
    var menu: PluginMenu? { get }

    /// 搜索面板里进入这个插件列表的命令（打「股票」命中，回车列表换成插件给的行，同「结束进程…」）。nil = 没有列表。
    var listCommand: AppCommand? { get }
    /// 列表的内容：query 空 = 默认内容（股票的自选），有字 = 搜。回调 nil = 出错（面板留着原来的行）。
    func list(_ query: String, _ done: @escaping @MainActor ([PluginRow]?) -> Void)
    /// 对列表里一行执行一个动作，做完回调（面板据此决定刷不刷新列表）。
    func perform(_ action: String, on row: PluginRow, _ done: @escaping @MainActor () -> Void)
    /// 列表里输入框的占位、没内容时那句话（nil 用通用的）。
    var listPlaceholder: String? { get }
    var listEmptyText: String? { get }
    /// 插件自己声明的设置项（JS 插件 manifest 里的 choices、涨跌颜色）
    var hasOwnSettings: Bool { get }
    /// 列表要不要联网取（搜索面板据此决定打字时合并多久、要不要一打字就转圈）
    var usesNetwork: Bool { get }
}

extension Plugin {
    var panelCommands: [PluginCommandInfo] { [] }
    func commands(_ context: PluginContext) -> [AppCommand] { [] }
    func instantRows(_ query: String, _ context: PluginContext) -> [SearchRow] { [] }
    var menu: PluginMenu? { nil }
    var listCommand: AppCommand? { nil }
    func list(_ query: String, _ done: @escaping @MainActor ([PluginRow]?) -> Void) { done(nil) }
    func perform(_ action: String, on row: PluginRow, _ done: @escaping @MainActor () -> Void) { done() }
    var listPlaceholder: String? { nil }
    var listEmptyText: String? { nil }
    var hasOwnSettings: Bool { false }
    var usesNetwork: Bool { false }
}

/// manifest 里的颜色名 → 图标块底色。认不出的当灰色。
/// 行图标也认 `#RGB` / `#RRGGBB`（开发工具箱的颜色转换拿它画色块），透明度不看。
enum PluginTint {
    static func color(_ name: String) -> Color {
        if name.hasPrefix("#"), let rgb = hexRGB(String(name.dropFirst())) {
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return .gray
        }
    }

    private static func hexRGB(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }
}

/// 插件页里列的一条命令（设关键词用）：命令 id、名字、图标。
struct PluginCommandInfo: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

extension Plugin {
    /// 有没有东西可设（命令关键词、菜单栏、JS 插件的涨跌颜色）。没有的（计算器）不在侧边栏占一行，
    /// 开关只在「插件」总览页（用户 2026-11-06：只有一个和总览重复的「启用」，没意义）。
    var hasSettingsPage: Bool { !panelCommands.isEmpty || menu != nil || hasOwnSettings }
}

// MARK: - 列表行

/// 插件列表里的一行（股票的一只）。插件给描述，面板按统一的样子画：行首文字图标块，标题 + 小标签，
/// 副标题；行尾迷你走势线、数值、涨跌胶囊。
struct PluginRow: Equatable {
    let pluginID: String
    let id: String
    let title: String
    var badge: String? = nil
    var subtitle: String? = nil
    var value: String? = nil
    var detail: String? = nil
    var tone: PluginMenuTone = .secondary
    /// 走势线的点（已经抽稀过，最多 `PluginRow.maxSpark` 个）
    var spark: [Double] = []
    /// 行首图标块：一两个字（沪 / 港 / 美）+ 底色名（`PluginTint`）
    var iconText: String? = nil
    var iconTint: String? = nil
    /// 第一个是回车做的事；⌘↩ 列出全部
    var actions: [PluginRowAction] = []

    static let maxSpark = 64
}

struct PluginRowAction: Equatable {
    let id: String
    let title: String
    var symbol: String? = nil
    /// 标红垫底（移出自选这类）
    var destructive = false
    /// 做完面板不关、列表刷新（加入 / 移出自选）；否则先关面板再做（打开网页）
    var stays = false
    /// 做完清空输入、回到列表首页，游标落在这一行（搜到了加进自选之后回到自选，用户 2026-11-06 要的）
    var clearsQuery = false
}

/// 涨跌用什么颜色：A 股习惯红涨绿跌（默认），美股习惯反过来。插件页里改（`PluginPane`），菜单、面板共用。
enum PluginColors {
    static let key = "pluginUpIsRed"
    static var upIsRed: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func nsColor(_ tone: PluginMenuTone) -> NSColor {
        switch tone {
        case .plain: return .labelColor
        case .secondary: return .secondaryLabelColor
        case .up: return upIsRed ? .systemRed : .systemGreen
        case .down: return upIsRed ? .systemGreen : .systemRed
        }
    }
}

// MARK: - 菜单

/// 菜单行右边那一栏的颜色。涨跌的红绿由原生按设置定，插件只说是涨还是跌。
enum PluginMenuTone {
    case plain, secondary, up, down
}

/// 二级菜单里能点的一行：标题（后面可带灰色小字），右边一个数，再右边一栏。
struct PluginMenuItem {
    var title: String
    /// 标题后面的灰色小字（港 / 美 / :8086）
    var badge: String? = nil
    /// 右边的数（价格、CPU）
    var value: String? = nil
    /// 最右一栏（涨跌幅、内存）
    var detail: String? = nil
    var detailTone: PluginMenuTone = .secondary
    /// 行首图标：给 NSImage（App 图标）或 SF Symbol 名，二选一
    var image: NSImage? = nil
    var symbol: String? = nil
    var action: (@MainActor () -> Void)? = nil
}

enum PluginMenuRow {
    case header(String)
    case item(PluginMenuItem)
    /// 灰色一行字（更新时间、开盘前）
    case note(String)
    case separator
}

/// 插件交给状态栏的二级菜单内容。
///
/// 菜单是同步弹出的，插件取数可能要等：打开菜单时原生先画 `snapshot`（上一次的结果），同时调
/// `refresh`，新数据回来原地换掉；2 秒没回来就留着快照、底下写「数据未更新」（`PluginMenuHost`）。
@MainActor
protocol PluginMenu: AnyObject {
    /// 上一次的结果；nil = 还没取过。
    var snapshot: [PluginMenuRow]? { get }
    /// 现取一份，取到了在主线程回调（同时更新 snapshot）。
    func refresh(_ done: @escaping @MainActor ([PluginMenuRow]) -> Void)
}

// MARK: - 注册表

/// 装了哪些插件、哪些开着、哪些放进状态栏菜单。设置页、搜索面板、状态栏都读这一份。
@MainActor
final class PluginRegistry: ObservableObject {
    // `shared`（内置 + 装了的 JS 插件）在 JSPlugin.swift：官网样例程序编这个文件、不编 JS 插件那几个

    private enum Key {
        static let disabled = "disabledPlugins"
        static let inMenu = "pluginsInMenu"
    }

    /// 装着的插件：内置的在前，JS 插件按 id 排在后面。商店装、更新、卸载后整份换（`reloadInstalled`）。
    @Published private(set) var plugins: [Plugin]
    /// 关掉的插件。默认全开，所以存的是关掉的那些（以后新加的插件装上就是开的）。
    @Published private(set) var disabled: Set<String>
    /// 放进状态栏菜单的插件，按菜单里的先后（设置 → 插件 →「菜单栏里的顺序」，用户 2026-11-06 要能调）。
    /// 默认一个都不放（菜单要克制）；新放进去的接在末尾。老版本存的是按字母排的同一个键，直接接着用。
    @Published private(set) var menuOrder: [String]
    /// nil = 不存盘（官网样例程序、校验程序用，别读写本机真实的设置）。
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?, plugins: [Plugin]? = nil) {
        self.defaults = defaults
        self.plugins = plugins ?? BuiltinPlugins.all()
        disabled = Set(defaults?.stringArray(forKey: Key.disabled) ?? [])
        var seen = Set<String>()
        menuOrder = (defaults?.stringArray(forKey: Key.inMenu) ?? []).filter { seen.insert($0).inserted }
    }

    func plugin(_ id: String) -> Plugin? { plugins.first { $0.id == id } }

    func replace(_ plugins: [Plugin]) { self.plugins = plugins }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        guard on == disabled.contains(id) else { return }
        if on { disabled.remove(id) } else { disabled.insert(id) }
        defaults?.set(disabled.sorted(), forKey: Key.disabled)
        log("🧩 plugin \(id) → \(on ? "on" : "off")")
    }

    /// 设置里「在菜单栏显示」的开关值（不看插件开没开：关掉插件再打开，菜单开关还在）。
    func wantsMenu(_ id: String) -> Bool { menuOrder.contains(id) }

    func setWantsMenu(_ id: String, _ on: Bool) {
        guard on != menuOrder.contains(id) else { return }
        if on { menuOrder.append(id) } else { menuOrder.removeAll { $0 == id } }
        defaults?.set(menuOrder, forKey: Key.inMenu)
    }

    /// 在菜单里往前（-1）/ 往后（+1）挪一位。只在此刻出现在菜单里的那几个之间挪
    /// （关掉的、卸掉的还留在记录里，跳过它们，不然点一下看上去没动）。
    func moveInMenu(_ id: String, by offset: Int) {
        let visible = menuPlugins.map(\.id)
        guard let from = visible.firstIndex(of: id), visible.indices.contains(from + offset),
              let a = menuOrder.firstIndex(of: id), let b = menuOrder.firstIndex(of: visible[from + offset]) else { return }
        menuOrder.swapAt(a, b)
        defaults?.set(menuOrder, forKey: Key.inMenu)
    }

    var enabled: [Plugin] { plugins.filter { isEnabled($0.id) } }

    /// 此刻要出现在状态栏菜单里的插件（开着、有菜单、设置里打开了），按 `menuOrder` 排。
    var menuPlugins: [Plugin] {
        menuOrder.compactMap { id in plugins.first { $0.id == id && $0.menu != nil && isEnabled(id) } }
    }

    func commands(_ context: PluginContext) -> [AppCommand] {
        enabled.flatMap { $0.commands(context) + ($0.listCommand.map { [$0] } ?? []) }
    }

    func instantRows(_ query: String, _ context: PluginContext) -> [SearchRow] {
        enabled.flatMap { $0.instantRows(query, context) }
    }
}

// MARK: - 菜单的画法

/// 把插件给的行画成 NSMenuItem，并管「先画快照、再等新数据、超时留快照」。状态栏每个插件一份。
@MainActor
final class PluginMenuHost: NSObject {
    let plugin: Plugin
    private let source: PluginMenu
    private weak var submenu: NSMenu?
    /// 每次刷新加一：过期的回包丢掉。
    private var generation = 0

    static let timeout: TimeInterval = 2

    init?(plugin: Plugin) {
        guard let source = plugin.menu else { return nil }
        self.plugin = plugin
        self.source = source
    }

    /// 有列表的插件，子菜单最后自动带一行「在快捷搜索里打开」，点了进它的列表（main.swift 接）。
    static var openList: ((String) -> Void)?
    /// 打开设置里某个插件的那一页（JS 插件 `tabflick.openSettings()`，main.swift 接）。
    static var openSettings: ((String) -> Void)?

    /// 状态栏菜单里插件那一行（子菜单先填快照，同时去取新的）。
    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: plugin.title, action: nil, keyEquivalent: "")
        item.icon = NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        submenu = menu
        // 子菜单不能是空的：空子菜单的父项会被判成禁用，展不开（同浏览器行那条）
        render(source.snapshot ?? [.note(L10n.t("正在读取…", "Loading…"))], stale: false)
        item.submenu = menu
        item.isEnabled = true
        refresh()
        return item
    }

    private func refresh() {
        generation += 1
        let current = generation
        source.refresh { [weak self] rows in
            guard let self, current == self.generation else { return }
            self.answered = current
            self.render(rows, stale: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation, self.answered != current else { return }
                self.render(self.source.snapshot ?? [], stale: true)
            }
        }
    }
    /// 最近一次回了数据的是第几轮（超时检查看它）。
    private var answered = 0

    /// 整个子菜单按行重画（菜单开着也能改，改完马上显示）。
    private func render(_ rows: [PluginMenuRow], stale: Bool) {
        guard let menu = submenu else { return }
        menu.removeAllItems()
        let columns = Self.columns(for: rows)
        for row in rows {
            switch row {
            case .header(let text):
                menu.addItem(.sectionHeader(title: text))
            case .note(let text):
                menu.addItem(Self.noteItem(text))
            case .separator:
                menu.addItem(.separator())
            case .item(let entry):
                menu.addItem(makeItem(entry, columns: columns))
            }
        }
        if stale {
            menu.addItem(Self.noteItem(L10n.t("数据未更新", "Not updated")))
        }
        if plugin.listCommand != nil, let open = Self.openList {
            if !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }
            let id = plugin.id
            menu.addItem(makeItem(PluginMenuItem(title: L10n.t("在快捷搜索里打开", "Open in Quick Search"),
                                                 symbol: "magnifyingglass", action: { open(id) }),
                                  columns: columns))
        }
    }

    private static func noteItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 右边两栏的位置：按这一批里最宽的标题、数值、最右栏算，让数字竖着对齐。
    private struct Columns {
        var value: CGFloat
        var detail: CGFloat
    }

    private static var font: NSFont { NSFont.menuFont(ofSize: 0) }
    private static var digitFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) }
    private static var badgeFont: NSFont { NSFont.systemFont(ofSize: font.pointSize - 2) }

    private static func columns(for rows: [PluginMenuRow]) -> Columns {
        func width(_ text: String?, _ font: NSFont) -> CGFloat {
            guard let text, !text.isEmpty else { return 0 }
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        var title: CGFloat = 0, value: CGFloat = 0, detail: CGFloat = 0
        for case .item(let entry) in rows {
            let badge = entry.badge.map { width(" " + $0, badgeFont) } ?? 0
            title = max(title, width(entry.title, font) + badge)
            value = max(value, width(entry.value, digitFont))
            detail = max(detail, width(entry.detail, digitFont))
        }
        let valueStop = title + 28 + value
        return Columns(value: valueStop, detail: valueStop + (detail > 0 ? 16 + detail : 0))
    }

    private func makeItem(_ entry: PluginMenuItem, columns: Columns) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: columns.value),
                          NSTextTab(textAlignment: .right, location: columns.detail)]
        let text = NSMutableAttributedString(string: entry.title,
                                             attributes: [.font: Self.font, .paragraphStyle: style])
        if let badge = entry.badge {
            text.append(NSAttributedString(string: " " + badge, attributes: [
                .font: Self.badgeFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        }
        if entry.value != nil || entry.detail != nil {
            text.append(NSAttributedString(string: "\t" + (entry.value ?? ""), attributes: [
                .font: Self.digitFont, .paragraphStyle: style]))
        }
        if let detail = entry.detail {
            text.append(NSAttributedString(string: "\t" + detail, attributes: [
                .font: Self.digitFont, .foregroundColor: Self.color(entry.detailTone), .paragraphStyle: style]))
        }
        item.attributedTitle = text
        if let image = entry.image {
            item.icon = image
        } else if let symbol = entry.symbol {
            item.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let action = entry.action {
            item.target = self
            item.action = #selector(runAction(_:))
            item.representedObject = PluginMenuAction(action)
            item.isEnabled = true
        } else {
            item.isEnabled = false
        }
        return item
    }

    private static func color(_ tone: PluginMenuTone) -> NSColor { PluginColors.nsColor(tone) }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? PluginMenuAction)?.run()
    }
}

/// 菜单项的 representedObject 装闭包用。
private final class PluginMenuAction: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}
