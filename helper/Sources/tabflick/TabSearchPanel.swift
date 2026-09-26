import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 行与选中结果

/// 面板列表里的一行。三种来源混排在同一张列表里，游标和 ⌘ 数字按屏上顺序连续编号。
enum SearchRow: Identifiable {
    /// 活着的标签（切换）
    case tab(SwitcherItem)
    /// 已关闭的标签（找回，新标签打开）
    case closed(ClosedTab)
    /// 查询本身像个网址（新标签打开）
    case url(String)
    /// 书签（新标签打开）
    case bookmark(BookmarkInfo)

    var id: String {
        switch self {
        case .tab(let item):     return item.id
        case .closed(let entry): return "closed#\(entry.id)"
        case .url(let url):      return "url#\(url)"
        case .bookmark(let bm):  return "bm#\(bm.path)#\(bm.url)"
        }
    }

    var favIconUrl: String {
        switch self {
        case .tab(let item):     return item.tab.favIconUrl
        case .closed(let entry): return entry.favIconUrl
        case .url, .bookmark:    return ""
        }
    }
}

/// 用户在面板里选定了什么。面板已经关掉、键盘焦点已回到浏览器。
enum SearchPick {
    case tab(SwitcherItem)
    case closed(ClosedTab)
    case url(String)
    case bookmark(BookmarkInfo)
}

// MARK: - 视图模型

/// 标签搜索面板的状态。`rows` 是 `all` / `closed` / 查询经 `TabSearch` 过滤后的投影。
@MainActor
final class TabSearchModel: ObservableObject {
    /// 当前浏览器的全部标签，MRU 顺序，index 0 是当前标签。
    @Published private(set) var all: [SwitcherItem] = []
    /// 当前浏览器最近关闭的标签，按关闭时间降序。只在有查询时参与。
    @Published private(set) var closed: [ClosedTab] = []
    /// 当前浏览器的书签。只在有查询时参与。
    @Published private(set) var bookmarks: [BookmarkInfo] = []
    @Published var query = "" {
        didSet { guard oldValue != query else { return }; refilter(keepCursorOn: nil) }
    }
    @Published private(set) var rows: [SearchRow] = [] {
        // 行数 / 分组头变了面板要改高度。放 didSet 而不是订阅 $rows：@Published 在
        // willSet 发出，那时窗口先缩、内容后换，肉眼就是闪一下；didSet 里值已落定，
        // 同步改窗口尺寸时 SwiftUI 会在同一次布局里换上新内容。
        didSet {
            let height = contentHeight
            if height != lastContentHeight {
                lastContentHeight = height
                onContentHeightChange?(height)
            }
        }
    }
    /// 活标签行的数量。已关闭那一段从这个下标开始（如果有）。
    @Published private(set) var liveCount = 0
    /// 已关闭行的数量。书签那一段从 `liveCount + closedCount` 开始（如果有）。
    @Published private(set) var closedCount = 0
    @Published private(set) var cursor = 0
    /// favicon，按 favIconUrl 索引（活标签和已关闭共用一份）。
    @Published var icons: [String: IconInfo] = [:]
    /// ⌘ 正被按着：行尾显示 ⌘1–⌘9 的角标。
    @Published var commandHeld = false

    private var lastContentHeight: CGFloat = -1
    var onContentHeightChange: ((CGFloat) -> Void)?

    /// 游标这次是被谁移动的。只有键盘移动才自动滚动 —— 理由同 SwitcherModel：
    /// hover 改游标 → 滚动 → 鼠标下换了一行 → 又 hover，游标会一路飞到底。
    private(set) var cursorSource: CursorSource = .keyboard

    /// 当前标签的 id（`all` 的首项）。行尾用「当前」代替时间。
    var currentID: String? { all.first?.id }

    /// 已关闭那一段有没有画出来（有匹配的关闭记录时才有）。
    var hasClosedSection: Bool { closedCount > 0 }
    /// 书签那一段有没有画出来。
    var hasBookmarkSection: Bool { rows.count > liveCount + closedCount && bookmarkRows > 0 }
    private var bookmarkRows = 0
    var bookmarkStart: Int { liveCount + closedCount }

