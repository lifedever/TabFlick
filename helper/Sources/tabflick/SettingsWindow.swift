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
                "为 Chrome 补上按最近使用顺序切换标签的能力。",
                "Most-recently-used tab switching for Google Chrome."
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
                    } else {
                        Text(L10n.t("检查更新", "Check for Updates"))
                    }
                }
                .disabled(updates.status == .checking)

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
         L10n.t("关于", "About")]
    }

    private func refreshContentIfVisible() {
        guard let window, window.isVisible else { return }
        generalHost?.rootView = GeneralPane(settings: settings)
        switcherHost?.rootView = SwitcherPane(settings: settings, connected: connected)
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
            let about = NSHostingController(rootView: AboutPane(updates: updates))
            // 让 preferredContentSize 跟随 SwiftUI 内容：NSTabViewController
            // 切 tab 时按它做窗口尺寸动画（顶边锚定是 AppKit 原生行为）
            general.sizingOptions = [.preferredContentSize]
            switcher.sizingOptions = [.preferredContentSize]
            about.sizingOptions = [.preferredContentSize]
            generalHost = general
            switcherHost = switcher
            aboutHost = about

            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let symbols = ["gearshape", "rectangle.on.rectangle.angled", "info.circle"]
            for (index, controller) in ([general, switcher, about] as [NSViewController]).enumerated() {
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
