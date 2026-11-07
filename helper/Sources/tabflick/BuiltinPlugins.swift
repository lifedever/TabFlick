import AppKit
import SwiftUI

/// 内置插件：原来写死在搜索面板里的四样，改成插件后能在设置里单独关（2026-11-06）。
/// 功能本身没变，各自的实现还在原来的文件里（Calculator / AppCommands / WindowCommands / ProcessList），
/// 这里只是把它们接到插件协议上。
enum BuiltinPlugins {
    /// 顺序 = 设置侧边栏里的顺序，也是命令在面板里同分时的先后（锁屏、结束进程、窗口命令，同插件化之前）。
    @MainActor static func all() -> [Plugin] {
        [CalculatorPlugin(), AppCommandsPlugin(), ProcessesPlugin(), WindowCommandsPlugin()]
    }
}

// MARK: - 计算器

@MainActor
final class CalculatorPlugin: Plugin {
    let id = "calculator"
    var title: String { L10n.t("计算器", "Calculator") }
    var summary: String {
        L10n.t("在搜索面板里打一道算式，最上面一行出结果，回车拷贝。",
               "Type a math expression in the search panel. The result shows on top; ↵ copies it.")
    }
    let symbol = "plus.forwardslash.minus"
    var tint: Color { .gray }
    var icon: NSImage? { BuiltinPluginIcons.calculator }
    let origin = PluginOrigin.builtin

    func instantRows(_ query: String, _ context: PluginContext) -> [SearchRow] {
        guard let calculation = Calculator.evaluate(query) else { return [] }
        return [.calculation(calculation, pasteInto: context.windowTarget?.name)]
    }
}

// MARK: - App 命令

@MainActor
final class AppCommandsPlugin: Plugin {
    let id = "appCommands"
    var title: String { L10n.t("App 命令", "App Commands") }
    var summary: String {
        L10n.t("Amphetamine 开始、结束会话，锁定屏幕。", "Start or end an Amphetamine session, and lock the screen.")
    }
    let symbol = "command"
    var tint: Color { .orange }
    var icon: NSImage? { BuiltinPluginIcons.appCommands }
    let origin = PluginOrigin.builtin

    var panelCommands: [PluginCommandInfo] {
        AppCommands.all.map { command in
            let title = command.bundleID.map { command.title + " · " + Self.appName($0) } ?? command.title
            return PluginCommandInfo(id: command.id, title: title, symbol: command.symbol)
        }
    }

    func commands(_ context: PluginContext) -> [AppCommand] { AppCommands.all }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - 窗口命令

@MainActor
final class WindowCommandsPlugin: Plugin {
    let id = "windowCommands"
    var title: String { L10n.t("窗口命令", "Window Commands") }
    var summary: String {
        L10n.t("居中、最大化、左右半屏、移到下一个显示器等，动的是打开搜索面板前在用的那个窗口。",
               "Center, maximize, left or right half, next display and more, for the window you were using before opening the search panel.")
    }
    let symbol = "macwindow"
    var tint: Color { .indigo }
    var icon: NSImage? { BuiltinPluginIcons.windowCommands }
    let origin = PluginOrigin.builtin

    var panelCommands: [PluginCommandInfo] {
        WindowAction.allCases.map { PluginCommandInfo(id: "window." + $0.rawValue, title: $0.title, symbol: $0.symbol) }
    }

    func commands(_ context: PluginContext) -> [AppCommand] { WindowCommands.commands(for: context.windowTarget) }
}

// MARK: - 结束进程

@MainActor
final class ProcessesPlugin: Plugin {
    let id = "processes"
    var title: String { L10n.t("结束进程", "Kill Process") }
    var summary: String {
        L10n.t("按名字或端口找进程，确认后结束。",
               "Find a process by name or port and kill it after confirming.")
    }
    let symbol = ProcessesCommand.symbol
    var tint: Color { ProcessesCommand.tint }
    var icon: NSImage? { BuiltinPluginIcons.processes }
    let origin = PluginOrigin.builtin

    var panelCommands: [PluginCommandInfo] {
        [PluginCommandInfo(id: ProcessesCommand.command.id, title: ProcessesCommand.title, symbol: ProcessesCommand.symbol)]
    }

    /// 这条命令就是插件本身，画插件的图标（窗口命令、锁屏各有各的符号，只染插件的颜色）
    func commands(_ context: PluginContext) -> [AppCommand] {
        var command = ProcessesCommand.command
        command.icon = icon
        return [command]
    }

    let processMenu = ProcessMenu()
    var menu: PluginMenu? { processMenu }
}

/// 状态栏里「结束进程 ▸」：占用最高的几个进程，点一个先确认再结束。
@MainActor
final class ProcessMenu: PluginMenu {
    static let countKey = "processMenuCount"
    static let sortKey = "processMenuSort"
    static let countChoices = [3, 5, 8, 10]
    static let defaultCount = 5

    /// 菜单里「在快捷搜索里打开」：⌥Space 面板直接进进程列表（main.swift 接）。
    var openProcessList: (() -> Void)?

    private(set) var snapshot: [PluginMenuRow]?
    private let sampler = ProcessSampler()
    private let queue = DispatchQueue(label: "TabFlick.processMenu", qos: .userInitiated)

    static var count: Int {
        let stored = UserDefaults.standard.integer(forKey: countKey)
        return countChoices.contains(stored) ? stored : defaultCount
    }

