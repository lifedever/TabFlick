import Cocoa

let kPort: UInt16 = 41573

/// 授权流程。必须持有强引用，否则轮询计时器会被释放。
@MainActor var permissionCoordinator: PermissionCoordinator?
/// 未授权时也要有菜单栏图标 —— 那是授权入口，也是「app 还活着」的唯一证据。
@MainActor var permissionStatusItem: StatusItemController?

@MainActor
private func fatalAlert(_ title: String, _ message: String) -> Never {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L10n.t("退出", "Quit"))
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}

// main.swift 的 top-level 代码运行在主线程，等同于 MainActor 上下文。
MainActor.assumeIsolated {

    // .accessory：有窗口能力但不占 Dock、不抢激活。
    // 打开设置窗口时会临时切成 .regular 以显示 Dock 图标。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    log("tabflick started — binary built \(binaryBuildTime())")

    // 权限要在装键盘钩子之前确认。打包成 .app 后没有终端，
    // 缺权限如果只往 stderr 打字，用户看到的就是「双击图标什么都没发生」。
    if !PermissionGuide.isTrusted {
        // 入口只放在菜单栏，不开窗口 —— PermissionFlow 的浮层会被任何属于
        // 我们的窗口盖住或挤走，而菜单点完就收起，不占前台。
        log("Accessibility permission missing — waiting via menu bar")

        MainMenu.install(openSettings: nil)   // 至少让 ⌘Q 可用

        let coordinator = PermissionCoordinator()
        let statusItem = StatusItemController()
        statusItem.showUnauthorized()
        statusItem.onRequestAuthorization = {
            MainActor.assumeIsolated { coordinator.authorize() }
        }
        coordinator.startWaiting { PermissionGuide.relaunch() }

        permissionCoordinator = coordinator
        permissionStatusItem = statusItem

        // 首次启动时用户不知道该看哪儿，主动把浮层打开一次
        coordinator.authorize()
    } else {
        let settings = AppSettings()
        settings.applyAppearance()

        let updates = UpdateChecker()
        let server = WebSocketServer(port: kPort)
        let controller = MRUController(server: server, settings: settings)
        let statusItem = StatusItemController()
        let folders = FavoriteFolderStore()
        let settingsWindow = SettingsWindowController(settings: settings, updates: updates,
                                                     folders: folders)

        // 没有主菜单，⌘W/⌘Q/⌘, 这些 key equivalent 无处路由，
        // 设置窗口会对标准快捷键毫无反应。
        MainMenu.install(openSettings: {
            MainActor.assumeIsolated { settingsWindow.show() }
        })

        // 自动检查更新：频率现读设置，到点才真的查
        updates.frequency = { MainActor.assumeIsolated { settings.updateCheckFrequency } }
        updates.startPeriodicChecks()

        // 刚升级完就弹一次「这版更新了什么」。放启动流程里而不是挂在某个
        // 视图的生命周期上 —— 后台自启时 SwiftUI 一个窗口都不会创建，
        // 挂视图上的初始化永远不执行（PasteMemo #66）。
        ReleaseNotes.presentIfUpgraded(currentVersion: updates.currentVersion)

        // 设置的事实源在 app：改动后立刻推给所有客户端（收藏按浏览器分发），
        // 扩展只执行不持久化。SW 重启后自己会来 requestSettings。
        settings.onChange = { [weak controller] in
            MainActor.assumeIsolated { controller?.pushSettingsToAll() }
        }
        // 取消收藏（菜单或设置页删除）要连带撤销置顶
        settings.onFavoritesRemoved = { [weak controller] removed in
            MainActor.assumeIsolated { controller?.unpinRemovedFavorites(removed) }
        }
        // 语言是渲染时取的，改完要把已经建好的界面重建一遍
        settings.onLanguageChange = {
            MainActor.assumeIsolated {
                statusItem.rebuildMenu()
                settingsWindow.reloadForLanguageChange()
                MainMenu.rebuild()
            }
        }

        controller.onStatusChange = { connected, tabCount in
            MainActor.assumeIsolated {
                statusItem.render(connected: connected, tabCount: tabCount,
                                  browserName: controller.activeBrowserDisplayName)
                settingsWindow.setConnected(connected)
                settingsWindow.setBrowserStatuses(controller.browserStatuses)
            }
        }

        // 状态栏的扩展版本警告（橙色项，点击直达升级说明）
        statusItem.extensionWarning = {
            MainActor.assumeIsolated {
                let outdated = controller.browserStatuses.filter(\.needsUpdate)
                guard !outdated.isEmpty else { return nil }
                let names = outdated.map(\.name).joined(separator: "、")
                return L10n.t("扩展需要更新：\(names)", "Extension update needed: \(names)")
            }
        }
        statusItem.onExtensionWarningClick = {
            NSWorkspace.shared.open(URL(string: "https://www.lifedever.com/TabFlick/install-extension.html")!)
        }

        // 两个入口通向同一个窗口：菜单栏的「设置…」和浏览器工具栏的图标
        statusItem.onOpenSettings = {
            MainActor.assumeIsolated { settingsWindow.show() }
        }
        controller.onExtensionRequestedSettings = {
            MainActor.assumeIsolated { settingsWindow.show() }
        }
        statusItem.onCheckForUpdates = {
            MainActor.assumeIsolated { updates.check(userInitiated: true) }
        }

        // 浏览器行：每个已连接浏览器一行，各带自己的标签子菜单，
        // 点击把对应浏览器带到前台并切过去
        statusItem.menuBrowsersProvider = {
            MainActor.assumeIsolated { controller.menuBrowsers }
        }
        statusItem.onPickTabInBrowser = { tabId, browser in
            MainActor.assumeIsolated { controller.activateFromMenu(tabId: tabId, browser: browser) }
        }

        // 子菜单末尾的「最近关闭」：点一条把它重新打开
        statusItem.onReopenClosedTab = { id, browser in
            MainActor.assumeIsolated { controller.reopenClosedTab(id: id, browser: browser) }
        }
        statusItem.onClearClosedTabs = { browser in
            MainActor.assumeIsolated { controller.clearClosedTabs(browser: browser) }
        }

        // 收藏的文件夹：状态栏直接列出，子菜单选 App 打开；
        // 「收藏当前 Finder 目录」通过 osascript 问 Finder 前窗口的位置
        statusItem.favoriteFoldersProvider = {
            MainActor.assumeIsolated { folders.entries }
        }
        statusItem.onRemoveFolder = { path in
            MainActor.assumeIsolated {
                folders.remove(path: path)
                let name = URL(fileURLWithPath: path).lastPathComponent
                Toast.show(L10n.t("已取消收藏「\(name)」",
                                  "Removed “\(name)” from favorites"))
            }
        }
        statusItem.onFolderOpened = { path, app in
            MainActor.assumeIsolated {
                folders.touch(path: path)
                folders.touchOpener(appPath: app.standardizedFileURL.path)
            }
        }
        statusItem.openerHistoryProvider = {
            MainActor.assumeIsolated { folders.openerLastUsed }
        }
        statusItem.onAddFinderFolder = {
            FinderFront.fetchFolder { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let path):
                        let name = URL(fileURLWithPath: path).lastPathComponent
                        switch folders.add(path: path) {
                        case .added:
                            Toast.show(L10n.t("已收藏「\(name)」",
                                              "Added “\(name)” to favorites"))
                        case .movedToFront:
                            Toast.show(L10n.t("「\(name)」已在收藏里，移到最前",
                                              "“\(name)” is already a favorite — moved to front"))
                        case .invalid:
                            break
                        }
                    case .failure(.notAuthorized):
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.t("需要「自动化」权限",
                                                   "Automation permission needed")
                        alert.informativeText = L10n.t(
                            "收藏当前 Finder 目录需要询问 Finder 前面的窗口在看哪个文件夹。\n\n请在 系统设置 → 隐私与安全性 → 自动化 中允许 TabFlick 控制「访达」。",
                            "To favorite the current Finder folder, TabFlick asks Finder which folder its front window shows.\n\nAllow TabFlick to control Finder under System Settings → Privacy & Security → Automation.")
                        alert.addButton(withTitle: L10n.t("打开系统设置", "Open System Settings"))
                        alert.addButton(withTitle: L10n.t("稍后", "Later"))
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    case .failure(.noFolder):
                        let alert = NSAlert()
                        alert.alertStyle = .informational
                        alert.messageText = L10n.t("没有可收藏的 Finder 窗口",
                                                   "No Finder window to add")
                        alert.informativeText = L10n.t(
                            "先在 Finder 里打开想收藏的文件夹，再点这一项。",
                            "Open the folder in Finder first, then use this item.")
                        alert.addButton(withTitle: L10n.t("好", "OK"))
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            }
        }

        // 收藏当前标签（绑定优先 + 域名兜底的判定在 MRUController）
        statusItem.favoriteState = {
            MainActor.assumeIsolated { controller.currentTabFavorited }
        }
        statusItem.onToggleFavorite = {
            MainActor.assumeIsolated { controller.toggleFavoriteCurrentTab() }
        }

        // 置顶快捷键：设置变化时重挂 event tap 匹配；菜单项右侧原生显示
        statusItem.pinHotkeyProvider = {
            MainActor.assumeIsolated {
                guard let hotkey = settings.pinHotkey else { return nil }
                return (hotkey.character, hotkey.modifierFlags)
            }
        }
        let applyHotkeys = {
            MainActor.assumeIsolated {
                if let hotkey = settings.pinHotkey {
                    configurePinHotkey(keyCode: Int64(hotkey.keyCode), flags: hotkey.cgFlags) {
                        MainActor.assumeIsolated { controller.toggleFavoriteCurrentTab() }
                    }
                } else {
                    configurePinHotkey(keyCode: nil, flags: [], handler: nil)
                }
                if let hotkey = settings.switcherHotkey {
                    configureSwitcherHotkey(keyCode: Int64(hotkey.keyCode), flags: hotkey.cgFlags)
                } else {
                    configureSwitcherHotkey(keyCode: nil, flags: [])   // 默认 ⌃⇥
                }
                // 必须排在切换器键之后 —— 没单独设置时它要跟随切换器键的结果
                configureGlobalHotkey(keyCode: settings.globalHotkey.map { Int64($0.keyCode) },
                                      flags: settings.globalHotkey?.cgFlags ?? [],
                                      enabled: settings.globalSwitcher)
            }
        }
        settings.onHotkeyChange = applyHotkeys
        applyHotkeys()

        // 全局切换器开关：拦截范围（tap 里的 enabled 标志）和就绪状态
        // 都得当场重算，否则要等下一次 MRU 推送才生效。
        settings.onInterceptScopeChange = { [weak controller] in
            MainActor.assumeIsolated {
                applyHotkeys()
                controller?.refreshReadiness()
            }
        }

        // 扩展低于本版 app 的最低兼容版本时提示一次。
        // 只认「过旧」不认「不一致」—— app 发版没动协议时不骚扰用户。
        controller.onExtensionOutdated = { extVersion, requiredVersion in
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.t("扩展需要更新", "Extension update required")
                alert.informativeText = L10n.t(
                    "当前扩展 v\(extVersion)，本版应用需要 v\(requiredVersion) 或更新的扩展（协议有变化，旧扩展部分功能会失效）。\n\n请下载新的扩展包替换原文件夹后，在 chrome://extensions 重新加载。",
                    "Extension v\(extVersion) is installed, but this app version needs extension v\(requiredVersion) or newer (the protocol changed; older extensions lose features).\n\nDownload the new extension package, replace your folder, then reload it in chrome://extensions."
                )
                alert.addButton(withTitle: L10n.t("查看升级说明", "Open Upgrade Guide"))
                alert.addButton(withTitle: L10n.t("稍后", "Later"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "https://www.lifedever.com/TabFlick/install-extension.html")!)
                }
            }
        }

        server.onText = { data, clientID in
            MainActor.assumeIsolated { controller.handleMessage(data, from: clientID) }
        }
        server.onClientConnected = { clientID in
            MainActor.assumeIsolated { controller.handleClientConnected(clientID) }
        }
        server.onClientDisconnected = { clientID in
            MainActor.assumeIsolated { controller.handleClientDisconnected(clientID) }
        }
        server.onClientIdentified = { clientID, browser in
            MainActor.assumeIsolated { controller.handleClientIdentified(clientID, browser: browser) }
        }
        // 前台浏览器变化时切换账本（多浏览器场景）
        setActiveBrowserChangeHandler {
            MainActor.assumeIsolated { controller.activeBrowserChanged() }
        }

        do {
            try server.start()
            log("WebSocket server listening → ws://127.0.0.1:\(kPort)/")
        } catch {
            log("❌ Failed to start WebSocket server: \(error)")
            fatalAlert(
                L10n.t("TabFlick 无法启动", "TabFlick could not start"),
                L10n.t(
                    "端口 \(kPort) 已被占用。可能已经有一个 TabFlick 在运行了 —— 看看菜单栏。",
                    "Port \(kPort) is already in use. Another copy of TabFlick may already be running — check the menu bar."
                )
            )
        }

        let tap = EventTap()
        do {
            try tap.start(
                onStep: { backward in
                    MainActor.assumeIsolated { controller.step(backward: backward) }
                },
                onArrow: { direction in
                    MainActor.assumeIsolated { controller.arrow(direction) }
                },
                onCommit: {
                    MainActor.assumeIsolated { controller.commit() }
                },
                onGaveUp: {
                    MainActor.assumeIsolated {
                        log("⚠️  Keyboard hook gave up after repeated timeouts — ⌃⇥ now passes through")
                        statusItem.render(connected: false, tabCount: 0, browserName: nil)
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.t("TabFlick 已停止拦截快捷键",
                                                   "TabFlick stopped intercepting the shortcut")
                        alert.informativeText = L10n.t(
                            """
                            键盘钩子被系统反复禁用，为避免影响你正常打字，TabFlick 已主动停用它。
                            ⌃⇥ 现在回落到 Chrome 自带的切换方式。

                            重启 TabFlick 可以恢复。如果反复出现，请到 GitHub 反馈。
                            """,
                            """
                            The keyboard hook was repeatedly disabled by the system, so TabFlick \
                            turned it off rather than risk interfering with your typing. \
                            ⌃⇥ now falls back to Chrome's built-in switching.

                            Restarting TabFlick restores it. If this keeps happening, please \
                            report it on GitHub.
                            """
                        )
                        alert.addButton(withTitle: L10n.t("好", "OK"))
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                },
                onPermissionLost: {
                    MainActor.assumeIsolated {
                        log("⚠️  Accessibility permission revoked — keyboard hook disabled")
                        statusItem.render(connected: false, tabCount: 0, browserName: nil)
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.t("辅助功能权限已被移除",
                                                   "Accessibility permission was removed")
                        alert.informativeText = L10n.t(
                            """
                            TabFlick 已立即停用键盘钩子，不会影响你正常使用键盘。⌃⇥ 回落到                             Chrome 自带的切换方式。

                            重新授予权限后，需要退出并重新打开 TabFlick 才会生效 ——                             macOS 只在进程启动时读取这项权限。
                            """,
                            """
                            TabFlick disabled its keyboard hook immediately, so your typing is                             unaffected. ⌃⇥ falls back to Chrome's built-in switching.

                            After granting the permission again, quit and reopen TabFlick —                             macOS only reads this permission when a process starts.
                            """
                        )
                        alert.addButton(withTitle: L10n.t("好", "OK"))
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            )
            log("Keyboard hook installed — waiting for ⌃⇥ in Chrome")
        } catch {
            log("❌ \(error)")
            fatalAlert(
                L10n.t("TabFlick 无法安装键盘钩子", "TabFlick could not install its keyboard hook"),
                String(describing: error)
            )
        }

        // 退出前显式关掉键盘钩子。进程结束时系统本来也会回收，但显式关闭能让
        // 「退出后键盘还怪怪的」这种怀疑彻底不成立。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            stopEventTap()
            log("Keyboard hook disabled — quitting")
        }
    }
}

NSApplication.shared.run()
