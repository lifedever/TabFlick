import AppKit
import SwiftUI

// MARK: - 视图模型

enum CursorSource {
    case keyboard
    case mouse
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var tabs: [TabInfo] = []
    @Published private(set) var cursor: Int = 0
    @Published var icons: [Int: NSImage] = [:]
    @Published var thumbs: [Int: NSImage] = [:]

    /// 游标这次是被谁移动的。决定要不要自动滚动 —— 见 SwitcherView 里的说明。
    private(set) var cursorSource: CursorSource = .keyboard

    /// 鼠标点选了某张卡片。是回调不是状态，所以不加 @Published。
    var onPick: ((Int) -> Void)?

    /// 必须走这里改游标：source 要先于 cursor 落定，
    /// 否则 onChange 读到的是上一次的来源。
    func setCursor(_ index: Int, source: CursorSource) {
        cursorSource = source
        cursor = index
    }
}

// MARK: - 尺寸

private let kThumbWidth: CGFloat = 140
private let kThumbHeight: CGFloat = 88
private let kTitleRowHeight: CGFloat = 20
private let kCardPadding: CGFloat = 7
private let kCardWidth = kThumbWidth + kCardPadding * 2
private let kCardHeight = kThumbHeight + kTitleRowHeight + kCardPadding * 2 + 4
private let kCardSpacing: CGFloat = 8
private let kOuterPadding: CGFloat = 12
private let kPanelCornerRadius: CGFloat = 22

// MARK: - SwiftUI 内容

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: kCardSpacing) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabCard(tab: tab,
                                icon: model.icons[tab.id],
                                thumb: model.thumbs[tab.id],
                                selected: index == model.cursor,
                                onHover: { model.setCursor(index, source: .mouse) },
                                onPick: { model.onPick?(index) })
                            .id(index)
                    }
                }
                .padding(kOuterPadding)
            }
            // 只有键盘移动游标时才自动滚动。
            //
            // hover 也触发滚动的话会形成正反馈环：滚动让卡片在屏幕上位移 →
            // 鼠标底下换成了别的卡片 → 又触发 hover → 又滚动，游标会一路
            // 飞到列表尽头。而且 hover 本来就不需要滚动 —— 鼠标能指到的
            // 卡片必然已经在可视区内。
            .onChange(of: model.cursor) { newValue in
                guard model.cursorSource == .keyboard else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        // 在 vibrancy 材质之上再叠一层色。纯材质在浅色外观下渲染出来是灰的，
        // 跟 Arc 那种通透的白差一大截；深色下反过来需要压深才有层次。
        // 两种外观的取值规律不同，所以这里按 colorScheme 分开给，不用语义色。
        .background {
            (scheme == .dark ? Color.black.opacity(0.26) : Color.white.opacity(0.74))
        }
        // 浮层边缘的 hairline。同样要按外观分开给：浅色下需要的是极淡的
        // 黑描边(用 primary 0.12 会明显发黑)，深色下需要的是较亮的白高光边。
        .overlay {
            RoundedRectangle(cornerRadius: kPanelCornerRadius, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.14)
                                              : Color.black.opacity(0.055),
                              lineWidth: 1)
        }
    }
}

private struct TabCard: View {
    let tab: TabInfo
    let icon: NSImage?
    let thumb: NSImage?
    let selected: Bool
    let onHover: () -> Void
    let onPick: () -> Void

    /// 上一次的鼠标**屏幕**坐标。
    ///
    /// 必须用屏幕坐标而不是 onContinuousHover 给的视图局部坐标：卡片自己
    /// 滚动时，鼠标一动不动局部坐标也会变，用局部坐标会把滚动误判成鼠标移动。
    @State private var lastMouseScreenPoint: CGPoint?

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
                .frame(width: kThumbWidth, height: kThumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // 描边只是兜底(纯白网页贴纯白背景时的最后一道分界),
                // 真正把缩略图和背景分开的是下面的投影 —— Arc 就是这个路子,
                // 描边一重就显得糙。
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                // 层次感的主要来源。Arc 的投影比常规 UI 重得多:大半径、低透明,
                // 糊开一大片而不是勾一条硬边。
                .shadow(color: .black.opacity(selected ? 0.24 : 0.18),
                        radius: selected ? 7 : 5,
                        y: selected ? 3.5 : 2.5)

            HStack(spacing: 5) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                    }
                }
                .scaledToFit()
                .frame(width: 13, height: 13)

                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 未选中不是"淡出"而是"不加粗"。.secondary 太浅了,
                    // Arc 的未选中标题也是接近黑的深灰,只靠字重区分。
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))

                Spacer(minLength: 0)
            }
            .frame(width: kThumbWidth, height: kTitleRowHeight)
        }
        .padding(kCardPadding)
        .frame(width: kCardWidth, height: kCardHeight)
        // 选中态就是一块灰底，没有边框 —— Arc 的做法。
        // 之前那圈 1.5px 蓝框和它整体的克制感格格不入。
        // 未选中完全透明；语义色 primary 自动适配深浅色外观。
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())          // 透明区域也要能点，不然只有缩略图可点
        .onTapGesture(perform: onPick)
        // 只有鼠标真的移动过才让 hover 接管游标。onHover 在浮层弹出的瞬间、
        // 以及键盘滚动把卡片挪到鼠标下时都会触发，直接响应会把键盘选中的项抢掉。
        .onContinuousHover { phase in
            switch phase {
            case .active:
                let point = NSEvent.mouseLocation   // 屏幕坐标，不受滚动影响
                if let last = lastMouseScreenPoint,
                   abs(point.x - last.x) > 1 || abs(point.y - last.y) > 1 {
                    onHover()
                }
                lastMouseScreenPoint = point
            case .ended:
                lastMouseScreenPoint = nil
            @unknown default:
                break
            }
        }
    }

    /// 缩略图 → favicon 放大 → globe，三级降级。
    /// chrome:// 这类页面截不了图，永远只有后两级。
    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            // 截不到图的卡片(chrome:// 页面等)底色必须和有截图的卡片一致 ——
            // 之前用半透明灰,在灰背景上和浮层糊成一片,卡片边界整个消失了。
            // textBackgroundColor 就是网页本身的底色:浅色近白、深色近黑。
            Rectangle().fill(Color(nsColor: .textBackgroundColor))

            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .opacity(0.8)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 承载面板

