import Foundation

/// 标签被关闭的原因。扩展侧判定后随记录一起上报（见 background.js
/// 「已关闭标签记录」一节）。
enum CloseReason: String, Codable {
    /// 存活时间到期，扩展自动清理掉的
    case lifetime
    /// 切换器卡片上的 ✕
    case switcher
    /// 取消收藏后补做置顶撤销时连带关掉的
    case unpin
    /// 关闭整个窗口时连带的
    case window
    /// 用户手动关的：⌘W / 点标签上的 ✕ / 中键
    case manual

    /// 认不出的取值一律退回 manual。
    ///
    /// 默认合成的解码会在这里抛错，而 `[ClosedTab]` 是整份数组一起解的 ——
    /// 一条记录带着未来版本新增的原因，整个历史列表就全没了。「原因记不准」
    /// 比「记录整批消失」轻得多。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CloseReason(rawValue: raw) ?? .manual
    }

    /// 菜单右侧徽标里的短标注。
    var label: String {
        switch self {
        case .lifetime: return L10n.t("自动", "auto")
        case .switcher: return L10n.t("切换器", "switcher")
        case .unpin:    return L10n.t("取消置顶", "unpinned")
        case .window:   return L10n.t("关窗口", "window")
        case .manual:   return L10n.t("手动", "manual")
        }
    }
}

/// 一条已关闭标签的存档。
struct ClosedTab: Identifiable, Codable, Equatable {
    let id: String
    let url: String
    let title: String
    let favIconUrl: String
    /// 归属浏览器的 bundle id。和收藏一样按浏览器分账 —— 状态栏里每个
    /// 浏览器的子菜单只列它自己关掉的那些。
    let browser: String
    let reason: CloseReason
    /// 关闭时刻（ms epoch，扩展侧 `Date.now()`）。口径和 `TabInfo.lastAccessed`
    /// 一致，相对时间的格式化因此可以共用同一份。
    let closedAt: Double

    /// 标题最多留这么多字符。它**完全由网页控制**，而菜单只显示 60 个 ——
    /// 不设限的话一个离谱的 `document.title` 就能把存档撑大，
    /// 且每次 record 都要把整份重写一遍。
    static let maxTitleLength = 300

    /// 超过这个长度的 URL 整条不收（不是截断 —— 截断的 URL 打不开，
    /// 留着只占地方）。正常 URL 离这个数很远，地址栏的实际上限也就 2048 上下。
    static let maxURLLength = 8192

    init(url: String, title: String, favIconUrl: String,
         browser: String, reason: CloseReason, closedAt: Double) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title.count > Self.maxTitleLength
            ? String(title.prefix(Self.maxTitleLength)) : title
        self.favIconUrl = favIconUrl.count > Self.maxURLLength ? "" : favIconUrl
        self.browser = browser
        self.reason = reason
        self.closedAt = closedAt
    }

    /// 「23 分钟前」。
    var relativeClosedAt: String? { relativeTime(msEpoch: closedAt) }

    /// 菜单里显示的标题：没有标题的（还没加载完就被关掉）退回 URL。
    var displayTitle: String { title.isEmpty ? url : title }
}

/// 已关闭标签的存档。
///
/// 落在 **Application Support** 而不是 Caches：缩略图丢了会自己重新攒回来，
/// 这份丢了就是永久丢失，性质完全不同。
///
/// 存储是整份 JSON 重写而不是追加写：上限一千条、单条两百来字节，整份也就
/// 两百 KB，一次原子写不到 1ms；换来的是绝不会出现半截记录，以及少一整套
/// 追加日志的压实逻辑。而且关闭事件在扩展侧已经按 120ms 合并成批了，
/// 写入频率本来就不高。
@MainActor
final class ClosedTabStore {

    /// 最近关闭的在前。
    private(set) var entries: [ClosedTab] = []

    private let file: URL

    /// 保留上限。存活时间设成一年时，第一次自动清理可能一口气关掉几百个，
    /// 一千条能装下那种尖峰还有富余。
    private let maxEntries = 1000
    /// 超过这个岁数的记录丢弃。回收站不是历史记录，久到想不起来的东西
    /// 留着只是负担 —— 而且这是一份浏览记录，不该无限期堆在磁盘上。
    private let maxAge: TimeInterval = 30 * 86_400

