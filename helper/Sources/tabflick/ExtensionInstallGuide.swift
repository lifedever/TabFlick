import AppKit
import SwiftUI

/// 打开浏览器的扩展管理页。
@MainActor
enum ExtensionPage {
    static let address = "chrome://extensions/"

    /// 在这个浏览器里打开扩展页。chrome:// 地址各家 Chromium 浏览器都认（Edge、Brave 会跳到自己的）。
    /// 走「用这个 App 打开网址」：命令行传进去的 chrome:// 地址 Chrome 会滤掉，这条路不会
    /// （Chrome for Testing 148 实测）。打不开就把地址拷到剪贴板，让用户自己粘。
    static func open(in bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let url = URL(string: address) else {
            fallback()
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            log("🧩 open \(address) in \(bundleID) failed: \(error.localizedDescription)")
            DispatchQueue.main.async { MainActor.assumeIsolated { fallback() } }
        }
    }

    private static func fallback() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        Toast.show(L10n.t("在地址栏打开 chrome://extensions", "Open chrome://extensions in the address bar"),
                   detail: L10n.t("地址已拷贝", "Address copied"), kind: .info)
    }
}

/// 首次安装扩展的引导（设置 → 浏览器 →「安装扩展」）：打开那个浏览器的扩展页，旁边浮一个小窗，
/// 写两步、给一个能直接拖进扩展页的文件夹。扩展连上后自己关。
///
/// 文件夹是 app 管的固定目录（`ExtensionUpdater.managed`），从这里装的扩展以后跟着 app 自动更新。
/// 小窗不抢焦点、浮在浏览器上面：用户这时在浏览器里开开发者模式，焦点要留在浏览器。
@MainActor
final class ExtensionInstallGuide {
    private let updater: ExtensionUpdater
    private var panel: NSPanel?
    private(set) var browser: String?

    init(updater: ExtensionUpdater) {
        self.updater = updater
    }

    func show(browser bundleID: String) {
        updater.prepareManaged { [weak self] folder in
            guard let self else { return }
            guard let folder else {
                Toast.show(L10n.t("扩展文件没准备好", "Couldn't prepare the extension files"), kind: .failure)
                return
            }
            self.browser = bundleID
            ExtensionPage.open(in: bundleID)
            self.present(folder: folder, browserName: BrowserSupport.displayName(bundleID))
        }
    }

    /// 已连接的浏览器变了。引导的那个连上了就关掉、说一声。
    func connectedBrowsersChanged(_ connected: Set<String>) {
        guard let browser, panel != nil, connected.contains(browser) else { return }
        close()
        Toast.show(L10n.t("扩展已连接", "Extension connected"), detail: BrowserSupport.displayName(browser))
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        browser = nil
    }

    private func present(folder: URL, browserName: String) {
        panel?.orderOut(nil)
        let view = GuideView(browserName: browserName, folder: folder, onReveal: {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }, onCopyPath: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
            Toast.show(L10n.t("已拷贝路径", "Path copied"), detail: folder.path)
        })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = GuidePanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = L10n.t("安装扩展", "Install Extension")
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.onClose = { [weak self] in
            self?.panel = nil
            self?.browser = nil
        }
        // 屏幕右侧、竖直居中：扩展页的开发者模式开关在右上角，小窗别正好盖住它
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 32,
                                         y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private final class GuidePanel: NSPanel {
    var onClose: (() -> Void)?
    override func close() {
        super.close()
        onClose?()
    }
}

private struct GuideView: View {
    let browserName: String
    let folder: URL
    let onReveal: () -> Void
    let onCopyPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("在 \(browserName) 里装 TabFlick Bridge", "Install TabFlick Bridge in \(browserName)"))
                .font(.system(size: 13, weight: .semibold))
            step(1, L10n.t("打开扩展页右上角的「开发者模式」", "Turn on Developer mode at the top right of the extensions page"))
            // 开发者模式没开时扩展页不接拖放，浏览器把文件夹当文件打开成一页目录列表（用户实测撞上过），
            // 所以条件写进这一步
            step(2, L10n.t("开发者模式打开后，把下面的文件夹拖到扩展页上",
                           "Once Developer mode is on, drag the folder below onto the extensions page"))
            FolderDragTile(folder: folder)
                .frame(height: 76)
            // 拖不进去的兜底：哪家 Chromium 浏览器的扩展页都有这个按钮，选择框里 ⌘⇧G 能直接进隐藏的资源库
            Text(L10n.t("也可以点扩展页上的「加载已解压的扩展程序」，在选择框里按 ⌘⇧G 粘贴路径",
                        "Or click Load unpacked on the extensions page, press ⌘⇧G in the file dialog and paste the path"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("拷贝路径", "Copy Path"), action: onCopyPath)
                    .controlSize(.small)
                Button(L10n.t("在访达中显示", "Show in Finder"), action: onReveal)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 能拖出去的文件夹：拖到扩展页上（开着开发者模式）就是「加载已解压的扩展程序」。
private struct FolderDragTile: NSViewRepresentable {
    let folder: URL
    func makeNSView(context: Context) -> FolderDragView { FolderDragView(folder: folder) }
    func updateNSView(_ view: FolderDragView, context: Context) { view.folder = folder }
}

private final class FolderDragView: NSView, NSDraggingSource {
    var folder: URL
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(folder: URL) {
        self.folder = folder
        super.init(frame: .zero)
        icon.image = NSWorkspace.shared.icon(forFile: folder.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.stringValue = folder.lastPathComponent
        label.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = folder.path
    }

    required init?(coder: NSCoder) { fatalError() }

    // 整块都是拖动把手：图标和名字不单独接鼠标
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // 小窗不拿焦点，第一下按下去就要能拖
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        path.fill()
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: folder as NSURL)
        let image = NSWorkspace.shared.icon(forFile: folder.path)
        image.size = NSSize(width: 44, height: 44)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
