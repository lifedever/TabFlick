import AppKit

/// 主菜单。
///
/// TabFlick 是 accessory app，平时不显示菜单栏，但 ⌘W / ⌘Q / ⌘, 这些标准
/// 快捷键全靠 `NSApp.mainMenu` 的 key equivalent 路由 —— 没有主菜单，设置
/// 窗口对 ⌘W 就毫无反应。另外设置窗口打开期间 app 会临时切成 `.regular`，
/// 菜单栏是真的会显示出来的，所以内容也要像样：
///   - app 菜单：设置… ⌘, 、退出 ⌘Q
///   - 编辑菜单：全部 nil-target 走响应链。现在的设置页虽然没有输入框，
///     但没有这份菜单，将来任何文本框的 ⌘C/⌘V/⌘A 都是死的
///   - 窗口菜单：关闭 ⌘W（nil-target → key window 的 performClose）
@MainActor
enum MainMenu {

    /// ⌘, 的回调。存下来供语言切换后重建菜单时复用。
    private static var openSettings: (() -> Void)?
    private static let target = ActionTarget()

    /// 装配主菜单。未授权阶段传 nil，菜单里不放「设置…」。
    static func install(openSettings action: (() -> Void)?) {
        openSettings = action
        build()
    }

    /// 语言变了要重建：菜单项标题是创建时写死的，不会自己更新。
    static func rebuild() {
        build()
    }

    private static func build() {
        let main = NSMenu()

        // app 菜单。顶层标题由系统固定显示为进程名，写什么都不生效。
        let appMenu = NSMenu()
        if openSettings != nil {
            let settings = NSMenuItem(title: L10n.t("设置…", "Settings…"),
                                      action: #selector(ActionTarget.openSettings(_:)),
                                      keyEquivalent: ",")
            settings.target = target
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
        }
        appMenu.addItem(NSMenuItem(title: L10n.t("退出 TabFlick", "Quit TabFlick"),
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单。undo/redo 没有可 #selector 的 Swift 符号，只能字符串构造。
        let edit = NSMenu(title: L10n.t("编辑", "Edit"))
        edit.addItem(NSMenuItem(title: L10n.t("撤销", "Undo"),
                                action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: L10n.t("重做", "Redo"),
                                action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L10n.t("剪切", "Cut"),
                                action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L10n.t("拷贝", "Copy"),
                                action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L10n.t("粘贴", "Paste"),
                                action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L10n.t("全选", "Select All"),
                                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        // 窗口菜单。⌘W 走 nil-target，落到当前 key window 的 performClose；
        // 设置窗口是 .closable 的，关闭后 windowWillClose 会把激活策略收回
        // .accessory（既有逻辑，见 SettingsWindowController）。
        let window = NSMenu(title: L10n.t("窗口", "Window"))
        window.addItem(NSMenuItem(title: L10n.t("关闭窗口", "Close Window"),
                                  action: #selector(NSWindow.performClose(_:)),
                                  keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: L10n.t("最小化", "Minimize"),
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    /// ⌘, 的落点。菜单动作总在主线程投递，@MainActor 标注是成立的
    /// （嵌套类型不继承外层的 global actor，要显式标）。
    @MainActor
    private final class ActionTarget: NSObject {
        @objc func openSettings(_ sender: Any?) {
            MainMenu.openSettings?()
        }
    }
}
