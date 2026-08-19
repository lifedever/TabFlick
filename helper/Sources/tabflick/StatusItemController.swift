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
    private let loginItemLine = NSMenuItem(title: L10n.t("开机时启动", "Open at Login"), action: nil, keyEquivalent: "")

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
    }
    var onCheckForUpdates: (() -> Void)?

    private var connected = false
    private var lastTabCount = 0

    override init() {
        super.init()
        buildMenu()
        render(connected: false, tabCount: 0)
    }

    // MARK: - 菜单

    private func buildMenu() {
        // statusLine / loginItemLine 是复用的存储属性，而 NSMenuItem 同一时刻
        // 只能属于一个菜单 —— 不先从旧菜单摘下来，第二次 buildMenu（init 后的
        // showUnauthorized、或语言切换的 rebuildMenu）会在 insertItem 处抛
        // NSInternalInconsistencyException 直接崩掉。
        statusLine.menu?.removeItem(statusLine)
        loginItemLine.menu?.removeItem(loginItemLine)

        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        if unauthorized {
            let grant = NSMenuItem(title: L10n.t("授权 TabFlick…", "Authorize TabFlick…"),
                                   action: #selector(requestAuthorization), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())

            let quitOnly = NSMenuItem(title: L10n.t("退出 TabFlick", "Quit TabFlick"),
                                      action: #selector(quit), keyEquivalent: "q")
            quitOnly.target = self
            menu.addItem(quitOnly)
            statusItem.menu = menu
            return
        }

        let settings = NSMenuItem(title: L10n.t("设置…", "Settings…"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        loginItemLine.action = #selector(toggleLoginItem)
        loginItemLine.target = self
        menu.addItem(loginItemLine)

        menu.addItem(.separator())

        let logs = NSMenuItem(title: L10n.t("打开日志文件", "Open Log File"), action: #selector(openLog), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let updates = NSMenuItem(title: L10n.t("检查更新…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("退出 TabFlick", "Quit TabFlick"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// 语言变了要重建菜单：菜单项标题是创建时写死的，不会自己更新。
    func rebuildMenu() {
        buildMenu()
        render(connected: connected, tabCount: lastTabCount)
    }

    /// 菜单每次打开时现读登录项状态，不缓存 —— 用户可能刚在系统设置里改过。
    func menuWillOpen(_ menu: NSMenu) {
        guard !unauthorized else { return }
        switch LoginItem.state {
        case .enabled:
            loginItemLine.state = .on
            loginItemLine.title = L10n.t("开机时启动", "Open at Login")
        case .disabled:
            loginItemLine.state = .off
            loginItemLine.title = L10n.t("开机时启动", "Open at Login")
        case .requiresApproval:
            // 已注册但等用户在系统设置里批准。显示成"关"会让人反复点却毫无反应。
            loginItemLine.state = .mixed
            loginItemLine.title = L10n.t("开机时启动（需在系统设置中批准）", "Open at Login (approve in Settings)")
        }
    }

    // MARK: - 状态

    func render(connected: Bool, tabCount: Int) {
        self.connected = connected
        self.lastTabCount = tabCount

        let symbol = "rectangle.on.rectangle.angled"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TabFlick")
        image?.isTemplate = true          // 跟随菜单栏明暗自动反色
        statusItem.button?.image = image
        // 断开时压暗图标：不换符号，位置和形状保持稳定，只是"灰掉"
        statusItem.button?.alphaValue = connected ? 1.0 : 0.45

        statusLine.title = connected
            ? L10n.t("已连接 · \(tabCount) 个标签", "Connected · \(tabCount) tab\(tabCount == 1 ? "" : "s")")
            : L10n.t("扩展未连接", "Extension not connected")
    }

    // MARK: - 动作

    @objc private func requestAuthorization() {
        onRequestAuthorization?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func toggleLoginItem() {
        let result = LoginItem.toggle()
        if result == .requiresApproval {
            LoginItem.openSystemSettings()
        }
        menuWillOpen(statusItem.menu!)   // 立刻回读，别假设操作成功
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: kLogPath))
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
