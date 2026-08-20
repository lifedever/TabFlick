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
    @Published var icons: [Int: IconInfo] = [:]
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
    /// 宫格模式的列数；0 表示横向长条。
    let gridColumns: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if gridColumns > 0 {
                    // 宫格：面板尺寸在 presentNow 里已按「一屏放得下」算好，
                    // 只有标签多到连整屏宫格都装不下时才会真的纵向滚动。
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(kCardWidth), spacing: kCardSpacing),
                                                 count: gridColumns),
                                  spacing: kCardSpacing) {
                            cards
                        }
                        .padding(kOuterPadding)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: kCardSpacing) {
                            cards
                        }
                        .padding(kOuterPadding)
                    }
                }
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
        // 浅色:纯材质渲染出来发灰,叠白才有 Arc 那种通透的白。
        // 深色:**什么都不叠**——玻璃的「透」全靠材质本身,之前无论叠黑
        // (0.26)还是叠白(0.07)都在把模糊后的背景色盖掉,面板立刻变成
        // 一块不透明铁板。深色的透感由 .hudWindow 材质负责(见 presentNow)。
        .background {
            scheme == .dark ? Color.clear : Color.white.opacity(0.74)
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

    /// 两种排布共用同一组卡片。`.id(index)` 供 ScrollViewReader 按游标定位。
    private var cards: some View {
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
}

private struct TabCard: View {
    let tab: TabInfo
    let icon: IconInfo?
    let thumb: NSImage?
    let selected: Bool
    let onHover: () -> Void
    let onPick: () -> Void

    @Environment(\.colorScheme) private var scheme

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
                // 未选中:极淡 hairline 兜底(纯白网页贴纯白背景时的最后一道分界),
                // 真正把缩略图和背景分开的是下面的投影 —— Arc 就是这个路子。
                // 选中:accent 描边,Arc 的选中指示就是这圈蓝框 —— 深色下
                // 灰底高亮几乎不可见,描边是唯一在两种外观下都够醒目的指示。
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor
                                               : (scheme == .dark ? Color.white.opacity(0.16)
                                                                  : Color.primary.opacity(0.07)),
                                      lineWidth: selected ? 2 : (scheme == .dark ? 1 : 0.5))
                }
                // 层次感的主要来源。Arc 的投影比常规 UI 重得多:大半径、低透明,
                // 糊开一大片而不是勾一条硬边。
                .shadow(color: .black.opacity(selected ? 0.24 : 0.18),
                        radius: selected ? 7 : 5,
                        y: selected ? 3.5 : 2.5)

            HStack(spacing: 5) {
                Group {
                    if let icon {
                        Image(nsImage: icon.image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                    }
                }
                .scaledToFit()
                .frame(width: 13, height: 13)
                .padding(icon == nil ? 0 : 1.5)
                .background {
                    if let icon { faviconBacking(isLight: icon.isLight, radius: 3) }
                }

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

    /// favicon 的反差底板。
    ///
    /// 亮图标（GitHub 深色模式那只白猫）垫深底，暗图标（多数品牌 logo）垫浅底。
    /// 不跟随系统外观 —— 决定可见性的是图标自己的颜色，不是界面的明暗。
    @ViewBuilder
    private func faviconBacking(isLight: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isLight ? Color(white: 0.16) : Color(white: 0.99))
    }

    /// 缩略图 → favicon 放大 → globe，三级降级。
    /// chrome:// 这类页面截不了图，永远只有后两级。
    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            // 截不到图的卡片(chrome:// 页面等)的底色。浅色下用
            // textBackgroundColor(近白,和真截图的网页白底一致);深色下它
            // 近黑,黑卡片贴深色面板整个糊成一片 —— 改用中性灰,让卡片
            // 在面板上立得起来(Arc 深色下的空卡片也是这种亮一档的灰)。
            // 深色下用**半透明**白 —— 不透明灰块(0.22/0.30 都试过)在玻璃
            // 面板上就是一块铁板,怎么调灰度都糊;半透明让玻璃的模糊背景
            // 透上来,卡片才轻(Arc 的空卡片就是这种「玻璃上的亮一层」)。
            Rectangle().fill(scheme == .dark ? Color.white.opacity(0.14)
                                             : Color(nsColor: .textBackgroundColor))

            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let icon {
                // 截不到图时 favicon 是整张卡片唯一的信息，必须看得清。
                // 底色按图标自身的亮度取反差 —— favicon 来源不可控，
                // 任何固定颜色都会在某一类图标上失效。
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .padding(11)
                    .background {
                        faviconBacking(isLight: icon.isLight, radius: 11)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14),
                                    radius: 5, y: 2)
                    }
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

    private let settings: AppSettings

    /// 宫格模式下当前显示的列数；长条模式为 0。
    /// ⌃↑/⌃↓ 按行移动游标时以它为步长（见 MRUController.stepRow）。
    private(set) var gridRowStride = 0

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var shownAt: Date?

    init(settings: AppSettings) {
        self.settings = settings
    }

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

        let effect = NSVisualEffectView()
        // 浅色用 .popover(接近白、干净;.hudWindow 在浅色下发灰)。
        // 深色用 .hudWindow —— HUD 浮层专用材质,模糊重、透感强,背景色能
        // 透进面板(系统 ⌘⇥ 切换器就是这个观感);.popover 在深色下太闷。
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effect.material = isDark ? .hudWindow : .popover
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

        // 面板尺寸上限：不越出 Chrome 窗口，也不越出所在屏幕的可见区。
        let maxPanelWidth = min(anchor.width, screen.visibleFrame.width) * 0.94
        let maxPanelHeight = min(anchor.height, screen.visibleFrame.height) * 0.94

        let count = model.tabs.count
        let width: CGFloat
        let height: CGFloat

        switch settings.switcherLayout {
        case .strip:
            gridRowStride = 0
            let n = CGFloat(count)
            let naturalWidth = n * kCardWidth + max(0, n - 1) * kCardSpacing + kOuterPadding * 2
            width = min(naturalWidth, maxPanelWidth)
            height = kCardHeight + kOuterPadding * 2

        case .grid:
            // 先按塞满宽度算至少要几行，再回头平衡列数：30 个标签在
            // 12 列上限下排成 10×3，而不是 12+12+6 那种最后一行孤零零的样子。
            // 只有标签多到整屏都放不下时才铺满宽度、纵向滚动。
            let maxCols = max(1, Int((maxPanelWidth - kOuterPadding * 2 + kCardSpacing)
                                     / (kCardWidth + kCardSpacing)))
            let maxRows = max(1, Int((maxPanelHeight - kOuterPadding * 2 + kCardSpacing)
                                     / (kCardHeight + kCardSpacing)))
            let neededRows = (count + maxCols - 1) / maxCols
            let cols = neededRows <= maxRows ? (count + neededRows - 1) / neededRows : maxCols
            let rows = min(neededRows, maxRows)
            gridRowStride = cols
            width = CGFloat(cols) * kCardWidth + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2
            height = CGFloat(rows) * kCardHeight + CGFloat(rows - 1) * kCardSpacing + kOuterPadding * 2
        }

        let hosting = NSHostingView(rootView: SwitcherView(model: model, gridColumns: gridRowStride))

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