    /// 能不能在面板里关标签：只剩一个标签时不关 —— 关掉浏览器窗口就跟着没了。
    var canCloseTabs: Bool { all.count > 1 }

    var onPick: ((SearchRow) -> Void)?
    /// 要求关掉某个活标签（参数 item.id）。
    var onCloseTab: ((String) -> Void)?

    /// 标题 → 拼音索引的缓存。逐字转拼音不算便宜，标题在两次刷新之间基本不变。
    private var pinyinCache: [String: (full: String, initials: String)] = [:]

    func setCursor(_ index: Int, source: CursorSource) {
        cursorSource = source
        cursor = index
    }

    /// 换一份数据。面板开着时 MRU 推送也会走这里，游标尽量留在原来那一项上；
    /// 每次打开（`keepCursor: false`）则从头算 —— 面板常驻，上一轮的游标还留在
    /// 模型里，继承它会落到刚切过去的那个标签，也就是现在的「当前」，毫无意义。
    func setItems(_ items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
                  keepCursor: Bool = true) {
        let keep = keepCursor && rows.indices.contains(cursor) ? rows[cursor].id : nil
        all = items
        self.closed = closed
        self.bookmarks = bookmarks
        refilter(keepCursorOn: keep)
    }

    private func candidate(title: String, url: String) -> SearchCandidate {
        let py: (full: String, initials: String)
        if let cached = pinyinCache[title] {
            py = cached
        } else {
            py = Pinyin.index(title)
            pinyinCache[title] = py
        }
        return SearchCandidate(title: title, url: url, pinyin: py.full, initials: py.initials)
    }

    /// 已关闭 / 书签各自最多列这么多条。
    static let closedLimit = 5
    static let bookmarkLimit = 5

    private func refilter(keepCursorOn keep: String?) {
        let liveCandidates = all.map { candidate(title: $0.tab.title, url: $0.tab.url) }
        var next: [SearchRow] = TabSearch.rank(liveCandidates, query: query).map { .tab(all[$0]) }
        liveCount = next.count

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            // 已关闭：只在有查询时出现，按关闭时间倒序取前几条；和活标签同网址的不列
            //（它已经开着，切过去就是）。
            let liveURLs = Set(all.map(\.tab.url))
            let closedCandidates = closed.map { candidate(title: $0.title, url: $0.url) }
            let matched = TabSearch.rank(closedCandidates, query: query)
                .map { closed[$0] }
                .filter { !liveURLs.contains($0.url) }
                .sorted { $0.closedAt > $1.closedAt }
                .prefix(Self.closedLimit)
            next += matched.map { .closed($0) }
            closedCount = matched.count

            // 书签：按匹配得分排，开着的和已关闭段里有的不重复列；同网址收在多个
            // 文件夹里只列第一个。
            var taken = liveURLs.union(matched.map(\.url))
            let bookmarkCandidates = bookmarks.map { candidate(title: $0.title, url: $0.url) }
            var picked: [BookmarkInfo] = []
            for index in TabSearch.rank(bookmarkCandidates, query: query) {
                let bm = bookmarks[index]
                guard !taken.contains(bm.url) else { continue }
                taken.insert(bm.url)
                picked.append(bm)
                if picked.count == Self.bookmarkLimit { break }
            }
            next += picked.map { .bookmark($0) }
            bookmarkRows = picked.count

            // 像网址就在末尾挂一行「在新标签打开」，有匹配时也挂 —— 用户可能就是想开它
            if let url = TabSearch.urlCandidate(query) { next.append(.url(url)) }
        } else {
            closedCount = 0
            bookmarkRows = 0
        }
        rows = next

