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
        let controller = MRUController(server: server)
        let statusItem = StatusItemController()
        let settingsWindow = SettingsWindowController(settings: settings, updates: updates)

        // 设置的事实源在 app：改动后立刻推给扩展，扩展只执行不持久化。
        settings.onChange = { [weak controller] in
            MainActor.assumeIsolated { controller?.pushSettings(settings.payload) }
        }
        // 扩展的 service worker 被回收重启后会来要一次配置
        controller.onNeedSettingsPush = { [weak controller] in
            MainActor.assumeIsolated { controller?.pushSettings(settings.payload) }
        }
        // 语言是渲染时取的，改完要把已经建好的界面重建一遍
        settings.onLanguageChange = {
            MainActor.assumeIsolated {
                statusItem.rebuildMenu()
                settingsWindow.reloadForLanguageChange()
            }
        }

        controller.onStatusChange = { connected, tabCount in
            MainActor.assumeIsolated {
                statusItem.render(connected: connected, tabCount: tabCount)
                settingsWindow.setConnected(connected)
            }
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

        server.onText = { data in
            MainActor.assumeIsolated { controller.handleMessage(data) }
        }
        server.onClientCountChange = { count in
            MainActor.assumeIsolated { controller.handleClientCountChange(count) }
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
                onCommit: {
                    MainActor.assumeIsolated { controller.commit() }
                },
                onGaveUp: {
                    MainActor.assumeIsolated {
                        log("⚠️  Keyboard hook gave up after repeated timeouts — ⌃⇥ now passes through")
                        statusItem.render(connected: false, tabCount: 0)
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
                        statusItem.render(connected: false, tabCount: 0)
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
