import AppKit
import SwiftUI

/// 更新窗口：写着这期间各版改了什么，「立即更新」后在同一个窗口里显示下载、安装进度，
/// 装完 app 退出重启（`UpdateChecker.installAndRestart`）。
///
/// 只由用户的动作打开：「关于」页的「更新到 x…」、手动「检查更新」查到新版本。
/// 后台检查不开它，只发系统通知（`UpdateNotifier`）。
@MainActor
final class UpdateDialogController: NSObject, NSWindowDelegate {

    private unowned let updates: UpdateChecker
    private var window: NSWindow?
    private var shownVersion: String?

    init(updates: UpdateChecker) {
        self.updates = updates
        super.init()
    }

    func show(_ offer: UpdateOffer) {
        // 打开窗口时临时变成普通 app（同设置窗口）：有 Dock 图标、能 ⌘⇥ 切回来
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 已经开着：同一版、或者正在下载 / 安装（别把进度换掉）就只提到前面
        if let window, shownVersion == offer.version || updates.isDownloading || updates.isInstalling {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let old = window {
            old.delegate = nil
            old.close()
        }

        let view = UpdateDialogView(updates: updates, offer: offer, currentVersion: updates.currentVersion) {
            [weak self] in self?.close()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = L10n.t("软件更新", "Software Update")
        w.isReleasedWhenClosed = false
        w.delegate = self
        // 先把内容布局出来再居中：自适应尺寸的窗口在内容到位前 center()，
        // 会以近零尺寸算中心，随后向右下展开（PasteMemo #66）
        host.view.layoutSubtreeIfNeeded()
        w.setContentSize(host.view.fittingSize)
        w.center()
        window = w
        shownVersion = offer.version
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // 关窗 = 这次不更新了：下载中的停掉。安装中关掉也无妨，马上就退出重启
        updates.cancelDownload()
        window = nil
        shownVersion = nil

        // 等窗口真正关掉再判断，此刻它仍算 visible。设置窗口还开着就别抢它的策略
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasVisibleWindow = NSApp.windows.contains { w in
                // 切换器浮层、搜索面板是 NSPanel，不能算进来
                w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled) && !w.title.isEmpty
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - 窗口内容

private struct UpdateDialogView: View {
    @ObservedObject var updates: UpdateChecker
    let offer: UpdateOffer
    let currentVersion: String
    let onClose: () -> Void

    /// 各版说明切好的块，新的在前。打开时算一次：下载进度每跳一下整个视图都会重算 body。
    private let sections: [(version: String, blocks: [ReleaseNotesParser.Block])]

    init(updates: UpdateChecker, offer: UpdateOffer, currentVersion: String, onClose: @escaping () -> Void) {
        self.updates = updates
        self.offer = offer
        self.currentVersion = currentVersion
        self.onClose = onClose
        // 「更新内容」是发布说明里的 markdown 小标题，不是界面文案（同 ReleaseNotes.present 那条）
        let heading = L10n.prefersChineseContent ? "更新内容" : "What's New"
        sections = offer.notes
            .map { ($0.version, ReleaseNotesParser.blocks(from: ReleaseNotesParser.section(from: $0.body, heading: heading))) }
            .filter { !$0.1.isEmpty }
    }

    /// 落下好几版时去发布列表，只差一版时直接去那一版。
    private var releasePage: URL {
        offer.notes.count > 1
            ? ReleaseNotes.releasesPage
            : URL(string: "https://github.com/lifedever/TabFlick/releases/tag/v\(offer.version)")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notes
            Divider()
            footer
                .frame(height: 24)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("有新版本 \(offer.version)", "Version \(offer.version) is available"))
                    .font(.system(size: 15, weight: .semibold))
                Group {
                    if offer.assetURL != nil {
                        Text(L10n.t("当前版本 \(currentVersion)，装完自动重启",
                                    "You have \(currentVersion). It restarts on its own once installed."))
                    } else {
                        // 这一版的 release 缺当前架构的 DMG，退回发布页手动下载
                        Text(L10n.t(
                            "当前版本 \(currentVersion)。这一版没有适合这台 Mac 的安装包，去发布页手动下载。",
                            "You have \(currentVersion). This release has no package for this Mac — grab one from the releases page."
                        ))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if sections.isEmpty {
                    Text(L10n.t("更新说明取不到，可以去 GitHub 看。",
                                "Couldn't load the notes for this version — they're on GitHub."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if sections.count == 1 {
                    ReleaseNotesBlocks(blocks: sections[0].blocks)
                } else {
                    // 落下好几版：每版一个版本号小标题，新的在前
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        Text(verbatim: section.version)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.top, index == 0 ? 0 : 10)
                        ReleaseNotesBlocks(blocks: section.blocks)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 480, height: 320)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if updates.isInstalling {
                ProgressView().controlSize(.small)
                Text(L10n.t("安装中…", "Installing…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if updates.isDownloading {
                ProgressView(value: updates.downloadProgress)
                    .frame(width: 260)
                Text("\(Int(updates.downloadProgress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L10n.t("取消", "Cancel")) {
                    updates.cancelDownload()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Link(L10n.t("在 GitHub 上查看", "View on GitHub"), destination: releasePage)
                    .font(.system(size: 12))
                Spacer()
                Button(L10n.t("稍后", "Later"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                if offer.assetURL != nil {
                    Button(L10n.t("立即更新", "Update Now")) {
                        updates.startDownload(offer)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.t("前往下载", "Open Download Page")) {
                        NSWorkspace.shared.open(UpdateChecker.releasesPage)
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
