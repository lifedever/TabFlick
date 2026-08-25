import AppKit
import ApplicationServices
import SwiftUI

// MARK: - 视图模型

enum CursorSource {
    case keyboard
    case mouse
}

/// 切换器里的一项。
///
/// 身份是 `id` 而不是 `tab.id`：全局切换器把多个浏览器的标签放进同一张列表，
/// 而 tabId 只在**单个浏览器内**唯一 —— 拿它当身份，点夸克的卡片可能切到
/// Chrome 里同号的标签。`clientID` 让每一项都自带「命令发给谁」。
struct SwitcherItem: Identifiable {
    let id: String
    let tab: TabInfo
    /// 归属浏览器 bundle id。nil = 当前浏览器切换器（只有一个浏览器，
    /// 不画分组头）。视图据此决定要不要分组。
    let browser: String?
    /// 这一项的命令要发给哪条连接。
    let clientID: UUID

    init(tab: TabInfo, browser: String?, clientID: UUID) {
        // 用连接 id 而不是 bundle id 做前缀：同一个浏览器多开 profile 时
        // 是两条连接，各有各的 tabId 空间。ForEach 撞 id 会让 SwiftUI
        // 渲染错乱，这里用构造保证唯一，不靠「大概不会撞」。
        self.id = "\(clientID.uuidString)#\(tab.id)"
        self.tab = tab
        self.browser = browser
        self.clientID = clientID
    }
}

/// 浮层的呈现方式。四种排布共用同一个视图，由它分派。
///
/// 三个维度是**分开**的，不塞进枚举载荷：排布（哪种摆法）、卡片档位
/// （一屏装不下就降一档）、画不画分组头（只有一个浏览器时不画）。
/// 塞进载荷的话每加一个维度都要给四个 case 各改一遍签名，而 `grouped`
/// 对 strip/grid 根本没意义。
struct SwitcherPresentation: Equatable {
    enum Layout: Equatable {
        /// 当前浏览器：横向长条。
        case strip
        /// 当前浏览器：宫格，参数为列数。
        case grid(columns: Int)
        /// 全局：Raycast 式纵向列表，浏览器做分组标题。
        case globalList
        /// 全局：每个浏览器一段缩略图卡片，参数为列数。
        case globalCards(columns: Int)
    }

    let layout: Layout

    /// 卡片降一档。只在二维排布（宫格 / 全局卡片）里、且大卡片一屏装不下时置位。
    var compact = false

    /// 画分组头。**只有一个浏览器时不画** —— 唯一的那个组名是废话，
    /// 还白占一行高度。视图和尺寸计算必须读同一个值，否则面板高度和内容对不上。
    var grouped = false

