import AppKit
import SwiftUI

/// 版本说明：升级后的「已更新到 x」提示 +「关于」页「本版更新内容」打开的说明窗口。
///
/// 升级后**不再自动弹说明窗口**（2026-11-25 用户定的）：说明在更新窗口里装之前就看过了，
/// 重启后只给一个 toast。原来那套「取说明 → 弹窗，取不到留 pending 下次启动接着试」随之删掉。
///
/// 检测放在**新版本**里，不需要旧版本配合：更新器换完 Contents 会重启，
/// 之后跑的就是新版本的代码，它自己发现「上次运行的不是我」即可。
@MainActor
enum ReleaseNotes {

    private static let repo = "lifedever/TabFlick"
    private static let lastRunKey = "lastRunVersion"
    /// 判断「装过老版本」用的旁证，见 decide。
    private static let everCheckedKey = "lastUpdateCheck"
    /// 以前的版本留下的键：说明欠着没弹、看过说明再装的版本、跳过的版本。现在都不用了，启动时清掉。
    private static let retiredKeys = ["pendingNotesVersion", "notesSeenBeforeInstall", "skippedUpdateVersion"]

    /// 「本版更新内容」取说明的超时。用户在盯着，宁可早点给「取不到」的窗口（里面有去 GitHub 的入口）。
    private static let manualTimeout: TimeInterval = 15

    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    // MARK: - 是不是刚升级

    /// 这次启动是不是紧跟在一次升级之后。**纯函数、不碰 UserDefaults**，好让校验脚本穷举。
    ///
    /// 没有 lastRun 记录有两种可能：全新安装，或者从**还没有这个记录的老版本**升上来。
    /// 后者才算升级。用「查过更新」当旁证：老用户必然查过（更新就是这么来的），
    /// 全新安装的用户在第一次启动的这一刻还没查过。版本号变了就算，降级也算（提示的是现在这一版）。
    nonisolated static func justUpgraded(lastRun: String?, everChecked: Bool, current: String) -> Bool {
        lastRun.map { $0 != current } ?? everChecked
    }

    /// 启动时调：刚升级就在稍后调 `onUpgrade` 给个「已更新到 x」。
    /// `lastRunVersion` 要在启动流程里**同步**写掉，不能等异步回来。
    static func announceIfUpgraded(currentVersion: String, onUpgrade: @escaping (String) -> Void) {
        let defaults = UserDefaults.standard
        let upgraded = justUpgraded(lastRun: defaults.string(forKey: lastRunKey),
                                    everChecked: defaults.object(forKey: everCheckedKey) != nil,
                                    current: currentVersion)
        defaults.set(currentVersion, forKey: lastRunKey)
        retiredKeys.forEach { defaults.removeObject(forKey: $0) }
        guard upgraded else { return }
        log("🎉 升级到 \(currentVersion)")
        // 这一步在 NSApplication.run() 之前，用 GCD 排；等启动落定再提示
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onUpgrade(currentVersion) }
    }

    // MARK: - 取说明

    /// 按 tag 精确取这一版的说明。API 被限流时从 releases.atom 里找（`GitHubReleases.notes`）。
    static func fetch(version: String, timeout: TimeInterval) async -> String? {
        await GitHubReleases.notes(version: version, timeout: timeout)
    }

    // 解析在 ReleaseNotesParser.swift（纯 Foundation，可脱离 app 单独编译验证）

    // MARK: - 呈现

    private static var window: NSWindow?

    /// 「关于」页的「本版更新内容」。取不到时也给个窗口，里面有去 GitHub 的入口。
    static func presentLatest(currentVersion: String) {
        Task { @MainActor in
            let body = await fetch(version: currentVersion, timeout: manualTimeout)
            present(version: currentVersion, body: body)
        }
    }

    private static func present(version: String, body: String?) {
        // 这个「更新内容」是**发布说明里的 markdown 小标题**，不是窗口标题 ——
        // 它得和 build/v*-notes.md 里 `## 更新内容` / `## What's New` 一字不差。
        // 底下那行窗口标题长得像，别看见两处一样就一起改：改了这里会挑不到段落，
        // 而且不报错，只是窗口里空一块。
        let parsed = body.map {
            ReleaseNotesParser.blocks(
                from: ReleaseNotesParser.section(from: $0,
                                                 heading: L10n.prefersChineseContent ? "更新内容" : "What's New"))
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
        w.title = L10n.t("TabFlick 更新内容", "What's New in TabFlick")
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
                    Text(L10n.t("这一版改了什么", "What changed"))
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
                        Text(L10n.t("更新说明取不到，可以去 GitHub 看。",
                                    "Couldn't load the notes for this version — they're on GitHub."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ReleaseNotesBlocks(blocks: blocks)
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
}

/// 发布说明的几种块怎么画。「更新内容」窗口和更新窗口共用。
struct ReleaseNotesBlocks: View {
    let blocks: [ReleaseNotesParser.Block]

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            row(block)
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
