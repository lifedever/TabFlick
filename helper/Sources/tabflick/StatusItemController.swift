import AppKit

/// 菜单栏图标与菜单。
///
/// TabFlick 是 `LSUIElement`，没有 Dock 图标也没有窗口 —— 菜单栏是它唯一
/// 可见的部分，也是「它到底还活着吗」的唯一答案。所以状态行必须如实反映
/// 扩展的连接情况，而不只是摆个图标。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// 浏览器行（每个已连接浏览器一行，各带自己的标签子菜单）。
    /// 每次菜单展开时现拆现建（menuNeedsUpdate），不做增量维护 ——
    /// 标签随时在变，缓存一份反而要操心失效。
    private var browserItems: [NSMenuItem] = []

    /// 浏览器行的数据源（活动浏览器排最前）。
    var menuBrowsersProvider: (() -> [MRUController.MenuBrowser])?
    /// 点了某浏览器子菜单里的标签。参数 (tab.id, 浏览器 bundle id)。
    var onPickTabInBrowser: ((Int, String) -> Void)?
    /// 点了「最近关闭」里的一条。参数 (ClosedTab.id, 浏览器 bundle id)。
    var onReopenClosedTab: ((String, String) -> Void)?
    /// 清空某浏览器的已关闭记录。参数是浏览器 bundle id。
    var onClearClosedTabs: ((String) -> Void)?

    /// 「收藏当前标签」菜单项。标题/图标随当前标签的收藏状态切换。
    private let favoriteItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// 当前标签是否已收藏；nil = 没有当前标签（未连接），菜单项置灰。
    var favoriteState: (() -> Bool?)?
    /// 点了「收藏 / 取消收藏当前标签」。
    var onToggleFavorite: (() -> Void)?
    /// 置顶快捷键（菜单项右侧显示用）。nil = 未设置，不显示。
    var pinHotkeyProvider: (() -> (key: String, modifiers: NSEvent.ModifierFlags)?)?

    /// 「收藏的文件夹」区。文件夹行每次展开时现拆现建（同浏览器行），
    /// 插在 sepAfterPin 下方。「收藏当前 Finder 目录」和「置顶当前标签」
    /// 共用上下文动作槽位（互斥显示）。
    private var folderItems: [NSMenuItem] = []
    private let addFinderFolderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// 动作槽前后的两道分隔线。动作项按前台上下文显隐后，相邻的分隔线
    /// 会叠在一起，得跟着收敛（见 menuNeedsUpdate）。每次 buildMenu
    /// 重建新实例，不跨菜单复用；sepAfterPin 兼任文件夹列表的插入锚点。
    private var sepAfterStatus = NSMenuItem.separator()
    private var sepAfterPin = NSMenuItem.separator()

    /// 收藏的文件夹列表数据源。
    var favoriteFoldersProvider: (() -> [FavoriteFolder])?
    /// 点了「收藏当前 Finder 目录」。
    var onAddFinderFolder: (() -> Void)?
    /// 点了某文件夹的「取消收藏」。参数是标准化路径。
    var onRemoveFolder: ((String) -> Void)?
    /// 某文件夹刚被某个 App 打开（记录最近使用：平铺区按文件夹的、
    /// 「打开方式」按 App 的）。参数是 (标准化路径, App URL)。
    var onFolderOpened: ((String, URL) -> Void)?
    /// 「打开方式」各 App 的最近点击时刻（key = App 标准化路径，排序用）。
    var openerHistoryProvider: (() -> [String: Double])?

    /// 「扩展需要更新」警告项。文案由 provider 给，nil = 隐藏。
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var extensionWarning: (() -> String?)?
    var onExtensionWarningClick: (() -> Void)?

    /// 打开 app 的设置窗口。
    var onOpenSettings: (() -> Void)?
    /// 未授权状态下点「授权」。
    var onRequestAuthorization: (() -> Void)?

    /// 未授权模式：菜单里只留授权入口和退出。
    ///
    /// 关键是这个入口必须在**菜单**里而不是窗口里 —— PermissionFlow 的浮层只在
    /// 系统设置是前台应用时可见，任何属于我们自己的窗口都会把它挤掉。菜单点完
    /// 就收起，不占前台，这正是 PasteMemo 那边一直好用的原因。
    private var unauthorized = false

    func showUnauthorized() {
        unauthorized = true
        statusLine.submenu = nil
        buildMenu()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                accessibilityDescription: "TabFlick")
            image?.isTemplate = true
            button.image = image
            button.alphaValue = 1.0
        }
        statusLine.title = L10n.t("未授权 —— 需要「辅助功能」权限",
                                  "Not authorized — Accessibility permission required")
        statusLine.image = Self.symbol("exclamationmark.triangle")
    }
    var onCheckForUpdates: (() -> Void)?

    private var connected = false
    private var lastTabCount = 0
    private var lastBrowserName: String?

    override init() {
        super.init()
        buildMenu()
        render(connected: false, tabCount: 0, browserName: nil)
    }

    // MARK: - 菜单

    private func buildMenu() {
        // statusLine / favoriteItem 是复用的存储属性，而 NSMenuItem 同一时刻
        // 只能属于一个菜单 —— 不先从旧菜单摘下来，第二次 buildMenu（init 后的
        // showUnauthorized、或语言切换的 rebuildMenu）会在 insertItem 处抛
        // NSInternalInconsistencyException 直接崩掉。
        statusLine.menu?.removeItem(statusLine)
        favoriteItem.menu?.removeItem(favoriteItem)
        warningItem.menu?.removeItem(warningItem)
        addFinderFolderItem.menu?.removeItem(addFinderFolderItem)

        let menu = NSMenu()
        // 自动启用会把「子菜单还是空的」的状态行判成禁用（子菜单在展开时才
        // 填充，父项灰着就永远展不开 —— 鸡生蛋死锁）。改手动管理：状态行
        // 的可用性跟随子菜单挂载（见 render），其余动作项默认可用。
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // 扩展版本警告（橙色），menuNeedsUpdate 时按实际状态显隐
        warningItem.target = self
        warningItem.action = #selector(warningClicked)
        warningItem.isHidden = true
        menu.addItem(warningItem)

        sepAfterStatus = .separator()
        menu.addItem(sepAfterStatus)

        // 菜单项图标要么全有要么全无 —— 系统会给个别标准项（如「设置」）
        // 自动配图标，其余项没有就参差不齐，所以统一显式给全。
        if unauthorized {
            let grant = NSMenuItem(title: L10n.t("授权 TabFlick…", "Authorize TabFlick…"),
                                   action: #selector(requestAuthorization), keyEquivalent: "")
            grant.target = self
            grant.image = Self.symbol("lock.shield")
            menu.addItem(grant)
            menu.addItem(.separator())

            let quitOnly = NSMenuItem(title: L10n.t("退出 TabFlick", "Quit TabFlick"),
                                      action: #selector(quit), keyEquivalent: "q")
            quitOnly.target = self
            quitOnly.image = Self.symbol("power")
            menu.addItem(quitOnly)
            statusItem.menu = menu
            return
        }

        favoriteItem.target = self
        favoriteItem.action = #selector(toggleFavorite)
        favoriteItem.title = L10n.t("置顶当前标签", "Pin Current Tab")
        favoriteItem.image = Self.symbol("pin")
        favoriteItem.isEnabled = false   // menuNeedsUpdate 时按当前标签刷新
        menu.addItem(favoriteItem)

        // 和「置顶当前标签」共用同一个槽位：置顶只在浏览器前台出现、这条
        // 只在 Finder 前台出现，互斥，永远不会同时可见（2026-09-02 用户定的）
        addFinderFolderItem.target = self
        addFinderFolderItem.action = #selector(addFinderFolder)
        addFinderFolderItem.title = L10n.t("收藏当前 Finder 目录", "Add Current Finder Folder")
        addFinderFolderItem.image = Self.symbol("folder.badge.plus")
        addFinderFolderItem.isEnabled = true
        menu.addItem(addFinderFolderItem)

        sepAfterPin = .separator()
        menu.addItem(sepAfterPin)

        // 收藏的文件夹列表在 menuNeedsUpdate 时插到 sepAfterPin 下方

        menu.addItem(.separator())

        let updates = NSMenuItem(title: L10n.t("检查更新…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.image = Self.symbol("arrow.triangle.2.circlepath")
        menu.addItem(updates)

        let settings = NSMenuItem(title: L10n.t("设置…", "Settings…"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.image = Self.symbol("gearshape")
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("退出 TabFlick", "Quit TabFlick"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = Self.symbol("power")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// 语言变了要重建菜单：菜单项标题是创建时写死的，不会自己更新。
    func rebuildMenu() {
        buildMenu()
        render(connected: connected, tabCount: lastTabCount, browserName: lastBrowserName)
    }

    // MARK: - 状态

    /// browserName：活动浏览器的显示名。多浏览器时账本随前台切换，
    /// 名字必须点明这是谁的标签。
    func render(connected: Bool, tabCount: Int, browserName: String?) {
        self.connected = connected
        self.lastTabCount = tabCount
        self.lastBrowserName = browserName

        statusItem.button?.image = Self.cardIcon
        // 断开时压暗图标：不换符号，位置和形状保持稳定，只是"灰掉"
        statusItem.button?.alphaValue = connected ? 1.0 : 0.45

        // 连接时状态行被浏览器行取代（menuNeedsUpdate 时构建），
        // 只有未连接时它才出场
        statusLine.title = L10n.t("扩展未连接", "Extension not connected")
        statusLine.image = Self.symbol("exclamationmark.circle")
        statusLine.isEnabled = false
    }

    // MARK: - 标签子菜单

    /// 主菜单每次打开时把浏览器行和它们的子菜单一次性建好 —— 不能等
    /// 子菜单自己展开时再填：空子菜单的父项会被判成禁用，永远展不开
    /// （2026-08-20 实测截图）。「置顶当前标签」等动态项也在这时刷新。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshBrowserLines(in: menu)

        // 动作项跟着前台上下文走：「置顶当前标签」只在浏览器前台时出现，
        // 「收藏当前 Finder 目录」只在 Finder 前台时出现 —— 不相干的时候
        // 点了也「成功」，只会让人懵（2026-09-02 用户反馈）。
        // 状态栏菜单不抢激活（accessory app，弹 alert 都得显式 NSApp.activate
        // 就是旁证），所以打开菜单这一刻 frontmost 还是用户正在用的 App。
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let pinVisible = refreshFavoriteItem(browserIsFront: BrowserSupport.isSupported(front))
        let finderIsFront = front == "com.apple.finder"
        addFinderFolderItem.isHidden = !finderIsFront
        let foldersVisible = refreshFolderLines(in: menu)
        refreshWarningItem()

        // 动作槽和文件夹列表显隐后相邻分隔线会叠在一起：中间那道只在两段
        // 都在时要，顶上那道只要还有任意一段就要（全藏时由列表后的那道
        // 独自分隔）。
        if !unauthorized {
            let actionVisible = pinVisible || finderIsFront
            sepAfterPin.isHidden = !(actionVisible && foldersVisible)
            sepAfterStatus.isHidden = !(actionVisible || foldersVisible)
        }
    }

    /// 每个已连接浏览器一行：「Chrome · 5 个标签 ▸」，行首是浏览器图标，
    /// 子菜单是它自己的标签列表。未连接时一行都没有，statusLine 顶上。
    private func refreshBrowserLines(in menu: NSMenu) {
        for item in browserItems { menu.removeItem(item) }
        browserItems.removeAll()

        let browsers = menuBrowsersProvider?() ?? []
        statusLine.isHidden = !browsers.isEmpty
        guard !browsers.isEmpty else { return }

        var insertIndex = menu.index(of: statusLine) + 1
        for browser in browsers {
            let count = browser.entries.count
            let item = NSMenuItem(title: L10n.t("\(browser.name) · \(count) 个标签",
                                                "\(browser.name) · \(count) tab\(count == 1 ? "" : "s")"),
                                  action: nil, keyEquivalent: "")
            item.image = Self.browserIcon(browser.bundleID)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            fillTabsMenu(submenu, browser: browser)
            item.submenu = submenu
            item.isEnabled = true
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
            browserItems.append(item)
        }
    }

    /// 浏览器 App 图标缩到菜单标准的 16pt。
    private static func browserIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return symbol("globe")
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func refreshWarningItem() {
        guard let text = extensionWarning?() else {
            warningItem.isHidden = true
            return
        }
        warningItem.isHidden = false
        warningItem.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.systemOrange,
                         .font: NSFont.menuFont(ofSize: 0)])
        warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
    }

    @objc private func warningClicked() {
        onExtensionWarningClick?()
    }

    /// 返回菜单项是否可见（浏览器不在前台时整项隐藏）。
    private func refreshFavoriteItem(browserIsFront: Bool) -> Bool {
        favoriteItem.isHidden = !browserIsFront
        guard browserIsFront else { return false }
        if let isFavorited = favoriteState?() {
            favoriteItem.isEnabled = true
            favoriteItem.title = isFavorited
                ? L10n.t("取消置顶当前标签", "Unpin Current Tab")
                : L10n.t("置顶当前标签", "Pin Current Tab")
            favoriteItem.image = Self.symbol(isFavorited ? "pin.fill" : "pin")
        } else {
            favoriteItem.isEnabled = false
            favoriteItem.title = L10n.t("置顶当前标签", "Pin Current Tab")
            favoriteItem.image = Self.symbol("pin")
        }
        // 设置了快捷键就用系统原生方式显示在菜单项右侧
        if let hotkey = pinHotkeyProvider?() {
            favoriteItem.keyEquivalent = hotkey.key
            favoriteItem.keyEquivalentModifierMask = hotkey.modifiers
        } else {
            favoriteItem.keyEquivalent = ""
            favoriteItem.keyEquivalentModifierMask = []
        }
        return true
    }

    private func fillTabsMenu(_ menu: NSMenu, browser: MRUController.MenuBrowser) {
        menu.removeAllItems()
        let entries = browser.entries

        // 多窗口时按窗口分组（组头小灰字），组的顺序 = 窗口在 MRU 里首次
        // 出现的顺序，当前窗口天然排最前；单窗口不加组头，保持干净。
        // 注意「只切换当前窗口」开着时扩展只推当前窗口的标签，此时这里
        // 天然只有一组 —— 菜单范围和状态行的计数、切换器保持一致。
        var windowOrder: [Int] = []
        for entry in entries where !windowOrder.contains(entry.tab.windowId) {
            windowOrder.append(entry.tab.windowId)
        }

        for (groupIndex, windowId) in windowOrder.enumerated() {
            let group = entries.filter { $0.tab.windowId == windowId }
            if windowOrder.count > 1 {
                menu.addItem(.sectionHeader(title: L10n.t(
                    "窗口 \(groupIndex + 1) · \(group.count) 个标签",
                    "Window \(groupIndex + 1) · \(group.count) tab\(group.count == 1 ? "" : "s")")))
            }
            for entry in group {
                let raw = entry.tab.title.isEmpty ? entry.tab.url : entry.tab.title
                let title = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
                let item = NSMenuItem(title: title, action: #selector(pickTab(_:)), keyEquivalent: "")
                item.target = self
                // 标签 id 在不同浏览器间会撞号，必须连浏览器身份一起带上
                item.representedObject = ["tabId": entry.tab.id, "browser": browser.bundleID] as [String: Any]
                item.image = Self.faviconIcon(entry.icon)
                if entry.tab.id == entries.first?.tab.id {
                    item.state = .on   // MRU 首位就是当前标签
                }
                // 右侧灰字徽标：最近使用时间。Chrome 只给 lastAccessed
                // （最近使用），不给创建时间 —— 最近使用也正好和 MRU 排序、
                // 存活时间清理的判定口径一致。
                if let rel = entry.tab.relativeLastAccessed {
                    item.badge = NSMenuItemBadge(string: rel)
                }
                menu.addItem(item)
            }
        }

        fillClosedSection(menu, browser: browser)
    }

    /// 活标签之后的「最近关闭」一段：点一条即找回。
    ///
    /// 一条都没有时整段不出现 —— 刚装上、还没关过任何标签的用户不该
    /// 对着一个空标题和一个「清空」按钮发愣。
    private func fillClosedSection(_ menu: NSMenu, browser: MRUController.MenuBrowser) {
        guard !browser.closed.isEmpty else { return }

        menu.addItem(.separator())
        // 存档比列出来的多时，标题就得说清「你看到的是最近 N 条」——
        // 否则下面那个「清空」会显得只清这几条。
        let shown = browser.closed.count
        let total = max(browser.closedTotal, shown)
        menu.addItem(.sectionHeader(title: total > shown
            ? L10n.t("最近关闭 · \(shown) / \(total)", "Recently closed · \(shown) of \(total)")
            : L10n.t("最近关闭 · \(shown) 个", "Recently closed · \(shown)")))

        for entry in browser.closed {
            let raw = entry.tab.displayTitle
            let title = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
            let item = NSMenuItem(title: title, action: #selector(reopenClosed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["closedId": entry.tab.id,
                                      "browser": browser.bundleID] as [String: Any]
            item.image = Self.faviconIcon(entry.icon)
            // 徽标里带上关闭原因：「程序替我关的」和「我自己关的」是完全不同
            // 的两件事，不标出来用户无从判断该不该找回它。
            let reason = entry.tab.reason.label
            item.badge = NSMenuItemBadge(
                string: entry.tab.relativeClosedAt.map { "\(reason) · \($0)" } ?? reason)
            menu.addItem(item)
        }

        // 隔开再放清空：紧挨着最后一条标签的话，冲着「找回」去的点击很容易
        // 顺手多滑一格，而这个动作没有撤销。
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.t("清空全部 \(total) 条记录",
                                             "Clear All \(total) Records"),
                               action: #selector(clearClosed(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = browser.bundleID
        clear.image = Self.symbol("trash")
        menu.addItem(clear)
    }

    /// favicon 统一缩到菜单标准的 16pt；没缓存到的用 globe 占位
    /// （图标要么全有要么全无）。
    private static func faviconIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon, let copy = icon.copy() as? NSImage else { return symbol("globe") }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: - 收藏的文件夹

    /// 平铺区容量：按最近打开排的前几个直接躺在主菜单里，
    /// 其余收进「更多 ▸」—— 收藏几十个也不会把主菜单挤爆。
    private static let kInlineFolderLimit = 5

    /// 「收藏的文件夹」列表：最近打开的前几个平铺，溢出的进「更多 ▸」，
    /// 每条的子菜单列出能打开它的 App。列表**始终显示**（有收藏就列）——
    /// 在任何 App 里都要能一键打开项目，这是功能本体。
    /// 返回列表是否有可见内容（决定外层分隔线的收敛）。
    private func refreshFolderLines(in menu: NSMenu) -> Bool {
        for item in folderItems { item.menu?.removeItem(item) }
        folderItems.removeAll()
        // 未授权菜单里没有这一区
        guard sepAfterPin.menu === menu else { return false }

        let folders = FavoriteFolderStore.byRecency(favoriteFoldersProvider?() ?? [])
        guard !folders.isEmpty else { return false }

        var insertIndex = menu.index(of: sepAfterPin) + 1
        let header = NSMenuItem.sectionHeader(title: L10n.t("收藏的文件夹", "Favorite Folders"))
        menu.insertItem(header, at: insertIndex)
        folderItems.append(header)
        insertIndex += 1

        // 「能打开文件夹的 App」查一次全体共用：查询按内容类型
        // （public.folder）走，跟具体是哪个文件夹无关。
        let openers = folderOpeners()
        // 消歧标题必须对全量算：两个同名夹子一个在平铺、一个在「更多」时，
        // 各算各的就都不带父目录，重名照样分不清。
        let titles = FavoriteFolderStore.displayTitles(folders)

        for (folder, title) in zip(folders.prefix(Self.kInlineFolderLimit),
                                   titles.prefix(Self.kInlineFolderLimit)) {
            let item = folderMenuItem(folder, title: title, openers: openers)
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
            folderItems.append(item)
        }

        let overflowFolders = folders.dropFirst(Self.kInlineFolderLimit)
        if !overflowFolders.isEmpty {
            // 数量用 badge。试过并进标题（「更多 · 4 个」），用户裁定不如
            // badge 好看（2026-09-02），改回来，别再翻烙饼
            let more = NSMenuItem(title: L10n.t("更多", "More"), action: nil, keyEquivalent: "")
            more.image = Self.symbol("ellipsis.circle")
            more.badge = NSMenuItemBadge(count: overflowFolders.count)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for (folder, title) in zip(overflowFolders,
                                       titles.dropFirst(Self.kInlineFolderLimit)) {
                submenu.addItem(folderMenuItem(folder, title: title, openers: openers))
            }
            more.submenu = submenu
            more.isEnabled = true
            menu.insertItem(more, at: insertIndex)
            insertIndex += 1
            folderItems.append(more)
        }
        return true
    }

    /// 一条收藏的菜单行 —— 平铺区和「更多」共用同一副面孔。
    private func folderMenuItem(_ folder: FavoriteFolder, title: String,
                                openers: [(name: String, url: URL)]) -> NSMenuItem {
        let exists = FileManager.default.fileExists(atPath: folder.path)
        let item = NSMenuItem(title: exists ? title : title + L10n.t("（不存在）", " (missing)"),
                              action: nil, keyEquivalent: "")
        item.toolTip = folder.path
        item.image = exists
            ? Self.menuIcon(NSWorkspace.shared.icon(forFile: folder.path))
            : Self.symbol("questionmark.folder")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // 目录已经不存在时打开方式全部免谈，只留拷贝路径和取消收藏
        fillFolderMenu(submenu, folder: folder, openers: exists ? openers : [])
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    private func fillFolderMenu(_ menu: NSMenu, folder: FavoriteFolder,
                                openers: [(name: String, url: URL)]) {
        if !openers.isEmpty {
            menu.addItem(.sectionHeader(title: L10n.t("打开方式", "Open With")))
            for opener in openers {
                let item = NSMenuItem(title: opener.name,
                                      action: #selector(openFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["path": folder.path, "app": opener.url] as [String: Any]
                item.image = Self.menuIcon(NSWorkspace.shared.icon(forFile: opener.url.path))
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: L10n.t("拷贝路径", "Copy Path"),
                              action: #selector(copyFolderPath(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = folder.path
        copy.image = Self.symbol("doc.on.doc")
        menu.addItem(copy)

        let remove = NSMenuItem(title: L10n.t("取消收藏", "Remove from Favorites"),
                                action: #selector(removeFolder(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = folder.path
        remove.image = Self.symbol("folder.badge.minus")
        menu.addItem(remove)
    }

    /// 终端类 App 是**没法枚举的**：Terminal / iTerm 这些不向 Launch Services
    /// 登记 public.folder（本机实测 `urlsForApplications(toOpen:)` 连系统自带
    /// Terminal 都不返回），而「是不是终端」没有任何 UTI / API 可查 ——
    /// 只能按 bundle id（反向 DNS，永不本地化）点名，装了才显示。
    /// 这是硬编码规则明文允许的场景：无法从 API 推导的列表。
    private static let terminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    /// 能打开文件夹的 App。点过的按最近点击排前（MRU，2026-09-02 用户
    /// 要求）；没点过的按 Finder → 已装终端 → Launch Services 枚举垫底。
    private func folderOpeners() -> [(name: String, url: URL)] {
        var seen = Set<URL>()
        var result: [(name: String, url: URL)] = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { return }
            result.append((Self.appDisplayName(url), url))
        }

        if let finder = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.finder") {
            append(finder)
        }
        for id in Self.terminalBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                append(url)
            }
        }

        // 查询用哪个目录都一样（按 public.folder 匹配），拿主目录当代表
        let claimed = NSWorkspace.shared
            .urlsForApplications(toOpen: FileManager.default.homeDirectoryForCurrentUser)
            .map { (Self.appDisplayName($0), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        for (_, url) in claimed { append(url) }

        let lastUsed = openerHistoryProvider?() ?? [:]
        guard !lastUsed.isEmpty else { return result }
        let paths = result.map { $0.url.standardizedFileURL.path }
        let byPath = Dictionary(uniqueKeysWithValues: zip(paths, result))
        return FavoriteFolderStore.openerOrder(paths, lastUsed: lastUsed)
            .compactMap { byPath[$0] }
    }

    /// App 显示名。Finder 开了「显示所有文件扩展名」时 `displayName` 会带
    /// `.app` 尾巴，菜单里不需要它。
    private static func appDisplayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// 文件 / App 图标缩到菜单标准的 16pt。
    private static func menuIcon(_ icon: NSImage) -> NSImage {
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    @objc private func addFinderFolder() {
        onAddFinderFolder?()
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let path = info["path"] as? String,
              let app = info["app"] as? URL else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let appName = Self.appDisplayName(app)
        let folderName = folder.lastPathComponent
        // toast 等真打开了再报：冷启动的 App 要一两秒，提前说「已打开」是撒谎
        NSWorkspace.shared.open([folder], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        log("⚠️  open folder failed: \(error.localizedDescription)")
                        Toast.show(L10n.t("打开失败：\(error.localizedDescription)",
                                          "Failed to open: \(error.localizedDescription)"))
                    } else {
                        Toast.show(L10n.t("已在 \(appName) 打开「\(folderName)」",
                                          "Opened “\(folderName)” in \(appName)"))
                    }
                }
            }
        }
        log("📁 open \(path) with \(app.lastPathComponent)")
        onFolderOpened?(path, app)
    }

    @objc private func copyFolderPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Toast.show(L10n.t("已拷贝路径", "Path copied"))
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onRemoveFolder?(path)
    }

    @objc private func pickTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let tabId = info["tabId"] as? Int,
              let browser = info["browser"] as? String else { return }
        onPickTabInBrowser?(tabId, browser)
    }

    @objc private func reopenClosed(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["closedId"] as? String,
              let browser = info["browser"] as? String else { return }
        onReopenClosedTab?(id, browser)
    }

    @objc private func clearClosed(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? String else { return }
        onClearClosedTabs?(browser)
    }

    // MARK: - 图标

    /// 菜单栏图标：竖向卡片堆叠——前卡直立实心、后卡空心描边斜出右上。
    /// 实心/空心的层次让前卡有分量，9° 的倾斜保留「切换/翻动」的动感
    /// （平行偏移就成了普通「拷贝」图标，也和 PasteMemo 的构图撞车）。
    /// 前卡周围用 destinationOut 抠一圈缝，让后卡的线不贴着前卡
    /// （SF Symbols 的叠卡图标都是这个做法）。模板图，自动跟随菜单栏
    /// 明暗反色。
    private static let cardIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let w: CGFloat = 9.5, h: CGFloat = 12, r: CGFloat = 2.25, stroke: CGFloat = 1.2

            // 先在原点附近摆好几何，最后按墨迹包围盒整体平移居中
            let front = NSRect(x: 0, y: 0, width: w, height: h)

            // 后卡：同尺寸，中心偏右上，绕自身中心倾斜 9°
            let backCenter = NSPoint(x: front.midX + 3.2, y: front.midY - 3.2)
            let t = NSAffineTransform()
            t.translateX(by: backCenter.x, yBy: backCenter.y)
            t.rotate(byDegrees: -9)
            t.translateX(by: -backCenter.x, yBy: -backCenter.y)
            let backRect = NSRect(x: backCenter.x - w / 2, y: backCenter.y - h / 2,
                                  width: w, height: h)
            let back = NSBezierPath(roundedRect: backRect, xRadius: r, yRadius: r)
            back.transform(using: t as AffineTransform)
            back.lineWidth = stroke

            // 墨迹 = 前卡填充 ∪ 后卡描边外缘。算出包围盒后平移到画布正中 ——
            // 手调 origin 每改一次参数就偏一次（上一版就是这么偏上的），
            // 程序化居中一劳永逸。平移量不取整：后卡斜 9° 本来就全程抗锯齿，
            // 前卡是填充不是描边，亚像素平移对清晰度没有实际影响，
            // 取整反而留下最多 1/4pt 的偏心。
            let ink = front.union(back.bounds.insetBy(dx: -stroke / 2, dy: -stroke / 2))
            NSGraphicsContext.current?.cgContext.translateBy(x: rect.midX - ink.midX,
                                                             y: rect.midY - ink.midY)

            NSColor.black.setStroke()
            back.stroke()

            // 前卡周围抠缝
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front.insetBy(dx: -1.3, dy: -1.3),
                         xRadius: r + 1.3, yRadius: r + 1.3).fill()
            NSGraphicsContext.restoreGraphicsState()

            // 前卡实心
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front, xRadius: r, yRadius: r).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TabFlick"
        return image
    }()

    // MARK: - 动作

    @objc private func requestAuthorization() {
        onRequestAuthorization?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func toggleFavorite() {
        onToggleFavorite?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