        if let keep, let index = rows.firstIndex(where: { $0.id == keep }) {
            setCursor(index, source: .keyboard)
        } else if trimmed.isEmpty, rows.count > 1 {
            // 空查询时首行是当前标签，回车切到它等于没切；游标落到上一个标签，
            // 和 ⌃⇥ 按一下的落点一致（用户 2026-09-26 点名要求）。
            setCursor(1, source: .keyboard)
        } else {
            setCursor(0, source: .keyboard)
        }
    }

    /// ↑↓ 移动游标，到头回绕（用户 2026-09-26 点名：到底就按不动太别扭）。
    /// 和切换器浮层的「越界不动」不同：那边是按住修饰键循环、方向键是辅助；
    /// 这里方向键就是主导航，列表短的时候回绕比撞墙顺手。
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (cursor + delta + rows.count) % rows.count
        setCursor(next, source: .keyboard)
    }

    /// 列表区需要的内容高度（不含输入框），面板据此定高、超过上限就滚动。
    /// 视图里分组头和行的尺寸必须和这里用同一组常量，否则面板底部裁掉半行。
    var contentHeight: CGFloat {
        guard !rows.isEmpty else { return kSearchRowHeight + kSearchListInset * 2 }
        let rowsHeight = CGFloat(rows.count) * kSearchRowHeight
            + CGFloat(rows.count - 1) * kSearchRowSpacing
        let headerHeight = kSearchSectionTopSpace + kSearchSectionHeaderHeight + kSearchSectionRuleSpace
        let headers = CGFloat((hasClosedSection ? 1 : 0) + (hasBookmarkSection ? 1 : 0))
        return rowsHeight + headers * headerHeight + kSearchListInset * 2
    }
}

// MARK: - 尺寸

private let kSearchPanelWidth: CGFloat = 680
private let kSearchFieldHeight: CGFloat = 54
private let kSearchRowHeight: CGFloat = 44
private let kSearchRowSpacing: CGFloat = 1
private let kSearchListInset: CGFloat = 6
/// 一屏最多显示的行数，超出滚动。
private let kSearchVisibleRows = 10
/// ⌘ 数字直选的行数（⌘1–⌘9）。
let kSearchQuickPickCount = 9
/// 行 favicon 的边长。输入框里的放大镜占同样宽的格子、用同样的间距，
/// 这样占位文字和下面的标题落在同一条竖线上（同切换器列表分组头那条约定）。
private let kSearchRowIconSize: CGFloat = 22
private let kSearchIconGap: CGFloat = 10
private let kSearchRowInset: CGFloat = 10
/// 「最近关闭」分组头：和全局切换器的分组头同一套 —— 小字、淡色、拉字距，
/// 下面一道 1px 线。`kSearchSectionRuleSpace` 含那道线，模型算高度时用同一个值。
private let kSearchSectionHeaderHeight: CGFloat = 22
private let kSearchSectionRuleSpace: CGFloat = 7
/// 分组头和上面最后一行活标签之间的空档，不留的话两段挤成一坨（用户反馈）。
private let kSearchSectionTopSpace: CGFloat = 10

/// 列表区高度上限：满 10 行。
private let kSearchListMaxHeight: CGFloat =
    CGFloat(kSearchVisibleRows) * kSearchRowHeight
    + CGFloat(kSearchVisibleRows - 1) * kSearchRowSpacing
    + kSearchListInset * 2

private func listHeight(content: CGFloat) -> CGFloat {
    min(content, kSearchListMaxHeight)
}

private func panelHeight(content: CGFloat) -> CGFloat {
    kSearchFieldHeight + 1 + listHeight(content: content)
}

// MARK: - 输入框

/// 让面板拿得到 SwiftUI 里那个 NSTextField（焦点、输入源都要在面板层做）。
@MainActor
final class SearchFieldHandle {
    weak var field: NSTextField?
}

/// 顶部输入框。用 NSTextField 而不是 SwiftUI TextField，为的是两件事：
/// 面板一弹出就能把它设成 first responder（不靠 FocusState 碰运气），
/// 以及 ↑↓ / 回车 / Esc 走 `doCommandBy` —— 中文输入法组字期间这些键归输入法，
/// 系统不会调到这里，天然不会打断组字。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let handle: SearchFieldHandle
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 20),
                         .foregroundColor: NSColor.secondaryLabelColor])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):        parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):          parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):   parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

// MARK: - SwiftUI 内容

