import AppKit
import SwiftUI

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { _ in settings.toggleLaunchAtLogin() }
                )) {
                    Text(L10n.t("开机时启动", "Open at Login"))
                }
                .toggleStyle(.switch)

                if settings.launchNeedsApproval {
                    Label(L10n.t("需要在「系统设置 → 通用 → 登录项」中批准",
                                 "Needs approval in System Settings → General → Login Items"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker(L10n.t("语言", "Language"), selection: $settings.language) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                Picker(L10n.t("外观", "Appearance"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section {
                Picker(L10n.t("自动检查更新", "Check for updates"), selection: $settings.updateCheckFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { freq in
                        Text(freq.label).tag(freq)
                    }
                }

                Text(L10n.t(
                    "发现新版本时会提示，确认后自动下载安装并重新启动。",
                    "You'll be notified when an update is found; it downloads, installs, and relaunches automatically after you confirm."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

// MARK: - 切换器

private struct SwitcherPane: View {
    @ObservedObject var settings: AppSettings
    let connected: Bool

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.scopeToWindow) {
                    Text(L10n.t("只切换当前窗口的标签", "Limit switching to the current window"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "关闭后，所有 Chrome 窗口的标签会合并成一张列表。两种模式下每个窗口都保留各自的使用历史。",
                    "When off, tabs from every Chrome window appear in one list. Either way, each window keeps its own history."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("范围", "Scope"))
            }

            Section {
                Picker(L10n.t("样式", "Style"), selection: $settings.switcherLayout) {
                    ForEach(SwitcherLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }

                Text(L10n.t(
                    "长条横向排成一行；宫格自动换行，尽量一屏放下所有标签。宫格下可以用 ⌃ + 方向键上下左右移动。",
                    "Strip lays tabs out in a single row; grid wraps them to fit on one screen. In grid mode, hold ⌃ and use all four arrow keys to move."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("布局", "Layout"))
            }

            Section {
                Label(
                    connected
                        ? L10n.t("扩展已连接", "Extension connected")
                        : L10n.t("扩展未连接 —— 设置会在重新连接后生效",
                                 "Extension not connected — settings apply once it reconnects"),
                    systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(connected ? .green : .orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

// MARK: - 标签管理

private struct TabManagementPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if settings.favorites.isEmpty {
                    Text(L10n.t("还没有置顶。在 Chrome 里置顶任意标签，或在菜单栏选「置顶当前标签」。",
                                "Nothing pinned yet. Pin any tab in Chrome, or use \u{201C}Pin Current Tab\u{201D} in the menu bar."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if settings.favorites.count > 6 {
                    // 收藏多时限高滚动 —— 设置窗口按内容自适应高度，
                    // 列表无限增长会把窗口顶出屏幕。
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(settings.favorites) { fav in
                                favoriteRow(fav)
                                    .padding(.vertical, 5)
                                if fav.id != settings.favorites.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                } else {
                    ForEach(settings.favorites) { fav in
                        favoriteRow(fav)
                    }
                }

                Text(L10n.t(
                    "与 Chrome 双向同步：置顶即加入、取消置顶即移除（⌘W 关闭不算）。Chrome 重启后自动恢复置顶，并带回最后访问的页面。",
                    "Two-way sync with Chrome: pinning adds, unpinning removes (⌘W doesn't count). Pins come back after Chrome restarts, restored to the last page visited."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(settings.favorites.isEmpty
                     ? L10n.t("置顶标签", "Pinned tabs")
                     : L10n.t("置顶标签 · \(settings.favorites.count) 个",
                              "Pinned tabs · \(settings.favorites.count)"))
            }

            Section {
                Toggle(isOn: $settings.allowTabClose) {
                    Text(L10n.t("切换器中悬停显示关闭按钮", "Show close button on hover in the switcher"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "悬停切换器卡片时显示 ✕，点击关闭标签。只剩 2 个标签时不显示。",
                    "Hover a switcher card to reveal ✕. Hidden when only two tabs remain."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("关闭标签", "Closing tabs"))
            }

            Section {
                Picker(L10n.t("自动清理未使用的标签", "Auto-clean unused tabs"),
                       selection: $settings.tabLifetime) {
                    ForEach(TabLifetime.allCases) { lifetime in
                        Text(lifetime.label).tag(lifetime)
                    }
                }

                Text(L10n.t(
                    "超时未使用的标签自动关闭。置顶、发声、标签组内及各窗口当前标签不受影响。",
                    "Closes tabs unused past the limit. Pinned, audible, grouped, and current tabs are exempt."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("标签存活时间", "Tab lifetime"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    @ViewBuilder
    private func favoriteRow(_ fav: FavoriteTab) -> some View {
        HStack(spacing: 8) {
            FaviconView(fav: fav)
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.title.isEmpty ? fav.url : fav.title)
                    .lineLimit(1)
                // 显示「最后访问」而不是原始收藏地址 —— 恢复时开的就是它
                Text(settings.favoriteCurrentUrls[fav.id] ?? fav.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                settings.favorites.removeAll { $0.id == fav.id }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("移除并取消置顶", "Remove and unpin"))
        }
    }
}

/// 置顶列表行首的站点图标。
///
/// 不用 AsyncImage：很多站点的 favicon 是 `data:image/svg+xml` 内联 SVG
/// （云效 Flow 就是），AsyncImage 的解码管线不认 SVG，会永远停在占位图。
/// NSImage(data:) 原生支持 SVG / ICO / PNG，成功率高得多。
/// 候选链：置顶时记录的 favIconUrl → 域名根的 /favicon.ico → globe。
private struct FaviconView: View {
    let fav: FavoriteTab
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .task(id: fav.id) {
            image = await Self.load(fav)
        }
    }

    private static func load(_ fav: FavoriteTab) async -> NSImage? {
        var candidates: [URL] = []
        if let stored = fav.favIconUrl, !stored.isEmpty, let url = URL(string: stored) {
            candidates.append(url)
        }
        if let page = URL(string: fav.url), let host = page.host,
           let ico = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            candidates.append(ico)
        }
        for url in candidates {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = NSImage(data: data), image.isValid {
                return image
            }
        }
        return nil
    }
}

// MARK: - 快捷键

private struct HotkeyPane: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.t("置顶 / 取消置顶当前标签", "Pin / unpin current tab"))
                    Spacer()
                    Button {
                        recording ? stopRecording() : startRecording()
                    } label: {
                        Text(recording
                             ? L10n.t("按下快捷键…", "Press shortcut…")
                             : (settings.pinHotkey?.display ?? L10n.t("点击录制", "Record")))
                            .frame(minWidth: 96)
                    }
                    if settings.pinHotkey != nil && !recording {
                        Button {
                            settings.pinHotkey = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("清除", "Clear"))
                    }
                }

                Text(L10n.t(
                    "需包含 ⌘ / ⌃ / ⌥ 至少一个修饰键，仅在 Chrome 前台生效，Esc 取消录制。注意避开 Chrome 自带的快捷键（如 ⌘T 新建标签、⌘D 收藏书签）。",
                    "Include at least one of ⌘ / ⌃ / ⌥. Works only while Chrome is frontmost; Esc cancels recording. Avoid Chrome's own shortcuts (⌘T new tab, ⌘D bookmark)."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("快捷键", "Shortcuts"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc 取消
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            settings.pinHotkey = HotkeyConfig(keyCode: event.keyCode,
                                              modifiers: mods.rawValue,
                                              character: chars.lowercased())
            return nil   // 这次按键被录制吃掉，不下发
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - 关于

private struct AboutPane: View {
    @ObservedObject var updates: UpdateChecker

    private var icon: NSImage {
        NSApp.applicationIconImage ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 72, height: 72)

            VStack(spacing: 3) {
                Text("TabFlick").font(.system(size: 16, weight: .semibold))
                Text(L10n.t("版本 \(updates.currentVersion)", "Version \(updates.currentVersion)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.t(
                "增强 Chrome 标签体验：最近使用顺序切换、标签管理、置顶常驻。",
                "Enhance Chrome's tab experience: MRU switching, tab management, and pins that persist."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    updates.check(userInitiated: true)
                } label: {
                    if updates.status == .checking {
                        Text(L10n.t("检查中…", "Checking…"))
                    } else if updates.isDownloading {
                        Text(L10n.t("下载中…", "Downloading…"))
                    } else {
                        Text(L10n.t("检查更新", "Check for Updates"))
                    }
                }
                .disabled(updates.status == .checking || updates.isDownloading)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://www.lifedever.com/sponsor/")!)
                } label: {
                    Label(L10n.t("赞助开发", "Sponsor"), systemImage: "heart.fill")
                }
            }

            HStack(spacing: 16) {
                Link(L10n.t("官网", "Website"),
                     destination: URL(string: "https://www.lifedever.com/TabFlick/")!)
                Link("GitHub",
                     destination: URL(string: "https://github.com/lifedever/TabFlick")!)
                Link(L10n.t("反馈问题", "Report an Issue"),
                     destination: URL(string: "https://github.com/lifedever/TabFlick/issues")!)
            }
            .font(.system(size: 11))

            Text("MIT License © lifedever")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - 窗口

// macOS 26 的「玻璃」外观长在窗口的 titlebar/toolbar 上：SwiftUI `TabView`
// 渲染出来的是内容区里的一颗分段控件，永远得不到那层玻璃。要拿到系统设置
// 那种效果，tab 必须真的住进 toolbar —— 这正是 NSTabViewController 的
// `.toolbar` 样式，切换时窗口尺寸动画、顶边锚定也都是它的原生行为。
//
// 窗口标题固定为「设置」,不随 pane 变。注意 title 必须设在
// NSTabViewController 上而不是 window 上 —— NSWindow(contentViewController:)
// 会把 window.title **绑定**到 contentViewController.title,直接写
// window.title 会被绑定覆盖回 "Untitled"(nil title 的显示值)。

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let settings: AppSettings
    private let updates: UpdateChecker
    private var window: NSWindow?
    private var connected = false

    private var generalHost: NSHostingController<GeneralPane>?
    private var switcherHost: NSHostingController<SwitcherPane>?
    private var tabManagementHost: NSHostingController<TabManagementPane>?
    private var hotkeyHost: NSHostingController<HotkeyPane>?
    private var aboutHost: NSHostingController<AboutPane>?
    private var tabController: NSTabViewController?

    init(settings: AppSettings, updates: UpdateChecker) {
        self.settings = settings
        self.updates = updates
        super.init()
    }

    func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        refreshContentIfVisible()
    }

    /// 语言变了要重建内容 —— 文案是渲染时取的，不会自己更新。
    func reloadForLanguageChange() {
        guard let tabController else { return }
        for (item, title) in zip(tabController.tabViewItems, Self.paneTitles) {
            item.label = title
        }
        tabController.title = L10n.t("设置", "Settings")
        refreshContentIfVisible()
    }

    private static var paneTitles: [String] {
        [L10n.t("通用", "General"),
         L10n.t("切换器", "Switcher"),
         L10n.t("标签管理", "Tabs"),
         L10n.t("快捷键", "Shortcuts"),
         L10n.t("关于", "About")]
    }

    private func refreshContentIfVisible() {
        guard let window, window.isVisible else { return }
        generalHost?.rootView = GeneralPane(settings: settings)
        switcherHost?.rootView = SwitcherPane(settings: settings, connected: connected)
        tabManagementHost?.rootView = TabManagementPane(settings: settings)
        hotkeyHost?.rootView = HotkeyPane(settings: settings)
        aboutHost?.rootView = AboutPane(updates: updates)
    }

    func show() {
        // 打开窗口时临时变成普通 app：出现 Dock 图标、能用 ⌘⇥ 切回来。
        // 关闭后由 windowWillClose 收回 .accessory。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        settings.refreshLaunchAtLogin()   // 用户可能刚在系统设置里改过

        if window == nil {
            let general = NSHostingController(rootView: GeneralPane(settings: settings))
            let switcher = NSHostingController(rootView: SwitcherPane(settings: settings, connected: connected))
            let tabManagement = NSHostingController(rootView: TabManagementPane(settings: settings))
            let hotkey = NSHostingController(rootView: HotkeyPane(settings: settings))
            let about = NSHostingController(rootView: AboutPane(updates: updates))
            // 让 preferredContentSize 跟随 SwiftUI 内容：NSTabViewController
            // 切 tab 时按它做窗口尺寸动画（顶边锚定是 AppKit 原生行为）
            general.sizingOptions = [.preferredContentSize]
            switcher.sizingOptions = [.preferredContentSize]
            tabManagement.sizingOptions = [.preferredContentSize]
            hotkey.sizingOptions = [.preferredContentSize]
            about.sizingOptions = [.preferredContentSize]
            generalHost = general
            switcherHost = switcher
            tabManagementHost = tabManagement
            hotkeyHost = hotkey
            aboutHost = about

            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let symbols = ["gearshape", "rectangle.on.rectangle.angled", "rectangle.stack", "command", "info.circle"]
            for (index, controller) in ([general, switcher, tabManagement, hotkey, about] as [NSViewController]).enumerated() {
                let item = NSTabViewItem(viewController: controller)
                item.label = Self.paneTitles[index]
                item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            tabs.title = L10n.t("设置", "Settings")
            tabController = tabs

            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self

            // 必须先把内容布局出来再居中：自适应尺寸的窗口如果在内容到位前
            // center()，会以近零尺寸算中心，随后内容以左上角为锚向右下展开，
            // 窗口最终落在屏幕右下象限（PasteMemo #66）。
            tabs.view.layoutSubtreeIfNeeded()
            w.setContentSize(general.view.fittingSize)
            w.center()
            window = w
        } else {
            refreshContentIfVisible()
        }

        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 等窗口真正关掉再判断，此刻它仍算 visible。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasVisibleWindow = NSApp.windows.contains { w in
                // 切换器浮层是 borderless 的 NSPanel，不能算进来，
                // 否则每次按 ⌃⇥ 都会把 Dock 图标顶出来
                w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled) && !w.title.isEmpty
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
