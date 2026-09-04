import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 所有设置 pane 的统一宽度。**必须全体一致**：宽度不一的话切 tab 时窗口
/// 会跟着伸缩跳动（2026-09-02 用户反馈「跳来跳去体验不好」）。取 560 是
/// 因为「文件夹管理」要放完整路径，460 截断太狠 —— 就全体跟它对齐。
private let kSettingsPaneWidth: CGFloat = 560

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
        .frame(width: kSettingsPaneWidth)
    }
}

// MARK: - 切换器

private struct SwitcherPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
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

                Text(L10n.t(
                    "列出所有浏览器的标签，按浏览器分组。默认沿用切换器快捷键，只在浏览器之外唤出；想在浏览器里也能用，去「快捷键」单独给它设一个。",
                    "Lists tabs from every browser, grouped by browser. It reuses the switcher shortcut and only opens outside a browser — give it its own key under Shortcuts to use it anywhere."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("全局切换器", "Global switcher"))
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }
}

// MARK: - 浏览器

/// 每个已安装的 Chromium 系浏览器一行，显示连接与扩展版本状态。
/// 这是多浏览器状态的唯一完整视图 —— 连接是按浏览器分账的。
private struct BrowserPane: View {
    let browsers: [MRUController.BrowserStatus]

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
                    "未连接说明这个浏览器没装扩展，或者没开着。扩展要每个浏览器装一次。",
                    "Not connected means no extension there, or the browser isn't running. Install it once per browser."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(L10n.t("下载扩展", "Download Extension")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/lifedever/TabFlick/releases/latest/download/TabFlick-Extension.zip")!)
                    }
                    Link(L10n.t("安装说明", "Install Guide"),
                         destination: URL(string: "https://www.lifedever.com/TabFlick/install-extension.html")!)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    @ViewBuilder
    private func browserRow(_ browser: MRUController.BrowserStatus) -> some View {
        HStack(spacing: 8) {
            appIcon(browser.bundleID)
            Text(browser.name)
            Spacer()
            if !browser.connected {
                Label(L10n.t("未连接", "Not connected"), systemImage: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if browser.needsUpdate {
                Label(L10n.t("已连接 · 扩展 v\(browser.extVersion ?? "?") 需更新到 v\(MRUController.requiredExtensionVersion) 以上",
                             "Connected · extension v\(browser.extVersion ?? "?"), needs v\(MRUController.requiredExtensionVersion)+"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
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
                    Text(L10n.t("还没有置顶。在浏览器里置顶任意标签即可。",
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
                    "和浏览器双向同步：置顶即收藏，取消置顶即移除，⌘W 关掉不算。重启浏览器会自动恢复，停在你最后看的那一页。",
                    "Syncs both ways: pinning adds, unpinning removes, ⌘W doesn't. Restored on restart, at the page you last viewed."
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
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    private var hasMultipleBrowsers: Bool {
        Set(settings.favorites.map(\.browser)).count > 1
    }

    private func browserName(_ bundleID: String) -> String {
        BrowserSupport.displayName(bundleID)
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
                Text((hasMultipleBrowsers ? browserName(fav.browser) + " · " : "")
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

    var body: some View {
        Form {
            Section {
                if folders.entries.isEmpty {
                    Text(L10n.t("还没有收藏。从状态栏菜单点「添加文件夹…」，或在 Finder 打开目录后点「收藏当前 Finder 目录」。",
                                "Nothing yet. Use “Add Folder…” in the menu bar, or open a folder in Finder and use “Add Current Finder Folder”."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if folders.entries.count > 6 {
                    // 收藏多时限高滚动 —— 设置窗口按内容自适应高度，
                    // 列表无限增长会把窗口顶出屏幕（同置顶标签列表）。
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
                    .frame(height: 220)
                } else {
                    ForEach(folders.entries, id: \.path) { folder in
                        folderRow(folder)
                    }
                }

                Text(L10n.t(
                    "状态栏菜单按最近打开排序，平铺前 5 个，其余收在「更多」里。",
                    "The menu lists the 5 most recently opened; the rest live under More."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(folders.entries.isEmpty
                     ? L10n.t("收藏的文件夹", "Favorite Folders")
                     : L10n.t("收藏的文件夹 · \(folders.entries.count) 个",
                              "Favorite Folders · \(folders.entries.count)"))
            }

            openWithSection
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    /// 「打开方式」管理：只列当前生效的，行尾垃圾桶移除，「添加 App…」
    /// 补回或新增 —— 和上面收藏列表同一副面孔（2026-09-02 用户点名
    /// 不要开关，要加减）。列表组装和菜单共用 OpenerCatalog。
    @ViewBuilder
    private var openWithSection: some View {
        let apps = OpenerCatalog.candidates(extras: folders.openerExtras)
            .filter { !folders.openerHidden.contains($0.id) }
        Section {
            if apps.count > 6 {
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
                .frame(height: 190)
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

// MARK: - 快捷键

private struct HotkeyPane: View {
    @ObservedObject var settings: AppSettings

    private enum Target { case switcher, global, pin }
    @State private var recording: Target?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                row(label: L10n.t("唤出切换器（按住修饰键循环）", "Open the switcher (hold to cycle)"),
                    target: .switcher,
                    current: settings.switcherHotkey?.display,
                    placeholder: L10n.t("⌃⇥（默认）", "⌃⇥ (default)"),
                    clear: { settings.switcherHotkey = nil })

                row(label: L10n.t("唤出全局切换器（所有浏览器）", "Open the global switcher (all browsers)"),
                    target: .global,
                    current: settings.globalHotkey?.display,
                    placeholder: L10n.t("同切换器键", "Same as switcher"),
                    clear: { settings.globalHotkey = nil })
                    .disabled(!settings.globalSwitcher)

                row(label: L10n.t("置顶 / 取消置顶当前标签", "Pin / unpin current tab"),
                    target: .pin,
                    current: settings.pinHotkey?.display,
                    placeholder: nil,
                    clear: { settings.pinHotkey = nil })

                Text(L10n.t(
                    "至少带一个 ⌘ / ⌃ / ⌥，⇧ 留给反向切换。Esc 取消录制。\n除全局切换器外都只在浏览器前台生效。别撞上 ⌘T、⌘D，或终端和编辑器的 ⌃⇥。",
                    "Use at least one of ⌘ / ⌃ / ⌥; ⇧ is reserved for reverse. Esc cancels.\nAll but the global switcher work only while a browser is frontmost. Watch out for ⌘T, ⌘D, and the ⌃⇥ in terminals and editors."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                if !settings.globalSwitcher {
                    Text(L10n.t("全局切换器还没开，去「切换器」里打开。",
                                "The global switcher is off — turn it on under Switcher."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("快捷键", "Shortcuts"))
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
        .onDisappear { stopRecording() }
    }

    /// placeholder 是「没设置时按钮上显示什么」，非空即表示清除后有兜底行为；
    /// nil 表示清除即禁用。
    @ViewBuilder
    private func row(label: String, target: Target,
                     current: String?, placeholder: String?,
                     clear: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button {
                recording == target ? stopRecording() : startRecording(target)
            } label: {
                Text(recording == target
                     ? L10n.t("按下快捷键…", "Press shortcut…")
                     : (current ?? placeholder ?? L10n.t("点击录制", "Record")))
                    .frame(minWidth: 110)
            }
            if current != nil && recording != target {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(placeholder == nil ? L10n.t("清除", "Clear")
                                         : L10n.t("恢复默认", "Reset to default"))
            }
        }
    }

    private func startRecording(_ target: Target) {
        stopRecording()
        recording = target
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc 取消
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            let config = HotkeyConfig(keyCode: event.keyCode,
                                      modifiers: mods.rawValue,
                                      character: chars.lowercased())
            switch target {
            case .switcher: settings.switcherHotkey = config
            case .global:   settings.globalHotkey = config
            case .pin:      settings.pinHotkey = config
            }
            return nil   // 这次按键被录制吃掉，不下发
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
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
        .frame(width: kSettingsPaneWidth)
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
    private let folders: FavoriteFolderStore
    private var window: NSWindow?
    private var connected = false

    private var generalHost: NSHostingController<GeneralPane>?
    private var switcherHost: NSHostingController<SwitcherPane>?
    private var tabManagementHost: NSHostingController<TabManagementPane>?
    private var foldersHost: NSHostingController<FoldersPane>?
    private var browserHost: NSHostingController<BrowserPane>?
    private var hotkeyHost: NSHostingController<HotkeyPane>?
    private var aboutHost: NSHostingController<AboutPane>?

    private var browserStatuses: [MRUController.BrowserStatus] = []

    func setBrowserStatuses(_ statuses: [MRUController.BrowserStatus]) {
        guard statuses != browserStatuses else { return }
        browserStatuses = statuses
        refreshContentIfVisible()
    }
    private var tabController: NSTabViewController?

    init(settings: AppSettings, updates: UpdateChecker, folders: FavoriteFolderStore) {
        self.settings = settings
        self.updates = updates
        self.folders = folders
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
         L10n.t("文件夹管理", "Folders"),
         L10n.t("浏览器", "Browsers"),
         L10n.t("快捷键", "Shortcuts"),
         L10n.t("关于", "About")]
    }

    private func refreshContentIfVisible() {
        guard let window, window.isVisible else { return }
        generalHost?.rootView = GeneralPane(settings: settings)
        switcherHost?.rootView = SwitcherPane(settings: settings)
        tabManagementHost?.rootView = TabManagementPane(settings: settings)
        foldersHost?.rootView = FoldersPane(folders: folders)
        browserHost?.rootView = BrowserPane(browsers: browserStatuses)
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
            let switcher = NSHostingController(rootView: SwitcherPane(settings: settings))
            let tabManagement = NSHostingController(rootView: TabManagementPane(settings: settings))
            let foldersPane = NSHostingController(rootView: FoldersPane(folders: folders))
            let browser = NSHostingController(rootView: BrowserPane(browsers: browserStatuses))
            let hotkey = NSHostingController(rootView: HotkeyPane(settings: settings))
            let about = NSHostingController(rootView: AboutPane(updates: updates))
            // 让 preferredContentSize 跟随 SwiftUI 内容：NSTabViewController
            // 切 tab 时按它做窗口尺寸动画（顶边锚定是 AppKit 原生行为）
            general.sizingOptions = [.preferredContentSize]
            switcher.sizingOptions = [.preferredContentSize]
            tabManagement.sizingOptions = [.preferredContentSize]
            foldersPane.sizingOptions = [.preferredContentSize]
            browser.sizingOptions = [.preferredContentSize]
            hotkey.sizingOptions = [.preferredContentSize]
            about.sizingOptions = [.preferredContentSize]
            generalHost = general
            switcherHost = switcher
            tabManagementHost = tabManagement
            foldersHost = foldersPane
            browserHost = browser
            hotkeyHost = hotkey
            aboutHost = about

            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let symbols = ["gearshape", "rectangle.on.rectangle.angled", "rectangle.stack", "folder", "globe", "command", "info.circle"]
            for (index, controller) in ([general, switcher, tabManagement, foldersPane, browser, hotkey, about] as [NSViewController]).enumerated() {
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