    static var sort: ProcessSort {
        UserDefaults.standard.string(forKey: sortKey).flatMap(ProcessSort.init(rawValue:)) ?? .cpu
    }

    /// 连读两次（隔 0.3 秒）算出 CPU，取前几个。在后台队列上做，同面板里的进程列表（`ProcessMonitor`）。
    /// 只在状态栏菜单打开、而且设置里把它放进菜单时才跑。
    func refresh(_ done: @escaping @MainActor ([PluginMenuRow]) -> Void) {
        let apps = ProcessMonitor.runningApps()
        let sampler = self.sampler
        let own = getpid()
        let count = Self.count
        let sort = Self.sort
        queue.async {
            sampler.reset()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.3)
            let built = ProcessCatalog.build(sampler.sample(), apps: apps.map { $0.resolvingPaths() }, ownPID: own)
            let top = Array(ProcessCatalog.sorted(built.items, by: sort).prefix(count))
            Task { @MainActor in
                let rows = self.rows(top, sort: sort)
                self.snapshot = rows
                done(rows)
            }
        }
    }

    private func rows(_ items: [ProcessItem], sort: ProcessSort) -> [PluginMenuRow] {
        var rows: [PluginMenuRow] = [.header(sort == .cpu ? L10n.t("CPU 占用最高", "Top CPU")
                                                         : L10n.t("内存占用最高", "Top Memory"))]
        for item in items {
            let cpu = ProcessCatalog.formatCPU(item.cpu)
            let memory = ProcessCatalog.formatMemory(item.memory)
            let icon = (NSWorkspace.shared.icon(forFile: item.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            rows.append(.item(PluginMenuItem(
                title: item.name,
                badge: item.ports.first.map { ":\($0)" },
                value: sort == .cpu ? cpu : memory,
                detail: sort == .cpu ? memory : cpu,
                image: icon,
                action: { Self.confirmAndEnd(item) })))
        }
        if items.isEmpty { rows.append(.note(L10n.t("没有可以结束的进程", "No processes to kill"))) }
        rows.append(.separator)
        rows.append(.item(PluginMenuItem(title: L10n.t("在快捷搜索里打开", "Open in Quick Search"),
                                         symbol: "magnifyingglass",
                                         action: { [weak self] in self?.openProcessList?() })))
        return rows
    }

    /// 菜单里没有「再按一次回车」，用确认框代替（面板里是两次回车）。动手前 `ProcessEnder` 还会再核对一次
    /// pid + 启动时间：菜单里这份可能是几秒前的快照。
    private static func confirmAndEnd(_ item: ProcessItem) {
        // 状态栏 App 不抢激活，弹框要显式激活；关了框把前台还回去
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = item.isApp
            ? L10n.t("退出「\(item.name)」？", "Quit “\(item.name)”?")
            : L10n.t("结束「\(item.name)」？", "Kill “\(item.name)”?")
        var facts = ["CPU " + ProcessCatalog.formatCPU(item.cpu), ProcessCatalog.formatMemory(item.memory)]
        if !item.ports.isEmpty {
            let ports = item.ports.map(String.init).joined(separator: ", ")
            facts.append(L10n.t("端口 \(ports)", "Port \(ports)"))
        }
        alert.informativeText = facts.joined(separator: " · ")
        alert.icon = NSWorkspace.shared.icon(forFile: item.path)
        alert.addButton(withTitle: item.isApp ? L10n.t("退出", "Quit") : L10n.t("结束", "Kill"))
        let force = alert.addButton(withTitle: item.isApp ? L10n.t("强制退出", "Force Quit") : L10n.t("强制结束", "Force Kill"))
        force.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        switch response {
        case .alertFirstButtonReturn: ProcessEnder.endReporting(item, force: false)
        case .alertSecondButtonReturn: ProcessEnder.endReporting(item, force: true)
        default: break
        }
    }
}

extension ProcessEnder {
    /// 结束并用 toast 报结果：等它真退了才说「已退出」（App 可能在问要不要保存，提前说是撒谎），
    /// 5 秒还活着照实说。搜索面板退出 App、状态栏菜单结束进程共用。
    @MainActor static func endReporting(_ item: ProcessItem, force: Bool) {
        switch end(item, force: force) {
        case .sent:
            waitForExit(item, timeout: 5) { exited in
                if exited {
                    Toast.show(L10n.t("已退出「\(item.name)」", "“\(item.name)” has quit"))
                    return
                }
                let detail: String?
                if force {
                    detail = nil
                } else if item.isApp {
                    detail = L10n.t("可能在等你保存文档。", "It may be waiting for you to save a document.")
                } else {
                    detail = L10n.t("再结束一次时选「强制结束」。", "Try again with Force Kill.")
                }
                Toast.show(L10n.t("「\(item.name)」还没退出", "“\(item.name)” is still running"),
                           detail: detail, kind: .info)
            }
        case .gone:
            Toast.show(L10n.t("「\(item.name)」已经退出了", "“\(item.name)” had already quit"), kind: .info)
        case .denied:
            Toast.show(L10n.t("没有权限结束「\(item.name)」", "No permission to kill “\(item.name)”"), kind: .failure)
        case .failed:
            Toast.show(L10n.t("没能结束「\(item.name)」", "Couldn't kill “\(item.name)”"), kind: .failure)
        }
    }
}