private struct TabSearchView: View {
    @ObservedObject var model: TabSearchModel
    let fieldHandle: SearchFieldHandle
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: kSearchIconGap) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: kSearchRowIconSize)
                SearchField(text: $model.query,
                            placeholder: L10n.t("搜索标签", "Search tabs"),
                            handle: fieldHandle,
                            onMove: { model.move($0) },
                            onSubmit: {
                                guard model.rows.indices.contains(model.cursor) else { return }
                                model.onPick?(model.rows[model.cursor])
                            },
                            onCancel: onCancel)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, kSearchListInset + kSearchRowInset)
            .frame(height: kSearchFieldHeight)

            Divider().opacity(0.6)

            if model.rows.isEmpty {
                Text(model.all.isEmpty
                     ? L10n.t("还没有标签", "No tabs yet")
                     : L10n.t("没有匹配的标签", "No matching tabs"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: listHeight(content: model.contentHeight))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: kSearchRowSpacing) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                VStack(spacing: 0) {
                                    if index == model.liveCount, model.hasClosedSection {
                                        sectionHeader(L10n.t("最近关闭", "Recently closed"))
                                    }
                                    if index == model.bookmarkStart, model.hasBookmarkSection {
                                        sectionHeader(L10n.t("书签", "Bookmarks"))
                                    }
                                    SearchRowView(
                                        row: row,
                                        icon: model.icons[row.favIconUrl],
                                        selected: index == model.cursor,
                                        isCurrent: row.id == model.currentID,
                                        quickKey: model.commandHeld && index < kSearchQuickPickCount
                                                  ? index + 1 : nil,
                                        closable: model.canCloseTabs,
                                        onHover: { model.setCursor(index, source: .mouse) },
                                        onPick: { model.onPick?(row) },
                                        onClose: { model.onCloseTab?(row.id) })
                                }
                                .id(row.id)
                            }
                        }
                        .padding(kSearchListInset)
                    }
                    .frame(height: listHeight(content: model.contentHeight))
                    .onChange(of: model.cursor) { _, cursor in
                        guard model.cursorSource == .keyboard,
                              model.rows.indices.contains(cursor) else { return }
                        proxy.scrollTo(model.rows[cursor].id, anchor: nil)
                    }
                }
            }
        }
        .frame(width: kSearchPanelWidth)
        // 窗口是 titled（见 present 里的说明），隐藏了的标题栏仍算安全区，
        // 不忽略的话输入框上方会空出一条标题栏高度
        .ignoresSafeArea()
    }

    /// 「最近关闭」分组头。和全局切换器的分组头一个思路：头部字更小更淡、字距拉开，
    /// 真正划清界限的是下面那道 1px 线；靠「加粗名字」区分只会像又一行。
    /// 不放图标（用户裁掉的），文字和下面行的标题对齐；上面留一段空档和活标签分开。
    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .padding(.leading, kSearchRowIconSize + kSearchIconGap)
                Spacer(minLength: 8)
            }
            .frame(height: kSearchSectionHeaderHeight)
            .padding(.top, kSearchSectionTopSpace)
            .padding(.horizontal, kSearchRowInset)

            Rectangle()
                .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                .frame(height: 1)
                .padding(.bottom, kSearchSectionRuleSpace - 1)
        }
    }
}

/// 列表里的一行：favicon、标题、域名；行尾按住 ⌘ 时是 ⌘n 角标，hover 时（活标签）
/// 是 ✕，否则是「多久之前」（当前标签写「当前」，已关闭写「x 前关闭」）。
private struct SearchRowView: View {
    let row: SearchRow
    let icon: IconInfo?
    let selected: Bool
    let isCurrent: Bool
    let quickKey: Int?
    let closable: Bool
    let onHover: () -> Void
    let onPick: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var lastMouseScreenPoint: CGPoint?
    @State private var hovering = false

    private var title: String {
        switch row {
        case .tab(let item):     return item.tab.title.isEmpty ? item.tab.url : item.tab.title
        case .closed(let entry): return entry.title.isEmpty ? entry.url : entry.title
        case .url:               return L10n.t("在新标签打开", "Open in new tab")
        case .bookmark(let bm):  return bm.title.isEmpty ? bm.url : bm.title
        }
    }

    /// 书签的副标题写所在文件夹而不是域名 —— 一眼分得出这是书签；根下的没有文件夹才退回域名。
    private var subtitle: String {
        switch row {
        case .tab(let item):     return Self.host(of: item.tab.url)
        case .closed(let entry): return Self.host(of: entry.url)
        case .url(let url):      return url
        case .bookmark(let bm):  return bm.path.isEmpty ? Self.host(of: bm.url) : bm.path
        }
    }

