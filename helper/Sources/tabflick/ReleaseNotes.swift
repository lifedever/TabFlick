import AppKit
import SwiftUI

/// 「本次更新了什么」——升级后第一次启动时弹一次。
///
/// 检测逻辑放在**新版本**里，不需要旧版本配合：更新器换完 Contents 会重启，
/// 之后跑的就是新版本的代码，它自己发现「上次运行的不是我」即可。
@MainActor
enum ReleaseNotes {

    private static let repo = "lifedever/TabFlick"
    private static let lastRunKey = "lastRunVersion"
    /// 判断「装过老版本」用的旁证，见 shouldPresent。
    private static let everCheckedKey = "lastUpdateCheck"

    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    // MARK: - 是否该弹

    /// 这次启动是不是「刚升级完」。顺带把版本号记下来 —— 无论最终有没有弹出
    /// 窗口都记，免得取不到说明时每次启动都重试、某天网络好了突然弹一个
    /// 早就过时的更新说明。
    static func consumeUpgradeFlag(currentVersion: String) -> Bool {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: lastRunKey)
        defaults.set(currentVersion, forKey: lastRunKey)

        if let last { return last != currentVersion }

        // 没有记录有两种可能：全新安装，或者从**还没有这个功能的版本**升上来。
        // 后者才该弹。用「查过更新」当旁证：老用户必然查过（更新就是这么来的），
        // 全新安装的用户在第一次启动的这一刻还没查过。
        return defaults.object(forKey: everCheckedKey) != nil
    }

    // MARK: - 取说明

    /// 按 tag 精确取这一版的说明。用 /latest 会在「装的不是最新版」时张冠李戴。
    static func fetch(version: String) async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? String, !body.isEmpty else { return nil }
        return body
    }

    // 解析在 ReleaseNotesParser.swift（纯 Foundation，可脱离 app 单独编译验证）

    // MARK: - 呈现

    private static var window: NSWindow?

    /// 升级后调用：取说明、能取到就弹。取不到就安静跳过 —— 为了一个
    /// 「看看更新了什么」的窗口去打断用户，不值得。
    static func presentIfUpgraded(currentVersion: String) {
        // 标记要**同步**消费掉：这一步在启动流程里必须落定，不能等异步回来
        guard consumeUpgradeFlag(currentVersion: currentVersion) else { return }
        log("🎉 升级到 \(currentVersion)，稍后取本版发布说明")

        // 等运行循环起来再动手。这个函数在 NSApplication.run() **之前**被调用，
        // 此刻直接开 Task 要等主 actor 排上队才执行，时机不由我们说了算
        // （实测过一次二十几秒才弹出来）。顺带也避开启动窗口，别跟扩展握手
        // 抢带宽 —— UpdateChecker 的周期检查同样是这么延后的。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                guard let body = await fetch(version: currentVersion) else {
                    log("发布说明取不到，跳过本次更新说明窗口")
                    return
                }
                log("发布说明已取到，弹出更新内容窗口")
                present(version: currentVersion, body: body)
            }
        }
    }

    /// 手动打开（设置 → 关于）。取不到时也给个窗口，里面有去 GitHub 的入口。
    static func presentLatest(currentVersion: String) {
        Task { @MainActor in
            present(version: currentVersion, body: await fetch(version: currentVersion))
        }
    }

    private static func present(version: String, body: String?) {
        let parsed = body.map {
            ReleaseNotesParser.blocks(
                from: ReleaseNotesParser.section(from: $0,
                                                 heading: L10n.t("更新内容", "What's New")))
        } ?? []

        // 打开窗口时临时变成普通 app（同设置窗口）：有 Dock 图标、能 ⌘⇥ 切回来
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window?.close()
        let view = WhatsNewView(version: version, blocks: parsed) {
            window?.close()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = L10n.t("更新内容", "What's New")
        w.isReleasedWhenClosed = false
        w.delegate = WindowWatcher.shared
        // 先把内容布局出来再居中：自适应尺寸的窗口在内容到位前 center()，
        // 会以近零尺寸算中心，随后向右下展开（PasteMemo #66）
        host.view.layoutSubtreeIfNeeded()
        w.setContentSize(host.view.fittingSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// 关窗后把激活策略收回 .accessory，否则 Dock 图标会一直挂着。
    private final class WindowWatcher: NSObject, NSWindowDelegate {
        static let shared = WindowWatcher()
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                ReleaseNotes.window = nil
                // 设置窗口可能还开着，那就别抢它的策略
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== notification.object as? NSWindow }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

// MARK: - 窗口内容

private struct WhatsNewView: View {
    let version: String
    let blocks: [ReleaseNotesParser.Block]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("已更新到 \(version)", "Updated to \(version)"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("这一版带来了这些变化", "Here's what changed"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if blocks.isEmpty {
                        Text(L10n.t("这一版的更新说明暂时取不到，可以到 GitHub 上查看。",
                                    "Couldn't load the notes for this version — they're on GitHub."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            row(block)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(width: 480, height: 320)

            Divider()

            HStack {
                Link(L10n.t("在 GitHub 上查看", "View on GitHub"), destination: ReleaseNotes.releasesPage)
                    .font(.system(size: 12))
                Spacer()
                Button(L10n.t("好", "OK"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotesParser.Block) -> some View {
        switch block {
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                markdown(text).fixedSize(horizontal: false, vertical: true)
            }
        case .callout(let text):
            markdown(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
        case .paragraph(let text):
            markdown(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 发布说明里有 **粗体** 和 [链接]()，交给 AttributedString 解析；
    /// 解析不了就按纯文本显示，绝不因为一个符号让整块内容消失。
    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed).font(.system(size: 12))
        }
        return Text(text).font(.system(size: 12))
    }
}
