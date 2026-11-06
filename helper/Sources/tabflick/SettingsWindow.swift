import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 各页铺满右边的内容区（窗口骨架见 SettingsShell.swift）。grouped Form 自己会滚，页面不定宽高。

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
                    "有新版本时提示你，确认后自动装好重启。",
                    "Prompts you when there's a new version, then installs and restarts."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("日志文件", "Log file"))
                        Text(kLogPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(L10n.t("打开", "Open")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: kLogPath))
                    }
                }
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - 排除的 App

private struct ExcludedAppsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View { excludedSection }

    /// 排除名单：这些 App 在前台时不接管全局切换器的键（搜索面板不看它，用户定的：
    /// 那是全局工具，要关就关开关）。2026-09-26 从切换器页搬去「通用」，2026-11-06 搬回切换器页、
    /// 全局切换器关着时整段不出现（用户问「这个功能还有用吗」：它只管全局切换器，关着时放在「通用」最显眼处让人困惑）。
    ///
    /// 只有手工这一份。自动检测做过一版又拆了（2026-09-11）：AX 只读得到
    /// 摆进菜单栏的绑定，Electron / 自绘界面的 App（Claude、VS Code）把
    /// ⌃⇥ 判在自己的代码里，系统根本不知道 —— 一个「自动排除」开关打开后
    /// 照样被抢，比没有这个开关更糟。状态栏菜单的「排除 XX」是快捷入口。
    @ViewBuilder
    private var excludedSection: some View {
        Section {
            ForEach(sortedExcluded) { app in
                excludedRow(app)
            }

            Button {
                chooseApp()
            } label: {
                Label(L10n.t("添加 App…", "Add App…"), systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text(L10n.t("这些 App 在前台时不接管全局切换器的快捷键。浏览器里的键和搜索面板不受影响。",
                        "The global switcher shortcut is left alone while these apps are frontmost. In-browser keys and the search panel are unaffected."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.t("排除的 App", "Excluded apps"))
        }
    }

    /// 按名字排序（添加顺序对找一项没有帮助）。
    private var sortedExcluded: [ExcludedApp] {
        settings.globalExcludedApps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func exclude(bundleID: String, name: String) {
        guard !settings.globalExcludedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        settings.globalExcludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default
            .urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // bundle id 是判定口径，取不到就没法排除 —— 选中的不是正经 app bundle
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t("这个 App 认不出来", "Can't identify this app")
            alert.informativeText = L10n.t("读不到它的标识符，换一个试试。",
                                           "Its identifier couldn't be read. Try another one.")
            alert.addButton(withTitle: L10n.t("好", "OK"))
            alert.runModal()
            return
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        exclude(bundleID: bundleID, name: name)
    }

    @ViewBuilder
    private func excludedRow(_ app: ExcludedApp) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
            // App 已卸载时图标降级、名字留着 —— 这条记录还得能被认出来删掉
            if url == nil {
                Text(L10n.t("未安装", "Not installed"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settings.globalExcludedApps.removeAll { $0.bundleID == app.bundleID }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("取消排除", "Stop excluding"))
        }
    }
}

// MARK: - 切换器

private struct SwitcherPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HotkeyRow(label: L10n.t("唤出切换器（按住修饰键循环）", "Open the switcher (hold to cycle)"),
                          config: $settings.switcherHotkey, placeholder: "⌃ ⇥")
                hotkeyNote("至少带一个 ⌘ / ⌃ / ⌥，⇧ 留给反向切换。Esc 取消录制。只在浏览器前台生效，别撞上终端和编辑器的 ⌃⇥。",
                           "Use at least one of ⌘ / ⌃ / ⌥; ⇧ is reserved for reverse. Esc cancels. Works only while a browser is frontmost — watch out for the ⌃⇥ in terminals and editors.")
            } header: {
                Text(L10n.t("快捷键", "Shortcut"))
            }

            Section {
                Toggle(isOn: $settings.scopeToWindow) {
                    Text(L10n.t("只切换当前窗口的标签", "Limit switching to the current window"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "关掉则合并所有窗口的标签。每个窗口的使用顺序都是独立记的。",
                    "Off means all windows share one list. Each window keeps its own order either way."
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
                    "长条排成一行，宫格换行铺满一屏。宫格下 ⌃ + 方向键可以四向移动。",
                    "Strip is one row; grid wraps to fill the screen. In grid mode, ⌃ plus arrows moves in all four directions."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("布局", "Layout"))
            }

            Section {
                Toggle(isOn: $settings.globalSwitcher) {
                    Text(L10n.t("在浏览器之外也能唤出", "Open outside the browser"))
                }
                .toggleStyle(.switch)

                Picker(L10n.t("样式", "Style"), selection: $settings.globalSwitcherStyle) {
                    ForEach(GlobalSwitcherStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .disabled(!settings.globalSwitcher)

                HotkeyRow(label: L10n.t("快捷键", "Shortcut"),
                          config: $settings.globalHotkey,
                          placeholder: L10n.t("同切换器键", "Same as switcher"))
                    .disabled(!settings.globalSwitcher)

                Text(L10n.t(
                    "列出所有浏览器的标签，按浏览器分组。默认沿用切换器快捷键，只在浏览器之外唤出；想在浏览器里也能用，单独给它设一个键。",
                    "Lists tabs from every browser, grouped by browser. It reuses the switcher shortcut and only opens outside a browser — give it its own key to use it anywhere."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("全局切换器", "Global switcher"))
            }

            // 排除名单只管全局切换器，关着时不出现
            if settings.globalSwitcher {
                ExcludedAppsSection(settings: settings)
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - 浏览器

/// 每个已安装的 Chromium 系浏览器一行，显示连接与扩展版本状态。
/// 这是多浏览器状态的唯一完整视图 —— 连接是按浏览器分账的。
private struct BrowserPane: View {
    let browsers: [MRUController.BrowserStatus]
    /// app 里带着扩展（打包版）才能从这里装；`swift run` 的开发版没有，退回下载 zip
    var canInstall = false
    var onInstall: (String) -> Void = { _ in }
    var onUpdate: (String) -> Void = { _ in }
    var onOpenExtensions: (String) -> Void = { _ in }

    var body: some View {
        Form {
            Section {
                if browsers.isEmpty {
                    Text(L10n.t("没有发现已安装的 Chromium 系浏览器。",
                                "No Chromium-based browsers found."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(browsers) { browser in
                        browserRow(browser)
                    }
                }
            } header: {
                Text(L10n.t("已安装的浏览器", "Installed browsers"))
            }

            Section {
                Text(L10n.t(
                    "扩展要每个浏览器装一次。浏览器开着却显示未连接的，到它的扩展页看看扩展是不是关了。",
                    "Install the extension once per browser. If a running browser shows Not connected, check whether the extension is turned off in its extensions page."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if !canInstall {
                        Button(L10n.t("下载扩展", "Download Extension")) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/lifedever/TabFlick/releases/latest/download/TabFlick-Extension.zip")!)
                        }
                    }
                    Link(L10n.t("安装说明", "Install Guide"),
                         destination: URL(string: "https://www.lifedever.com/TabFlick/install-extension.html")!)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func browserRow(_ browser: MRUController.BrowserStatus) -> some View {
        HStack(spacing: 8) {
            appIcon(browser.bundleID)
            Text(browser.name)
            Spacer()
            if !browser.connected && !browser.running && browser.everConnected {
                // 浏览器没开，扩展当然连不上；以前连上过就是装着的，别让人以为要再装一次。
                // 版本号是最后一次连上时报的
                Label(L10n.t("未打开", "Not running") + (browser.lastExtVersion.map { " · v\($0)" } ?? ""),
                      systemImage: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !browser.connected && browser.everConnected {
                // 开着却没连上：以前连上过就是装过，多半是扩展被关了。不给「安装扩展」：再从固定目录装一份，
                // 扩展 ID 跟着路径变、Profile 标识丢，置顶会被重复收编、「最近关闭」看不到（2026-11-04 撞上过）
                Label(L10n.t("未连接", "Not connected"), systemImage: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(L10n.t("打开扩展页", "Open Extensions Page")) { onOpenExtensions(browser.bundleID) }
                    .controlSize(.small)
            } else if !browser.connected {
                Label(L10n.t("未安装扩展", "Extension not installed"), systemImage: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if canInstall {
                    Button(L10n.t("安装扩展", "Install Extension")) { onInstall(browser.bundleID) }
                        .controlSize(.small)
                }
            } else if browser.needsUpdate {
                // 不写「需更新到 vX」：版本号够了却没点 ↻ 的也算要更新，那时写目标版本是在讲一件假事
                Label(L10n.t("已连接 · 扩展 v\(browser.extVersion ?? "?") 需要更新",
                             "Connected · extension v\(browser.extVersion ?? "?") needs updating"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button(L10n.t("更新", "Update")) { onUpdate(browser.bundleID) }
                    .controlSize(.small)
            } else {
                Label(L10n.t("已连接", "Connected") + (browser.extVersion.map { " · v\($0)" } ?? ""),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 标签管理

private struct TabManagementPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if settings.favorites.isEmpty {
                    Text(L10n.t("还没有置顶。在浏览器里置顶任意标签。",
                                "Nothing pinned yet. Pin any tab in your browser."))
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
                    "和浏览器双向同步：置顶即收藏，取消置顶或关掉标签即移除，关整个窗口不算。重启浏览器会自动恢复，停在你最后看的那一页。",
                    "Syncs both ways: pinning adds; unpinning or closing the tab removes, closing the whole window doesn't. Restored on restart, at the page you last viewed."
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
                    "只剩两个标签时不显示。全局切换器没有这个按钮。",
                    "Hidden when only two tabs are left. Not available in the global switcher."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Toggle(isOn: $settings.undoCloseTab) {
                    Text(L10n.t("⌘Z 恢复刚关闭的标签", "⌘Z reopens the tab you just closed"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "不在输入框里时，⌘Z 恢复最近关掉的标签或窗口，连按继续往前。自动清理关掉的不算。新标签页和 chrome:// 页面上不起作用。",
                    "Outside text fields, ⌘Z brings back the last closed tab or window; keep pressing to go further back. Tabs closed by auto-clean are skipped. Doesn't work on the New Tab page or chrome:// pages."
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
                    "超时没用过的标签会被关掉。置顶、正在放声音、在标签组里、以及各窗口当前那个都不动。",
                    "Closes tabs you haven't used in that long. Pinned, audible, grouped, and current tabs stay."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("标签存活时间", "Tab lifetime"))
            }

            Section {
                HotkeyRow(label: L10n.t("置顶 / 取消置顶当前标签", "Pin / unpin current tab"),
                          config: $settings.pinHotkey, placeholder: nil)
                hotkeyNote("至少带一个 ⌘ / ⌃ / ⌥。Esc 取消录制。只在浏览器前台生效，别撞上 ⌘T、⌘D。",
                           "Use at least one of ⌘ / ⌃ / ⌥. Esc cancels. Works only while a browser is frontmost — watch out for ⌘T and ⌘D.")
            } header: {
                Text(L10n.t("快捷键", "Shortcut"))
            }
        }
        .formStyle(.grouped)
    }

    /// 收藏分布在不止一个浏览器（或同一个浏览器的多个 Profile）时，每行标出归属
    private var hasMultipleOwners: Bool {
        Set(settings.favorites.map { $0.browser + "|" + ($0.profile ?? "") }).count > 1
    }

    private func ownerName(_ fav: FavoriteTab) -> String {
        let browser = BrowserSupport.displayName(fav.browser)
        guard let key = fav.profile, let profile = ProfileNames.provider?(key) else { return browser }
        return "\(browser) · \(profile)"
    }

    @ViewBuilder
    private func favoriteRow(_ fav: FavoriteTab) -> some View {
        HStack(spacing: 8) {
            FaviconView(fav: fav)
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.title.isEmpty ? fav.url : fav.title)
                    .lineLimit(1)
                // 显示「最后访问」而不是原始收藏地址 —— 恢复时开的就是它。
                // 收藏跨多个浏览器时（按浏览器分账），前缀标注归属。
                Text((hasMultipleOwners ? ownerName(fav) + " · " : "")
                     + (settings.favoriteCurrentUrls[fav.id] ?? fav.url))
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

/// 置顶列表标 Profile 名用：profileKey → 给用户看的名字（MRUController 提供，main.swift 接上）。
/// 那个 Profile 没连着就认不出，返回 nil（只写浏览器名）。
@MainActor
enum ProfileNames {
    static var provider: ((String) -> String?)?
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

// MARK: - 文件夹

private struct FoldersPane: View {
    @ObservedObject var folders: FavoriteFolderStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            // 菜单栏这一段（2026-11-06 加开关）：开关跟着功能走，不另开一页「菜单栏」
            Section {
                Toggle(isOn: $settings.showFoldersInMenu) {
                    Text(L10n.t("在菜单栏显示", "Show in Menu Bar"))
                }
                .toggleStyle(.switch)

                // 下拉而不是 Stepper：Stepper 的数字是纯文本，点上去会被选中
                // 变蓝，用户反馈「太难用」（2026-09-15）。档位之外的值（旧版
                // Stepper 存下的）也列进去，不然当前值在菜单里没有对应项。
                Picker(L10n.t("状态栏平铺数量", "Shown in the menu"),
                       selection: $settings.inlineFolderLimit) {
                    ForEach(AppSettings.inlineFolderLimitChoices(including: settings.inlineFolderLimit),
                            id: \.self) { n in
                        Text(L10n.t("\(n) 个", "\(n)")).tag(n)
                    }
                }
                .disabled(!settings.showFoldersInMenu)

                Text(settings.showFoldersInMenu
                     ? L10n.t("状态栏菜单按最近打开排序，平铺前 \(settings.inlineFolderLimit) 个，其余收在「更多」里。",
                              "The menu lists the \(settings.inlineFolderLimit) most recently opened; the rest live under More.")
                     : L10n.t("状态栏菜单里不显示收藏的文件夹，也没有「添加文件夹…」。搜索面板里照样能搜到。",
                              "The menu bar menu leaves out favorite folders and “Add Folder…”. They're still in the search panel."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("菜单栏", "Menu Bar"))
            }

            Section {
                if folders.entries.isEmpty {
                    Text(L10n.t("还没有收藏。从状态栏菜单点「添加文件夹…」，或在 Finder 打开目录后点「收藏当前 Finder 目录」。",
                                "Nothing yet. Use “Add Folder…” in the menu bar, or open a folder in Finder and use “Add Current Finder Folder”."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if folders.entries.count > 12 {
                    // 收藏多时限高滚动 —— 设置窗口按内容自适应高度，
                    // 列表无限增长会把窗口顶出屏幕（同置顶标签列表）。
                    // 打开方式拆走后这页只剩这一个列表，12 条以内直接摆开。
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(folders.entries, id: \.path) { folder in
                                folderRow(folder)
                                    .padding(.vertical, 5)
                                if folder.path != folders.entries.last?.path {
                                    Divider()
                                }
                            }
                        }
                        // 尾部留白：overlay 滚动条浮在内容上，不留的话
                        // 行尾的删除按钮会被它压住（2026-09-02 截图实测）
                        .padding(.trailing, 14)
                    }
                    .frame(height: 400)
                } else {
                    ForEach(folders.entries, id: \.path) { folder in
                        folderRow(folder)
                    }
                }

            } header: {
                Text(folders.entries.isEmpty
                     ? L10n.t("收藏的文件夹", "Favorite Folders")
                     : L10n.t("收藏的文件夹 · \(folders.entries.count) 个",
                              "Favorite Folders · \(folders.entries.count)"))
            }

        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func folderRow(_ folder: FavoriteFolder) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                Text(folder.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                folders.remove(path: folder.path)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("取消收藏", "Remove"))
        }
    }
}


// MARK: - 打开方式

/// 「打开方式」管理：只列当前生效的，行尾垃圾桶移除，「添加 App…」
/// 补回或新增 —— 和收藏列表同一副面孔（2026-09-02 用户点名不要开关，
/// 要加减）。列表组装和菜单共用 OpenerCatalog。原来和文件夹列表同一页，
/// 两个列表叠起来页面太长，2026-09-15 拆成独立分页。
private struct OpenWithPane: View {
    @ObservedObject var folders: FavoriteFolderStore

    var body: some View {
        Form {
            openWithSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var openWithSection: some View {
        let apps = OpenerCatalog.candidates(extras: folders.openerExtras)
            .filter { !folders.openerHidden.contains($0.id) }
        Section {
            // 独立分页后不再和文件夹列表争高度：12 条以内直接摆开，
            // 再多才滚动（一屏 12 行 ≈ 340pt，还在 13 寸屏的设置窗口高度内）。
            if apps.count > 12 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(apps) { app in
                            openerRow(app)
                                .padding(.vertical, 4)
                            if app.id != apps.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.trailing, 14)   // 避开悬浮滚动条（同上面的列表）
                }
                .frame(height: 340)
            } else {
                ForEach(apps) { app in
                    openerRow(app)
                }
            }

            Button {
                addOpenerApp()
            } label: {
                Label(L10n.t("添加 App…", "Add App…"), systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text(L10n.t(
                "移除即从「打开方式」菜单消失，随时用「添加 App…」加回；系统没枚举到的终端 / 编辑器也从这里补。",
                "Removing an app takes it out of the Open With menu; use “Add App…” to bring any back — or to add editors and terminals the system misses."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } header: {
            Text(L10n.t("打开方式", "Open With"))
        }
    }

    @ViewBuilder
    private func openerRow(_ app: OpenerApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text(app.name)
            Spacer()
            Button {
                // 两本账一次清：extras 里的去 extras，发现来源的进 hidden。
                // 只清一边的话，「手动加过的又能被系统枚举到」的 App
                // 要点两次才消失。
                // 账本 key 是 id（变体带 # 后缀），不是 App 路径
                folders.removeOpenerExtra(appPath: app.id)
                folders.setOpenerHidden(true, appPath: app.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("从打开方式中移除", "Remove from Open With"))
        }
    }

    private func addOpenerApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default
            .urls(for: .applicationDirectory, in: .localDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            folders.addOpenerExtra(appPath: url.standardizedFileURL.path)
        }
    }
}

// MARK: - 搜索

/// ⌘E 搜索面板的设置。从「切换器」页拆出来（2026-09-26）：加了站内搜索列表后那一页
/// 一屏放不下。
private struct SearchPane: View {
    @ObservedObject var settings: AppSettings
    @State private var memoryCount = 0

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.tabSearch) {
                    Text(L10n.t("启用搜索面板", "Enable the search panel"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "输标题、网址或拼音，找浏览器标签、书签、历史记录、文件夹和应用。Tab 换范围，⌘↩ 展开对这一项的操作，按住 ⌘ 时用 1–\(kSearchQuickPickCount) 直接选。",
                    "Type a title, URL or pinyin to find tabs, bookmarks, history, folders and apps. Tab changes scope, ⌘↩ shows actions for the selected item, and ⌘1–\(kSearchQuickPickCount) picks a row."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("搜索面板", "Search panel"))
            }

            Section {
                HotkeyRow(label: L10n.t("浏览器里", "In a browser"),
                          config: $settings.searchHotkey, placeholder: "⌘ E")
                HotkeyRow(label: L10n.t("别的 App 里（搜所有浏览器）", "In any other app (all browsers)"),
                          config: $settings.globalSearchHotkey, placeholder: "⌥ Space")
                hotkeyNote("至少带一个 ⌘ / ⌃ / ⌥。Esc 取消录制。浏览器里那个会盖住网页自己的同名快捷键；别的 App 里那个在所有 App 里都生效。",
                           "Use at least one of ⌘ / ⌃ / ⌥. Esc cancels. The in-browser key overrides the page's own; the other one works in every app.")
            }
            .disabled(!settings.tabSearch)

            Section {
                Picker(L10n.t("浏览器里", "In a browser"), selection: $settings.allEmptyContent) {
                    ForEach(AppSettings.allEmptyChoices) { Text($0.label).tag($0) }
                }
                Picker(L10n.t("别的 App 里", "In any other app"), selection: $settings.globalEmptyContent) {
                    ForEach(AppSettings.globalEmptyChoices) { Text($0.label).tag($0) }
                }
            } header: {
                Text(L10n.t("「全部」没输入时显示", "“All” shows when empty"))
            }

            Section {
                ForEach(Array(settings.searchModeOrder.enumerated()), id: \.element) { index, mode in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { settings.searchModesEnabled.contains(mode) },
                            set: { on in
                                if on { settings.searchModesEnabled.insert(mode) }
                                else { settings.searchModesEnabled.remove(mode) }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Text(mode.label)
                        Spacer()
                        Button {
                            settings.searchModeOrder.swapAt(index, index - 1)
                        } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button {
                            settings.searchModeOrder.swapAt(index, index + 1)
                        } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == settings.searchModeOrder.count - 1)
                    }
                }
                Text(L10n.t("勾上的进循环。面板打开时是第一个，按 Tab 依次往下切，⇧Tab 往回。「文件夹」是状态栏收藏的那些，回车用上次的方式打开，⌘↩ 换一个；「应用」默认关，装了 Raycast 的用不上。用「别的 App 里」那个键打开时，「应用」排在「浏览器标签」前面。",
                            "Checked ones are in the cycle. The panel opens on the first; Tab moves down, ⇧Tab back up. Folders are your menu bar favorites — Enter opens with the last-used app, ⌘↩ picks another. Apps is off by default; Raycast users won't need it. Opened with the “In any other app” key, Apps comes before Browser tabs."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Tab 顺序", "Tab order"))
            }
            .disabled(!settings.tabSearch)

            Section {
                ForEach($settings.siteSearches) { $site in
                    siteSearchRow($site)
                }
                Button(L10n.t("添加站点…", "Add site…")) {
                    settings.siteSearches.append(SiteSearch(name: "", template: "https://"))
                }
                Text(L10n.t("「搜索」模式里列在搜索引擎后面的「在 X 搜索」。网址里的 %s 换成关键词。",
                            "The “Search X” rows shown under Search mode after the search engine. %s in the URL is replaced with the query."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("站内搜索", "Site search"))
            }
            .disabled(!settings.tabSearch)

            Section {
                HStack {
                    Text(L10n.t("同样的输入再搜时，上次选的那条排在前面；首页的「推荐」是你常选的；「最近使用」按你切换 App 的记录排。都只存在这台 Mac 上，清除时一起清掉。",
                                "Search the same thing again and what you picked last time comes first; Suggestions on the home list are what you pick often; Recent is ordered by the apps you switch to. All stored only on this Mac and cleared together."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("清除", "Clear")) {
                        SearchMemory.shared.clear()
                        // App 切换记录、首页推荐的账也是使用记录，一起清（AppCatalog、SuggestionStore 收通知清内存、删文件）
                        NotificationCenter.default.post(name: .clearUsageHistory, object: nil)
                        memoryCount = 0
                    }
                    .disabled(memoryCount == 0)
                }
            } header: {
                Text(L10n.t("搜索记忆", "Search memory"))
            }
            .onAppear { memoryCount = SearchMemory.shared.count + SuggestionStore.shared.count + AppCatalog.storedActivityCount() }

            // 不属于任何插件的命令（「打开方式…」）的关键词放这里；插件的命令在各自的插件页
            Section {
                CommandKeywordRow(command: PluginCommandInfo(id: "system.openWith",
                                                             title: L10n.t("打开方式…", "Open With…"),
                                                             symbol: "arrow.up.forward.app"))
            } header: {
                Text(L10n.t("命令", "Commands"))
            } footer: {
                CommandKeywordFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func siteSearchRow(_ site: Binding<SiteSearch>) -> some View {
        HStack(spacing: 8) {
            // 分组表单里 TextField 的第一个参数会被当成前置标签画出来，
            // 占位要走 prompt、标签隐藏
            TextField("", text: site.name, prompt: Text(L10n.t("名字", "Name")))
                .labelsHidden()
                .frame(width: 110)
            TextField("", text: site.template, prompt: Text("https://example.com/search?q=%s"))
                .labelsHidden()
            Button {
                settings.siteSearches.removeAll { $0.id == site.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("删除", "Delete"))
        }
    }
}

// MARK: - 快捷键录制行

/// 一行快捷键设置：标签 + 键位胶囊 + 圆形恢复钮。哪个功能的键就放在哪个功能的页里
///（2026-09-26 撤掉了集中的「快捷键」页）。
///
/// placeholder 是「没设置时胶囊里显示什么」，非空即表示清除后有兜底行为；
/// nil 表示清除即禁用。样式照 Raycast（2026-09-15 用户给的参考图）：键位是一颗
/// 贴着内容宽度的灰色胶囊，右边一颗圆形「恢复」钮；没设置时胶囊里用次级色写默认值。
private struct HotkeyRow: View {
    let label: String
    @Binding var config: HotkeyConfig?
    let placeholder: String?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let current = config?.displaySpaced
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording
                     ? L10n.t("按下快捷键…", "Press shortcut…")
                     : (current ?? placeholder ?? L10n.t("录制", "Record")))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(current != nil || recording ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.18)
                                            : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            if current != nil && !recording {
                Button { config = nil } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(placeholder == nil ? L10n.t("清除", "Clear")
                                         : L10n.t("恢复默认", "Reset to default"))
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc 取消
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            config = HotkeyConfig(keyCode: event.keyCode,
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

/// 录制行下面那句通用说明。
private func hotkeyNote(_ zh: L10nText, _ en: L10nText) -> some View {
    Text(L10n.t(zh, en))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
}

// MARK: - 插件

/// 插件图标块：彩色圆角方块 + 白色实心符号（同侧边栏、搜索面板的 ActionTile）。
private struct PluginTile: View {
    let plugin: Plugin
    var side: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(plugin.tint.gradient)
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: plugin.symbol)
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

extension Plugin {
    /// 「内置」「官方 · 1.0.0」
    var originLabel: String {
        switch origin {
        case .builtin: return L10n.t("内置", "Built-in")
        case .official(let version): return L10n.t("官方", "Official") + " · " + version
        }
    }
}

/// 「内置」「官方 · 版本」小标签。
private struct PluginOriginBadge: View {
    let origin: PluginOrigin

    var body: some View {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
    }

    private var label: String {
        switch origin {
        case .builtin: return L10n.t("内置", "Built-in")
        case .official(let version): return L10n.t("官方", "Official") + " · " + version
        }
    }
}

/// 插件总览：装了哪些，各自开关。每个插件的详细设置在侧边栏它自己那一行。
private struct PluginsPane: View {
    @ObservedObject var registry: PluginRegistry
    @ObservedObject private var store = PluginStore.shared
    /// 等确认卸载的插件 id
    @State private var removing: String?

    private var builtins: [Plugin] { registry.plugins.filter { $0.origin == .builtin } }
    private var installed: [Plugin] { registry.plugins.filter { $0.origin != .builtin } }
    /// 商店里有、还没装的
    private var available: [StoreEntry] { store.entries.filter { registry.plugin($0.id) == nil } }
    private var updates: [StoreEntry] { installed.compactMap { store.update(for: $0) } }

    var body: some View {
        Form {
            Section {
                ForEach(builtins, id: \.id) { plugin in
                    PluginListRow(symbol: plugin.symbol, tint: plugin.tint, title: plugin.title,
                                  badge: L10n.t("内置", "Built-in"), summary: plugin.summary) {
                        enabledToggle(plugin)
                    }
                }
            } header: {
                Text(L10n.t("内置", "Built-in"))
            } footer: {
                footnote(L10n.t("跟着 TabFlick 一起更新，不能卸载，只能关掉。关掉的插件不再出现在搜索面板和菜单栏里。",
                                "Updated with TabFlick. They can't be removed, only turned off. A plugin that's off no longer shows up in the search panel or the menu bar."))
            }

            Section {
                if installed.isEmpty {
                    footnote(L10n.t("还没有装插件，在下面「可安装」里挑。", "No plugins installed yet. Pick one under Available."))
                }
                ForEach(installed, id: \.id) { plugin in
                    let update = store.update(for: plugin)
                    PluginListRow(symbol: plugin.symbol, tint: plugin.tint, title: plugin.title,
                                  badge: plugin.originLabel, summary: plugin.summary) {
                        if let update {
                            if store.busy.contains(plugin.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(L10n.t("更新到 \(update.version)", "Update to \(update.version)")) { store.install(update) }
                                    .disabled(PluginStore.needsNewerApp(update) != nil)
                            }
                        }
                        enabledToggle(plugin)
                        Button {
                            removing = plugin.id
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t("卸载", "Remove"))
                    }
                }
            } header: {
                HStack {
                    Text(L10n.t("已安装", "Installed"))
                    Spacer()
                    if updates.count > 1 {
                        Button(L10n.t("全部更新", "Update All")) { updates.forEach(store.install) }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                switch store.status {
                case .idle, .loading where store.entries.isEmpty:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        footnote(L10n.t("正在取插件列表…", "Loading the plugin list…"))
                    }
                case .failed(let message) where store.entries.isEmpty:
                    footnote(L10n.t("取不到插件列表：\(message)", "Couldn't load the plugin list: \(message)"))
                default:
                    if available.isEmpty {
                        footnote(L10n.t("商店里的插件都装上了。", "Every plugin in the store is installed."))
                    }
                    ForEach(available) { entry in
                        storeRow(entry)
                    }
                }
            } header: {
                HStack {
                    Text(L10n.t("可安装", "Available"))
                    Spacer()
                    if case .loaded(let at) = store.status {
                        Text(L10n.t("检查于 \(Self.time(at))", "Checked at \(Self.time(at))"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button(L10n.t("刷新", "Refresh")) { store.refresh(force: true) }
                        .controlSize(.small)
                        .disabled(store.status == .loading)
                }
            } footer: {
                footnote(L10n.t("只有官方插件。装之前写明它会访问哪些网站，插件联网出了这个范围一律拦下。",
                                "Official plugins only. Each one lists the sites it connects to, and anything else is blocked."))
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
        .alert(L10n.t("卸载「\(removingTitle)」？", "Remove “\(removingTitle)”?"),
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            // 存过数据（自选、收藏的城市）才问留不留（用户 2026-11-06）；默认留着
            if let id = removing, PluginStore.hasData(id) {
                Button(L10n.t("卸载，保留数据", "Remove, Keep Data")) { uninstall(keepData: true) }
                Button(L10n.t("卸载并删除数据", "Remove and Delete Data"), role: .destructive) { uninstall(keepData: false) }
            } else {
                Button(L10n.t("卸载", "Remove"), role: .destructive) { uninstall(keepData: true) }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) { removing = nil }
        } message: {
            if let id = removing, PluginStore.hasData(id) {
                Text(L10n.t("插件存的数据（比如自选、收藏的城市）保留的话，重装回来还在。",
                            "If you keep its data (watchlists, saved cities), it comes back when you reinstall."))
            }
        }
    }

    private var removingTitle: String { removing.flatMap { registry.plugin($0)?.title } ?? "" }

    private func uninstall(keepData: Bool) {
        if let id = removing, let plugin = registry.plugin(id) { store.uninstall(plugin, keepData: keepData) }
        removing = nil
    }

    private func storeRow(_ entry: StoreEntry) -> some View {
        let language = L10n.current.rawValue
        let hosts = entry.hosts.isEmpty
            ? L10n.t("不联网", "Works offline")
            : L10n.t("会访问 \(entry.hosts.joined(separator: L10n.listSeparator))", "Connects to \(entry.hosts.joined(separator: ", "))")
        return PluginListRow(symbol: entry.symbol, tint: PluginTint.color(entry.tint),
                             title: PluginManifest.pick(entry.names, language: language) ?? entry.id,
                             badge: entry.version,
                             summary: PluginManifest.pick(entry.summaries, language: language) ?? "",
                             detail: hosts) {
            if let need = PluginStore.needsNewerApp(entry) {
                Text(L10n.t("需要 TabFlick \(need)", "Needs TabFlick \(need)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if store.busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.t("安装", "Install")) { store.install(entry) }
            }
        }
    }

    private func enabledToggle(_ plugin: Plugin) -> some View {
        Toggle("", isOn: Binding(get: { registry.isEnabled(plugin.id) }, set: { registry.setEnabled(plugin.id, $0) }))
            .toggleStyle(.switch)
            .labelsHidden()
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 插件列表的一行：图标块、名字 + 小标签、说明（和一行灰字），右边放按钮和开关。
private struct PluginListRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let badge: String
    let summary: String
    var detail: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            PluginSymbolTile(symbol: symbol, tint: tint, side: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Text(badge)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { trailing() }
        }
        .padding(.vertical, 2)
    }
}

/// 一个插件自己的页：开关、它在搜索面板里加了什么、菜单栏（有菜单的插件才有）。
private struct PluginPane: View {
    @ObservedObject var registry: PluginRegistry
    let plugin: Plugin

    private var enabled: Bool { registry.isEnabled(plugin.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    PluginTile(plugin: plugin, side: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(plugin.title).font(.system(size: 15, weight: .semibold))
                            PluginOriginBadge(origin: plugin.origin)
                        }
                        Text(plugin.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                // 开关只在「插件」总览页（这里再放一个是重复，用户 2026-11-06）；关着时说一句去哪里开
                if !enabled {
                    Text(L10n.t("已关闭。在「插件」页打开后这里的设置才生效。",
                                "Turned off. Turn it on in Plugins for these settings to take effect."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !plugin.panelCommands.isEmpty {
                Section {
                    ForEach(plugin.panelCommands) { command in
                        CommandKeywordRow(command: command)
                    }
                } header: {
                    Text(L10n.t("在搜索面板里", "In the Search Panel"))
                } footer: {
                    CommandKeywordFooter()
                }
                .disabled(!enabled)
            }

            // 插件自己声明的设置项（V2EX 看热议还是最新）
            if let choices = (plugin as? JSPlugin)?.manifest.choices, !choices.isEmpty {
                Section {
                    ForEach(choices, id: \.key) { choice in
                        PluginChoicePicker(pluginID: plugin.id, choice: choice)
                    }
                }
                .disabled(!enabled)
            }

            // 要用户填的（和风天气的 API Host、Key）+ 去哪拿的链接
            if let manifest = (plugin as? JSPlugin)?.manifest, !manifest.inputs.isEmpty {
                Section {
                    ForEach(manifest.inputs, id: \.key) { input in
                        PluginInputField(pluginID: plugin.id, input: input)
                    }
                } footer: {
                    PluginInputFooter(inputs: manifest.inputs, links: manifest.links)
                }
                .disabled(!enabled)
            }

            // 只给声明了要它的插件（股票）：V2EX 这类没有涨跌的不该出现（用户 2026-11-06 截图）
            if (plugin as? JSPlugin)?.manifest.usesUpDownColors == true {
                Section {
                    PluginColorPicker()
                }
                .disabled(!enabled)
            }

            if plugin.menu != nil {
                Section {
                    Toggle(isOn: Binding(get: { registry.wantsMenu(plugin.id) },
                                         set: { registry.setWantsMenu(plugin.id, $0) })) {
                        Text(L10n.t("在菜单栏显示", "Show in Menu Bar"))
                    }
                    .toggleStyle(.switch)

                    if plugin is ProcessesPlugin {
                        ProcessMenuOptions()
                            .disabled(!registry.wantsMenu(plugin.id))
                    }

                    Text(L10n.t("状态栏菜单里多一行「\(plugin.title)」，展开看内容。",
                                "Adds “\(plugin.title)” to the menu bar menu; hover it to see the contents."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.t("菜单栏", "Menu Bar"))
                }
                .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
    }
}

/// 一条命令 + 它的关键词输入框。占位就是命令名：不填就按命令名搜（用户 2026-11-06 定的默认）。
private struct CommandKeywordRow: View {
    let command: PluginCommandInfo
    @ObservedObject private var store = CommandKeywordStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(command.title)
                .lineLimit(1)
            Spacer(minLength: 12)
            // 分组表单里 TextField 的第一个参数会被画成前置标签，占位要走 prompt + labelsHidden
            TextField("", text: Binding(get: { store.text(for: command.id) },
                                        set: { store.setText($0, for: command.id) }),
                      prompt: Text(command.title.replacingOccurrences(of: "…", with: "")))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

private struct CommandKeywordFooter: View {
    var body: some View {
        Text(L10n.t("打出关键词，这条命令排在最前，回车就执行。多个关键词用空格分开，不填就按命令名搜。",
                    "Type a keyword and that command comes first; ↩ runs it. Separate keywords with spaces. Leave it empty to search by the command's name."))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// 插件声明的一个设置项，画成下拉框。值存 `PluginSettingsStore`，插件下一次调用就读到新的。
private struct PluginChoicePicker: View {
    let pluginID: String
    let choice: PluginChoice
    @State private var value = ""

    var body: some View {
        let language = L10n.current.rawValue
        Picker(PluginManifest.pick(choice.titles, language: language) ?? choice.key,
               selection: Binding(get: { value.isEmpty ? PluginSettingsStore.value(pluginID, choice) : value },
                                  set: { value = $0; PluginSettingsStore.set(pluginID, choice.key, $0) })) {
            ForEach(choice.options, id: \.value) { option in
                Text(PluginManifest.pick(option.titles, language: language) ?? option.value).tag(option.value)
            }
        }
    }
}

/// 插件要用户填的一段文字，`secret` 的画成密码框。边打边存（`PluginSettingsStore`），插件下一次调用就读到新的。
private struct PluginInputField: View {
    let pluginID: String
    let input: PluginInput
    @State private var text: String?

    var body: some View {
        let language = L10n.current.rawValue
        let title = PluginManifest.pick(input.titles, language: language) ?? input.key
        let prompt = PluginManifest.pick(input.placeholders, language: language).map { Text($0) }
        let binding = Binding(get: { text ?? PluginSettingsStore.text(pluginID, input) },
                              set: { value in
                                  let clipped = String(value.prefix(PluginInput.maxLength))
                                  text = clipped
                                  PluginSettingsStore.set(pluginID, input.key, clipped)
                              })
        if input.secret {
            SecureField(title, text: binding, prompt: prompt)
        } else {
            TextField(title, text: binding, prompt: prompt)
        }
    }
}

/// 输入框下面：manifest 给的说明 + 链接（去哪拿 Key）。
private struct PluginInputFooter: View {
    let inputs: [PluginInput]
    let links: [PluginLink]

    var body: some View {
        let language = L10n.current.rawValue
        VStack(alignment: .leading, spacing: 4) {
            ForEach(inputs.compactMap { PluginManifest.pick($0.notes, language: language) }, id: \.self) { note in
                Text(note)
            }
            if !links.isEmpty {
                HStack(spacing: 12) {
                    ForEach(links, id: \.url) { link in
                        Link(PluginManifest.pick(link.titles, language: language) ?? link.url.absoluteString, destination: link.url)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// 涨跌用什么颜色（菜单和搜索面板共用，`PluginColors`）。A 股习惯红涨绿跌，美股反过来。
private struct PluginColorPicker: View {
    @AppStorage(PluginColors.key) private var upIsRed = true

    var body: some View {
        Picker(L10n.t("涨跌颜色", "Up and down colors"), selection: $upIsRed) {
            Text(L10n.t("红涨绿跌", "Red up, green down")).tag(true)
            Text(L10n.t("绿涨红跌", "Green up, red down")).tag(false)
        }
    }
}

/// 「结束进程」放进菜单栏时列几个、按什么排。菜单每次打开时现读（`ProcessMenu.count` / `.sort`）。
private struct ProcessMenuOptions: View {
    @AppStorage(ProcessMenu.countKey) private var count = ProcessMenu.defaultCount
    @AppStorage(ProcessMenu.sortKey) private var sort = ProcessSort.cpu.rawValue

    var body: some View {
        Picker(L10n.t("列几个", "Show"), selection: $count) {
            ForEach(ProcessMenu.countChoices, id: \.self) { n in
                Text(L10n.t("\(n) 个", "\(n)")).tag(n)
            }
        }
        Picker(L10n.t("排序", "Sort by"), selection: $sort) {
            ForEach(ProcessSort.allCases, id: \.rawValue) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
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

                // 升级后那次弹窗如果没网就跳过了，这里是补看的入口
                Button(L10n.t("本版更新内容", "What's New")) {
                    ReleaseNotes.presentLatest(currentVersion: updates.currentVersion)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            Text(L10n.t(
                "按最近使用顺序切换标签，外加标签管理和置顶常驻。",
                "MRU tab switching, plus tab management and pins that persist."
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
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 内容区

/// 右边的内容区：按侧边栏选中的页挑页面。会变的数据（浏览器状态）从 `context` 读，变了只重画。
private struct SettingsDetail: View {
    @ObservedObject var nav: SettingsNavigationModel
    @ObservedObject var context: SettingsContext
    let settings: AppSettings
    let updates: UpdateChecker
    let folders: FavoriteFolderStore
    let canInstallExtension: Bool
    let onInstallExtension: (String) -> Void
    let onUpdateExtension: (String) -> Void
    let onOpenExtensionPage: (String) -> Void

    var body: some View {
        page
            // 换语言整页重建：文案是渲染时取的
            .id(context.languageRevision)
            // 去掉标题栏底色和那条分隔线，内容直接从顶上开始，同系统设置
            .toolbarBackground(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var page: some View {
        switch nav.selection {
        case .general: GeneralPane(settings: settings)
        case .switcher: SwitcherPane(settings: settings)
        case .search: SearchPane(settings: settings)
        case .tabs: TabManagementPane(settings: settings)
        case .folders: FoldersPane(folders: folders, settings: settings)
        case .openWith: OpenWithPane(folders: folders)
        case .browsers:
            BrowserPane(browsers: context.browserStatuses, canInstall: canInstallExtension,
                        onInstall: onInstallExtension, onUpdate: onUpdateExtension,
                        onOpenExtensions: onOpenExtensionPage)
        case .plugins: PluginsPane(registry: PluginRegistry.shared)
        case .plugin(let id):
            if let plugin = PluginRegistry.shared.plugin(id) {
                PluginPane(registry: PluginRegistry.shared, plugin: plugin)
            } else {
                // 刚卸载的插件：页面没了，显示总览
                PluginsPane(registry: PluginRegistry.shared)
            }
        case .about: AboutPane(updates: updates)
        }
    }
}

// MARK: - 窗口

// 窗口标题跟着当前页走（同系统设置、PasteMemo）。标题要设在 contentViewController 上：
// 窗口的 title 绑定在 contentViewController.title 上，只写 window.title 会被绑定盖回去。

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let settings: AppSettings
    private let updates: UpdateChecker
    private let folders: FavoriteFolderStore
    private var window: NSWindow?
    private var split: SettingsSplitViewController?
    private let nav = SettingsNavigationModel()
    private let context = SettingsContext()

    /// 浏览器页的「安装扩展」「更新」按钮，main.swift 接。canInstallExtension = app 里带着扩展。
    var canInstallExtension = false
    var onInstallExtension: ((String) -> Void)?
    var onUpdateExtension: ((String) -> Void)?
    var onOpenExtensionPage: ((String) -> Void)?

    var isShowing: Bool { window?.isVisible == true }
    /// 打开窗口时现取浏览器状态（main.swift 接 controller.browserStatuses）。
    var browserStatusProvider: (() -> [MRUController.BrowserStatus])?

    init(settings: AppSettings, updates: UpdateChecker, folders: FavoriteFolderStore) {
        self.settings = settings
        self.updates = updates
        self.folders = folders
        super.init()
        nav.onLocationChange = { [weak self] in self?.syncTitle() }
    }

    func setBrowserStatuses(_ statuses: [MRUController.BrowserStatus]) {
        guard statuses != context.browserStatuses else { return }
        context.browserStatuses = statuses
    }

    func setConnected(_ value: Bool) {
        guard context.connected != value else { return }
        context.connected = value
    }

    /// 语言变了：侧边栏和内容区整个重建（文案是渲染时取的），侧边栏宽度、窗口标题、箭头提示跟着换。
    func reloadForLanguageChange() {
        context.languageRevision += 1
        split?.setSidebarWidth(kSettingsSidebarWidth)
        split?.syncNavigationState()
        syncTitle()
    }

    private func syncTitle() {
        let title = nav.selection.title
        split?.title = title
        window?.title = title
    }

    /// 打开并翻到某一页（插件「去填 Key」那一行用）。
    func show(page: SettingsPage) {
        show()
        nav.selection = page
    }

    func show() {
        // 打开窗口时临时变成普通 app：出现 Dock 图标、能用 ⌘⇥ 切回来。
        // 关闭后由 windowWillClose 收回 .accessory。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        settings.refreshLaunchAtLogin()   // 用户可能刚在系统设置里改过
        // 浏览器状态现取一份：平时靠连接事件推过来，app 启动后浏览器一直没开过就一次都没推，列表是空的
        if let provider = browserStatusProvider { setBrowserStatuses(provider()) }

        if window == nil {
            let detail = SettingsDetail(
                nav: nav, context: context, settings: settings, updates: updates, folders: folders,
                canInstallExtension: canInstallExtension,
                onInstallExtension: { [weak self] in self?.onInstallExtension?($0) },
                onUpdateExtension: { [weak self] in self?.onUpdateExtension?($0) },
                onOpenExtensionPage: { [weak self] in self?.onOpenExtensionPage?($0) })
            let sidebarWidth = kSettingsSidebarWidth
            let controller = SettingsSplitViewController(
                nav: nav, sidebar: SettingsSidebar(nav: nav, context: context), detail: detail,
                sidebarWidth: sidebarWidth)
            split = controller

            // 内容区 600 宽：原来各页是 560，「文件夹管理」要放完整路径
            let size = NSSize(width: sidebarWidth + 600, height: 600)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = controller
            w.setContentSize(size)
            w.contentMinSize = NSSize(width: sidebarWidth + 460, height: 420)
            // 侧边栏通顶到标题栏下面
            w.styleMask.insert(.fullSizeContentView)
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
            syncTitle()
            controller.installToolbar(on: w)
            w.setFrameAutosaveName("SettingsWindow")
            if !w.setFrameUsingName("SettingsWindow") { w.center() }
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