    /// 给日志用的一行摘要。布局算错的表现是「面板底部裁掉半行」这种
    /// 只在标签数刚好卡边界时才看得出的事，日志里留一行实际用了几列几档，
    /// 用户报「样子不对」时能直接对账。
    func describe(count: Int) -> String {
        let card = compact ? "小卡" : "大卡"
        switch layout {
        case .strip:                    return "长条 \(count) 张"
        case .grid(let c):              return "宫格 \(c) 列 · \(card) · \(count) 张"
        case .globalList:               return "全局列表\(grouped ? "·分组" : "") · \(count) 项"
        case .globalCards(let c):       return "全局卡片 \(c) 列 · \(card)\(grouped ? "·分组" : "") · \(count) 张"
        }
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published private(set) var cursor: Int = 0
    @Published var icons: [String: IconInfo] = [:]
    @Published var thumbs: [String: NSImage] = [:]

    /// 游标这次是被谁移动的。决定要不要自动滚动 —— 见 SwitcherView 里的说明。
    private(set) var cursorSource: CursorSource = .keyboard

    // 三个鼠标回调的参数都是 item.id，不是位置 index。
    //
    // 必须是 id：连续关闭标签时数组不断变短、卡片视图不断位移/重建，
    // 位置索引在渲染与点击之间存在失真窗口 —— 拿旧位置去索引新数组就会
    // 关错标签（2026-08-20 实测：连关几张后开始错位）。id 让动作载荷和
    // 卡片渲染的是同一项，「点谁就是谁」在构造上成立。

    /// 鼠标点选了某一项（参数 item.id）。是回调不是状态，所以不加 @Published。
    var onPick: ((String) -> Void)?

    /// 鼠标悬停到了某一项（参数 item.id）。必须回调给 MRUController 而不是
    /// 在视图里直接 setCursor —— 游标的事实源在状态机那边，视图私自改自己的
    /// 那份会造成「高亮在 A、⌃⇥ 却从 B 继续、松开切到 B」的失步。
    var onHover: ((String) -> Void)?

    /// 鼠标点了 ✕，要求关掉这个标签（参数 item.id）。同样只回调给
    /// MRUController，快照怎么改、游标落到哪都由状态机决定，视图只是投影。
    var onClose: ((String) -> Void)?

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

/// 卡片的一套尺寸。**只有两档，`compact` 就是下限**：缩略图是用来认版式的，
/// 再往下缩就只剩一块糊了，不如老实滚动。
///
/// 档位由「一屏装不装得下」决定（见 `fittedGrid`），不是按标签数卡阈值 ——
/// 同样 40 个标签，27 寸屏上大卡片一屏就够，13 寸上才需要降档。
private struct CardMetrics {
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let titleRowHeight: CGFloat
    let padding: CGFloat
    let titleFont: CGFloat
    let faviconSize: CGFloat
    let thumbCorner: CGFloat
    let cardCorner: CGFloat
    /// ✕ 和置顶星标的直径。
    let badgeSize: CGFloat

    var width: CGFloat { thumbWidth + padding * 2 }
    var height: CGFloat { thumbHeight + titleRowHeight + padding * 2 + 4 }

    static let standard = CardMetrics(thumbWidth: 140, thumbHeight: 88, titleRowHeight: 20,
                                      padding: 7, titleFont: 11, faviconSize: 13,
                                      thumbCorner: 7, cardCorner: 10, badgeSize: 20)

    /// 降档尺寸。曾经是 100×63（全局切换器专用），那一档小得没了气势；
    /// 120×75 是「一屏多塞四成」和「还看得出是哪个页面」之间的折中。
    static let compact = CardMetrics(thumbWidth: 120, thumbHeight: 75, titleRowHeight: 18,
                                     padding: 6, titleFont: 10.5, faviconSize: 12,
                                     thumbCorner: 6, cardCorner: 9, badgeSize: 18)
}

private let kCardSpacing: CGFloat = 8
private let kOuterPadding: CGFloat = 12
private let kPanelCornerRadius: CGFloat = 14

// 全局切换器（列表样式）的行高与分组头。列表比卡片信息密度高，
// 跨浏览器一屏能装下的标签多得多。
private let kListWidth: CGFloat = 520
/// 全局卡片样式的目标面板宽度（屏幕更窄时按屏幕来）。
///
/// 存在的理由是超宽屏：列数只夹屏幕的话，一个浏览器开二十个标签就排成
/// 横贯整屏的一长条 —— 眼睛得转头才扫得完。宁可多换一行。
/// 1440 这个值恰好给 8 列大卡片，和常见笔电全屏时浏览器内切换器的列数一致。
private let kGlobalCardsTargetWidth: CGFloat = 1440
/// 全局**列表**样式的面板高度上限，超出的部分滚动。
///
/// 不能只按屏幕算：跨浏览器的标签动辄几十个，94% 屏高的列表从上顶到下，
/// 眼睛要扫一整屏才找得到高亮那行。卡片样式不受这个限制 —— 它靠降档
/// （见 CardMetrics）把内容收进一屏，再夹高度只会让卡片白白变小还得滚。
private let kGlobalListMaxHeight: CGFloat = 520
/// 两行行高：标题一行、域名一行。
private let kRowHeight: CGFloat = 42
private let kRowSpacing: CGFloat = 1
private let kGroupHeaderHeight: CGFloat = 22
/// 分组头和它下面第一行之间的空档，含那道 1px 分隔线。
/// 视图和尺寸计算必须用同一个值，否则面板高度和实际内容对不上。
private let kGroupRuleSpace: CGFloat = 7
private let kGroupSpacing: CGFloat = 14

/// 行内左边距。分组头用同一个值，并让它的图标和行 favicon 同宽同位 ——
/// 这样分组名和标签名落在同一条竖线上（不对齐是第一版最扎眼的毛病）。
private let kRowInset: CGFloat = 10
/// favicon 与文字之间的间距。分组头同样沿用。
private let kRowIconGap: CGFloat = 9
private let kRowIconSize: CGFloat = 17

// MARK: - SwiftUI 内容

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let presentation: SwitcherPresentation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            content
            // 只有键盘移动游标时才自动滚动。
            //
            // hover 也触发滚动的话会形成正反馈环：滚动让卡片在屏幕上位移 →
            // 鼠标底下换成了别的卡片 → 又触发 hover → 又滚动，游标会一路
            // 飞到列表尽头。而且 hover 本来就不需要滚动 —— 鼠标能指到的
            // 卡片必然已经在可视区内。
            .onChange(of: model.cursor) { newValue in
                guard model.cursorSource == .keyboard,
                      model.items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.items[newValue].id, anchor: .center)
                }
            }
        }
        // 材质（.hudWindow）负责「透」，叠色负责定调。
        //
        // 深色沿用低透明度的烟灰，通透感靠材质透出来。**浅色不能照抄这个思路**：
        // 半透明面板的最终亮度由**背后的内容**主导 —— 浅色外观浮在深色终端上
        // 时，材质怎么调都是一块中灰，代码覆盖不了（PasteMemo 那轮玻璃实验
        // 屏上实测过）。全局切换器恰恰会浮在任何 App 之上，所以浅色这层叠色
        // 必须够厚，先把底子压成白的；少掉的那点通透是这笔交易的代价。
        .background {
            scheme == .dark ? Color(red: 64/255, green: 64/255, blue: 72/255).opacity(0.35)
                            : Color(red: 253/255, green: 252/255, blue: 251/255).opacity(0.88)
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

    @ViewBuilder
    private var content: some View {
        switch presentation.layout {
        case .strip:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: kCardSpacing) { cards(model.items) }
                    .padding(kOuterPadding)
            }

        case .grid(let columns):
            // 宫格：面板尺寸在 presentNow 里已按「一屏放得下」算好，
            // 只有标签多到连整屏宫格都装不下时才会真的纵向滚动。
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridItems(columns), spacing: kCardSpacing) {
                    cards(model.items)
                }
                .padding(kOuterPadding)
            }

        case .globalCards(let columns):
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: kGroupSpacing) {
                    ForEach(groups, id: \.browser) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            // 分组头对齐缩略图左缘（卡片自身还有一圈内边距）
                            if presentation.grouped {
                                groupHeader(group, inset: metrics.padding)
                            }
                            LazyVGrid(columns: gridItems(columns),
                                      alignment: .leading,
                                      spacing: kCardSpacing) {
                                cards(group.items)
                            }
                        }
                    }
                }
                .padding(kOuterPadding)
            }

        case .globalList:
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: kGroupSpacing) {
                    ForEach(groups, id: \.browser) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if presentation.grouped {
                                groupHeader(group, inset: kRowInset)
                            }
                            VStack(alignment: .leading, spacing: kRowSpacing) {
                                ForEach(group.items) { item in
                                    TabRow(item: item,
                                           icon: model.icons[item.id],
                                           selected: item.id == selectedID,
                                           onHover: { model.onHover?(item.id) },
                                           onPick: { model.onPick?(item.id) })
                                        .id(item.id)
                                }
                            }
                        }
                    }
                }
                .padding(kOuterPadding)
            }
        }
    }

    /// 这个排布用哪套卡片尺寸。档位由布局计算定（一屏装不下才降），
    /// 视图只照做 —— 两边各判一次的话，面板尺寸和卡片大小迟早对不上。
    private var metrics: CardMetrics {
        presentation.compact ? .compact : .standard
    }

    /// 开关默认关；开了之后剩 2 项时也不给 ✕：再关 1 个就只剩单标签，
    /// 而切换器本来就不为单标签出现，关到那一步面板就没意义了。
    ///
    /// 全局切换器一律不给：跨浏览器的列表里关的是**别的浏览器**里、
    /// 此刻根本不在你眼前的标签，误点的代价和"切过去"完全不对等。
    /// 少了这个槽位，行尾的时间也能齐齐地贴住右边。
    private var closable: Bool {
        switch presentation.layout {
        case .globalList, .globalCards: return false
        case .strip, .grid:             return model.allowClose && model.items.count > 2
        }
    }

    /// 当前选中项的 id。用它比对而不是让每张卡片去 firstIndex 反查位置 ——
    /// 后者是 O(n) × n 张卡片，标签一多每帧都在做无谓的线性扫描。
    private var selectedID: String? {
        model.items.indices.contains(model.cursor) ? model.items[model.cursor].id : nil
    }

    private func gridItems(_ columns: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.width), spacing: kCardSpacing), count: max(1, columns))
    }

    /// 按浏览器切段。items 进来时同一浏览器的项已经连在一起（MRUController
    /// 就是按组拼的），这里只做**连续切分**、不重排 —— 排序权归状态机。
    private var groups: [(browser: String, items: [SwitcherItem])] {
        var result: [(browser: String, items: [SwitcherItem])] = []
        for item in model.items {
            let key = item.browser ?? ""
            if result.last?.browser == key {
                result[result.count - 1].items.append(item)
            } else {
                result.append((key, [item]))
            }
        }
        return result
    }

    /// 分组头：浏览器图标 + 名字 + 标签数。
    ///
    /// 图标占的格子和下面每一行的 favicon **同宽同位**，名字自然就和标签名
    /// 落在同一条竖线上。图标本身画得比格子小一圈，让它读起来是「表头」
    /// 而不是又一行标签。
    /// 分组头 + 一道发丝分隔线。
    ///
    /// 光靠「图标 + 加粗名字」分不开：那个组合和下面的标签行长得太像，
    /// 读起来只是「又一行」。所以头部反过来做——**字更小、更淡、字距拉开**，
    /// 明确是标签而不是内容；真正划清界限的是那道横线。
    private func groupHeader(_ group: (browser: String, items: [SwitcherItem]),
                             inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: kRowIconGap) {
                Group {
                    if let icon = BrowserSupport.icon(group.browser) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: kRowIconSize - 3, height: kRowIconSize - 3)
                .frame(width: kRowIconSize, height: kRowIconSize)
                .opacity(0.85)

                Text(BrowserSupport.displayName(group.browser))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(0.45))

                Spacer(minLength: 8)

                countBadge(group.items.count)
            }
            .frame(height: kGroupHeaderHeight)
            .padding(.horizontal, inset)

            Rectangle()
                .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                .frame(height: 1)
                .padding(.bottom, kGroupRuleSpace - 1)
        }
    }

    /// 分组头右端的数量徽标。靠右放而不是紧跟在浏览器名后面 ——
    /// 名字长度参差，跟在后面时每一组的数字位置都不一样，扫一眼比不出来；
    /// 右对齐后几组的数量自然排成一列。
    private func countBadge(_ count: Int) -> some View {
        Text(L10n.t("\(count) 个标签", count == 1 ? "1 tab" : "\(count) tabs"))
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.11)
                                               : Color.black.opacity(0.06))
            }
    }

    /// 各排布共用同一组卡片。`.id(item.id)` 供 ScrollViewReader 按游标定位。
    ///
    /// 身份必须用 item.id 而不是位置：用位置当身份的话，删掉一张卡后右侧所有
    /// 卡片的 index 全变 → SwiftUI 把它们当「销毁 + 新建」处理，移除动画期间
    /// 新旧视图并存，点击可能落在携带旧位置的残影上。用 item.id 卡片只是
    /// 「移动」，视图和数据的对应关系全程不断。
    private func cards(_ items: [SwitcherItem]) -> some View {
        ForEach(items) { item in
            TabCard(tab: item.tab,
                    metrics: metrics,
                    icon: model.icons[item.id],
                    thumb: model.thumbs[item.id],
                    selected: item.id == selectedID,
                    closable: closable,
                    onHover: { model.onHover?(item.id) },
                    onPick: { model.onPick?(item.id) },
                    onClose: { model.onClose?(item.id) })
                .id(item.id)
        }
    }
}