/// 不抢焦点的浮层。
///
/// 焦点必须留在 Chrome：一旦这个面板拿走 key，Ctrl 的 flagsChanged 归属会变，
/// 松开 Ctrl 的时机就测不准了；切换完焦点也会落在错误的窗口上。
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanel {

    let model = SwitcherModel()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var shownAt: Date?

    /// 浮层最少可见这么久。
    ///
    /// 照 macOS ⌘⇥ 的行为：按下就立即显示，快速按松时就是「闪一下」。
    /// 但如果真的严格跟随按键，瞬间按松只会显示几十毫秒，肉眼根本捕捉不到，
    /// 观感上等于没出现过。所以给个下限，让那一下闪现是能看见的。
    private let minVisibleDuration: TimeInterval = 0.18

    /// 淡入时长。纯瞬显会有点生硬，一点点渐变就够。
    private let fadeInDuration: TimeInterval = 0.07

    // MARK: 显示 / 隐藏

    func requestShow() {
        // 上一轮还在等最短可见时间就又开始了新一轮 —— 直接复用同一个面板
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard panel == nil else { return }
        presentNow()
    }

    func hide() {
        guard panel != nil else { return }

        let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let remaining = minVisibleDuration - elapsed
        guard remaining > 0 else {
            closeNow()
            return
        }

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            self?.closeNow()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
    }

    private func closeNow() {
        panel?.orderOut(nil)
        panel = nil
        shownAt = nil
    }

    private func presentNow() {
        guard !model.tabs.isEmpty else { return }

        let hosting = NSHostingView(rootView: SwitcherView(model: model))

        let effect = NSVisualEffectView()
        // .popover 在浅色外观下接近白、深色下是深灰半透明,两边都干净;
        // .hudWindow 在浅色下发灰,和 Arc 那种通透感差得远
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 圆角必须走 maskImage,不能用 layer.cornerRadius —— 后者裁不住
        // vibrancy 材质,而且窗口阴影仍按直角矩形画,四角会漏出直角背景+直角阴影
        effect.maskImage = Self.roundedMask(radius: kPanelCornerRadius)

        // 优先贴着 Chrome 窗口居中；拿不到窗口时退回主屏居中
        let anchor = ChromeWindowLocator.frontmostWindowFrame()
                  ?? (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                  ?? NSScreen.main ?? NSScreen.screens[0]

        let count = CGFloat(model.tabs.count)
        let naturalWidth = count * kCardWidth + max(0, count - 1) * kCardSpacing + kOuterPadding * 2
        let width = min(naturalWidth, min(anchor.width, screen.visibleFrame.width) * 0.94)
        let height = kCardHeight + kOuterPadding * 2

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 接受鼠标事件（点选 + hover）。之前设 true 时点击会**穿透**到底下的
        // Chrome 网页，用户看到的是网页自己的菜单，而不是浮层在响应。
        // nonactivating + canBecomeKey=false 不影响收鼠标事件，焦点照样留在 Chrome。
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        effect.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        // SwiftUI 内容自己也要圆角裁剪,否则卡片会从 maskImage 的圆角处溢出
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.cornerRadius = kPanelCornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        effect.addSubview(hosting)
        panel.contentView = effect

        // 先定尺寸再定位置：反过来会以近零尺寸居中,内容到位后向右下展开
        panel.setContentSize(NSSize(width: width, height: height))
        let frame = panel.frame
        var origin = NSPoint(x: anchor.midX - frame.width / 2,
                             y: anchor.midY - frame.height / 2)
        // Chrome 窗口可能有一部分在屏幕外，夹回可见区
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()             // 不激活自己,焦点留在 Chrome
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.shownAt = Date()
    }

    /// NSVisualEffectView 的圆角遮罩。
    ///
    /// 用九宫格拉伸的图片当 mask：中心 1×1 像素拉伸填充，四角保持圆角原样。
    /// 这是 AppKit 里给 vibrancy 视图做圆角的正规方式，同时决定了窗口阴影的形状。
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Chrome 窗口定位

enum ChromeWindowLocator {

    static let bundleID = "com.google.Chrome"

    /// 最前面那个 Chrome 窗口的 frame，AppKit 坐标系（左下原点）。
    ///
    /// 只读窗口几何，不需要屏幕录制权限。
    static func frontmostWindowFrame() -> NSRect? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let pid = running.first?.processIdentifier else { return nil }

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // CGWindowList 的返回值是按前后顺序排的，第一个匹配的就是最前面那个。
        // 注意：字典里的数值是 CFNumber，`as? Int32` 会静默全部落空，
        // 必须先桥到 NSNumber 再取值。
        for entry in list {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,                                   // 0 = 普通窗口,滤掉浮动面板
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            // 太小的多半是提示条之类,不当主窗口
            guard bounds.width > 200, bounds.height > 200 else { continue }

            // CGWindowList 用左上原点的全局坐标,原点在主屏左上角;
            // AppKit 用左下原点。换算基准必须是主屏(screens[0])的高度。
            guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
            return NSRect(x: bounds.minX,
                          y: primaryHeight - bounds.maxY,
                          width: bounds.width,
                          height: bounds.height)
        }
        return nil
    }
}
