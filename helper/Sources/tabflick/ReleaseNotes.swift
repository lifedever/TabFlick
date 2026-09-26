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
    /// 「这一版的说明还欠着没弹」。见 presentIfUpgraded 那段关于两个标记的说明。
    private static let pendingKey = "pendingNotesVersion"

    /// 首次尝试的延迟。这个函数在 `NSApplication.run()` **之前**被调用，必须
    /// 用 GCD 排 —— 此刻开 `Task` 要等主 actor 的执行器就绪，时机不由我们说了算
    /// （实测过一次二十几秒才弹）。顺带避开启动窗口，别跟扩展握手抢带宽。
    private static let firstDelay: TimeInterval = 8
    /// 失败后再等多久重试。三次机会，最坏 ~2 分钟内收工。
    private static let retryGaps: [TimeInterval] = [12, 30]
    /// 后台静默取说明的超时。没有任何人在等这个请求，紧超时毫无意义 ——
    /// 0.12.1 那次就是抖了一下网络、15 秒没撑住，这一版的说明就此永久错过
    /// （app 更新的下载走的是自建 session，默认 60 秒，同样的抖动它撑过去了）。
    private static let backgroundTimeout: TimeInterval = 30
    /// 手动点「本版更新内容」时的超时。这里用户在盯着，宁可早点给「取不到」
    /// 的窗口（里面有去 GitHub 的入口），也不要让他干等半分钟。
    private static let manualTimeout: TimeInterval = 15

    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    // MARK: - 是否该弹

    /// 一次启动该怎么处置两个标记、要不要去取说明。
    struct StartupDecision: Equatable {
        /// 写回 `lastRunVersion`。
        var lastRun: String
        /// 写回 `pendingNotesVersion`；nil 表示把这个键删掉。
        var pending: String?
        /// 要不要去取说明并弹窗。
        var shouldFetch: Bool
        /// 本次启动是不是紧跟在一次升级之后（只影响日志措辞）。
        var justUpgraded: Bool
    }

    /// 启动时的全部决策。**纯函数、不碰 UserDefaults**，好让校验脚本能把
    /// 「全新安装 / 老版本升上来 / 同版本重启 / 上次没取到 / pending 过时 / 降级」
    /// 这几条路穷举一遍 —— 这里每条分支错了都不报错，只是弹错窗或者永远不弹。
    nonisolated static func decide(lastRun: String?, pending: String?,
                                   everChecked: Bool, current: String) -> StartupDecision {
        // 没有 lastRun 记录有两种可能：全新安装，或者从**还没有这个功能的版本**
        // 升上来。后者才该弹。用「查过更新」当旁证：老用户必然查过（更新就是这么
        // 来的），全新安装的用户在第一次启动的这一刻还没查过。
        let upgraded = lastRun.map { $0 != current } ?? everChecked

        if upgraded {
            return .init(lastRun: current, pending: current,
                         shouldFetch: true, justUpgraded: true)
        }
        // 不是刚升级，但上一版的说明还欠着 —— 只要版本号还对得上就接着试。
        // 对不上说明中间又变过版本，那份说明已经过时，丢掉。
        return .init(lastRun: current,
                     pending: pending == current ? current : nil,
                     shouldFetch: pending == current, justUpgraded: false)
    }

    // MARK: - 取说明

    /// 按 tag 精确取这一版的说明。用 /latest 会在「装的不是最新版」时张冠李戴。
    static func fetch(version: String, timeout: TimeInterval) async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
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

    /// 升级后调用：取说明、能取到就弹。
    ///
    /// **「升级了」和「说明弹过了」是两件事，各记各的标记**。`lastRunVersion`
    /// 仍然同步消费（它回答的是「这次启动是不是升级后第一次」，必须在启动流程里
    /// 当场落定）；能不能弹出来由 `pendingNotesVersion` 单独记账，只有真的弹出来
    /// 了才清掉。
    ///
    /// 这么拆是因为 0.12.1 那次：网络抖了一下、取说明的请求 15 秒没撑住，代码
    /// 「安静跳过」，而升级标记已经消费掉了 —— 这一版的说明从此再也不会自动弹。
    /// 一次网络抖动不该是死刑。现在取不到就留着 pending，下次启动接着试。
    ///
    /// 「不弹过时说明」的保护还在：pending 只在版本号仍然对得上时才继续尝试；
    /// 中间又升过一版的话，新版本启动时会把 pending 覆盖成自己。
    static func presentIfUpgraded(currentVersion: String) {
        let defaults = UserDefaults.standard
        let decision = decide(lastRun: defaults.string(forKey: lastRunKey),
                              pending: defaults.string(forKey: pendingKey),
                              everChecked: defaults.object(forKey: everCheckedKey) != nil,
                              current: currentVersion)
        // 标记要**同步**落定：这一步在启动流程里必须当场写完，不能等异步回来
        defaults.set(decision.lastRun, forKey: lastRunKey)
        if let pending = decision.pending {
            defaults.set(pending, forKey: pendingKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }

        guard decision.shouldFetch else { return }
        log(decision.justUpgraded
            ? "🎉 升级到 \(currentVersion)，稍后取本版发布说明"
            : "\(currentVersion) 的更新说明上次没取到，本次启动接着试")

        // 首次必须用 GCD 排（见 firstDelay 注释）。进到 Task 里时运行循环已经
        // 起来了，后面的重试用 Task.sleep 就行。
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) {
            Task { @MainActor in await fetchAndPresent(currentVersion) }
        }
    }

    /// 取说明 → 弹窗，失败退避重试。三次都不成就留着 pending，下次启动再来。
    private static func fetchAndPresent(_ version: String) async {
        for attempt in 0...retryGaps.count {
            if let body = await fetch(version: version, timeout: backgroundTimeout) {
                UserDefaults.standard.removeObject(forKey: pendingKey)
                log("发布说明已取到，弹出更新内容窗口")
                present(version: version, body: body)
                return
            }
            log("发布说明取不到（第 \(attempt + 1)/\(retryGaps.count + 1) 次）")
            guard attempt < retryGaps.count else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryGaps[attempt] * 1_000_000_000))
        }
        log("本次启动取不到 \(version) 的发布说明，下次启动再试")
    }

    /// 手动打开（设置 → 关于）。取不到时也给个窗口，里面有去 GitHub 的入口。
    static func presentLatest(currentVersion: String) {
        Task { @MainActor in
            let body = await fetch(version: currentVersion, timeout: manualTimeout)
            // 用户自己看过了，后台那条重试链就别再弹第二次
            if body != nil { UserDefaults.standard.removeObject(forKey: pendingKey) }
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