private struct TabCard: View {
    let tab: TabInfo
    let metrics: CardMetrics
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
        VStack(spacing: metrics.padding - 1) {
            thumbnail
                .frame(width: metrics.thumbWidth, height: metrics.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: metrics.thumbCorner, style: .continuous))
                // 「玻璃·浅调」的立体卡处理:1px 描边划清边界(0.5px·7% 那条
                // 发丝线撑不住白卡贴灰面板)。选中 = accent 蓝框(2px)+ 底下灰底,
                // 两种外观下都醒目。
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.thumbCorner, style: .continuous)
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

            HStack(spacing: metrics.padding - 2) {
                Group {
                    if let icon {
                        Image(nsImage: icon.image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                    }
                }
                .scaledToFit()
                .frame(width: metrics.faviconSize, height: metrics.faviconSize)
                .padding(icon == nil ? 0 : metrics.faviconSize * 0.115)
                .background {
                    if let icon { faviconBacking(isLight: icon.isLight, radius: metrics.thumbCorner - 4) }
                }

                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: metrics.titleFont, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 未选中不是"淡出"而是"不加粗"。.secondary 太浅了,
                    // Arc 的未选中标题也是接近黑的深灰,只靠字重区分。
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))

                Spacer(minLength: 0)
            }
            .frame(width: metrics.thumbWidth, height: metrics.titleRowHeight)
        }
        .padding(metrics.padding)
        .frame(width: metrics.width, height: metrics.height)
        // 选中态就是一块灰底，没有边框 —— Arc 的做法。
        // 之前那圈 1.5px 蓝框和它整体的克制感格格不入。
        // 未选中完全透明；语义色 primary 自动适配深浅色外观。
        // 深色选中底从白 18% 提到 28%:未选中缩略图底本身就是白 14%,
        // 只差 4 个百分点的话整块面板都挤在一条窄灰带里,选中格看不出来。
        .background {
            RoundedRectangle(cornerRadius: metrics.cardCorner, style: .continuous)
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
            .font(.system(size: metrics.badgeSize * 0.44, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
            .frame(width: metrics.badgeSize - 2, height: metrics.badgeSize - 2)
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
                .font(.system(size: metrics.badgeSize * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: metrics.badgeSize, height: metrics.badgeSize)
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
                    .frame(width: metrics.thumbHeight * 0.36, height: metrics.thumbHeight * 0.36)
                    .padding(metrics.thumbHeight * 0.125)
                    .background {
                        faviconBacking(isLight: icon.isLight, radius: metrics.thumbHeight * 0.125)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14),
                                    radius: 5, y: 2)
                    }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: metrics.thumbHeight * 0.3))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// favicon + 反差底板。
