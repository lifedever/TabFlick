import AppKit
import Combine
import SwiftUI

// 设置窗口的骨架：左边侧边栏、右边内容（2026-11-06 从顶部工具栏分页改过来，照 PasteMemo 的设置窗口）。
// 改的原因：功能越来越多（插件商店之后每个插件还有自己的页），工具栏一排放不下 —— 日语时已经要按
// 分页名把整个窗口撑宽，再加页就挤进 >> 溢出菜单。侧边栏竖着排，加多少页都放得下。
//
// 各页的内容在 SettingsWindow.swift（页面结构体是 private 的，内容区的 switch 也在那边）。

/// 设置的一页。侧边栏按 `groups` 分组画，内容区按它挑页面。
enum SettingsPage: Hashable, Identifiable {
    case general, switcher, search, tabs, folders, openWith, browsers
    /// 插件总览：装了哪些、开关
    case plugins
    /// 某个插件自己的页（按插件 id）
    case plugin(String)
    case about

    var id: String {
        switch self {
        case .plugin(let id): return "plugin:" + id
        default: return String(describing: self)
        }
    }

    /// 侧边栏的分组（组之间空一段）：功能、插件（总览 + 每个插件一行，学 Raycast）、关于。
    @MainActor static var groups: [[SettingsPage]] {
        [[.general, .switcher, .search, .tabs, .folders, .openWith, .browsers],
         // 没东西可设的插件（计算器）不占一行，开关在总览页
         [.plugins] + PluginRegistry.shared.plugins.filter(\.hasSettingsPage).map { .plugin($0.id) },
         [.about]]
    }

    @MainActor static var all: [SettingsPage] { groups.flatMap { $0 } }

    @MainActor private var pluginEntry: Plugin? {
        if case .plugin(let id) = self { return PluginRegistry.shared.plugin(id) }
        return nil
    }

    @MainActor var title: String {
        switch self {
        case .general: return L10n.t("通用", "General")
        case .switcher: return L10n.t("切换器", "Switcher")
        case .search: return L10n.t("搜索面板", "Search")
        case .tabs: return L10n.t("标签管理", "Tabs")
        case .folders: return L10n.t("文件夹管理", "Folders")
        case .openWith: return L10n.t("打开方式", "Open With")
        case .browsers: return L10n.t("浏览器", "Browsers")
        case .plugins: return L10n.t("插件", "Plugins")
        case .plugin(let id): return pluginEntry?.title ?? id
        case .about: return L10n.t("关于", "About")
        }
    }

    /// 侧边栏图标块里的白色符号（实心那一版，同搜索面板的 `ActionTile`）。
    @MainActor var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .switcher: return "rectangle.on.rectangle.angled.fill"
        case .search: return "magnifyingglass"
        case .tabs: return "rectangle.stack.fill"
        case .folders: return "folder.fill"
        case .openWith: return "arrow.up.forward.app.fill"
        case .browsers: return "globe"
        case .plugins: return "puzzlepiece.extension.fill"
        case .plugin: return pluginEntry?.symbol ?? "puzzlepiece.fill"
        case .about: return "info.circle"
        }
    }

    /// 插件页用插件自己的图标（有的话），别的页画符号 + 底色。
    @MainActor var icon: NSImage? {
        if case .plugin = self { return pluginEntry?.icon }
        return nil
    }

    /// 图标块底色，照系统设置：每页一种，相邻的不撞色。
    @MainActor var tint: Color {
        switch self {
        case .general: return .gray
        case .switcher: return .purple
        case .search: return .blue
        case .tabs: return .orange
        case .folders: return .cyan
        case .openWith: return .green
        case .browsers: return .indigo
        case .plugins: return .pink
        case .plugin: return pluginEntry?.tint ?? .gray
        case .about: return .gray
        }
    }
}

/// 侧边栏宽度：按当前语言最长的页名算（日语「このアプリケーションで開く」比中文宽一倍），
/// 至少 200。切语言时重算（`SettingsSplitViewController.setSidebarWidth`）。
@MainActor var kSettingsSidebarWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: 13)
    let widest = SettingsPage.all.map {
        ceil(($0.title as NSString).size(withAttributes: [.font: font]).width)
    }.max() ?? 0
    // 图标块 22 + 间距 8 + 行内边距 6×2 + 侧边栏内边距 10×2，再留 16 余量（NSString 量出来比实际画的窄几 pt）
    return max(200, widest + 22 + 8 + 12 + 20 + 16)
}

/// 内容区之外、各页要用的会变的数据。页面观察它，变了只重画、不重建（页面里的 @State 留着）。
@MainActor
final class SettingsContext: ObservableObject {
    @Published var browserStatuses: [MRUController.BrowserStatus] = []
    @Published var connected = false
    /// 换语言时加一：侧边栏和内容区按它整个重建（文案是渲染时取的）。
    @Published var languageRevision = 0
}