    /// 已关闭的行整体降到次级色：它是「找回」不是「切换」，扫一眼就该能分出来。
    private var dimmed: Bool {
        if case .closed = row { return true }
        return false
    }

    private var isTab: Bool {
        if case .tab = row { return true }
        return false
    }

    private static func host(of url: String) -> String {
        guard var host = URL(string: url)?.host else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.count > 40 ? "…" + host.suffix(38) : host
    }

    var body: some View {
        HStack(spacing: kSearchIconGap) {
            leadingIcon
                .frame(width: kSearchRowIconSize, height: kSearchRowIconSize)
                .opacity(dimmed ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(dimmed ? Color.primary.opacity(0.55)
                                                : (selected ? Color.primary : Color.primary.opacity(0.85)))
                    if case .tab(let item) = row, item.tab.pinned == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(dimmed ? 0.32 : 0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, kSearchRowInset)
        .frame(height: kSearchRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.20)
                                                  : Color.black.opacity(0.10))
                               : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                let point = NSEvent.mouseLocation
                if let last = lastMouseScreenPoint,
                   abs(point.x - last.x) > 1 || abs(point.y - last.y) > 1 {
                    onHover()
                }
                lastMouseScreenPoint = point
            case .ended:
                hovering = false
                lastMouseScreenPoint = nil
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch row {
        case .url:
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
        case .bookmark:
            // 书签树里没有 favicon，用书签图标占位
            Image(systemName: "bookmark")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
        default:
            Group {
                if let icon {
                    Image(nsImage: icon.image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let quickKey {
            Text("⌘\(quickKey)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.10)))
        } else if hovering, isTab, closable {
            // hover 到活标签：行尾的时间换成 ✕，点它关掉这个标签，面板不关
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help(L10n.t("关闭标签（⌘⌫）", "Close tab (⌘⌫)"))
        } else {
            switch row {
            case .tab(let item):
                if isCurrent {
                    Text(L10n.t("当前", "Current"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                } else if let ago = item.tab.relativeLastAccessed {
                    Text(ago)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .closed(let entry):
                if let ago = relativeTime(msEpoch: entry.closedAt) {
                    Text(L10n.t("\(ago)关闭", "closed \(ago)"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.30))
                }
            case .url:
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.30))
            case .bookmark:
                Text(L10n.t("书签", "Bookmark"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.30))
            }
        }
    }
}

// MARK: - 承载面板

/// 能拿 key 但**不激活 App** 的面板。
///
/// 和切换器浮层的红线不冲突：那条红线是为了测 Ctrl 松开的时机，而搜索面板由
/// 一次性快捷键唤出，没有「按住」这回事。`.nonactivatingPanel` + canBecomeKey 让
/// 键盘输入进面板、浏览器仍是前台 App —— 菜单栏不会切成我们的、浏览器窗口
/// 也不会退到后面，关掉面板键盘焦点自动回到浏览器。
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TabSearchPanel {

    let model = TabSearchModel()

    /// 面板**常驻**，启动时就建好（`warmUp`），之后每次 show 复用。
    ///
    /// 照 PasteMemo 快捷面板的做法：SwiftUI 首次布局、玻璃首次实例化、输入框首次
    /// 建 field editor 这些一次性开销和抖动全在启动时的离屏预热里发生，用户按 ⌘E
    /// 看到的永远是「第二次」。第一版每次 show 新建、close 销毁，首次打开输入框下方
    /// 会闪一块空白（2026-09-26 用户反馈），demo 复现不出，改成常驻后消失。
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TabSearchView>?
    private let fieldHandle = SearchFieldHandle()
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// 面板顶边的屏幕 y。行数变了面板只从底部伸缩，顶边不动。
    private var topY: CGFloat = 0
    private var visibleFrame = NSRect.zero
    private var shown = false

    var isVisible: Bool { shown }

    /// 面板关掉了（无论哪种方式）。event tap 靠它收回「键盘归面板」的标志。
    var onClose: (() -> Void)?

    /// 用户选定了一项。面板已关。
    var pickHandler: ((SearchPick) -> Void)?
    /// 用户要在面板里关掉一个活标签（参数 item.id）。面板不关。
    var closeHandler: ((String) -> Void)?

    init() {
        model.onPick = { [weak self] row in
            // 先关面板再切：关面板会把 key 还给浏览器，切换命令随后到达时
            // 焦点已经在它那边了。
            let pick = self?.pickHandler
            self?.close()
            switch row {
            case .tab(let item):     pick?(.tab(item))
            case .closed(let entry): pick?(.closed(entry))
            case .url(let url):      pick?(.url(url))
            case .bookmark(let bm):  pick?(.bookmark(bm))
            }
        }
        model.onCloseTab = { [weak self] itemID in self?.closeHandler?(itemID) }
        model.onContentHeightChange = { [weak self] height in self?.resizeToContent(height) }
    }

    /// 启动时调用：在屏幕外把面板整棵建出来并画一遍，然后收起。
    func warmUp() {
        guard panel == nil else { return }
        let panel = buildPanel()
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
        log("🔍 tab search panel warmed up")
    }

    func show(items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
              icons: [String: IconInfo]) {
        if shown { close() }
        // 此刻浏览器还是前台、还没有任何我们的窗口拿 key，读到的就是用户正在用的输入源
        let inputSource = Self.currentInputSourceID()
        model.query = ""
        model.icons = icons
        model.setItems(items, closed: closed, bookmarks: bookmarks, keepCursor: false)
        // ⌘E 唤出时 ⌘ 多半还按着，角标要立刻出现，不等下一次 flagsChanged
        model.commandHeld = NSEvent.modifierFlags.contains(.command)
        present(inputSource: inputSource)
    }

    /// 面板开着时数据变了（MRU 推送 / 在面板里关了标签）。
    /// `animated` 给关标签用：那一行淡出、下面的行滑上来。
    func update(items: [SwitcherItem], closed: [ClosedTab], bookmarks: [BookmarkInfo],
                icons: [String: IconInfo], animated: Bool = false) {
        guard shown else { return }
        model.icons = icons
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                model.setItems(items, closed: closed, bookmarks: bookmarks)
            }
        } else {
            model.setItems(items, closed: closed, bookmarks: bookmarks)
        }
    }

    func close() {
        guard shown, let panel else { return }
        shown = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
        onClose?()
    }

    private func present(inputSource: String?) {
        if panel == nil { warmUp() }
        guard let panel else { return }

        // 贴着浏览器窗口水平居中、偏上（Spotlight 的位置）；拿不到窗口就按屏幕。
        let defaultScreen = NSScreen.main ?? NSScreen.screens[0]
        let anchor = ChromeWindowLocator.frontmostWindowFrame() ?? defaultScreen.visibleFrame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? defaultScreen
        visibleFrame = screen.visibleFrame
        topY = anchor.maxY - anchor.height * 0.16

        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: model.contentHeight))
        panel.setFrame(frame(for: size, midX: anchor.midX), display: true)

        shown = true
        installMonitors(for: panel)
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel, inputSource: inputSource)
        if !OverlayPanel.usesGlassBackdrop { WindowShadow.applyStandardWindowShadow(to: panel) }
    }

    /// 把焦点交给输入框。输入源要在 makeFirstResponder **之前**钉成前台 App 正在用的
    /// 那个：系统开着「自动切换到文稿的输入法」时每个进程各记各的输入源，我们进程
    /// 第一次激活文本输入会被分配一个默认的，和浏览器里那个不一致就切一次，光标下
    /// 弹一下输入源指示器。
    private func focusField(in panel: NSPanel, inputSource: String?) {
        guard let field = fieldHandle.field else { return }
        if let editor = panel.fieldEditor(true, for: field) as? NSTextView {
            if let inputSource { editor.inputContext?.selectedKeyboardInputSource = inputSource }
            // 搜索框不需要 Writing Tools / 自动补全
            if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
            editor.isAutomaticTextCompletionEnabled = false
        }
        panel.makeFirstResponder(field)
    }

    private func buildPanel() -> NSPanel {
        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: model.contentHeight))
        let hosting = NSHostingView(rootView: TabSearchView(model: model, fieldHandle: fieldHandle,
                                                            onCancel: { [weak self] in
            self?.close()
        }))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        hosting.safeAreaRegions = []   // 标题栏不占内容空间（见下面 titled 的说明）
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.cornerRadius = OverlayPanel.panelCornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        // **必须是 .titled 而不是 .borderless**（2026-09-26 demo 逐个试过）：borderless
        // 面板一拿 key，WindowServer 就按整块矩形给它画 key 窗口的阴影 rim —— 屏上是
        // 四个直角 + 一圈深色描边 + 没有软阴影。`invalidateShadow`、先 orderFront 再
        // makeKey、orderOut 再上屏，全都没用。titled 窗口会登记自己的圆角形状，
        // 阴影就跟着圆角走；标题栏透明 + 隐藏 + fullSizeContentView 之后看不出区别。
        // 切换器浮层不受影响 —— 它永远不拿 key。
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // titled 之后顶部那条（隐形的）标题栏区域默认可拖，面板不该被拖走
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = OverlayPanel.makeBackdrop(size: size, content: hosting)

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    private func installMonitors(for panel: NSPanel) {
        // ⌘ 按下 / 松开 → 行尾角标显隐
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.model.commandHeld = event.modifierFlags.contains(.command)
            return event
        }!)