///
/// 亮图标（GitHub 深色模式那只白猫）垫深底，暗图标（多数品牌 logo）垫浅底。
/// 不跟随系统外观 —— 决定可见性的是图标自己的颜色，不是界面的明暗。
private struct FaviconChip: View {
    let icon: IconInfo?
    var size: CGFloat = 13
    var radius: CGFloat = 3
    /// 是否垫反差底板。缩略图上必须垫（图标要压在截图上），
    /// 列表里不垫（一列白方块会盖过标题）。
    var plate: Bool = true

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .padding(icon == nil || !plate ? 0 : size * 0.115)
        .background {
            if let icon, plate {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(icon.isLight ? Color(white: 0.16) : Color(white: 0.99))
            }
        }
    }
}

/// 全局切换器「列表」样式的一行。
///
/// 不放缩略图：跨浏览器的列表本来就长，一行一个标题的信息密度才撑得住
/// 「先定浏览器、再扫标题」这个用法（想要图就切「卡片」样式）。
private struct TabRow: View {
    let item: SwitcherItem
    let icon: IconInfo?
    let selected: Bool
    let onHover: () -> Void
    let onPick: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// 上一次的鼠标**屏幕**坐标。理由与 TabCard 相同：列表滚动时视图局部
    /// 坐标会变，用它判断「鼠标动没动」会把滚动误判成移动。
    @State private var lastMouseScreenPoint: CGPoint?