/// 设置窗口的导航：当前页 + 看过的页（标题栏那对前进 / 后退箭头用）。照 PasteMemo 的 `SettingsNavigationModel`。
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsPage = .general {
        didSet {
            guard oldValue != selection else { return }
            recordHistory()
            onLocationChange?()
        }
    }

    /// 当前页变了（同步窗口标题、箭头可用状态）。窗口骨架接。
    var onLocationChange: (() -> Void)?

    private var history: [SettingsPage] = [.general]
    private var historyIndex = 0
    /// 箭头触发的切换不再入栈，否则一路后退会把历史越堆越长。
    private var isNavigatingHistory = false

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        apply(history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        apply(history[historyIndex])
    }

    private func apply(_ page: SettingsPage) {
        isNavigatingHistory = true
        selection = page
        isNavigatingHistory = false
    }

    /// 从历史中间跳到新页时先截掉「前进」那一截（浏览器和系统设置都是这样）。
    private func recordHistory() {
        guard !isNavigatingHistory else { return }
        guard history.indices.contains(historyIndex), history[historyIndex] != selection else { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(selection)
        historyIndex = history.count - 1
    }
}

/// 侧边栏：彩色圆角图标块 + 页名，尺寸照系统设置。
///
/// 不用 `List`：它底层是 NSTableView，首次填充时行带着插入动画从下往上滑进来，打开窗口能看见图标
/// 窜一下（PasteMemo 实测，SwiftUI 侧的 `.transaction` 压不住）。统共十来行，不需要虚拟化，自己画。
struct SettingsSidebar: View {
    @ObservedObject var nav: SettingsNavigationModel
    @ObservedObject var context: SettingsContext
    /// 商店装、卸插件后侧边栏的插件行跟着变
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, pages in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pages) { row($0) }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .id(context.languageRevision)
    }

    private func row(_ page: SettingsPage) -> some View {
        let isSelected = nav.selection == page
        return HStack(spacing: 8) {
            if case .plugin = page {
                PluginIconTile(icon: page.icon, symbol: page.symbol, tint: page.tint, side: 22)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(page.tint.gradient)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: page.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
            Text(page.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { nav.selection = page }
    }
}

/// 窗口骨架：AppKit 的 `NSSplitViewController`，两栏各装一个 SwiftUI 视图（照 PasteMemo）。
///
/// 不用 SwiftUI 的 `NavigationSplitView`：它每轮布局都把自己算的约束写回底层 split view item，
/// 固定宽度和「分隔线不可拖」当场被冲掉（PasteMemo 试过三种压法都不行）。容器换成 AppKit 之后约束只有
/// 我们一家说了算，和系统设置同一套做法。`NSSplitViewItem(sidebarWithViewController:)` 还顺带给了
/// 系统的侧边栏材质和通顶效果。
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    private let nav: SettingsNavigationModel
    private let sidebarItem: NSSplitViewItem
    private var cancellable: AnyCancellable?

    /// 标题栏那对前进 / 后退。用 AppKit 的分段控件而不是 SwiftUI `.toolbar`：后者挂在 split view 里的
    /// hosting controller 上，桥不到窗口标题栏（PasteMemo 试过，按钮直接不出现）。
    private lazy var navigationSegments: NSSegmentedControl = {
        let back = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L10n.t("返回", "Back"))
        let forward = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: L10n.t("前进", "Forward"))
        let control = NSSegmentedControl(images: [back, forward].compactMap { $0 },
                                         trackingMode: .momentary, target: self, action: #selector(navigate(_:)))
        control.segmentStyle = .separated
        return control
    }()

    init<Sidebar: View, Detail: View>(nav: SettingsNavigationModel, sidebar: Sidebar, detail: Detail, sidebarWidth: CGFloat) {
        self.nav = nav
        sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar))
        super.init(nibName: nil, bundle: nil)

        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        setSidebarWidth(sidebarWidth)
        addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: detail)))

        // 历史一变就刷新箭头的可用状态
        cancellable = nav.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncNavigationState() }
        }
    }

    /// min == max：AppKit 自己把分隔线锁住。
    func setSidebarWidth(_ width: CGFloat) {
        sidebarItem.minimumThickness = width
        sidebarItem.maximumThickness = width
    }

    /// 必须在窗口显示**之前**调用：toolbar 一挂上去窗口的 safe area 顶部就变了，已显示的内容会整体
    /// 上移一下（PasteMemo 踩过）。
    func installToolbar(on window: NSWindow) {
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        syncNavigationState()
    }

    func syncNavigationState() {
        navigationSegments.setToolTip(L10n.t("返回", "Back"), forSegment: 0)
        navigationSegments.setToolTip(L10n.t("前进", "Forward"), forSegment: 1)
        navigationSegments.setEnabled(nav.canGoBack, forSegment: 0)
        navigationSegments.setEnabled(nav.canGoForward, forSegment: 1)
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { nav.goBack() } else { nav.goForward() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension NSToolbarItem.Identifier {
    static let settingsNavigation = NSToolbarItem.Identifier("settingsNavigation")
}

extension SettingsSplitViewController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .settingsNavigation else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = navigationSegments
        item.isNavigational = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.settingsNavigation] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.settingsNavigation] }
}
