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

    // 三个鼠标回调的参数都是 tab.id，不是位置 index。
    //
    // 必须是 id：连续关闭标签时数组不断变短、卡片视图不断位移/重建，
    // 位置索引在渲染与点击之间存在失真窗口 —— 拿旧位置去索引新数组就会
    // 关错标签（2026-08-20 实测：连关几张后开始错位）。id 让动作载荷和
    // 卡片渲染的是同一份 TabInfo，「点谁就是谁」在构造上成立。

    /// 鼠标点选了某张卡片（参数 tab.id）。是回调不是状态，所以不加 @Published。
    var onPick: ((Int) -> Void)?

    /// 鼠标悬停到了某张卡片（参数 tab.id）。必须回调给 MRUController 而不是
    /// 在视图里直接 setCursor —— 游标的事实源在状态机那边，视图私自改自己的
    /// 那份会造成「高亮在 A、⌃⇥ 却从 B 继续、松开切到 B」的失步。
    var onHover: ((Int) -> Void)?

    /// 鼠标点了卡片上的 ✕，要求关掉这个标签（参数 tab.id）。同样只回调给
    /// MRUController，快照怎么改、游标落到哪都由状态机决定，视图只是投影。
    var onClose: ((Int) -> Void)?

    /// 是否允许在卡片上关标签。设置项（AppSettings.allowTabClose）的投影，
    /// 浮层每次弹出时读入。
    @Published var allowClose = false

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
                guard model.cursorSource == .keyboard,
                      model.tabs.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.tabs[newValue].id, anchor: .center)
                }
            }
        }
        // 「玻璃·浅调」（mockups/switcher-redesign.html 方案 01）：
        // 材质（.hudWindow）负责「透」，这里的叠色只负责把色调拉向暖灰/烟灰，
        // 透明度必须低 —— 样张里的 62%/50% 是叠在纯模糊上的等效值，
        // 材质自带底色，叠太多两层一乘就成铁板（第一版就是这么翻的车）。
        .background {
            scheme == .dark ? Color(red: 64/255, green: 64/255, blue: 72/255).opacity(0.35)
                            : Color(red: 226/255, green: 223/255, blue: 218/255).opacity(0.25)
        }
        // 浮层边缘的 hairline。按外观分开给：浅色极淡黑描边，深色白高光边。
        .overlay {
            RoundedRectangle(cornerRadius: kPanelCornerRadius, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.16)
                                              : Color.black.opacity(0.08),
                              lineWidth: 1)
        }
        // 玻璃棱边：顶部一道白高光，沿边框向下渐隐。
        .overlay {
            RoundedRectangle(cornerRadius: kPanelCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.12 : 0.42),
                                            .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        }
    }

    /// 两种排布共用同一组卡片。`.id(tab.id)` 供 ScrollViewReader 按游标定位。
    ///
    /// 身份必须用 tab.id 而不是 index：用位置当身份的话，删掉一张卡后
    /// 右侧所有卡片的 index 全变 → SwiftUI 把它们当「销毁 + 新建」处理，
    /// 移除动画期间新旧视图并存，点击可能落在携带旧位置的残影上。
    /// 用 tab.id 卡片只是「移动」，视图和数据的对应关系全程不断。
    private var cards: some View {
        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
            TabCard(tab: tab,
                    icon: model.icons[tab.id],
                    thumb: model.thumbs[tab.id],
                    selected: index == model.cursor,
                    // 开关默认关；开了之后剩 2 张时也不给 ✕：再关 1 张就只剩
                    // 单标签，而切换器本来就不为单标签出现，关到那一步面板就没意义了。
                    closable: model.allowClose && model.tabs.count > 2,
                    onHover: { model.onHover?(tab.id) },
                    onPick: { model.onPick?(tab.id) },
                    onClose: { model.onClose?(tab.id) })
                .id(tab.id)
        }
    }
}