    init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("closed-tabs.json")
        load()
    }

    // MARK: - 查询

    /// 某个浏览器最近关闭的若干条。`entries` 已按时间降序，直接取前 N 个。
    func recent(browser: String, limit: Int) -> [ClosedTab] {
        Array(entries.lazy.filter { $0.browser == browser }.prefix(limit))
    }

    /// 某个浏览器的存档总数。菜单只列最近 20 条，而「清空」清的是全部 ——
    /// 不把总数说出来的话，用户看着 20 条却抹掉几百条。
    func count(browser: String) -> Int {
        entries.reduce(0) { $1.browser == browser ? $0 + 1 : $0 }
    }

    // MARK: - 写入

    func record(_ incoming: [ClosedTab]) {
        guard !incoming.isEmpty else { return }
        entries = Self.merging(existing: entries, incoming: incoming,
                               now: Date().timeIntervalSince1970 * 1000,
                               maxAge: maxAge, maxEntries: maxEntries)
        persist()
    }

    /// 合并规则：降序排 → 同「浏览器 + URL」去重保留最新 → 丢过期 → 截上限。
    ///
    /// 抽成不碰文件系统的静态纯函数，是为了能脱离 app 单独校验四条规则的
    /// 交织（`checks/closed-tab-store-check.swift`）—— 实例化 store 会直接
    /// 读写用户真实的存档文件。
    ///
    /// 排序 + Set 而不是「在 incoming 上套 `merged.removeAll` 循环」：后者是
    /// O(N×M) 次字符串比较，而存活时间设成一年时首轮清理能一口气送来几百
    /// 上千条 —— 那个写法会当场卡住主线程。
    /// `nonisolated`：它不碰任何实例状态，也就不该继承类的 MainActor 隔离
    /// —— 否则校验脚本没法在非主线程上下文里直接调它。
    nonisolated static func merging(existing: [ClosedTab], incoming: [ClosedTab],
                                    now: Double, maxAge: TimeInterval,
                                    maxEntries: Int) -> [ClosedTab] {
        var seen = Set<String>()
        var merged: [ClosedTab] = []
        merged.reserveCapacity(min(existing.count + incoming.count, maxEntries))

        let cutoff = now - maxAge * 1000
        for tab in (existing + incoming).sorted(by: { $0.closedAt > $1.closedAt }) {
            // 已按时间降序，遇到第一个过期的说明后面只会更旧
            guard tab.closedAt >= cutoff else { break }
            // 同一浏览器下同 URL 只留最新那条：反复开关同一个页面不该把列表
            // 刷满 —— 用户要找回的是「那个页面」，不是它的每一次生命周期。
            guard seen.insert("\(tab.browser)\n\(tab.url)").inserted else { continue }
            merged.append(tab)
            if merged.count >= maxEntries { break }
        }
        return merged
    }

    /// 找回之后就该从回收站消失 —— 留着的话用户下次点它会再开一个重复标签。
    func remove(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        persist()
    }

    /// 清空某个浏览器的记录。这是一份浏览记录，用户必须有权一键抹掉。
    func clear(browser: String) {
        guard entries.contains(where: { $0.browser == browser }) else { return }
        entries.removeAll { $0.browser == browser }
        persist()
        log("🗑  cleared closed-tab history [\(browser)]")
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode([ClosedTab].self, from: data) else {
            // 解析失败会让 entries 停在空数组，而下一次 record 是**整份重写** ——
            // 什么都不做的话，一个坏字节就会让几百条历史被一条新记录覆盖掉
            // （TaskTick #22 的「空库覆盖非空备份」是同一个形状）。所以先把
            // 坏文件挪到一边留作证据/手工恢复，绝不原地覆盖。
            let salvage = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: file, to: salvage)
            log("⚠️  closed-tabs.json 解析失败，已另存为 \(salvage.lastPathComponent)，本次以空列表启动")
            return
        }
        entries = decoded.sorted { $0.closedAt > $1.closedAt }
        if !entries.isEmpty {
            log("🗂  loaded \(entries.count) closed-tab record(s)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