    /// 右侧的域名。剥掉 www.，超长的从头部截断（保留能认出站点的尾部）——
    /// 交给 SwiftUI 去挤压的话，长标题一来域名就被压成一个孤零零的「…」。
    private var host: String {
        guard var host = URL(string: item.tab.url)?.host else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.count > 28 ? "…" + host.suffix(26) : host
    }

    var body: some View {
        HStack(spacing: kRowIconGap) {
            // 不垫反差底板：列表里 favicon 一列白方块太抢眼，压过了标题。
            // 代价是纯白透明底的图标（GitHub 深色模式那只猫）在浅色面板上会淡，
            // 真碍事的话把 plate 打开就行。
            FaviconChip(icon: icon, size: kRowIconSize, radius: 4, plate: false)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.tab.title.isEmpty ? item.tab.url : item.tab.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))

                    if item.tab.pinned == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
                    }
                }

                // 取不到域名（about:blank 之类）就不留空行，标题自己居中
                if !host.isEmpty {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 「多久之前打开」放行尾。fixedSize + 高优先级：长标题该让路的是
            // 标题（它本来就会截断），不是这一栏 —— 让它挤成一个孤零零的
            // 「…」比不显示还难看。
            if let ago = item.tab.relativeLastAccessed {
                Text(ago)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.30))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

        }
        .padding(.horizontal, kRowInset)
        .frame(height: kRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.20)
                                                  : Color.black.opacity(0.10))
                               : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        // 只有鼠标真的移动过才让 hover 接管游标（同 TabCard）。
        .onContinuousHover { phase in
            switch phase {
            case .active:
                let point = NSEvent.mouseLocation
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

    /// 本轮是不是全局切换器（内容跨浏览器）。MRUController 在起手拍快照时置位，
    /// presentNow 用它决定用哪套排布、以及贴哪儿。
    var isGlobal = false

    /// 当前正在显示的排布。关标签后重算时用它判断要不要重建 rootView；
    /// MRUController 也读它来决定方向键在这个排布下各自是什么意思。
    private(set) var presentation = SwitcherPresentation(layout: .strip)

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherView>?
    private var hideWorkItem: DispatchWorkItem?
    private var shownAt: Date?

    /// presentNow 按 Chrome 窗口 / 屏幕算出的面板尺寸上限。
    /// 关标签后重算布局（applyRemoval）沿用同一套上限，收缩前后同一套规则。
    private var panelMaxSize = NSSize.zero

    /// presentNow 拍下的定位基准：面板居中对齐的矩形（浏览器窗口 / 屏幕可见区）
    /// 和所在屏幕的可见区（夹取用）。关标签后行数变了要重新居中，得回到
    /// **同一个**基准 —— 不能在 cycling 中途重问 ChromeWindowLocator：那是
    /// 跨进程调用，而且前台窗口这期间还会变（同「起手拍快照」的语义）。
    private var panelAnchor = NSRect.zero
    private var panelVisibleFrame = NSRect.zero

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

    /// 起手新一轮 cycling：模式和内容都换了，先决定还能不能复用上一轮的面板。
    ///
    /// 上一轮结束后面板要等最短可见时间才真的关掉（见 hide），这段窗口里
    /// 又按一次就会复用它。同模式同尺寸复用没问题；**排布或尺寸变了**却
    /// 复用，新内容会套着旧排布、旧尺寸、旧位置显示 —— 在浏览器里切一下
    /// 再立刻按全局键，全局列表会被塞进上一轮那个长条面板里。
    func beginCycle(isGlobal: Bool, items: [SwitcherItem]) {
        self.isGlobal = isGlobal
        guard let panel, !items.isEmpty else { return }
        let (size, layout) = contentLayout(items: items,
                                           maxWidth: panelMaxSize.width,
                                           maxHeight: panelMaxSize.height)
        if layout != presentation || size != panel.frame.size { closeNow() }
    }

    func requestShow() {
        // 上一轮还在等最短可见时间就又开始了新一轮 —— 面板还能用就复用
        // （能不能用由 beginCycle 判过了）
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
    func applyRemoval(items: [SwitcherItem], cursor: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            model.items = items
            model.setCursor(cursor, source: .mouse)
        }

        guard let panel, !items.isEmpty else { return }

        let (size, layout) = contentLayout(items: items,
                                           maxWidth: panelMaxSize.width,
                                           maxHeight: panelMaxSize.height)
        if layout != presentation {
            presentation = layout
            hostingView?.rootView = SwitcherView(model: model, presentation: layout)
        }
        guard size != panel.frame.size else { return }

        // 行数变了（宫格里高度只由行数和卡片档位决定）= 卡片整体重排：末行的
        // 卡片全跑到上一行尾巴上，列数也跟着重新平衡，宽度甚至会**涨**回来
        //（10 张 5×2 → 6 张 1×6）。左上角锚定这时一张卡片都没保住，只留下
        // 一个顶边卡在原处的偏心面板。所以回到 presentNow 的居中规则。
        //
        // 行数没变（只是列数少一列）才继续锚左上角：被删卡片左侧的所有卡片
        // 在屏幕上纹丝不动，右侧邻居滑进原位 —— 和 Chrome 标签栏连续关标签
        // 的手感一致。之前无条件按中心收缩，每关一张所有卡片横移半张宽，
        // 鼠标下的目标一直在跑。
        let frame: NSRect
        if size.height == panel.frame.height {
            // 只收不涨一般不会越界，但保持与 presentNow 同一套夹取规则
            frame = clampedToVisible(NSRect(origin: panel.frame.origin, size: size))
        } else {
            frame = centeredFrame(size: size)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func presentNow() {
        guard !model.items.isEmpty else { return }
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

        // 贴着浏览器窗口居中；全局切换器不属于任何一个浏览器窗口（前台多半
        // 根本不是浏览器），改在当前屏幕居中。
        let defaultScreen = NSScreen.main ?? NSScreen.screens[0]
        let anchor = isGlobal ? defaultScreen.visibleFrame
                              : (ChromeWindowLocator.frontmostWindowFrame() ?? defaultScreen.visibleFrame)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? defaultScreen

        // 面板尺寸上限：不越出浏览器窗口，也不越出所在屏幕的可见区。
        let maxPanelWidth = min(anchor.width, screen.visibleFrame.width) * 0.94
        let maxPanelHeight = min(anchor.height, screen.visibleFrame.height) * 0.94
        panelMaxSize = NSSize(width: maxPanelWidth, height: maxPanelHeight)
        panelAnchor = anchor
        panelVisibleFrame = screen.visibleFrame

        let (contentSize, layout) = contentLayout(items: model.items,
                                                  maxWidth: maxPanelWidth,
                                                  maxHeight: maxPanelHeight)
        presentation = layout
        let width = contentSize.width
        let height = contentSize.height

        let hosting = NSHostingView(rootView: SwitcherView(model: model, presentation: layout))

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
        panel.setFrameOrigin(centeredFrame(size: panel.frame.size).origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()             // 不激活自己,焦点留在 Chrome
        // 上屏之后才有 window number，阴影参数只能这时候设（见 WindowShadow —— 它
        // 自己会等 WindowServer 把阴影初始化完，别改成一次性调用）
        WindowShadow.applyStandardWindowShadow(to: panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.hostingView = hosting
        self.shownAt = Date()

        log("浮层 \(layout.describe(count: model.items.count))  \(Int(width))×\(Int(height))  上限 \(Int(maxPanelWidth))×\(Int(maxPanelHeight))")
    }

    /// 把这个尺寸的面板摆到定位基准中心。presentNow 定位、applyRemoval 行数
    /// 变化后重新居中，共用这一份 —— 两处各抄一套的话，收缩后的「居中」
    /// 会和起手那一下差几个 pt，肉眼就是抖一下。
    private func centeredFrame(size: NSSize) -> NSRect {
        clampedToVisible(NSRect(x: panelAnchor.midX - size.width / 2,
                                y: panelAnchor.midY - size.height / 2,
                                width: size.width, height: size.height))
    }

    /// 夹回屏幕可见区（浏览器窗口可能有一部分在屏幕外）。
    private func clampedToVisible(_ frame: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.origin.x, panelVisibleFrame.minX + 8),
                             panelVisibleFrame.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.origin.y, panelVisibleFrame.minY + 8),
                             panelVisibleFrame.maxY - frame.height - 8)
        return frame
    }

    /// 算面板内容尺寸和排布。presentNow 和 applyRemoval 共用这一份，别各抄一套。
    ///
    /// 全局切换器走自己的两种排布（都按浏览器分组），与「切换器布局」设置无关 ——
    /// 那个设置管的是当前浏览器切换器。
    private func contentLayout(items: [SwitcherItem],
                               maxWidth: CGFloat,
                               maxHeight: CGFloat) -> (size: NSSize, presentation: SwitcherPresentation) {
        let count = items.count
        guard !isGlobal else {
            return globalLayout(items: items, maxWidth: maxWidth, screenMaxHeight: maxHeight)
        }

        switch settings.switcherLayout {
        case .strip:
            // 长条**不降档**：它本来就是横向滚动的排布，把卡片缩小并不能
            // 让「一屏装下」变成真的（20 个标签缩到 120pt 宽照样超屏），
            // 只是每张都变小了。标签多时它的答案就是滚动。
            let card = CardMetrics.standard
            let n = CGFloat(count)
            let naturalWidth = n * card.width + max(0, n - 1) * kCardSpacing + kOuterPadding * 2
            return (NSSize(width: min(naturalWidth, maxWidth),
                           height: card.height + kOuterPadding * 2),
                    SwitcherPresentation(layout: .strip))

        case .grid:
            let (fit, compact) = fittedGrid(count: count, maxWidth: maxWidth, maxHeight: maxHeight)
            return (fit.size, SwitcherPresentation(layout: .grid(columns: fit.columns), compact: compact))
        }
    }

    /// 一次网格试算的结果。
    private struct GridFit {
        let columns: Int
        let rows: Int
        /// 所有卡片都在可视区内（不需要纵向滚动）。
        let fits: Bool
        let size: NSSize
    }

    /// 连续网格（当前浏览器宫格 / 只有一个浏览器的全局卡片）的列数与面板尺寸。
    ///
    /// 先按塞满宽度算至少要几行，再回头平衡列数：30 个标签在 12 列上限下
    /// 排成 10×3，而不是 12+12+6 那种最后一行孤零零的样子。
    private func gridFit(count: Int, card: CardMetrics,
                         maxWidth: CGFloat, maxHeight: CGFloat) -> GridFit {
        let maxCols = max(1, Int((maxWidth - kOuterPadding * 2 + kCardSpacing)
                                 / (card.width + kCardSpacing)))
        let maxRows = max(1, Int((maxHeight - kOuterPadding * 2 + kCardSpacing)
                                 / (card.height + kCardSpacing)))
        let neededRows = (max(1, count) + maxCols - 1) / maxCols
        let fits = neededRows <= maxRows
        let cols = fits ? (max(1, count) + neededRows - 1) / neededRows : maxCols
        let rows = min(neededRows, maxRows)
        return GridFit(
            columns: cols,
            rows: rows,
            fits: fits,
            size: NSSize(width: CGFloat(cols) * card.width + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2,
                         height: CGFloat(rows) * card.height + CGFloat(rows - 1) * kCardSpacing + kOuterPadding * 2))
    }

    /// 网格排布的卡片档位：一屏装得下就用大卡片，装不下降**一**档再试。
    ///
    /// 只有这两档 —— 再往下缩，缩略图就只剩一块糊，卡片模式的全部价值
    /// （一眼认出是哪个页面）也就没了。compact 还装不下就老实纵向滚动，
    /// 游标会自动滚到可视区中央（见 SwitcherView 的 onChange）。
    ///
    /// 判据是「装不装得下」而不是标签数阈值：同样 40 个标签，27 寸屏上
    /// 大卡片一屏就够，13 寸上才需要降档 —— 阈值写死的话必然在某块屏上判错。
    private func fittedGrid(count: Int, maxWidth: CGFloat, maxHeight: CGFloat)
        -> (fit: GridFit, compact: Bool) {
        let standard = gridFit(count: count, card: .standard, maxWidth: maxWidth, maxHeight: maxHeight)
        guard !standard.fits else { return (standard, false) }
        return (gridFit(count: count, card: .compact, maxWidth: maxWidth, maxHeight: maxHeight), true)
    }

    /// 全局切换器的尺寸：按分组逐段累加，超过屏幕就纵向滚动。
    private func globalLayout(items: [SwitcherItem],
                              maxWidth: CGFloat,
                              screenMaxHeight: CGFloat) -> (size: NSSize, presentation: SwitcherPresentation) {
        // 每个浏览器的标签数（顺序即 items 里的连续分段）
        var groupSizes: [Int] = []
        var lastBrowser: String?
        for item in items {
            if item.browser == lastBrowser, !groupSizes.isEmpty {
                groupSizes[groupSizes.count - 1] += 1
            } else {
                groupSizes.append(1)
                lastBrowser = item.browser
            }
        }
        let groupCount = max(1, groupSizes.count)
        let gaps = CGFloat(groupCount - 1) * kGroupSpacing
        // 只有一个浏览器就不画分组头。视图读的是同一个标志（presentation.grouped），
        // 这里算高度也必须跟着减，否则面板底部会裁掉半行。
        let grouped = groupCount > 1
        let headerHeight = grouped ? kGroupHeaderHeight + kGroupRuleSpace : 0

        switch settings.globalSwitcherStyle {
        case .list:
            let maxHeight = min(screenMaxHeight, kGlobalListMaxHeight)
            let rowsHeight = groupSizes.reduce(CGFloat.zero) { total, n in
                total + headerHeight + CGFloat(n) * kRowHeight + CGFloat(n - 1) * kRowSpacing
            }
            let height = min(rowsHeight + gaps + kOuterPadding * 2, maxHeight)
            return (NSSize(width: min(kListWidth, maxWidth), height: height),
                    SwitcherPresentation(layout: .globalList, grouped: grouped))

        case .cards:
            let targetWidth = min(maxWidth, kGlobalCardsTargetWidth)

            // 只有一个浏览器时，内容和当前浏览器切换器没有任何区别 ——
            // 那就长得一模一样：同一套卡片尺寸、同一套平衡列数、同一套降档规则。
            // 分组头省掉之后，剩下的差异只有「贴屏幕居中」而不是「贴浏览器窗口」。
            guard grouped else {
                let (fit, compact) = fittedGrid(count: items.count,
                                                maxWidth: targetWidth,
                                                maxHeight: screenMaxHeight)
                return (fit.size, SwitcherPresentation(layout: .globalCards(columns: fit.columns),
                                                       compact: compact))
            }

            // 多浏览器：每组独立换行（小组不会被大组撑出一堆空位），
            // 所以列数取「最大的那组一行放得下」而不是平衡列数。
            // 高度装不下时和宫格同样降一档卡片，再装不下就滚。
            func fit(_ card: CardMetrics) -> (cols: Int, size: NSSize, fits: Bool) {
                let maxCols = max(1, Int((targetWidth - kOuterPadding * 2 + kCardSpacing)
                                         / (card.width + kCardSpacing)))
                let cols = max(1, min(maxCols, groupSizes.max() ?? 1))
                let sectionsHeight = groupSizes.reduce(CGFloat.zero) { total, n in
                    let rows = CGFloat((n + cols - 1) / cols)
                    return total + headerHeight + rows * card.height + (rows - 1) * kCardSpacing
                }
                let natural = sectionsHeight + gaps + kOuterPadding * 2
                let width = CGFloat(cols) * card.width + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2
                return (cols,
                        NSSize(width: min(width, maxWidth), height: min(natural, screenMaxHeight)),
                        natural <= screenMaxHeight)
            }

            let standard = fit(.standard)
            let chosen = standard.fits ? standard : fit(.compact)
            return (chosen.size,
                    SwitcherPresentation(layout: .globalCards(columns: chosen.cols),
                                         compact: !standard.fits,
                                         grouped: true))
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
    ///
    /// 结果缓存：全局切换器的分组头每帧都要问一次名字和图标，而这两个查询
    /// 都要走 Launch Services / 文件系统 —— 放进 SwiftUI 的 body 求值里
    /// 就是每次重绘都做一次跨进程调用。
    static func displayName(_ bundleID: String) -> String {
        if let hit = nameCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        nameCache[bundleID] = name
        return name
    }

    /// 浏览器的 App 图标（全局切换器的分组头、状态栏菜单用）。
    static func icon(_ bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]

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

    /// 最前面那个浏览器窗口的 frame，AppKit 坐标系（左下原点）。
    ///
    /// 主路径走 AX：`kAXFocusedWindow` 是浏览器自己认定的「用户正在用的那个
    /// 窗口」，语义正好是我们要的。辅助功能权限是 CGEventTap 的前提 —— 没有
    /// 它切换器根本不会被唤起，所以这条依赖不是新增的失败面。
    ///
    /// 兜底才扫 CGWindowList（只读窗口几何，不需要屏幕录制权限）。
    static func frontmostWindowFrame() -> NSRect? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: activeBundleID)
        guard let pid = running.first?.processIdentifier else { return nil }

        guard let bounds = axFocusedWindowBounds(pid: pid) ?? cgFrontmostWindowBounds(pid: pid) else {
            return nil
        }

        // AX 和 CGWindowList 都用左上原点的全局坐标,原点在主屏左上角;
        // AppKit 用左下原点。换算基准必须是主屏(screens[0])的高度。
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: bounds.minX,
                      y: primaryHeight - bounds.maxY,
                      width: bounds.width,
                      height: bounds.height)
    }

    /// 浏览器自己认定的焦点窗口。
    ///
    /// 地址栏展开时，那个建议下拉是一个**独立窗口**（`role=AXWindow`、
    /// `subrole=AXUnknown`、无标题），盖在主窗口上面；但 `kAXFocusedWindow`
    /// 始终指向主窗口，下拉从不入选（实测）。扩展 popup、下载气泡同理。
    private static func axFocusedWindowBounds(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // 这条在按键关键路径上：浏览器没响应时别把浮层一起拖住 —— 超时了走
        // CG 兜底，那条路不需要浏览器进程应答，照样拿得到几何。
        // 实测整条路径（含 create）中位 0.058ms、最大 0.133ms，
        // 0.15s 已是正常值的一千倍，纯粹当保险丝。
        AXUIElementSetMessagingTimeout(app, 0.15)

        guard let window = axElement(app, kAXFocusedWindowAttribute)
                        ?? axElement(app, kAXMainWindowAttribute),
              let origin = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute),
              // 病态测量值不要拿去定位（同 PermissionFlow 那轮的教训）
              size.width > 1, size.height > 1
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    /// 兜底：AX 取不到时扫 CGWindowList。
    ///
    /// 这里不能直接取「z 序最前的够大窗口」—— 地址栏下拉同样是 layer 0，
    /// 展开后也远超 200²，而且盖在主窗口上面（z 序更靠前）。CG 侧拿不到
    /// subrole，窗口标题又要屏幕录制权限（不该为此多要一个权限），只剩
    /// 几何判据：子窗口完全落在主窗口内部，据此排除。
    private static func cgFrontmostWindowBounds(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // CGWindowList 的返回值是按前后顺序排的，第一个匹配的就是最前面那个。
        // 注意：字典里的数值是 CFNumber，`as? Int32` 会静默全部落空，
        // 必须先桥到 NSNumber 再取值。
        var candidates: [CGRect] = []
        for entry in list {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,                                   // 0 = 普通窗口,滤掉浮动面板
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  // 太小的多半是提示条之类,不当主窗口
                  bounds.width > 200, bounds.height > 200
            else { continue }
            candidates.append(bounds)
        }

        // 两个窗口 frame 完全相同时互不排除（`!=` 挡掉），仍按 z 序取最前那个。
        return candidates.first { candidate in
            !candidates.contains { $0 != candidate && $0.contains(candidate) }
        }
    }

    // MARK: AX 取值

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