        // ⌘1–⌘9 直选、⌘⌫ 关游标那条。↑↓ / 回车 / Esc 归输入框的 doCommandBy
        //（见 SearchField），这里只管带 ⌘ 的键 —— 输入法组字期间不会有这些组合。
        //
        // ⌘Q / ⌘W / ⌘, 也要在这里截住：面板是 key window，这些 key equivalent 会
        // 路由到**我们自己的**主菜单 —— 用户想退的是浏览器，退掉的却是 TabFlick。
        // 一律当作「关掉面板」，键本身吞掉，用户再按一次就到浏览器了。
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard mods == .command else { return event }
            if event.keyCode == UInt16(kVK_Delete) {
                if self.model.rows.indices.contains(self.model.cursor),
                   case .tab(let item) = self.model.rows[self.model.cursor],
                   self.model.canCloseTabs {
                    self.model.onCloseTab?(item.id)
                }
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            if let n = Int(chars), (1...kSearchQuickPickCount).contains(n) {
                if self.model.rows.indices.contains(n - 1) {
                    self.model.onPick?(self.model.rows[n - 1])
                }
                return nil
            }
            if ["q", "w", ","].contains(chars.lowercased()) {
                self.close()
                return nil
            }
            return event
        }!)

        // 点到别处 / 切走 App：面板失去 key 就收起。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// 内容高度变了：从底部伸缩，顶边和水平位置不动。
    ///
    /// **不做动画**：窗口 frame 动画期间每一帧都重新布局，输入框和列表跟着
    /// 整块抖（用户原话「整个框在抖动」）。Spotlight / Alfred 都是瞬时改高度，
    /// 观感就是「输入框下面的内容少了一截」。
    private func resizeToContent(_ contentHeight: CGFloat) {
        guard let panel else { return }
        let size = NSSize(width: kSearchPanelWidth, height: panelHeight(content: contentHeight))
        guard size != panel.frame.size else { return }
        panel.setFrame(frame(for: size, midX: panel.frame.midX), display: true)
    }

    /// 当前选中的键盘输入源 id（如 com.tencent.inputmethod.wetype.pinyin）。
    private static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private func frame(for size: NSSize, midX: CGFloat) -> NSRect {
        var frame = NSRect(x: midX - size.width / 2, y: topY - size.height,
                           width: size.width, height: size.height)
        if frame.maxX > visibleFrame.maxX { frame.origin.x = visibleFrame.maxX - frame.width }
        if frame.minX < visibleFrame.minX { frame.origin.x = visibleFrame.minX }
        if frame.maxY > visibleFrame.maxY { frame.origin.y = visibleFrame.maxY - frame.height }
        if frame.minY < visibleFrame.minY { frame.origin.y = visibleFrame.minY }
        return frame
    }
}