private struct TabCard: View {
    let tab: TabInfo
    let icon: IconInfo?
    let thumb: NSImage?
    let selected: Bool
    let closable: Bool
    let onHover: () -> Void
    let onPick: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// 鼠标正悬在这张卡片上（决定 ✕ 的显隐）。
    @State private var hovering = false
    /// 鼠标正悬在 ✕ 本身上（按钮加深一档作反馈）。
    @State private var closeHovering = false

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
                // 「玻璃·浅调」的立体卡处理:1px 描边划清边界(0.5px·7% 那条
                // 发丝线撑不住白卡贴灰面板)。选中 = accent 蓝框(2px)+ 底下灰底,
                // 两种外观下都醒目。
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor
                                               : (scheme == .dark ? Color.white.opacity(0.14)
                                                                  : Color.black.opacity(0.12)),
                                      lineWidth: selected ? 2 : 1)
                }
                // 深色下蓝框和深灰背景对比有限,给选中卡加一圈 accent 光晕,
                // 玻璃面板上「点亮」的那张一眼可辨。浅色不需要(白底上蓝框已够跳)。
                .shadow(color: selected && scheme == .dark ? Color.accentColor.opacity(0.45) : .clear,
                        radius: 7)
                // 双层阴影:贴地投影勾边缘,环境光晕给层次;选中整体加深一档。
                .shadow(color: .black.opacity(scheme == .dark ? 0.40 : (selected ? 0.22 : 0.18)),
                        radius: scheme == .dark ? 5 : (selected ? 4 : 2),
                        y: scheme == .dark ? 2 : (selected ? 2 : 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.30 : (selected ? 0.16 : 0.12)),
                        radius: scheme == .dark ? 20 : (selected ? 20 : 16),
                        y: scheme == .dark ? 8 : (selected ? 8 : 6))
                // hover 时缩略图右上角出一枚 ✕。挂在阴影之后，
                // 免得按钮也被卡片的双层阴影再描一遍。
                .overlay(alignment: .topTrailing) {
                    if closable && hovering {
                        closeButton
                    }
                }
                // 左上角常驻星标：置顶（收藏）的标签一眼可辨。
                // 和 ✕ 同一设计语言：磨砂圆底 + 深色压暗 + 发丝描边。
                .overlay(alignment: .topLeading) {
                    if tab.pinned == true {
                        pinBadge
                    }
                }

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
        // 深色选中底从白 18% 提到 28%:未选中缩略图底本身就是白 14%,
        // 只差 4 个百分点的话整块面板都挤在一条窄灰带里,选中格看不出来。
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.28)
                                                  : Color.black.opacity(0.15))
                               : Color.clear)
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
        // ✕ 的显隐用简单的进出判断就够，不需要 onContinuousHover 那套
        // 移动量守卫 —— 它不动游标，浮层弹出时鼠标恰好停在卡片上就显示
        // 也是合理的（鼠标确实悬在这张卡上）。
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
    }

    /// 左上角的置顶星标。金黄星形在深色磨砂圆底上，亮暗缩略图都立得住。
    private var pinBadge: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
            .frame(width: 18, height: 18)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.black.opacity(0.35))
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .shadow(color: .black.opacity(0.30), radius: 2.5, y: 1)
            .padding(5)
    }

    /// 缩略图右上角的关闭钮：磨砂玻璃圆底再压一层深色，保证白 ✕ 在任何
    /// 截图（包括纯白网页）上都有反差；悬停变红（危险动作的通用信号）、
    /// 微放大、鼠标切成小手。点击由 Button 消费，不会落到卡片的
    /// onTapGesture（pick）上。
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(closeHovering ? Color.red.opacity(0.85)
                                                    : Color.black.opacity(0.38))
                    }
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(closeHovering ? 0.55 : 0.30),
                                               lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .scaleEffect(closeHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: closeHovering)
        .onHover { inside in
            closeHovering = inside
            // 小手光标。push/pop 必须配平 —— 点击后卡片被移除时按钮直接
            // 消失、收不到 onHover(false)，靠下面的 onDisappear 兜底。
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if closeHovering {
                NSCursor.pop()
                closeHovering = false
            }
        }
        .padding(5)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .topTrailing)))
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
            // 浅色从 textBackgroundColor(纯白,在灰玻璃上和真白页混淆)换成
            // 略带暖调的近白,和面板灰保持一档亮度差。
            Rectangle().fill(scheme == .dark ? Color.white.opacity(0.14)
                                             : Color(red: 250/255, green: 249/255, blue: 247/255))

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
    private var hostingView: NSHostingView<SwitcherView>?
    private var hideWorkItem: DispatchWorkItem?
    private var shownAt: Date?

    /// presentNow 按 Chrome 窗口 / 屏幕算出的面板尺寸上限。
    /// 关标签后重算布局（applyRemoval）沿用同一套上限，收缩前后同一套规则。
    private var panelMaxSize = NSSize.zero

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
        hostingView = nil
        shownAt = nil
    }

    /// 关掉了一个标签后的收尾：卡片带动画消失，面板中心不动往里收，
    /// 宫格列数按新数量重排。空列表不会走到这里 —— ✕ 只在 3 张以上时
    /// 出现（见 MRUController.closeTab 的守卫）。
    func applyRemoval(tabs: [TabInfo], cursor: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            model.tabs = tabs
            model.setCursor(cursor, source: .mouse)
        }

        guard let panel, !tabs.isEmpty else { return }

        let (size, columns) = contentLayout(count: tabs.count,
                                            maxWidth: panelMaxSize.width,
                                            maxHeight: panelMaxSize.height)
        if columns != gridRowStride {
            gridRowStride = columns
            hostingView?.rootView = SwitcherView(model: model, gridColumns: columns)
        }
        guard size != panel.frame.size else { return }

        // 左上角锚定收缩（AppKit 原点在左下，顶边不动要补 y）：连续关闭时
        // 被删卡片左侧的所有卡片在屏幕上纹丝不动，右侧邻居滑进原位 ——
        // 和 Chrome 标签栏连续关标签的手感一致。之前按中心收缩，每关一张
        // 所有卡片横移半张宽，鼠标下的目标一直在跑。
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        // 只收不涨一般不会越界，但保持与 presentNow 同一套夹取规则
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func presentNow() {
        guard !model.tabs.isEmpty else { return }
        model.allowClose = settings.allowTabClose

        let effect = NSVisualEffectView()
        // 深浅色都用 .hudWindow —— HUD 浮层专用材质,模糊重、透感强,背景色
        // 能透进面板(系统 ⌘⇥ 切换器就是这个观感)。浅色曾用 .popover,
        // 但它本身近乎不透明,再叠任何颜色都是铁板;「玻璃感」的前提是
        // 材质这一层就得透,灰调只能靠上面的轻微叠色给。
        effect.material = .hudWindow
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
        panelMaxSize = NSSize(width: maxPanelWidth, height: maxPanelHeight)

        let (contentSize, columns) = contentLayout(count: model.tabs.count,
                                                   maxWidth: maxPanelWidth,
                                                   maxHeight: maxPanelHeight)
        gridRowStride = columns
        let width = contentSize.width
        let height = contentSize.height

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
        self.hostingView = hosting
        self.shownAt = Date()
    }

    /// 按标签数算面板内容尺寸。宫格模式同时返回列数（也是 ⌃↑/⌃↓ 的行步长），
    /// 长条模式列数为 0。presentNow 和 applyRemoval 共用这一份，别各抄一套。
    private func contentLayout(count: Int,
                               maxWidth: CGFloat,
                               maxHeight: CGFloat) -> (size: NSSize, columns: Int) {
        switch settings.switcherLayout {
        case .strip:
            let n = CGFloat(count)
            let naturalWidth = n * kCardWidth + max(0, n - 1) * kCardSpacing + kOuterPadding * 2
            return (NSSize(width: min(naturalWidth, maxWidth),
                           height: kCardHeight + kOuterPadding * 2), 0)

        case .grid:
            // 先按塞满宽度算至少要几行，再回头平衡列数：30 个标签在
            // 12 列上限下排成 10×3，而不是 12+12+6 那种最后一行孤零零的样子。
            // 只有标签多到整屏都放不下时才铺满宽度、纵向滚动。
            let maxCols = max(1, Int((maxWidth - kOuterPadding * 2 + kCardSpacing)
                                     / (kCardWidth + kCardSpacing)))
            let maxRows = max(1, Int((maxHeight - kOuterPadding * 2 + kCardSpacing)
                                     / (kCardHeight + kCardSpacing)))
            let neededRows = (count + maxCols - 1) / maxCols
            let cols = neededRows <= maxRows ? (count + neededRows - 1) / neededRows : maxCols
            let rows = min(neededRows, maxRows)
            return (NSSize(width: CGFloat(cols) * kCardWidth + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2,
                           height: CGFloat(rows) * kCardHeight + CGFloat(rows - 1) * kCardSpacing + kOuterPadding * 2),
                    cols)
        }
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

// MARK: - 浏览器识别

/// 浏览器识别。**主路径是动态的**：per-client 识别出的「已连接扩展的
/// 浏览器」集合（connected）—— 任何 Chromium 浏览器装上扩展、连上 helper
/// 就自动获得支持，不靠维护名单。静态名单只是识别失败时的兜底，
/// 用户还可以追加：
///   defaults write com.lifedever.TabFlick extraBrowsers -array-add "<bundle id>"
/// bundle id 用 `osascript -e 'id of app "浏览器名"'` 查询。
@MainActor
enum BrowserSupport {
    /// 已连接扩展的浏览器（由 MRUController 随连接识别/断开维护）。
    static var connected: Set<String> = []

    static let builtin: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",        // Edge
        "com.brave.Browser",            // Brave
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",          // Vivaldi
        "com.operasoftware.Opera",      // Opera
        "net.imput.helium",             // Helium（按开发者 imput 的反向域名推定，未实测；
                                        // 不对就走 extraBrowsers 追加）
    ]

    static var all: Set<String> {
        builtin.union(UserDefaults.standard.stringArray(forKey: "extraBrowsers") ?? [])
    }

    static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return connected.contains(bundleID) || all.contains(bundleID)
    }

    /// 浏览器的显示名（本地化的 App 名，仅用于展示，不做任何判断）。
    /// Finder 设置为「显示扩展名」时 displayName 会带 .app 后缀，剥掉。
    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    private static var installedCache: (at: Date, ids: [String])?

    /// 系统里已安装的 Chromium 系浏览器（bundle id）。运行时发现，不靠名单：
    /// 枚举 http(s) 的处理程序，再按「Contents/Frameworks 里有
    /// `* Framework.framework`」识别 Chromium 家族 —— Chrome/Edge/Brave/
    /// Arc/Helium 都是这个打包布局；Safari/Firefox 不是，它们本来也装不了
    /// 我们的扩展。磁盘扫描不便宜，缓存 60 秒。
    static func installedBrowsers() -> [String] {
        if let cache = installedCache, Date().timeIntervalSince(cache.at) < 60 {
            return cache.ids
        }
        var result: [String] = []
        if let probe = URL(string: "https://example.com") {
            for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
                guard let id = Bundle(url: appURL)?.bundleIdentifier,
                      !result.contains(id) else { continue }
                if all.contains(id) || connected.contains(id) || looksChromium(appURL) {
                    result.append(id)
                }
            }
        }
        installedCache = (Date(), result)
        return result
    }

    private static func looksChromium(_ appURL: URL) -> Bool {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return false
        }
        return items.contains { $0.hasSuffix(" Framework.framework") }
    }
}

// MARK: - 浏览器窗口定位

@MainActor
enum ChromeWindowLocator {

    /// 最近一次处于前台的受支持浏览器。EventTap 的前台跟踪负责更新；
    /// 窗口定位、菜单栏激活浏览器都以它为准。
    static var activeBundleID = "com.google.Chrome"

    /// 最前面那个 Chrome 窗口的 frame，AppKit 坐标系（左下原点）。
    ///
    /// 只读窗口几何，不需要屏幕录制权限。
    static func frontmostWindowFrame() -> NSRect? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: activeBundleID)
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
