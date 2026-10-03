import AppKit
import Foundation

struct TabInfo: Decodable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let favIconUrl: String
    /// 最近一次被使用的时刻（ms epoch，Chrome 121+ 的 tab.lastAccessed）。
    /// 旧版扩展或旧版 Chrome 拿不到时为 nil/0，界面上就不显示时间。
    let lastAccessed: Double?
    /// 是否置顶。切换器卡片的置顶标记用；旧版扩展没有该字段。
    let pinned: Bool?
}

extension TabInfo {
    var relativeLastAccessed: String? { relativeTime(msEpoch: lastAccessed) }
}

/// 一条浏览器历史（扩展按输入实时查回来的）。
struct HistoryInfo: Decodable {
    let title: String
    let url: String
    /// 最近访问时刻（ms epoch），口径同 lastAccessed。
    let lastVisitTime: Double
    /// 归属连接（helper 填，不在协议里）。
    var clientID: UUID? = nil

    private enum CodingKeys: String, CodingKey { case title, url, lastVisitTime }
}

/// 一条书签（扩展把整棵树摊平后发来的）。
struct BookmarkInfo: Decodable {
    let title: String
    let url: String
    /// 所在文件夹路径，如「书签栏 / 工具」；直接放在根下的为空。
    let path: String
    /// 归属连接。跨浏览器搜索时打开它要发给这一条；协议里没有，helper 自己填。
    var clientID: UUID? = nil

    private enum CodingKeys: String, CodingKey { case title, url, path }
}

/// 一枚 favicon 及其视觉属性。
struct IconInfo {
    let image: NSImage
    /// 图标本身是否偏亮。决定该垫深底还是浅底 —— favicon 来源不可控，
    /// 固定颜色的底板必然会在某一类图标上失效（垫白底就看不见 GitHub
    /// 深色模式那只白猫）。
    let isLight: Bool
}

/// favicon 的内存缓存。key 用 favIconUrl 本身，同站多个标签页天然复用。
@MainActor
final class IconCache {
    private var images: [String: IconInfo] = [:]
    private var inflight: Set<String> = []

    func image(for url: String) -> IconInfo? { images[url] }

    /// 本机文件 / App 的图标（文件夹、应用行用），键 `file:<path>`。同步取、缩到 64、缓存。
    func fileIcon(path: String) -> IconInfo? {
        let key = "file:" + path
        if let hit = images[key] { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let raw = NSWorkspace.shared.icon(forFile: path)
        guard let image = Self.downscaled(raw, to: 64) else { return nil }
        let info = IconInfo(image: image, isLight: false)
        images[key] = info
        return info
    }

    /// 扩展取回来的图标（书签 / 历史行按域名要的），直接入缓存。
    func store(_ data: Data, for key: String) {
        guard let image = NSImage(data: data).flatMap({ Self.downscaled($0, to: 64) }) else { return }
        images[key] = IconInfo(image: image, isLight: Self.isLight(image))
    }

    // MARK: 站点图标（书签 / 历史行，浏览器自己也没有的那些）

    /// 落盘目录：成功的存 PNG，失败的记时间。helper 重启不重拉。
    private let siteIconDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TabFlick/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// 拉过但没拉到的站：24 小时内不再试。不记的话一个挂掉的站每次出现在列表里都
    /// 会再发两个请求（用户 2026-09-26 点名的风险）。
    private var siteMisses: [String: Date] = [:]
    private static let missTTL: TimeInterval = 24 * 3600
    private var siteMissesLoaded = false
    /// 同时在跑的站点请求数上限，多的排队；面板一屏最多几十行，别一下子全发出去。
    private var activeSiteFetches = 0
    private var siteFetchQueue: [(host: String, key: String, onLoaded: () -> Void)] = []
    private static let maxConcurrentSiteFetches = 4

    private func siteIconFile(_ key: String) -> URL {
        let name = key.replacingOccurrences(of: "site:", with: "")
            .replacingOccurrences(of: "/", with: "_")
        return siteIconDirectory.appendingPathComponent(name).appendingPathExtension("png")
    }

    private func loadSiteMissesIfNeeded() {
        guard !siteMissesLoaded else { return }
        siteMissesLoaded = true
        let file = siteIconDirectory.appendingPathComponent("misses.json")
        if let data = try? Data(contentsOf: file),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            let now = Date()
            for (key, ts) in raw {
                let date = Date(timeIntervalSince1970: ts)
                if now.timeIntervalSince(date) < Self.missTTL { siteMisses[key] = date }
            }
        }
    }

    private func saveSiteMisses() {
        let file = siteIconDirectory.appendingPathComponent("misses.json")
        let raw = siteMisses.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(raw) { try? data.write(to: file, options: .atomic) }
    }

    /// 浏览器没有这个站的图标（书签收了但从没打开过）：自己去站上取。
    /// 先试站点根目录的 favicon.ico，取不到再走 DuckDuckGo 的图标服务（不用 Google，
    /// 国内也通）。两条都不行就记一笔 miss，24 小时内不再碰，视图用类型图标占位。
    func fetchSiteIcon(host: String, key: String, onLoaded: @escaping () -> Void) {
        guard !host.isEmpty, images[key] == nil, !inflight.contains(key) else { return }
        loadSiteMissesIfNeeded()
        if let missed = siteMisses[key], Date().timeIntervalSince(missed) < Self.missTTL { return }
        // 磁盘上有就直接用，不发请求
        if let data = try? Data(contentsOf: siteIconFile(key)), let image = NSImage(data: data) {
            images[key] = IconInfo(image: image, isLight: Self.isLight(image))
            onLoaded()
            return
        }
        inflight.insert(key)
        siteFetchQueue.append((host, key, onLoaded))
        pumpSiteFetches()
    }

    private func pumpSiteFetches() {
        while activeSiteFetches < Self.maxConcurrentSiteFetches, !siteFetchQueue.isEmpty {
            let job = siteFetchQueue.removeFirst()
            activeSiteFetches += 1
            let candidates = [
                "https://\(job.host)/favicon.ico",
                "https://icons.duckduckgo.com/ip3/\(job.host).ico",
            ].compactMap(URL.init(string:))
            Self.fetchFirst(candidates) { [weak self] image, png in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeSiteFetches -= 1
                    self.inflight.remove(job.key)
                    if let image {
                        self.images[job.key] = IconInfo(image: image, isLight: Self.isLight(image))
                        if let png { try? png.write(to: self.siteIconFile(job.key), options: .atomic) }
                        job.onLoaded()
                    } else {
                        log("🖼  site icon miss: \(job.host)")
                        self.siteMisses[job.key] = Date()
                        self.saveSiteMisses()
                    }
                    self.pumpSiteFetches()
                }
            }
        }
    }

    /// 依次试这几个地址，第一个能解出图的就用（在下载线程上缩好、连同 PNG 字节一起回来）。
    private nonisolated static func fetchFirst(_ urls: [URL], completion: @escaping (NSImage?, Data?) -> Void) {
        guard let first = urls.first else { completion(nil, nil); return }
        var request = URLRequest(url: first)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok, let data, data.count > 16,
               let image = NSImage(data: data).flatMap({ downscaled($0, to: 64) }) {
                let png = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
                completion(image, png)
            } else {
                fetchFirst(Array(urls.dropFirst()), completion: completion)
            }
        }.resume()
    }

    /// 判断图标整体偏亮还是偏暗。
    ///
    /// favicon 大多带透明背景，直接取平均色会被透明区拉向黑色，所以要按
    /// alpha 反预乘，只看真正画了东西的那部分。
    ///
    /// 把整张图缩画到 1×1 的 CGContext 里取平均，**不用 Core Image**：之前每张
    /// 图新建一个 `CIContext`（自带几 MB 的缓存），几百个 favicon 攒下来几十 MB
    /// 的 Malloc Large（2026-09-26 量 footprint 时发现）。
    private static func isLight(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return false }

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else { return false }   // 几乎全透明，无从判断，当作暗的

        // 反预乘后按感知亮度加权
        let r = CGFloat(pixel[0]) / 255 / alpha
        let g = CGFloat(pixel[1]) / 255 / alpha
        let b = CGFloat(pixel[2]) / 255 / alpha
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62
    }

    /// 缩成不超过 `side` 见方的独立位图（不保留原图引用）。已经够小的原样返回。
    private nonisolated static func downscaled(_ image: NSImage, to side: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard max(w, h) > Int(side) else { return image }
        let scale = side / CGFloat(max(w, h))
        let tw = max(1, Int(CGFloat(w) * scale)), th = max(1, Int(CGFloat(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: tw, height: th))
    }

    func prefetch(_ urls: [String], onLoaded: @escaping () -> Void) {
        for url in urls where !url.isEmpty && images[url] == nil && !inflight.contains(url) {
            guard let parsed = URL(string: url) else { continue }
            inflight.insert(url)
            URLSession.shared.dataTask(with: parsed) { data, _, _ in
                // 下载线程上就缩成 64×64：不少站点的 favicon 是 192×192 以上的 PNG，
                // 几百张原尺寸位图攒起来几十 MB，而界面最大只画 22pt
                let image = data.flatMap { NSImage(data: $0) }.flatMap { Self.downscaled($0, to: 64) }
                Task { @MainActor in
                    self.inflight.remove(url)
                    guard let image else { return }   // 拿不到就让视图走 globe 占位
                    self.images[url] = IconInfo(image: image,
                                                isLight: Self.isLight(image))
                    onLoaded()
                }
            }.resume()
        }
    }
}

/// MRU 切换的状态机。
///
/// 语义照搬 macOS 的 App 切换器：
///   - 进入 cycling 时对当前 MRU 顺序拍一张**快照**
///   - 中途按 Tab 只在快照上移动游标，**不改动真实 MRU 顺序**
///   - 松开 Ctrl 才提交切换
///
/// 「中途不写回」是关键。Brave 的实现在每次按 Tab 时就更新顺序，导致
/// 「Ctrl+Tab+Tab 到 Y，再一下 Ctrl+Tab 回 X」这个最常用的来回切换走不通
/// （brave-browser#12157）。
@MainActor
final class MRUController {

    private let server: WebSocketServer
    private let settings: AppSettings
    private let overlay: OverlayPanel
    /// ⌘E 唤出的标签搜索面板。和切换器浮层各管各的，不共享游标和快照。
    private let search = TabSearchPanel()
    private let icons = IconCache()

    /// 网页缩略图缓存（内存 + 磁盘，按 URL 索引）。
    ///
    /// 放在 helper 而不是扩展侧：MV3 的 service worker 随时会被回收。
    /// 落盘则是因为 `captureVisibleTab` 只能截可见标签，图是一张张攒出来的，
    /// 只存内存的话 helper 一重启就退化成一排空卡片。
    private let thumbnails = ThumbnailStore()

    /// 哪些 URL 的缩略图是「完整视口、未裁剪」的（扩展发 `full: true`）。
    ///
    /// 只有这些图能当浮层的折射背景。磁盘缓存里还留着老版本按 400×250 居中裁过
    /// 的图，比例和覆盖范围都对不上，拿去按位置对齐会得到一块错位的假背景。
    /// 故意只放内存、不持久化：判据是「这张图是本次运行期间由新扩展发来的」，
    /// 存盘反而会把上次的判断带进来。
    private var fullViewportThumbs: Set<String> = []

    /// 已关闭标签的存档（状态栏子菜单末尾那一段「最近关闭」）。
    /// 落盘在 Application Support —— 浏览器重启、helper 重启都还在。
    private let closedTabs = ClosedTabStore()

    /// 状态栏子菜单里列出的已关闭标签条数。
    static let menuClosedTabLimit = 20

    /// 每个已连接客户端（浏览器）的独立状态。浏览器是物理隔离的主体：
    /// 标签列表、命令路由、置顶恢复都按客户端分账，绝不互串。
    struct ClientState {
        /// 该浏览器的实时 MRU 顺序，最近使用的在前，index 0 是当前标签。
        var tabs: [TabInfo] = []
        /// 随每次 mru 推送附带的「当前窗口」id，-1 表示未知。
        var currentWindowId = -1
        /// 归属浏览器的 bundle id；连接建立后由 pid 反查异步补上，nil = 未识别。
        var browser: String?
        /// 扩展上报的自身版本（requestSettings 握手带来）。
        var extVersion: String?
        /// 这个 Profile 的窗口最近一次获得焦点（扩展 0.17.0 起上报 `focused`）。多 Profile 时认前台用。
        var focusedAt: Date?
        /// Profile 的固定身份（扩展 0.17.0 起在握手里带，存在它自己的 storage.local）。
        /// 连接 id 每次重连都变，「最近关闭」按这个分账。nil = 老扩展。
        var profileKey: String?
        var extensionID: String?
        /// 浏览器自己给这个 Profile 起的名字（`BrowserProfiles` 读出来的），读不到是 nil。
        var profileName: String?
        let connectedAt = Date()
        /// 该浏览器的全部书签（摊平），扩展连上时整份推过来、变动时整份重推。
        /// 只放内存：扩展一重连就有，不值得落盘。
        var bookmarks: [BookmarkInfo] = []
    }

    private var clients: [UUID: ClientState] = [:]
    /// 最近一次推送 MRU 的客户端 —— 多连接且身份都没识别出来时的兜底路由。
    private var lastPushClient: UUID?

    /// 当前应该服务的客户端：前台浏览器对应的连接优先；只有一个连接时
    /// 直接用它（单浏览器用户完全不依赖 pid 识别这条链路）；多连接身份
    /// 不明时退回最近推送者。同一个浏览器有多条连接（多 Profile）时由
    /// `ProfilePicker` 认前台是哪个 Profile 的窗口 —— 原来取字典里第一条，
    /// 和用户正对着哪个窗口无关（2026-09-27 V2EX 用户报的）。
    private var activeClientID: UUID? {
        let front = ChromeWindowLocator.activeBundleID
        let matches = clients.filter { $0.value.browser == front }
        if matches.count == 1 { return matches.first?.key }
        if matches.count > 1 { return frontProfile(among: matches) }
        if clients.count == 1 { return clients.keys.first }
        if let last = lastPushClient, clients[last] != nil { return last }
        return clients.keys.first
    }

    private var lastProfilePick: (id: UUID, reason: ProfilePicker.Reason)?

    /// 多 Profile 时「前台是哪个」的判定结果，缓存 0.25 秒：判定要跨进程问一次 AX 窗口标题
    /// （中位 0.06ms，浏览器卡住时最多等 0.15s），而 `activeClientID` 在一次 MRU 推送里要读好几次。
    /// 用户按下 ⌃⇥、打开搜索面板时 `invalidateProfilePick()` 强制重判 —— 那两个时刻必须准。
    private var profilePickCache: (at: Date, ids: Set<UUID>, id: UUID)?

    func invalidateProfilePick() { profilePickCache = nil }

    private func frontProfile(among matches: [UUID: ClientState]) -> UUID? {
        let ids = Set(matches.keys)
        if let cached = profilePickCache, cached.ids == ids, Date().timeIntervalSince(cached.at) < 0.25 {
            return cached.id
        }
        let candidates = matches.map { id, client in
            ProfilePicker.Candidate(id: id, currentTitle: client.tabs.first?.title,
                                    allTitles: client.tabs.map(\.title), focusedAt: client.focusedAt)
        }
        let windowTitle = ChromeWindowLocator.focusedWindowTitle()
        guard let pick = ProfilePicker.pick(candidates, windowTitle: windowTitle,
                                            lastPush: lastPushClient) else { return nil }
        if pick.reason == .title, let windowTitle { learnProfileName(pick.id, windowTitle: windowTitle) }
        // 换了 Profile 或换了判据才记一笔（这个属性访问很频繁，别刷屏）
        if lastProfilePick?.id != pick.id || lastProfilePick?.reason != pick.reason {
            lastProfilePick = pick
            log("👤 profile → client \(pick.id.uuidString.prefix(8)) by \(pick.reason.rawValue) (\(matches.count) connections)")
        }
        profilePickCache = (Date(), ids, pick.id)
        return pick.id
    }

    /// 活动客户端（前台浏览器）的标签列表。切换器/菜单/命令都只看它。
    private var tabs: [TabInfo] {
        activeClientID.flatMap { clients[$0]?.tabs } ?? []
    }

    private var currentWindowId: Int {
        activeClientID.flatMap { clients[$0]?.currentWindowId } ?? -1
    }

    /// 客户端的记账浏览器：识别成功用识别结果；失败退回「最近前台的
    /// 受支持浏览器」—— 单浏览器场景两者必然一致。
    private func effectiveBrowser(of clientID: UUID) -> String {
        clients[clientID]?.browser ?? ChromeWindowLocator.activeBundleID
    }

    /// 收藏 → 活标签的绑定（favorite.id → tabId）。
    /// 置顶标签会在站内外漂移，域名判定随时失真；绑定是唯一稳定的对应。
    /// tabId 随浏览器会话失效，绑定死了就等下一次 favoriteBound 重建。
    private var favoriteTabBindings: [String: Int] = [:]

    /// 切换器实际使用的列表：「只切换当前窗口」开着就按 currentWindowId
    /// 过滤。过滤结果为空（窗口 id 对不上的异常情况）时退回全量，
    /// 宁可范围变大也不能让切换器凭空失灵。
    private var switcherTabs: [TabInfo] {
        guard settings.scopeToWindow else { return tabs }
        let scoped = tabs.filter { $0.windowId == currentWindowId }
        return scoped.isEmpty ? tabs : scoped
    }

    /// 当前浏览器切换器的条目。browser 传 nil —— 只有一个浏览器，不分组。
    private var switcherItems: [SwitcherItem] {
        guard let id = activeClientID else { return [] }
        return switcherTabs.map { SwitcherItem(tab: $0, browser: nil, clientID: id) }
    }

    /// 全局切换器的条目：所有已连接浏览器的标签，**按浏览器分组**。
    ///
    /// 组内保持该浏览器自己的 MRU 顺序；组间按「最近用过」排 —— 取组内
    /// 最大的 lastAccessed，不额外记账。人在别的应用里想切标签时，脑子里
    /// 先定「去哪个浏览器」再找标签，所以分组比一条纯 MRU 更好使。
    ///
    /// 「只切换当前窗口」在这里不适用：前台不是浏览器时根本没有「当前窗口」
    /// 这个概念，全局模式一律列全部窗口。
    private var globalItems: [SwitcherItem] {
        // 同一个浏览器多开 Profile 时每个 Profile 一条连接：按「浏览器 + Profile」分组，
        // 组头写「Google Chrome · 工作」（2026-09-28 用户要的，原来合成一组「Google Chrome」、
        // 和状态栏 / 搜索面板都已按 Profile 分对不上）。只有一个 Profile 的浏览器照旧一组。
        struct Group { let browser: String; let profile: String?; var entries: [(tab: TabInfo, clientID: UUID)] }
        var groups: [String: Group] = [:]
        for (id, client) in clients where !client.tabs.isEmpty {
            let browser = effectiveBrowser(of: id)
            let profile = profileLabel(for: id)
            let key = browser + "|" + (profile ?? "")
            groups[key, default: Group(browser: browser, profile: profile, entries: [])]
                .entries.append(contentsOf: client.tabs.map { ($0, id) })
        }
        return groups.values
            .map { group -> (group: Group, recency: Double) in
                (group, group.entries.compactMap(\.tab.lastAccessed).max() ?? 0)
            }
            .sorted { a, b in
                a.recency != b.recency ? a.recency > b.recency
                    : (a.group.browser, a.group.profile ?? "") < (b.group.browser, b.group.profile ?? "")
            }
            .flatMap { pair in
                pair.group.entries.map {
                    SwitcherItem(tab: $0.tab, browser: pair.group.browser, clientID: $0.clientID, profile: pair.group.profile)
                }
            }
    }

    /// 所有浏览器的标签总数。全局切换器的就绪判定用，不必真去拼条目。
    private var globalTabCount: Int {
        clients.values.reduce(0) { $0 + $1.tabs.count }
    }

    /// 本轮 cycling 的快照，与 `tabs` 隔离。
    private var snapshot: [SwitcherItem] = []
    private var cursor = 0
    private var cycling = false

    /// 本轮是全局切换器（跨浏览器）。起手时从 event tap 读一次就定死。
    private var cyclingGlobal = false

    /// 本轮 cycling 中是否用 ✕ 关过标签。关过的话，松开 Ctrl 时即使游标
    /// 停在 0 也要提交切换 —— 原来的「起点」标签可能已经被关掉了，
    /// Chrome 自动激活的是相邻标签而不是 MRU 上一个，不显式切一下的话
    /// 落点会和面板高亮对不上。切到本来就活跃的标签是无害的幂等操作。
    private var closedTabThisRound = false

    private var connected: Bool { !clients.isEmpty }
    private var pingTimer: Timer?

    /// cycling 卡死看门狗。
    ///
    /// 「按下开始、松开结束」的状态机，出口依赖一个可能丢失的事件。keyDown 里
    /// 已经有即时自愈，但那要等用户再按一次键；浮层如果卡在屏幕上，用户会以为
    /// 整个系统出问题了。这里做时间兜底：超时无条件收摊。
    private var cyclingWatchdog: Timer?
    private let cyclingTimeout: TimeInterval = 10

    private func armWatchdog() {
        cyclingWatchdog?.invalidate()
        let timer = Timer(timeInterval: cyclingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.forceEndCycling() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cyclingWatchdog = timer
    }

    private func disarmWatchdog() {
        cyclingWatchdog?.invalidate()
        cyclingWatchdog = nil
    }

    private func forceEndCycling() {
        guard cycling || eventTapIsCycling else { return }
        log("⚠️  Watchdog: cycling stuck for \(Int(cyclingTimeout))s — force reset")
        endCycling()
        resetEventTapCycling()
    }

    /// 收摊：清状态、收起浮层。不提交任何切换。
    private func endCycling() {
        cycling = false
        cyclingGlobal = false
        cursor = 0
        snapshot = []
        closedTabThisRound = false
        overlay.hide()
    }

    /// 连接状态或标签数变化，供菜单栏更新显示。计数是活动浏览器的。
    var onStatusChange: ((Bool, Int) -> Void)?

    private func publishStatus() {
        onStatusChange?(connected, tabs.count)
    }

    /// 扩展请求打开 app 的设置窗口（点了浏览器工具栏图标）。
    var onExtensionRequestedSettings: (() -> Void)?

    /// 扩展版本与 app 不配套（major.minor 不同）。参数 (扩展版本, 应用版本)。
    var onExtensionOutdated: ((String, String) -> Void)?
    private var reportedExtensionMismatch = false

    /// 本版 app 要求的扩展**最低兼容版本**。
    ///
    /// ⚠️ 不是「和 app 版本号保持一致」：只在**协议发生不兼容变化**时才手动
    /// 提升。app 发版没动扩展/协议 → 这里不动，老扩展继续用，不骚扰用户。
    /// （扩展 manifest 的 version 则是「扩展内容变了就升」，两者语义不同。）
    /// 0.9：新增 `tabsClosed` / `reopen` 两条消息。老扩展不发前者，「最近关闭」
    /// 那一段会**永远是空的**且没有任何提示 —— 用户只会以为功能坏了。
    /// 这正是这套提示存在的意义，所以这次提。
    static let requiredExtensionVersion = "0.9"
    /// 这版 TabFlick 配套的扩展版本（= extension/manifest.json 的 version，改扩展时两处一起升）。
    /// 低于它不影响基本功能，但有功能用不上（操作里的重新加载 / 删除历史、多 Profile 分账），
    /// 状态栏、设置页、搜索面板给不打扰的提示（用户 2026-09-27 要的）。和上面那个
    /// `requiredExtensionVersion`（协议不兼容才提，弹窗）是两回事。
    static let latestExtensionVersion = "0.18.0"

    /// 版本比较（按数字逐段，缺位补 0）：v 是否低于 required。
    private static func isOlder(_ v: String, than required: String) -> Bool {
        let a = v.split(separator: ".").compactMap { Int($0) }
        let b = required.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 每个已知浏览器的连接与扩展版本状态（设置页列表 + 菜单警告的数据源）。
    /// 「已知」= 连接过的（knownBrowsers 持久化）∪ 有置顶记录的 ∪ 当前连着的。
    struct BrowserStatus: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let connected: Bool
        let extVersion: String?
        let needsUpdate: Bool
    }

    var browserStatuses: [BrowserStatus] {
        var connectedByBrowser: [String: ClientState] = [:]
        for (id, client) in clients {
            connectedByBrowser[effectiveBrowser(of: id)] = client
        }
        // 卸载了的浏览器不再列：没连着、没置顶记录、磁盘上也找不到 ——
        // 列出来只能是「地球图标 + 原始 bundle id」。knownBrowsers 只增不减，
        // 这里顺手把它剔掉；重装并连上会自动回来。
        let pinned = Set(settings.favorites.map(\.browser))
        let gone = settings.knownBrowsers.filter {
            connectedByBrowser[$0] == nil && !pinned.contains($0)
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil
        }
        if !gone.isEmpty {
            settings.knownBrowsers.removeAll(where: gone.contains)
        }
        let known = Set(BrowserSupport.installedBrowsers())
            .union(settings.knownBrowsers)
            .union(pinned)
            .union(connectedByBrowser.keys)
        return known.sorted().map { bundleID in
            let client = connectedByBrowser[bundleID]
            // 这个浏览器任何一个 Profile 的扩展要更新都算
            let needsUpdate = clients.keys.contains { id in
                clients[id]?.browser == bundleID && extensionNeedsUpdate(id)
            }
            return BrowserStatus(bundleID: bundleID,
                                 name: BrowserSupport.displayName(bundleID),
                                 connected: client != nil,
                                 extVersion: client?.extVersion,
                                 needsUpdate: needsUpdate)
        }
    }

    /// 这条连接的扩展该更新了：版本低于配套版本；或者版本号够了却没带 Profile 标识 ——
    /// 扩展文件换了、浏览器里跑的还是旧代码（没在扩展页点 ↻，只比版本号查不出来）。
    func extensionNeedsUpdate(_ id: UUID) -> Bool {
        guard let client = clients[id], let version = client.extVersion else { return false }
        if Self.isOlder(version, than: Self.latestExtensionVersion) { return true }
        return client.profileKey == nil
    }

    /// 要更新扩展的那些连接，给用户看的名字（「Google Chrome · 个人资料名」）。状态栏警告项用。
    var outdatedExtensionNames: [String] {
        clients.keys
            .filter(extensionNeedsUpdate)
            .sorted { (clients[$0]?.connectedAt ?? .distantPast) < (clients[$1]?.connectedAt ?? .distantPast) }
            .map { id in
                let name = BrowserSupport.displayName(effectiveBrowser(of: id))
                return profileLabel(for: id).map { "\(name) · \($0)" } ?? name
            }
    }

    /// 记录扩展上报的版本供状态列表展示；低于最低兼容版本时弹一次提醒。
    /// 回调参数是 (扩展版本, 要求的最低版本)。
    private func recordExtensionVersion(_ clientID: UUID, _ version: String) {
        clients[clientID]?.extVersion = version
        publishStatus()
        guard Self.isOlder(version, than: Self.requiredExtensionVersion) else { return }
        guard !reportedExtensionMismatch else { return }   // 每次启动只弹一次
        reportedExtensionMismatch = true
        log("⚠️  extension \(version) < required \(Self.requiredExtensionVersion) — prompting update")
        onExtensionOutdated?(version, Self.requiredExtensionVersion)
    }

    /// 设置变化后向所有客户端各推各的 —— 收藏按浏览器过滤，
    /// 别的浏览器的置顶绝不会在这个浏览器里恢复。
    func pushSettingsToAll() {
        refreshPinnedDriftedFlag()
        for id in clients.keys { pushSettings(to: id) }
    }

    private func pushSettings(to id: UUID) {
        // 身份必须用**识别结果**，不能用 effectiveBrowser 的前台猜测：
        // 猜错一次就是把别家浏览器的置顶恢复进来。范围不明 → 发的配置不含
        // 收藏/待办（扩展见此不补开、不清理），身份齐了再补推完整版。
        let scope = favoriteScope(of: id)
        if scope == nil {
            log("⏳ settings without favorites → client \(id.uuidString.prefix(8))（浏览器 / Profile 身份未齐，齐了补推）")
        }
        server.send(settings.payload(favoritesFor: scope), to: id)
    }

    /// 这条连接的收藏账本范围（浏览器 + Profile）。nil = 还不能下发收藏：浏览器没识别、
    /// 握手没到、或新扩展却没带 Profile 标识 —— 下发错了就是在别的 Profile 里补开一排
    /// 置顶，宁可先不发（扩展收到不含收藏的配置什么都不动）。老扩展不报 Profile，
    /// 范围是「浏览器 + 无 Profile」，行为同以前。
    private func favoriteScope(of id: UUID) -> FavoriteScope? {
        guard let client = clients[id], let browser = client.browser, let ext = client.extVersion else { return nil }
        if Self.isOlder(ext, than: Self.panelCommandsExtensionVersion) {
            return FavoriteScope(browser: browser, profile: nil)
        }
        guard let key = client.profileKey else { return nil }
        return FavoriteScope(browser: browser, profile: key)
    }

    /// 数据没就绪时让 event tap 放行快捷键，降级到前台应用自己的行为。
    /// 判定基准是切换器视角的列表（按窗口过滤后）：当前窗口只有 1 个标签
    /// 时即便别的窗口还有标签，⌃⇥ 也该放行给 Chrome。
    ///
    /// 全局切换器的分母完全不同（所有浏览器的标签总数，不按窗口过滤），
    /// 单独算一份。
    private func updateReadiness() {
        setEventTapReady(connected && switcherTabs.count > 1)
        refreshPinnedDriftedFlag()
        // 搜索面板不按窗口过滤，也不要求两个以上：一个标签也搜得到
        setEventTapSearchReady(connected && !tabs.isEmpty)
        setEventTapGlobalSearchReady(connected && globalTabCount > 0)

        // 全局切换器「按了没反应」有两种完全不同的原因：拦截没开（就绪为 false，
        // 键被放行）和路由判错（吞了却没弹）。日志里要能一眼分开，所以
        // 状态翻转时记一笔。只在变化时写，不然每次 MRU 推送都刷一行。
        let globalReady = settings.globalSwitcher && connected && globalTabCount > 1
        if globalReady != lastGlobalReady {
            lastGlobalReady = globalReady
            log("🌐 global switcher \(globalReady ? "armed" : "idle") "
                + "(开关 \(settings.globalSwitcher ? "开" : "关")，\(clients.count) 个浏览器，\(globalTabCount) 个标签)")
        }
        setEventTapGlobalReady(globalReady)
    }

    private var lastGlobalReady = false

    /// 全局切换器开关变了 —— 立刻重算拦截范围，不然要等下一次 MRU 推送
    /// 才生效（表现为「刚打开开关按了没反应」）。
    func refreshReadiness() {
        updateReadiness()
    }

    init(server: WebSocketServer, settings: AppSettings) {
        self.server = server
        self.settings = settings
        self.overlay = OverlayPanel(settings: settings)
        thumbnails.warmUp()   // 磁盘上的图先读进来，第一次按 ⌃⇥ 就有画面
        // 已关闭列表的 favicon 也要能立刻显示。IconCache 只在内存里，helper
        // 一重启就空了 —— 存档却还在，不预热的话那一整段都是 globe 占位。
        // 每个浏览器只列 20 条，取最近 60 条足够覆盖几个浏览器。
        icons.prefetch(closedTabs.entries.prefix(60).map(\.favIconUrl)) { }
        overlay.model.onPick = { [weak self] itemID in
            self?.pick(itemID: itemID)
        }
        overlay.model.onHover = { [weak self] itemID in
            self?.hover(itemID: itemID)
        }
        overlay.model.onClose = { [weak self] itemID in
            self?.closeTab(itemID: itemID)
        }
        search.pickHandler = { [weak self] pick in
            self?.pickFromSearch(pick)
        }
        search.closeHandler = { [weak self] itemID in
            self?.closeFromSearch(itemID: itemID)
        }
        search.commandHandler = { [weak self] command, target in
            self?.runSearchCommand(command, on: target)
        }
        search.model.pinnedHomeProvider = { [weak self] item in
            self?.pinnedHomeURL(tabID: item.tab.id, clientID: item.clientID)
        }
        search.model.badgeProvider = { [weak self] row in
            guard let self else { return (nil, nil) }
            @MainActor func of(_ id: UUID?) -> (browser: String?, profile: String?) {
                guard let id else { return (nil, nil) }
                return (self.effectiveBrowser(of: id), self.profileLabel(for: id))
            }
            switch row {
            case .tab(let item):     return of(item.clientID)
            case .bookmark(let bm):  return of(bm.clientID)
            case .history(let h):    return of(h.clientID)
            case .closed(let entry): return (entry.browser, self.profileLabel(forClosed: entry))
            default:                 return (nil, nil)
            }
        }
        search.queryHandler = { [weak self] query in
            self?.scheduleHistoryQuery(query)
        }
        search.model.iconProvider = { [weak self] keys in
            guard let self else { return [:] }
            var map: [String: IconInfo] = [:]
            for key in keys where !key.isEmpty && map[key] == nil {
                if key.hasPrefix("file:") {
                    if let info = self.icons.fileIcon(path: String(key.dropFirst(5))) { map[key] = info }
                } else if let info = self.icons.image(for: key) {
                    map[key] = info
                }
            }
            return map
        }
        search.model.onMissingIcons = { [weak self] pairs in self?.requestFavicons(pairs) }
        search.openSettingsHandler = { [weak self] in self?.openSettings?() }
        search.modeHandler = { [weak self] mode in
            // 切到历史记录模式（或设成列历史的「全部」）时没输入也要拉一次最近访问的
            guard let self else { return }
            if mode == .history || (mode == .all && self.searchEmptyContent == .history) {
                self.scheduleHistoryQuery(self.search.model.query)
            }
        }
        search.onClose = { setEventTapSearchPanelOpen(false) }
        // 启动收尾后离屏预热搜索面板（照 PasteMemo 快捷面板的做法），首次 ⌘E 不再
        // 承担首次渲染的一次性抖动
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.search.warmUp() }
        }
        // 拼音字缓存也顺手在后台填热（见 Pinyin.prewarm）：搜索候选里已关闭记录占大头
        Pinyin.prewarm(closedTabs.entries.prefix(600).map(\.title))
    }

    /// 鼠标悬停：把状态机游标移过去，再回写视觉高亮。
    ///
    /// 游标只有这一份（状态机的），视觉是它的投影 —— 之前 hover 直接改
    /// 视图模型那份，悬停后 ⌃⇥ 从旧位置继续、松开 Ctrl 切到的也是旧游标
    /// 那张（高亮和实际切换对不上）。
    /// source 必须是 .mouse：hover 触发自动滚动会形成正反馈环（见 SwitcherView）。
    ///
    /// 视图回调带来的都是 item.id，这里按 id 在快照里反查位置 —— 位置索引在
    /// 「渲染 → 点击」之间可能失真（连续关闭时数组在变），id 不会。
    private func hover(itemID: String) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == itemID }),
              index != cursor else { return }
        cursor = index
        overlay.model.setCursor(index, source: .mouse)
        armWatchdog()
    }

    /// 鼠标点选某张卡片：把游标直接定位过去并立即提交。
    private func pick(itemID: String) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == itemID }) else { return }
        cursor = index
        // tap 侧的 cycling 也要清，否则用户松开 Ctrl 时会再 commit 一次
        resetEventTapCycling()
        log("🖱 clicked [\(index)] → \(snapshot[index].tab.title.prefix(50))")
        commit()
    }

    /// 点了卡片上的 ✕：关掉那个标签，卡片消失，本轮 cycling 继续。
    ///
    /// 功能默认关闭，由设置项 allowTabClose 打开（视图侧用它控制 ✕ 显隐，
    /// 这里是状态机侧的同一道门）。只在剩 3 张以上时可用：2 张关 1 张就
    /// 只剩单标签，切换器不为单标签出现，关到那一步面板就没意义了。
    /// 这条守卫同时保证 tabs 不会被关到触发 readiness 降级。
    private func closeTab(itemID: String) {
        // 全局切换器不提供关闭：那里关的是别的浏览器里、此刻不在眼前的标签。
        // 视图侧已经不画 ✕ 了，这里再挡一道 —— 这条路径是不可逆动作，
        // 不能只靠「界面没有入口」来保证。
        guard !cyclingGlobal,
              settings.allowTabClose,
              cycling, snapshot.count > 2,
              let index = snapshot.firstIndex(where: { $0.id == itemID }) else { return }

        let target = snapshot[index]
        log("✕ close [\(index)] → \(target.tab.title.prefix(50)) (tabId \(target.tab.id))")
        // 点对点发给这一项所属的连接 —— 全局模式下快照里混着多个浏览器，
        // 发给「活动客户端」会去关别家浏览器里同号的标签。
        server.send(["type": "close", "tabId": target.tab.id], to: target.clientID)
        closedTabThisRound = true

        snapshot.remove(at: index)
        // 本地同步剔除，不等扩展的 onRemoved 推送 —— 窗口期里如果开始
        // 新一轮 cycling，快照里不该出现已关掉的标签。
        clients[target.clientID]?.tabs.removeAll { $0.id == target.tab.id }
        publishStatus()

        // 关的在游标前面 → 游标跟着前移一位；关的是游标那张且它是末尾 →
        // 收到新末尾。其余情况游标位置不变（自然落到顶上来的下一张）。
        if index < cursor {
            cursor -= 1
        } else if cursor >= snapshot.count {
            cursor = snapshot.count - 1
        }

        overlay.applyRemoval(items: snapshot, cursor: cursor)
        armWatchdog()
    }

    // MARK: - 标签搜索

    /// 当前浏览器的全部标签（不按窗口过滤 —— 搜索的目的就是「找那个标签」，
    /// 不该被它在哪个窗口挡住），MRU 顺序。
    private var searchItems: [SwitcherItem] {
        guard let id = activeClientID else { return [] }
        return tabs.map { SwitcherItem(tab: $0, browser: nil, clientID: id) }
    }

    /// 当前浏览器的已关闭记录（搜索时的「最近关闭」候选），已按关闭时间降序。
    /// 取前 300 条足够：面板只列 5 条匹配，再往前的记录用户自己也记不得了。
    private var searchClosed: [ClosedTab] {
        let browser = activeBrowser
        // 多 Profile 时只列前台这个 Profile 的（用户 2026-09-27 定：⌘E 只搜当前 Profile）
        let profile = activeClientID.flatMap { clients[$0]?.profileKey }
        return Array(closedTabs.entries.lazy.filter { $0.browser == browser && $0.profile == profile }.prefix(300))
    }

    /// 当前浏览器的书签。
    private var searchBookmarks: [BookmarkInfo] {
        activeClientID.flatMap { clients[$0]?.bookmarks } ?? []
    }

    /// 本轮搜索面板是不是跨浏览器的（⌥⌘E 唤出）。打开那一刻定死，刷新和选定都按它走。
    private var searchIsGlobal = false

    // MARK: 文件夹 / 应用（搜索面板的两个模式，数据在 helper 自己手里）

    /// 面板里按 ⌘, 要开设置（main.swift 接进来）。
    var openSettings: (() -> Void)?
    /// 收藏的文件夹（状态栏那份，main.swift 接进来）。
    var folderProvider: (() -> [FavoriteFolder])?
    /// 「打开方式」候选，按最近用过排，第一个就是回车的默认。
    var openerProvider: (() -> [OpenerApp])?
    /// 用某个 App 打开文件夹（落库 + toast 由 main.swift 那边做）。
    var openFolderHandler: ((FavoriteFolder, OpenerApp) -> Void)?
    /// 取消收藏一个文件夹（落库 + toast 和状态栏那条是同一段，main.swift 接进来）。
    var unfavoriteFolderHandler: ((FavoriteFolder) -> Void)?
    private let appCatalog = AppCatalog()

    private var searchFolders: [FavoriteFolder] {
        FavoriteFolderStore.byRecency(folderProvider?() ?? [])
    }

    /// 跨浏览器搜索：所有浏览器的活标签合成一张按最近使用排的列表（不分组——搜索要的是
    /// 「找那个标签」，分组只会把命中的拆散），条目带归属浏览器，选定后先激活它再切。
    /// 跨浏览器面板的标签：所有连接的合成一张表，按最近用过排。和「最近使用」同一套规则
    /// （`RecentMix`，只是不混 App）：同一个 Profile 里照扩展的 MRU、正显示的标签跟着浏览器切到前台的
    /// 时间走——原来纯按 `lastAccessed` 排，切窗口时 MRU 变了它不变，先后会颠倒（2026-09-29 改）。
    private var globalSearchItems: [SwitcherItem] {
        var items: [SwitcherItem] = []
        for (id, client) in clients {
            let browser = effectiveBrowser(of: id)
            items += client.tabs.map { SwitcherItem(tab: $0, browser: browser, clientID: id) }
        }
        let inputs = recentTabInputs(items: items)
        return RecentMix.order(tabs: inputs.tabs, apps: [], browserActivatedAt: inputs.activated).compactMap {
            if case .tab(let i) = $0.ref { return items[i] } else { return nil }
        }
    }

    private var globalSearchClosed: [ClosedTab] { Array(closedTabs.entries.prefix(300)) }

    /// 跨浏览器搜索的书签。开着书签同步的多个 Profile 会各推一份一样的：同网址只列一条，
    /// 优先前台那个 Profile 的（选中后开在你正在用的那个里）。
    private var globalSearchBookmarks: [BookmarkInfo] {
        let front = activeClientID
        let order = clients.keys.sorted { a, b in
            (a == front) != (b == front) ? a == front : a.uuidString < b.uuidString
        }
        var seen = Set<String>()
        var result: [BookmarkInfo] = []
        for id in order {
            for bookmark in clients[id]?.bookmarks ?? [] where seen.insert(bookmark.url).inserted {
                var copy = bookmark
                copy.clientID = id
                result.append(copy)
            }
        }
        return result
    }

    /// 跨浏览器时「搜索 / 打开网址」这类没有归属的动作发给谁：最近用过的那个浏览器。
    private var mostRecentClientID: UUID? {
        clients.max { a, b in
            (a.value.tabs.first?.lastAccessed ?? 0) < (b.value.tabs.first?.lastAccessed ?? 0)
        }?.key ?? activeClientID
    }

    /// 把某个连接所属的浏览器激活到前台（跨 App 的激活必须 helper 做）。
    private func activateBrowser(of clientID: UUID) {
        _ = NSRunningApplication
            .runningApplications(withBundleIdentifier: effectiveBrowser(of: clientID))
            .first?
            .activate(options: [])
    }

    /// favicon 按 favIconUrl 索引（活标签和已关闭记录共用）。
    private func iconMap(for items: [SwitcherItem], closed: [ClosedTab]) -> [String: IconInfo] {
        var map: [String: IconInfo] = [:]
        for url in items.map(\.tab.favIconUrl) + closed.map(\.favIconUrl) where map[url] == nil {
            if let info = icons.image(for: url) { map[url] = info }
        }
        return map
    }

    // MARK: 书签 / 历史行的图标（按域名问扩展）

    private var faviconInflight: Set<String> = []
    private var faviconTimer: Timer?
    private var faviconQueue: [(key: String, url: String)] = []

    /// 面板里出现了还没有图标的书签 / 历史行。合并 150ms 攒一批发。
    private func requestFavicons(_ pairs: [(key: String, url: String)]) {
        for pair in pairs where !faviconInflight.contains(pair.key) && icons.image(for: pair.key) == nil {
            faviconInflight.insert(pair.key)
            faviconQueue.append(pair)
        }
        guard !faviconQueue.isEmpty else { return }
        faviconTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushFaviconQueue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        faviconTimer = timer
    }

    private func flushFaviconQueue() {
        guard let clientID = searchIsGlobal ? mostRecentClientID : activeClientID else {
            faviconQueue.removeAll(); faviconInflight.removeAll(); return
        }
        let batch = faviconQueue
        faviconQueue.removeAll()
        log("🖼  favicon query: \(batch.count) site(s)")
        server.send(["type": "faviconQuery",
                     "items": batch.map { ["key": $0.key, "url": $0.url] }], to: clientID)
        // 扩展几秒内没回（2026-09-27 实测过整批石沉大海：发了十几次、一次回包都没有，
        // 历史行全是占位图标）：没回的这些当作「浏览器也没有」，自己去站上取。
        // 不兜这一层的话 faviconInflight 永远不清，这些站再也不会被问第二次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.fallBackUnanswered(batch.map(\.key)) }
        }
    }

    private func fallBackUnanswered(_ keys: [String]) {
        let stale = keys.filter { faviconInflight.contains($0) }
        guard !stale.isEmpty else { return }
        log("🖼  favicon reply timed out: \(stale.count) site(s), fetching from the sites")
        for key in stale {
            faviconInflight.remove(key)
            let host = key.hasPrefix("site:") ? String(key.dropFirst(5)) : ""
            icons.fetchSiteIcon(host: host, key: key) { [weak self] in self?.refreshOverlayImages() }
        }
    }

    private func handleFaviconReply(_ root: [String: Any]) {
        guard let raw = root["items"] as? [[String: Any]] else { return }
        log("🖼  favicon reply: \(raw.count) hit, \((root["missing"] as? [String])?.count ?? 0) missing")
        for item in raw {
            guard let key = item["key"] as? String,
                  let base64 = item["data"] as? String,
                  let data = Data(base64Encoded: base64) else { continue }
            faviconInflight.remove(key)
            icons.store(data, for: key)
        }
        // 浏览器也没有的（书签收了从没打开过）：自己去站上补（用户 2026-09-26 要的）
        for key in root["missing"] as? [String] ?? [] {
            faviconInflight.remove(key)
            let host = key.hasPrefix("site:") ? String(key.dropFirst(5)) : ""
            icons.fetchSiteIcon(host: host, key: key) { [weak self] in self?.refreshOverlayImages() }
        }
        refreshOverlayImages()
    }

    // MARK: 历史记录（按输入实时问扩展）

    private var historyTimer: Timer?
    private var historyRequestID = 0
    /// 每次查询的回包要合并几条连接（跨浏览器模式）；按 requestId 攒，最后一条到了再给面板。
    private var historyPending: [Int: (query: String, waiting: Set<UUID>, items: [HistoryInfo])] = [:]

    /// 输入变了：合并 120ms 再发，用户还在敲的时候别一键一个请求。
    private func scheduleHistoryQuery(_ query: String) {
        historyTimer?.invalidate()
        let text = query.trimmingCharacters(in: .whitespaces)
        // 空输入只有两种情况要问：历史记录模式、或「全部」设成没输入时列历史
        let wantsRecent = search.currentMode == .history
            || (search.currentMode == .all && searchEmptyContent == .history)
        guard !text.isEmpty || wantsRecent else { search.setHistory([], for: ""); return }
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sendHistoryQuery(text) }
        }
        RunLoop.main.add(timer, forMode: .common)
        historyTimer = timer
    }

    private func sendHistoryQuery(_ text: String) {
        guard search.isVisible else { return }
        let targets: [UUID] = searchIsGlobal ? Array(clients.keys) : [activeClientID].compactMap { $0 }
        guard !targets.isEmpty else { return }
        historyRequestID += 1
        let id = historyRequestID
        historyPending = [id: (text, Set(targets), [])]   // 旧请求一律作废
        for clientID in targets {
            server.send(["type": "historyQuery", "text": text, "requestId": id], to: clientID)
        }
    }

    private func handleHistoryReply(_ root: [String: Any], from clientID: UUID) {
        guard let id = (root["requestId"] as? NSNumber)?.intValue,
              let raw = root["items"],
              let payload = try? JSONSerialization.data(withJSONObject: raw),
              let decoded = try? JSONDecoder().decode([HistoryInfo].self, from: payload) else { return }
        if handleLegacyProbeReply(id, items: decoded, from: clientID) { return }
        guard var pending = historyPending[id] else { return }
        pending.items += decoded.map { var h = $0; h.clientID = clientID; return h }
        pending.waiting.remove(clientID)
        if pending.waiting.isEmpty {
            historyPending.removeValue(forKey: id)
            search.setHistory(pending.items.sorted { $0.lastVisitTime > $1.lastVisitTime }, for: pending.query)
        } else {
            historyPending[id] = pending
        }
    }

    /// 面板开着时把当前数据推过去。
    private func refreshSearch(animated: Bool = false) {
        guard search.isVisible else { return }
        let items = searchIsGlobal ? globalSearchItems : searchItems
        let closed = searchIsGlobal ? globalSearchClosed : searchClosed
        let bookmarks = searchIsGlobal ? globalSearchBookmarks : searchBookmarks
        let recent: (rows: [SearchRow], leftAt: [String: Double]) =
            searchEmptyContent == .recent ? recentSearchRows(items: items) : ([], [:])
        // 在小程序里按的 ⌥Space：前台 App 是微信（小程序在系统眼里不是独立 App），窗口读回来之后才知道
        // 最上面的是小程序，这时最前那个小程序才是「当前」
        if searchIsGlobal, searchFrontBundle == WeChatWindows.bundleID, wechatMiniOnTop,
           let front = wechatWindows.filter({ $0.kind == .miniProgram }).min(by: { $0.order < $1.order }) {
            search.model.globalCurrentID = SearchRow.window(front).id
        }
        search.update(items: items, closed: closed, bookmarks: bookmarks,
                      folders: searchFolders, apps: appCatalog.ordered, openers: openerProvider?() ?? [],
                      windows: wechatWindows, recent: recent.rows, recentLeftAt: recent.leftAt,
                      icons: iconMap(for: items, closed: closed), animated: animated)
    }

    /// 微信里开着的小程序、单独弹出的聊天窗口（`WeChatWindows`），打开面板时读一次。
    private var wechatWindows: [AppWindow] = []
    /// 屏幕上微信最上面的是小程序（最后在用的是小程序，不是主窗口）。
    private var wechatMiniOnTop = false
    /// 打开面板那一刻的前台 App（在小程序里按的键要认出「当前」是哪个小程序）。
    private var searchFrontBundle: String?

    /// 读微信的窗口：跨进程，放后台线程，读完刷新面板。先清空：上一轮的可能已经关了，回车会跳个空。
    private func refreshWeChatWindows() {
        wechatWindows = []
        wechatMiniOnTop = false
        guard let target = WeChatWindows.target() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = WeChatWindows.read(target)
            Task { @MainActor [weak self] in
                guard let self, !snapshot.windows.isEmpty else { return }
                self.wechatWindows = snapshot.windows
                self.wechatMiniOnTop = snapshot.miniProgramOnTop
                self.refreshSearch()
            }
        }
    }

    /// 搜索快捷键：开着就关，关着就开。cycling 中不开 —— 两个浮层叠一起没法用。
    /// `global` = ⌥⌘E 唤出的跨浏览器搜索：所有浏览器的标签合成一张表、贴屏幕居中。
    func toggleTabSearch(global: Bool = false) {
        invalidateProfilePick()
        if search.isVisible {
            search.close()
            return
        }
        guard !cycling else { return }
        searchIsGlobal = global
        searchFrontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        refreshWeChatWindows()
        let items = global ? globalSearchItems : searchItems
        guard !items.isEmpty else { return }
        let closed = global ? globalSearchClosed : searchClosed
        // 已关闭记录的 favicon 平时只预热了菜单那 20 条，搜索候选多得多，补最近 60 条
        //（再往前的命中了也就显示 globe，不值得每次打开都发几百个请求）
        icons.prefetch(closed.prefix(60).map(\.favIconUrl)) { [weak self] in self?.refreshOverlayImages() }
        let bookmarks = global ? globalSearchBookmarks : searchBookmarks
        let recent: (rows: [SearchRow], leftAt: [String: Double]) =
            searchEmptyContent == .recent ? recentSearchRows(items: items) : ([], [:])
        // 多浏览器时行尾用浏览器图标认归属；只有一个浏览器时和浏览器内没区别
        let browsers = Set(items.compactMap(\.browser))
        // App 清单：「全部」模式里应用排第一，所以每次打开都保证清单是新的
        //（后台线程扫、一分钟内不重扫，扫完刷新面板）
        appCatalog.refreshIfStale { [weak self] in self?.refreshSearch() }
        search.model.showBrowserIcons = global && Set(clients.keys.map { effectiveBrowser(of: $0) }).count > 1
        // ⌘E 只看前台这个 Profile 的扩展；⌥Space 用到所有连接，任何一个要更新都提示
        search.model.extensionOutdated = global
            ? clients.keys.contains(where: extensionNeedsUpdate)
            : activeClientID.map(extensionNeedsUpdate) ?? false
        search.show(items: items, closed: closed, bookmarks: bookmarks,
                    folders: searchFolders, apps: appCatalog.ordered, openers: openerProvider?() ?? [],
                    siteSearches: settings.siteSearches, modes: settings.activeSearchModes,
                    allEmptyContent: searchEmptyContent, windows: wechatWindows,
                    recent: recent.rows, recentLeftAt: recent.leftAt,
                    icons: iconMap(for: items, closed: closed),
                    // 多个浏览器，或同一个浏览器开了多个 Profile（多条连接）都要标归属
                    global: global, showBrowserBadges: global && (browsers.count > 1 || clients.count > 1),
                    searchBrowser: (global ? mostRecentClientID : activeClientID).map { effectiveBrowser(of: $0) },
                    globalCurrent: global ? frontBrowserCurrentItem(in: items) ?? frontAppRow(in: recent.rows) : nil)
        setEventTapSearchPanelOpen(true)
        // 「全部」没输入时要列历史的话，打开就得去要一次最近访问的
        if searchEmptyContent == .history { scheduleHistoryQuery("") }
        log("🔍 tab search opened\(global ? " (global)" : ""): \(items.count) tabs, \(closed.count) closed, \(bookmarks.count) bookmarks")
    }

    /// 跨浏览器搜索键在浏览器前台按下时，那个浏览器（多 Profile 时是前台那个）正显示的标签
    /// 在合表里的 id：面板把它当「当前」放到第二行，和 ⌘E 一样（用户 2026-09-29 要的）。
    /// 前台不是已连接的浏览器时 nil。打开面板时读一次前台 App，不在 event tap 热路径上。
    private func frontBrowserCurrentItem(in items: [SwitcherItem]) -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              clients.values.contains(where: { $0.browser == front }),
              let id = activeClientID, clients[id]?.browser == front,
              let tab = clients[id]?.tabs.first else { return nil }
        return items.first { $0.clientID == id && $0.tab.id == tab.id }?.id
    }

    /// 前台是普通 App（不是浏览器）时，它在「最近使用」里那一行：和当前标签一样放第二行、标「当前」。
    private func frontAppRow(in recent: [SearchRow]) -> String? {
        guard let path = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL.path else { return nil }
        return recent.first { row in
            if case .app(let app) = row { return app.path == path }
            return false
        }?.id
    }

    /// 这次打开的面板「全部」没输入时列什么：⌘E 和跨浏览器面板各有一项设置。
    private var searchEmptyContent: EmptyContent {
        searchIsGlobal ? settings.globalEmptyContent : settings.allEmptyContent
    }

    /// 「最近使用」里已退出的 App 列多久内用过的（用户 2026-09-29 定的：用完就 ⌘Q 的 App 也要在；
    /// 不设窗口的话所有用过的 App 都垫在后面，等于把「应用」模式搬进来）。
    private static let recentQuitWindow: TimeInterval = 24 * 3600

    /// 「最近使用」的行：所有浏览器的标签 + 运行中的普通 App + 24 小时内用过、已退出的 App
    /// （菜单栏小工具、TabFlick 自己不算），按最近用过排（规则在 `RecentMix`）。
    /// 只在设成「最近使用」时算，打开和刷新面板时各一次。
    private func recentSearchRows(items: [SwitcherItem]) -> (rows: [SearchRow], leftAt: [String: Double]) {
        let own = Bundle.main.bundleIdentifier
        var apps: [AppEntry] = []
        var appTimes: [RecentMix.App] = []
        var seen = Set<String>()
        func add(_ entry: AppEntry, extra: [Date?]) {
            // 同一个 App 装了两份（路径不同、bundle id 相同）只列一次，运行中的那份先来
            guard entry.bundleID != own, !seen.contains(entry.path),
                  !(entry.bundleID.map { seen.contains("id:" + $0) } ?? false) else { return }
            seen.insert(entry.path)
            if let id = entry.bundleID { seen.insert("id:" + id) }
            var entry = entry
            // 装上这功能之前就切过的 App 没有切换记录，退到 Spotlight 的上次打开（运行中的再退到启动时间）
            let used = ([appCatalog.lastActivated(entry.usageKey), entry.lastUsed] + extra).compactMap { $0 }.max()
            apps.append(entry)
            appTimes.append(RecentMix.App(usedAt: used.map { $0.timeIntervalSince1970 * 1000 },
                                          leftAt: appCatalog.lastDeactivated(entry.usageKey)
                                              .map { $0.timeIntervalSince1970 * 1000 },
                                          bundleID: entry.bundleID))
        }
        // 小程序开着的话，「小程序」进程那一行不列：它的时间从不更新（点小程序切到前台的是微信），
        // 下面换成各个小程序、跟着微信排
        let hasMiniPrograms = wechatWindows.contains { $0.kind == .miniProgram }
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, let url = app.bundleURL?.standardizedFileURL,
                  !(hasMiniPrograms && app.bundleIdentifier == WeChatWindows.miniProgramBundleID) else { continue }
            // 装在扫描目录里的用清单那份（带访达注释、英文原名），装在别处的现造一个
            let entry = appCatalog.entry(atPath: url.path)
                ?? AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                            alternateName: nil, path: url.path, bundleID: app.bundleIdentifier)
            add(entry, extra: [app.launchDate])
        }
        for entry in appCatalog.used(since: Date().addingTimeInterval(-Self.recentQuitWindow))
        where !(hasMiniPrograms && entry.bundleID == WeChatWindows.miniProgramBundleID) {
            add(entry, extra: [])
        }

        let inputs = recentTabInputs(items: items)
        let (tabs, activated, deactivated) = (inputs.tabs, inputs.activated, inputs.deactivated)
        // 微信的窗口都跟着「微信」那一行排、用它的时间：小程序在系统眼里不是独立 App，点它切到前台的是
        // 微信（见 WeChatWindows.read）；微信在前台时在窗口之间切来切去没有通知，拿不到各自的时间。
        // 小程序之间按窗口前后（跟着点击走，实测），最上面是小程序就排在「微信」前面，聊天窗口垫后
        let miniPrograms = wechatWindows.filter { $0.kind == .miniProgram }.sorted { $0.order < $1.order }
        let otherWindows = wechatWindows.filter { $0.kind != .miniProgram }.sorted { $0.order < $1.order }
        var rows: [SearchRow] = []
        var leftAt: [String: Double] = [:]
        func append(_ row: SearchRow, _ left: Double?) {
            rows.append(row)
            if let left { leftAt[row.id] = left }
        }
        for entry in RecentMix.order(tabs: tabs, apps: appTimes, browserActivatedAt: activated,
                                     browserDeactivatedAt: deactivated) {
            let row: SearchRow
            switch entry.ref {
            case .tab(let i): row = .tab(items[i])
            case .app(let i): row = .app(apps[i])
            }
            guard case .app(let app) = row, app.bundleID == WeChatWindows.bundleID else {
                append(row, entry.leftAt)
                continue
            }
            if wechatMiniOnTop { miniPrograms.forEach { append(.window($0), entry.leftAt) } }
            append(row, entry.leftAt)
            if !wechatMiniOnTop { miniPrograms.forEach { append(.window($0), entry.leftAt) } }
            otherWindows.forEach { append(.window($0), entry.leftAt) }
        }
        return (rows, leftAt)
    }

    /// 标签交给 `RecentMix` 的输入：连接编号、标签在该连接 MRU 里的位置、是不是它那个浏览器最近在前台
    /// 的 Profile，以及各浏览器切到前台 / 切走的时间。「最近使用」和跨浏览器标签表共用。
    private func recentTabInputs(items: [SwitcherItem])
        -> (tabs: [RecentMix.Tab], activated: [String: Double], deactivated: [String: Double]) {
        // 连接编号，以及每条连接里标签在 MRU 中的位置（扩展的 MRU 在切窗口时也更新，比 lastAccessed 准）
        let clientIndex = Dictionary(uniqueKeysWithValues: clients.keys.sorted { $0.uuidString < $1.uuidString }
            .enumerated().map { ($1, $0) })
        var mruIndex: [UUID: [Int: Int]] = [:]
        for (id, client) in clients {
            mruIndex[id] = Dictionary(client.tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        // 每个浏览器最近在前台的 Profile：多条连接时取最近上报焦点的那条（没上报过的都算）
        var frontProfiles = Set<UUID>()
        for ids in Dictionary(grouping: clients.keys, by: { effectiveBrowser(of: $0) }).values {
            let focused = ids.compactMap { id in clients[id]?.focusedAt.map { (id, $0) } }
            if ids.count > 1, let latest = focused.max(by: { $0.1 < $1.1 }) {
                frontProfiles.insert(latest.0)
            } else {
                frontProfiles.formUnion(ids)
            }
        }
        let tabs = items.map { item in
            RecentMix.Tab(lastAccessed: item.tab.lastAccessed, browser: item.browser,
                          client: clientIndex[item.clientID] ?? 0,
                          mruIndex: mruIndex[item.clientID]?[item.tab.id] ?? Int.max,
                          frontProfile: frontProfiles.contains(item.clientID))
        }
        var activated: [String: Double] = [:]
        var deactivated: [String: Double] = [:]
        for browser in Set(items.compactMap(\.browser)) {
            if let at = appCatalog.lastActivated(browser) { activated[browser] = at.timeIntervalSince1970 * 1000 }
            if let at = appCatalog.lastDeactivated(browser) { deactivated[browser] = at.timeIntervalSince1970 * 1000 }
        }
        return (tabs, activated, deactivated)
    }

    /// 面板里选定了一项。面板已经关掉、键盘焦点回到了浏览器。
    private func pickFromSearch(_ pick: SearchPick) {
        // 跨浏览器模式下目标多半在别的 App 里：扩展的 windows.update(focused:) 只管
        // 浏览器自家窗口，跨 App 激活必须 helper 做（和全局切换器提交同一条路）。
        // 浏览器内模式前台就是它，不用动。
        let fallbackClient = searchIsGlobal ? mostRecentClientID : activeClientID
        func target(_ clientID: UUID?) -> UUID? {
            guard let clientID else { return nil }
            if searchIsGlobal { activateBrowser(of: clientID) }
            return clientID
        }
        switch pick {
        case .tab(let item):
            log("🔍 pick → \(item.tab.title.prefix(50)) (tabId \(item.tab.id))")
            guard let clientID = target(item.clientID) else { return }
            server.send(["type": "switch", "tabId": item.tab.id], to: clientID)
        case .closed(let entry):
            log("🔍 reopen closed → \(entry.displayTitle.prefix(50))")
            reopenClosedTab(id: entry.id)   // 自己会激活浏览器、按记录的 Profile 找连接
        case .url(let url):
            guard let clientID = target(fallbackClient) else { return }
            log("🔍 open url → \(url.prefix(80))")
            server.send(["type": "reopen", "url": url], to: clientID)
        case .bookmark(let bookmark):
            guard let clientID = target(bookmark.clientID ?? fallbackClient) else { return }
            log("🔍 open bookmark → \(bookmark.title.prefix(50))")
            server.send(["type": "reopen", "url": bookmark.url], to: clientID)
        case .history(let entry):
            guard let clientID = target(entry.clientID ?? fallbackClient) else { return }
            log("🔍 open history → \(entry.title.prefix(50))")
            server.send(["type": "reopen", "url": entry.url], to: clientID)
        case .action(.webSearch(let text)):
            guard let clientID = target(fallbackClient) else { return }
            log("🔍 web search → \(text.prefix(60))")
            server.send(["type": "search", "text": text], to: clientID)
        case .action(.siteSearch(let site, let text)):
            guard let url = site.url(for: text), let clientID = target(fallbackClient) else { return }
            log("🔍 site search \(site.name) → \(text.prefix(60))")
            server.send(["type": "reopen", "url": url], to: clientID)
        case .folder(let folder, let opener):
            // 没指定就用最近用过的那个方式；一个都没有就 Finder
            let chosen = opener ?? openerProvider?().first
                ?? OpenerApp(name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
            log("🔍 open folder → \(folder.name) with \(chosen.name)")
            openFolderHandler?(folder, chosen)
        case .appCommand(let command, let app):
            log("🔍 app command → \(app?.name ?? "system"): \(command.id)")
            AppCommands.run(command, appName: app?.name)
        case .window(let window):
            // 窗口标题是聊天名 / 小程序名，日志里只写类型，不写标题
            log("🔍 raise window → \(window.kind.rawValue)")
            WeChatWindows.raise(window)
        case .app(let app):
            log("🔍 launch app → \(app.name)")
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    Task { @MainActor in
                        Toast.show(L10n.t("打不开 \(app.name)", "Couldn't open \(app.name)"),
                                   detail: error.localizedDescription, kind: .failure)
                    }
                }
            }
        }
    }

    /// 「操作」列表里选了一项（⌘↩ 展开的；默认动作不走这里）。拷贝 / 重新加载 / 在访达中
    /// 显示 / 退出时面板已关；关闭 / 移除 / 删除 / 取消收藏时面板还开着、已退回原列表，
    /// 这里改完数据刷新一下，列表原地收缩。
    private func runSearchCommand(_ command: RowCommand, on target: SearchRow) {
        switch command {
        case .primary:
            return
        case .copyURL, .copyTitle, .copyMarkdown, .copyPath:
            guard let text = target.copyText(for: command) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let title: String
            switch command {
            case .copyURL:      title = L10n.t("已拷贝网址", "URL copied")
            case .copyTitle:    title = L10n.t("已拷贝标题", "Title copied")
            case .copyMarkdown: title = L10n.t("已拷贝 Markdown 链接", "Markdown link copied")
            default:            title = L10n.t("已拷贝路径", "Path copied")
            }
            Toast.show(title, detail: text)
        case .reloadTab:
            guard case .tab(let item) = target, supportsPanelCommands(item.clientID) else { return }
            log("🔍 reload → \(item.tab.title.prefix(50)) (tabId \(item.tab.id))")
            server.send(["type": "reload", "tabId": item.tab.id], to: item.clientID)
            Toast.show(L10n.t("已重新加载", "Reloaded"), detail: target.displayTitle)
        case .returnToPinned:
            guard case .tab(let item) = target else { return }
            returnToPinnedURL(tabID: item.tab.id, clientID: item.clientID)
        case .closeTab:
            guard case .tab(let item) = target else { return }
            closeFromSearch(itemID: item.id)
        case .closeDuplicates:
            guard case .tab(let item) = target, let tabs = clients[item.clientID]?.tabs else { return }
            // 同一条连接里和它网址完全相同的其余标签，留下它自己
            let key = TabSearchModel.duplicateKey(item)
            let others = tabs.filter {
                $0.id != item.tab.id
                    && TabSearchModel.duplicateKey(SwitcherItem(tab: $0, browser: item.browser, clientID: item.clientID)) == key
            }
            guard !others.isEmpty else { return }
            log("🔍 close \(others.count) duplicate(s) of \(item.tab.title.prefix(50))")
            for tab in others {
                server.send(["type": "close", "tabId": tab.id], to: item.clientID)
            }
            let closedIDs = Set(others.map(\.id))
            clients[item.clientID]?.tabs.removeAll { closedIDs.contains($0.id) }
            publishStatus()
            updateReadiness()
            refreshSearch(animated: true)
        case .removeClosed:
            guard case .closed(let entry) = target else { return }
            log("🔍 forget closed → \(entry.displayTitle.prefix(50))")
            closedTabs.remove(id: entry.id)
            refreshSearch()
        case .deleteHistory:
            guard case .history(let entry) = target,
                  let clientID = entry.clientID ?? (searchIsGlobal ? mostRecentClientID : activeClientID),
                  supportsPanelCommands(clientID) else { return }
            log("🔍 delete history → \(entry.url.prefix(80))")
            server.send(["type": "deleteHistory", "url": entry.url], to: clientID)
            search.model.removeHistory(url: entry.url)
        case .revealInFinder:
            guard let path = target.filePath else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .getInfo:
            guard let path = target.filePath else { return }
            showFinderInfo(path)
        case .unfavorite:
            guard case .folder(let folder) = target else { return }
            unfavoriteFolderHandler?(folder)
            refreshSearch()
        case .quitApp:
            guard case .app(let app) = target else { return }
            log("🔍 quit app → \(app.name)")
            if app.bundleID == Bundle.main.bundleIdentifier { NSApp.terminate(nil); return }
            let running = app.bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                ?? NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == app.path }
            // 普通退出：有没存的文档由那个 App 自己问，不强退
            running.forEach { $0.terminate() }
        }
    }

    /// 让访达打开这一项的「显示简介」窗口。没有公开 API，只能请访达自己开：osascript 子进程、
    /// 后台队列（同「收藏当前 Finder 目录」那条：首次会弹「自动化」授权，NSAppleScript 会把
    /// 主线程卡在授权框上）。路径走 argv 传进脚本，不拼进脚本源码，带引号的路径也安全。
    private func showFinderInfo(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "tell application \"Finder\"",
                "-e", "activate",
                "-e", "open information window of (POSIX file (item 1 of argv) as alias)",
                "-e", "end tell",
                "-e", "end run",
                path,
            ]
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log("ℹ️ get info failed to launch: \(error)")
                return
            }
            guard process.terminationStatus != 0 else { return }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("ℹ️ get info failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            Task { @MainActor in
                Toast.show(L10n.t("打不开简介", "Couldn't open Get Info"),
                           detail: L10n.t("系统设置 → 隐私与安全性 → 自动化里允许 TabFlick 控制「访达」。",
                                          "Allow TabFlick to control Finder in System Settings → Privacy & Security → Automation."),
                           kind: .failure)
            }
        }
    }

    /// 「重新加载」「从历史记录中删除」是扩展 0.17.0 加的命令，「回到置顶地址」（navigate）
    /// 是 0.18.0 加的。老扩展收到只会忽略 —— 照发不误再报「已重新加载」、把历史从列表里
    /// 摘掉，就是在说假话。不支持时如实说。
    nonisolated private static let panelCommandsExtensionVersion = "0.17.0"
    nonisolated private static let navigateExtensionVersion = "0.18.0"

    private func supportsPanelCommands(_ clientID: UUID,
                                       since minimum: String = MRUController.panelCommandsExtensionVersion) -> Bool {
        if let version = clients[clientID]?.extVersion,
           !Self.isOlder(version, than: minimum) { return true }
        Toast.show(L10n.t("扩展版本太旧，做不了这个操作", "The extension is too old for this"),
                   detail: L10n.t("下载最新的扩展包替换原文件夹，再到 chrome://extensions 重新加载。",
                                  "Download the latest extension zip, replace the folder, then reload it in chrome://extensions."),
                   kind: .failure)
        return false
    }

    /// 面板里关掉一个活标签（⌘⌫ / 行尾 ✕）。面板不关，列表原地收缩。
    /// 和切换器的 closeTab 一样点对点发给所属连接、本地同步剔除。
    private func closeFromSearch(itemID: String) {
        guard let item = search.model.all.first(where: { $0.id == itemID }),
              search.model.canCloseTabs else { return }
        log("🔍 ✕ close → \(item.tab.title.prefix(50)) (tabId \(item.tab.id))")
        server.send(["type": "close", "tabId": item.tab.id], to: item.clientID)
        clients[item.clientID]?.tabs.removeAll { $0.id == item.tab.id }
        publishStatus()
        updateReadiness()
        refreshSearch(animated: true)
    }

    // MARK: - 来自 WebSocket

    func handleMessage(_ data: Data, from clientID: UUID) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
        case "focused":
            // 这个 Profile 的某个窗口刚获得焦点（多 Profile 时认前台用）
            clients[clientID]?.focusedAt = Date()
        case "mru":
            guard clients[clientID] != nil,
                  let raw = root["tabs"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([TabInfo].self, from: payload) else { return }
            clients[clientID]?.tabs = decoded
            clients[clientID]?.currentWindowId = (root["currentWindowId"] as? NSNumber)?.intValue ?? -1
            lastPushClient = clientID
            syncFavoriteBindings(for: clientID)
            icons.prefetch(decoded.map(\.favIconUrl)) { [weak self] in
                self?.refreshOverlayImages()
            }
            updateReadiness()
            publishStatus()
            if searchIsGlobal || clientID == activeClientID { refreshSearch() }
            if !cycling, clientID == activeClientID {
                log("MRU updated: \(decoded.count) tabs, current: \(decoded.first?.title.prefix(40) ?? "?")")
            }

        case "history":
            handleHistoryReply(root, from: clientID)

        case "favicons":
            handleFaviconReply(root)

        case "bookmarks":
            guard clients[clientID] != nil,
                  let raw = root["items"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([BookmarkInfo].self, from: payload) else { return }
            clients[clientID]?.bookmarks = decoded
            Pinyin.prewarm(decoded.map(\.title))
            log("🔖 bookmarks: \(decoded.count) from \(effectiveBrowser(of: clientID))")
            if searchIsGlobal || clientID == activeClientID { refreshSearch() }

        case "thumb":
            guard let url = root["url"] as? String, !url.isEmpty,
                  let base64 = root["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            thumbnails.store(data, for: url)
            // 只有「完整视口、未裁剪」的图能当折射背景用（见 background.js 的
            // downscale）。磁盘缓存里混着老版本裁过的图，比例对不上，拿去对齐
            // 会得到错位的假背景 —— 所以按 URL 记一份白名单，只认本次运行期间
            // 收到的新图。内存里存就够：当前标签在激活时刚截过，必然在名单里。
            if root["full"] as? Bool == true { fullViewportThumbs.insert(url) }
            refreshOverlayImages()

        case "tabsClosed":
            // 扩展关掉标签后的存档上报（一批一条消息，见 background.js
            // 「已关闭标签记录」）。无痕 / chrome:// 已在扩展侧滤掉。
            guard let raw = root["tabs"] as? [[String: Any]], !raw.isEmpty else { return }
            let browser = effectiveBrowser(of: clientID)
            let now = Date().timeIntervalSince1970 * 1000
            let records = raw.compactMap { entry -> ClosedTab? in
                guard let url = entry["url"] as? String, url.hasPrefix("http"),
                      url.count <= ClosedTab.maxURLLength else { return nil }
                return ClosedTab(
                    url: url,
                    title: entry["title"] as? String ?? "",
                    favIconUrl: entry["favIconUrl"] as? String ?? "",
                    browser: browser,
                    profile: clients[clientID]?.profileKey,
                    reason: CloseReason(rawValue: entry["reason"] as? String ?? "") ?? .manual,
                    // 夹到「现在」：时钟错乱送来一个未来时刻的话，它会永远
                    // 排在降序列表最前，把真正最近关的那些挤出可见范围。
                    closedAt: min((entry["closedAt"] as? NSNumber)?.doubleValue ?? now, now))
            }
            guard !records.isEmpty else { return }
            closedTabs.record(records)
            refreshSearch()
            // 菜单里这一段也要有图标。活着时缓存过的能直接命中，剩下的
            // （helper 重启后）在这里补拉 —— 只拉菜单真正会显示的那些，
            // 一次清理几百个标签时不能顺手发几百个并发请求出去。
            icons.prefetch(records.prefix(Self.menuClosedTabLimit).map(\.favIconUrl)) { }
            let summary = Dictionary(grouping: records, by: \.reason)
                .map { "\($0.key.rawValue)×\($0.value.count)" }
                .sorted()
                .joined(separator: " ")
            log("🗑  archived \(records.count) closed tab(s) [\(BrowserSupport.displayName(browser))]: \(summary)")

        case "pinnedTab":
            // 浏览器里被置顶的标签（用户手动置顶，或程序离线期间置顶、
            // 连接后由 ensureFavorites 收编上报）。置顶 = 收藏。
            // 每条记录有独立 id，同域名甚至同 URL 都允许多条 ——
            // 列表如实镜像浏览器的置顶状态。自家 ensure 补的置顶由扩展侧
            // selfPinned 标记拦下，不会走到这里。
            guard let tabId = (root["tabId"] as? NSNumber)?.intValue,
                  let url = root["url"] as? String, url.hasPrefix("http"),
                  let host = URL(string: url)?.host else { return }
            // 只在**这个浏览器 + Profile**的账本里去重/认领 —— 隔离主体原则。
            // 范围不明（身份没齐）就不认：扩展只有收到收藏后才会收编上报，正常走不到这里
            guard let scope = favoriteScope(of: clientID) else { return }
            let browser = scope.browser
            let mine = settings.favorites.filter(scope.contains)
            // 已绑定这个标签的收藏 → 无事
            if mine.contains(where: { favoriteTabBindings[$0.id] == tabId }) {
                return
            }
            // 无活绑定、且最后访问/原始 URL 与之精确相同的收藏 → 认领
            // （浏览器重启后的收编落在这里）
            if let orphan = mine.first(where: { fav in
                favoriteTabBindings[fav.id] == nil
                    && (settings.favoriteCurrentUrls[fav.id] ?? fav.url) == url
            }) {
                favoriteTabBindings[orphan.id] = tabId
                return
            }
            // 多 Profile：升级前的收藏里有这个置顶 → 归这个 Profile（它真开着），不新建
            if adoptLegacyFavorite(scope: scope, url: url, host: host, tabId: tabId) != nil { return }
            let title = root["title"] as? String ?? ""
            log("★ browser pin → favorite: \(title.prefix(50)) (\(host)) [\(browser)]")
            let fav = FavoriteTab(url: url, title: title,
                                  favIconUrl: root["favIconUrl"] as? String,
                                  browser: browser, profile: scope.profile)
            favoriteTabBindings[fav.id] = tabId
            settings.favorites.append(fav)

        case "unpinned":
            // 用户在浏览器里主动取消了某个标签的置顶（⌘W 关闭不会来这条）。
            // 收藏的语义就是「常驻置顶」，置顶被主动撤掉 = 用户不想要了，
            // 收藏一并移除。绑定命中优先 —— 漂移后按域名已经判不准了。
            let tabId = (root["tabId"] as? NSNumber)?.intValue
            let host = root["host"] as? String
            guard let scope = favoriteScope(of: clientID) else { return }
            let index = settings.favorites.firstIndex { fav in
                guard scope.contains(fav) else { return false }   // 只动自己浏览器 + Profile 的账
                if let tabId, favoriteTabBindings[fav.id] == tabId { return true }
                guard let host, !host.isEmpty else { return false }
                return URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                    || URL(string: fav.url)?.host == host
            }
            if let index {
                log("☆ browser unpin → unfavorite: \(settings.favorites[index].title.prefix(50))")
                settings.favorites.remove(at: index)
            }

        case "unpinsApplied":
            // 扩展补做完了离线期间攒下的取消置顶，销账
            guard let hosts = root["hosts"] as? [String], !hosts.isEmpty else { return }
            guard let scope = favoriteScope(of: clientID) else { return }
            settings.pendingUnpins.removeAll { scope.contains($0) && hosts.contains($0.host) }
            log("☆ pending unpins applied [\(scope.browser)]: \(hosts.joined(separator: ", "))")

        case "favoriteBound":
            // 扩展核对收藏后上报「这个收藏现在对应哪个活标签」
            guard let favId = root["id"] as? String,
                  let tabId = (root["tabId"] as? NSNumber)?.intValue else { return }
            favoriteTabBindings[favId] = tabId
            refreshPinnedDriftedFlag()

        case "requestSettings":
            // 扩展（重）连上了，向我们要一份当前配置（按它的浏览器 + Profile 过滤收藏）。
            // 先记版本和 Profile 标识再下发：收藏的范围要靠它们。
            // 旧扩展不带 extVersion 字段 → 按 0.1.0 处理，必然提示。
            let reportedKey = (root["profileKey"] as? String).flatMap { BrowserProfiles.isProfileKey($0) ? $0 : nil }
            // 握手一条连接只有一次，记下来：多 Profile 的问题全靠这行排查（扩展是不是新代码、
            // 标识带没带、校验过没过）
            log("🤝 client \(clientID.uuidString.prefix(8)) handshake: ext \(root["extVersion"] as? String ?? "?"), "
                + "profileKey \(reportedKey.map { String($0.prefix(8)) } ?? (root["profileKey"] == nil ? "absent" : "invalid")), "
                + "extensionId \((root["extensionId"] as? String).map { String($0.prefix(6)) } ?? "absent")")
            if let key = reportedKey {
                clients[clientID]?.profileKey = key
                if let ext = root["extensionId"] as? String, BrowserProfiles.isExtensionID(ext) {
                    clients[clientID]?.extensionID = ext
                }
            }
            recordExtensionVersion(clientID, root["extVersion"] as? String ?? "0.1.0")
            if reportedKey != nil { profileIdentityChanged(clientID) }
            pushSettings(to: clientID)

        case "openSettings":
            // 用户点了浏览器工具栏的 TabFlick 图标
            onExtensionRequestedSettings?()

        case "log":
            // 扩展侧的异常上报。SW 的 console 没人看,错误必须落到这份日志里
            if let message = root["message"] as? String { log("🧩 ext: \(message)") }

        case "pong":
            break

        default:
            break
        }
    }

    func handleClientConnected(_ id: UUID) {
        clients[id] = ClientState()
        log("✅ Extension connected (\(clients.count) client(s))")
        startPinging()
        updateReadiness()
        publishStatus()
        scheduleIdentityFallback(for: id)
    }

    /// 身份识别（lsof → pid → 父进程链）**失败**时的兜底。
    ///
    /// 识别成功要不了 200ms。到点还是 nil 说明这条链路断了 —— 此时如果**只有
    /// 一条连接**，猜错的余地本来就不存在，按前台浏览器认下来即可。
    ///
    /// 这个兜底不是可有可无的：配置里的收藏是按浏览器过滤下发的，身份不明
    /// 就不下发（否则会把别家浏览器的置顶恢复进来）。少了这一层，识别失败的
    /// 用户**收不到收藏、置顶不恢复、自动清理也不跑**，而且全程无报错。
    /// WebSocketServer 那句「单浏览器场景不受影响」的日志靠这里才成立。
    ///
    /// 多连接时不兜底：那正是猜错会串台的场景，宁可功能不生效也不能填错账本。
    private func scheduleIdentityFallback(for id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let client = self.clients[id], client.browser == nil else { return }
                guard self.clients.count == 1 else {
                    // 多连接下猜错会把别家浏览器的置顶恢复进来，只能不兜底。
                    // 但这条连接从此收不到收藏、置顶不恢复、清理也不跑 ——
                    // 不留一行日志的话，这个降级从外面完全看不出来。
                    log("⚠️  client \(id.uuidString.prefix(8)) 身份始终未识别，且有多条连接 —— "
                        + "该浏览器的收藏 / 置顶恢复 / 自动清理不会生效")
                    return
                }
                let fallback = ChromeWindowLocator.activeBundleID
                log("🔎 client \(id.uuidString.prefix(8)) 身份识别超时 → 单连接按前台浏览器兜底：\(fallback)")
                self.handleClientIdentified(id, browser: fallback)
            }
        }
    }

    /// 连接归属的浏览器识别完成。识别结果同时喂给 BrowserSupport 的
    /// 动态集合 —— 「装了扩展的浏览器自动获得支持」就是靠这里。
    func handleClientIdentified(_ id: UUID, browser: String) {
        guard clients[id] != nil else { return }
        clients[id]?.browser = browser
        BrowserSupport.connected = Set(clients.values.compactMap(\.browser))
        // 记住这个浏览器：设置页的浏览器列表要能显示「未连接」的老朋友
        if !settings.knownBrowsers.contains(browser) {
            settings.knownBrowsers.append(browser)
        }
        // 用户可能此刻就站在这个浏览器里 —— 立刻重算前台判定，
        // 否则要等下一次 App 切换才生效（表现为「第一次按没反应」）
        refreshFrontmostAppState()
        // 身份确定后把**属于它的**收藏推过去（初次 requestSettings 时
        // 身份可能还没解析出来，发的是兜底浏览器那份）
        pushSettings(to: id)
        profileIdentityChanged(id)
        updateReadiness()
        publishStatus()
    }

    // MARK: - 多 Profile 的身份

    /// 浏览器身份或 Profile 标识刚到（两者到的先后不定）。两样都齐了才处理老记录的归属。
    private func profileIdentityChanged(_ id: UUID) {
        guard let client = clients[id], let browser = client.browser, client.profileKey != nil else { return }
        // 升级前的置顶（没标 Profile）：这个浏览器只连着这一个 Profile 时整批归它（单 Profile
        // 用户原样接管）。连着多个时不整批给任何一个 —— 给错了就是在那个 Profile 里补开一排
        // 别人的置顶；改成谁真开着这个置顶标签就归谁（`adoptLegacyFavorite`）。
        if clients.values.filter({ $0.browser == browser }).count == 1, let key = client.profileKey {
            adoptLegacyFavoritesWholesale(browser: browser, profile: key)
        }
        scheduleLegacyClosedProbe(browser: browser)
    }

    private func adoptLegacyFavoritesWholesale(browser: String, profile: String) {
        guard settings.favorites.contains(where: { $0.browser == browser && $0.profile == nil }) else { return }
        var updated = settings.favorites
        for index in updated.indices where updated[index].browser == browser && updated[index].profile == nil {
            updated[index].profile = profile
        }
        settings.pendingUnpins = settings.pendingUnpins.map { pending in
            guard pending.browser == browser, pending.profile == nil else { return pending }
            var copy = pending
            copy.profile = profile
            return copy
        }
        settings.favorites = updated
        log("★ legacy favorites of \(browser) → profile \(profile.prefix(8))")
    }

    // MARK: 老「最近关闭」的归属：看哪个 Profile 的历史里有这些站

    /// 升级前的「最近关闭」没标 Profile。归属不能按「谁先上报」：TabFlick 一重启所有 Profile
    /// 同时重连，先后是随机的（2026-09-27 实测 1000 条被归到了刚建的空 Profile）。也读不了
    /// 浏览器数据目录（macOS 隐私保护）。改成问历史：拿最近几条老记录的域名，向这个浏览器的
    /// 每个 Profile 各查一次历史（现成的 historyQuery，不用改扩展），命中最多且唯一的那个就是
    /// 它们的来源 —— 标签是在哪个 Profile 里开的，它的历史里就有。等 2 秒再问：重启时所有
    /// Profile 陆续重连，一轮问齐。
    private struct LegacyProbe {
        let browser: String
        let round: Int
        let clientID: UUID
        let host: String
    }
    private var legacyProbes: [Int: LegacyProbe] = [:]
    private var legacyRounds: [String: (round: Int, expected: Int, received: Int, hits: [UUID: Int])] = [:]
    private var legacyProbeTimers: [String: Timer] = [:]
    private static let legacyOwnerKey = "closedTabsLegacyOwner"

    private func scheduleLegacyClosedProbe(browser: String) {
        guard !(UserDefaults.standard.stringArray(forKey: Self.legacyOwnerKey) ?? []).contains(browser),
              closedTabs.entries.contains(where: { $0.browser == browser && $0.profile == nil }) else { return }
        legacyProbeTimers[browser]?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.probeLegacyClosed(browser: browser) }
        }
        RunLoop.main.add(timer, forMode: .common)
        legacyProbeTimers[browser] = timer
    }

    private func probeLegacyClosed(browser: String) {
        let keyed = clients.filter { $0.value.browser == browser && $0.value.profileKey != nil }.map(\.key)
        var hosts: [String] = []
        for entry in closedTabs.entries where entry.browser == browser && entry.profile == nil {
            if let host = URL(string: entry.url)?.host, !hosts.contains(host) { hosts.append(host) }
            if hosts.count == 5 { break }
        }
        guard !keyed.isEmpty, !hosts.isEmpty else { return }
        let round = (legacyRounds[browser]?.round ?? 0) + 1
        legacyRounds[browser] = (round, keyed.count * hosts.count, 0, [:])
        for clientID in keyed {
            for host in hosts {
                historyRequestID += 1
                legacyProbes[historyRequestID] = LegacyProbe(browser: browser, round: round, clientID: clientID, host: host)
                server.send(["type": "historyQuery", "text": host, "requestId": historyRequestID], to: clientID)
            }
        }
    }

    /// 历史回包里属于归属探测的那些（按 requestId 认）。返回 true = 已处理，别再当搜索结果。
    private func handleLegacyProbeReply(_ id: Int, items: [HistoryInfo], from clientID: UUID) -> Bool {
        guard let probe = legacyProbes.removeValue(forKey: id) else { return false }
        guard var state = legacyRounds[probe.browser], state.round == probe.round else { return true }
        state.received += 1
        if items.contains(where: { URL(string: $0.url)?.host == probe.host }) {
            state.hits[probe.clientID, default: 0] += 1
        }
        legacyRounds[probe.browser] = state
        guard state.received == state.expected else { return true }
        // 一轮问齐：命中最多且唯一的那个 Profile 接管；都没命中而且只连着一个 Profile
        //（单 Profile 用户清过历史）也归它；分不出来就先不归，下次有 Profile 连上再问
        let keyed = clients.filter { $0.value.browser == probe.browser && $0.value.profileKey != nil }
        let ranked = state.hits.sorted { $0.value > $1.value }
        var owner: UUID?
        if let top = ranked.first, top.value > 0, ranked.dropFirst().first?.value != top.value {
            owner = top.key
        } else if ranked.isEmpty, keyed.count == 1,
                  clients.values.filter({ $0.browser == probe.browser }).count == 1 {
            owner = keyed.first?.key
        }
        log("🗂  legacy closed-tab probe [\(probe.browser)]: \(state.hits.map { "\($0.key.uuidString.prefix(8))=\($0.value)" }.joined(separator: " ")) → \(owner.map { String($0.uuidString.prefix(8)) } ?? "undecided")")
        guard let owner, let key = clients[owner]?.profileKey else { return true }
        closedTabs.adoptLegacy(browser: probe.browser, profile: key)
        var adopted = UserDefaults.standard.stringArray(forKey: Self.legacyOwnerKey) ?? []
        adopted.append(probe.browser)
        UserDefaults.standard.set(adopted, forKey: Self.legacyOwnerKey)
        publishStatus()
        return true
    }

    // MARK: Profile 名字：从窗口标题学

    /// Chrome 开了多个 Profile 时，窗口标题在标签标题后面带着 Profile 名（「页面 - 工作」）。
    /// 按标题认前台 Profile 的那一刻，把后缀里最后一段记成它的名字 —— 本来就要读这个标题，
    /// 零额外开销，也不用读浏览器数据目录（那要多要一个隐私权限）。后缀原样记一次日志备查。
    private var lastTitleSuffix: String?

    private func learnProfileName(_ id: UUID, windowTitle: String) {
        guard let tabTitle = clients[id]?.tabs.first?.title, !tabTitle.isEmpty,
              windowTitle.count > tabTitle.count, windowTitle.hasPrefix(tabTitle) else { return }
        let suffix = String(windowTitle.dropFirst(tabTitle.count))
        if suffix != lastTitleSuffix {
            lastTitleSuffix = suffix
            log("👤 window title suffix for \(id.uuidString.prefix(8)): “\(suffix)”")
        }
        let parts = suffix.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        // 只有浏览器名（「 - Google Chrome」）不算 Profile 名
        guard let name = parts.last, !name.isEmpty, name.count <= 40,
              name != BrowserSupport.displayName(effectiveBrowser(of: id)),
              clients[id]?.profileName != name else { return }
        clients[id]?.profileName = name
        log("👤 client \(id.uuidString.prefix(8)) = profile “\(name)”")
        publishStatus()
    }

    /// 多 Profile 时认领一条老收藏：这个 Profile 真开着和它同网址（再退一步同域名）的置顶标签。
    /// 返回认领到的收藏 id。
    private func adoptLegacyFavorite(scope: FavoriteScope, url: String, host: String, tabId: Int) -> String? {
        guard let profile = scope.profile else { return nil }
        let legacy = settings.favorites.indices.filter {
            settings.favorites[$0].browser == scope.browser && settings.favorites[$0].profile == nil
                && favoriteTabBindings[settings.favorites[$0].id] == nil
        }
        let exact = legacy.first { index in
            let fav = settings.favorites[index]
            return (settings.favoriteCurrentUrls[fav.id] ?? fav.url) == url || fav.url == url
        }
        let sameHost = legacy.first { index in
            let fav = settings.favorites[index]
            return URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                || URL(string: fav.url)?.host == host
        }
        guard let index = exact ?? sameHost else { return nil }
        let id = settings.favorites[index].id
        favoriteTabBindings[id] = tabId
        settings.favorites[index].profile = profile
        log("★ legacy favorite → profile \(profile.prefix(8)): \(settings.favorites[index].title.prefix(50))")
        return id
    }

    /// 给用户看的 Profile 名：浏览器自己的 Profile 名（从窗口标题学到的），还没学到按连上的
    /// 先后编号。这个浏览器只连着一个 Profile 时返回 nil —— 不用区分，别多一截字。
    func profileLabel(for id: UUID) -> String? {
        guard let client = clients[id] else { return nil }
        let browser = effectiveBrowser(of: id)
        let siblings = clients.filter { effectiveBrowser(of: $0.key) == browser }
            .sorted { $0.value.connectedAt < $1.value.connectedAt }
        guard siblings.count > 1 else { return nil }
        if let name = client.profileName { return name }
        let number = (siblings.firstIndex { $0.key == id } ?? 0) + 1
        return L10n.t("个人资料 \(number)", "Profile \(number)")
    }

    /// 按 Profile 标识认名字（设置页的置顶列表用）：那个 Profile 连着才认得出。
    func profileLabel(forKey key: String) -> String? {
        clients.first(where: { $0.value.profileKey == key }).flatMap { profileLabel(for: $0.key) }
    }

    /// 某条「最近关闭」记录所属 Profile 的名字（跨浏览器搜索行尾用）：那个 Profile 连着才认得出。
    private func profileLabel(forClosed entry: ClosedTab) -> String? {
        guard let key = entry.profile,
              let id = clients.first(where: { $0.value.profileKey == key })?.key else { return nil }
        return profileLabel(for: id)
    }

    func handleClientDisconnected(_ id: UUID) {
        let wasActive = (id == activeClientID)
        clients.removeValue(forKey: id)
        BrowserSupport.connected = Set(clients.values.compactMap(\.browser))
        if clients.isEmpty {
            log("⚠️  Extension disconnected — 快捷键放行给浏览器原生行为")
            stopPinging()
        } else {
            log("⚠️  Client disconnected (\(clients.count) left)")
        }
        // 全局模式的快照里混着所有浏览器，任何一家掉线都可能让快照里出现
        // 死连接（提交时命令发进空气）。收摊比留着安全。
        if wasActive || cyclingGlobal {
            endCycling()
            resetEventTapCycling()
        }
        // 面板里列的是这条连接的标签，连接没了选什么都发进空气；跨浏览器模式刷新即可
        if searchIsGlobal { refreshSearch() } else if wasActive { search.close() }
        updateReadiness()
        publishStatus()
    }

    /// 前台浏览器变化（EventTap 跟踪回调）：就绪状态和菜单计数换账本。
    func activeBrowserChanged() {
        updateReadiness()
        publishStatus()
    }

    // MARK: - 来自 EventTap

    func step(backward: Bool) {
        if !cycling { invalidateProfilePick() }   // 起手这一下必须按此刻的前台窗口判
        if !cycling {
            cycling = true
            // 全局还是当前浏览器，由 event tap 在按下那一刻按「前台是不是
            // 浏览器 + 按的是哪个键」定好，这里只取结果 —— 前台状态在
            // cycling 期间还会变，晚一步读就可能拍错快照。
            cyclingGlobal = eventTapCyclingIsGlobal
            snapshot = cyclingGlobal ? globalItems : switcherItems
            cursor = 0
            closedTabThisRound = false
            overlay.beginCycle(isGlobal: cyclingGlobal, items: snapshot)
            overlay.model.items = snapshot
            refreshOverlayImages()
        }

        guard snapshot.count > 1 else {
            log("⌃⇥ only \(snapshot.count) tab(s) — nowhere to go")
            return
        }

        cursor = backward
            ? (cursor - 1 + snapshot.count) % snapshot.count
            : (cursor + 1) % snapshot.count

        overlay.model.setCursor(cursor, source: .keyboard)
        overlay.requestShow()
        armWatchdog()

        log("⌃\(backward ? "⇧" : "")⇥ \(cyclingGlobal ? "(global) " : "")[\(cursor)/\(snapshot.count - 1)] → \(snapshot[cursor].tab.title.prefix(50))")
    }

    /// cycling 中的方向键。
    ///
    /// 每种排布把**视觉上的主轴**给「走列表」，另一个轴给「跳分组 / 按行移动」：
    /// 纵向列表里 ↑↓ 就该是上一条下一条（跟它跳浏览器会很别扭），横向卡片里
    /// ←→ 才是。这个映射只有知道当前排布的人能做，所以 tap 只报方向。
    func arrow(_ direction: ArrowDirection) {
        guard cycling, snapshot.count > 1 else { return }

        switch overlay.presentation.layout {
        case .globalList:
            switch direction {
            case .up:    step(backward: true)
            case .down:  step(backward: false)
            case .left:  stepBrowser(up: true)
            case .right: stepBrowser(up: false)
            }

        case .globalCards(let columns):
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up:    stepCardRow(up: true, cols: columns)
            case .down:  stepCardRow(up: false, cols: columns)
            }

        case .grid(let columns):
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up:    stepRow(up: true, cols: columns)
            case .down:  stepRow(up: false, cols: columns)
            }

        case .strip:
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up, .down: break   // 单行没有上下，但键已经吞了（防调度中心）
            }
        }
    }

    /// 当前浏览器宫格：按行移动游标。整块是一个连续网格，直接按列数跨。
    ///
    /// 上下都不回绕 —— 宫格里「从顶行再往上」的预期是停住，不是跳到底部。
    /// 最后一行不满时，从上一行按 ↓ 落到末尾一张。
    private func stepRow(up: Bool, cols: Int) {
        guard cols > 0 else { return }

        let lastRowStart = (snapshot.count - 1) / cols * cols
        if up {
            guard cursor >= cols else { return }
            moveCursor(to: cursor - cols, arrow: up ? "↑" : "↓")
        } else {
            guard cursor < lastRowStart else { return }
            moveCursor(to: min(cursor + cols, snapshot.count - 1), arrow: "↓")
        }
    }

    /// 全局卡片：按**视觉上的行**移动游标，跨分组边界也照走。
    ///
    /// 不能像宫格那样直接 `cursor ± cols`：卡片是**每个浏览器各自换行**的，
    /// 每组最后一行都可能不满，扁平的位置算术会算到别处去。比如 7 列、A 组
    /// 12 个、B 组 2 个时，视觉上是
    ///     行0  A0 … A6
    ///     行1  A7 … A11        ← 只有 5 个
    ///     行2  B0 B1
    /// 从 A9（第 2 列）按 ↓ 应该落到 B 组同列——B 只有 2 个，夹到最后一个；
    /// 扁平算术给出的 9+7=16 直接越界。
    ///
    /// 边界处**跨组**：在本组最后一行按 ↓ 进入下一组的第一行、同列（不够就
    /// 夹到该行末尾）；反之亦然。方向键走的是"眼睛看到的相邻"，跟标签属于
    /// 哪个浏览器无关。
    private func stepCardRow(up: Bool, cols: Int) {
        guard let target = GridGeometry.rowNeighbor(of: cursor,
                                                    groupStarts: groupStarts(),
                                                    total: snapshot.count,
                                                    cols: cols,
                                                    up: up) else { return }
        moveCursor(to: target, arrow: up ? "↑" : "↓")
    }

    /// 全局列表里 ⌃←/⌃→ 换浏览器：跳到上/下一个分组的第一项
    /// （= 该浏览器最近用过的标签）。纵向列表里左右没有空间含义，
    /// 正好拿来跳组；卡片模式的四个方向都有空间含义，就不这么用。
    private func stepBrowser(up: Bool) {
        let starts = groupStarts()
        guard starts.count > 1 else { return }

        // 游标所在分组 = 最后一个不超过 cursor 的起点
        let current = starts.lastIndex(where: { $0 <= cursor }) ?? 0
        let target = up ? current - 1 : current + 1
        guard starts.indices.contains(target) else { return }

        let name = snapshot[starts[target]].browser.map { BrowserSupport.displayName($0) } ?? "?"
        moveCursor(to: starts[target], arrow: up ? "←" : "→", note: name)
    }

    /// 快照里每个分组第一项的位置。globalItems 拼装时同一浏览器的项就是
    /// 连在一起的，所以只需要找「与前一项浏览器不同」的位置。
    private func groupStarts() -> [Int] {
        // 和浮层分组同一个依据（浏览器 + Profile），不然方向键跳组和画出来的组对不上
        var starts: [Int] = []
        var lastKey: String?
        for (index, item) in snapshot.enumerated() where item.groupKey != lastKey {
            starts.append(index)
            lastKey = item.groupKey
        }
        return starts
    }

    /// 方向键移动游标的统一收尾：越界一律不动（不回绕）。
    private func moveCursor(to index: Int, arrow: String, note: String? = nil) {
        guard snapshot.indices.contains(index), index != cursor else { return }
        cursor = index
        overlay.model.setCursor(cursor, source: .keyboard)
        overlay.requestShow()
        armWatchdog()
        let suffix = note.map { " → \($0)" } ?? " → \(snapshot[cursor].tab.title.prefix(50))"
        log("⌃\(arrow)  [\(cursor)/\(snapshot.count - 1)]\(suffix)")
    }

    func commit() {
        disarmWatchdog()
        guard cycling else { return }
        cycling = false
        overlay.hide()

        let wasGlobal = cyclingGlobal
        defer { cursor = 0; snapshot = []; closedTabThisRound = false; cyclingGlobal = false }

        // 关过标签的话 cursor == 0 也要提交（见 closedTabThisRound 的说明）。
        // 全局模式没有「原地不动」这回事：起手时前台可能根本不是浏览器，
        // 停在第 0 项也是一次实实在在的跳转。
        guard snapshot.indices.contains(cursor),
              wasGlobal || cursor != 0 || closedTabThisRound else {
            log("⌃ released: cursor back at origin, no switch")
            return
        }

        let target = snapshot[cursor]
        log("⌃ released → switching to: \(target.tab.title.prefix(50)) (tabId \(target.tab.id))")
        // 全局模式下目标多半在另一个 App 里：扩展的 windows.update(focused:)
        // 只管浏览器自家窗口之间的焦点，跨 App 的激活必须由 helper 在
        // macOS 层面做（和状态栏菜单点选同一条路）。
        if let browser = target.browser {
            _ = NSRunningApplication
                .runningApplications(withBundleIdentifier: browser)
                .first?
                .activate(options: [])
        }
        server.send(["type": "switch", "tabId": target.tab.id], to: target.clientID)
    }

    // MARK: - 收藏标签

    /// 当前标签（MRU 首位）。状态栏「收藏当前标签」用。
    var currentTab: TabInfo? { tabs.first }

    /// 活动浏览器的记账身份（收藏的读写都以它为账本）。
    private var activeBrowser: String {
        activeClientID.map { effectiveBrowser(of: $0) } ?? ChromeWindowLocator.activeBundleID
    }

    /// 活动浏览器的显示名（状态栏第一行用；未连接时 nil）。
    var activeBrowserDisplayName: String? {
        guard connected else { return nil }
        return BrowserSupport.displayName(activeBrowser)
    }

    /// 当前标签是否已收藏（nil = 没有当前标签）。绑定优先 ——
    /// 置顶标签可能已漂到别的域名，光看域名会误判成「未收藏」。
    /// 只查活动浏览器自己的账本。
    var currentTabFavorited: Bool? {
        guard let tab = tabs.first, let scope = activeClientID.flatMap(favoriteScope(of:)) else { return nil }
        let mine = settings.favorites.filter(scope.contains)
        if mine.contains(where: { favoriteTabBindings[$0.id] == tab.id }) { return true }
        guard let host = URL(string: tab.url)?.host else { return nil }
        return mine.contains { fav in
            URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                || URL(string: fav.url)?.host == host
        }
    }

    /// 某个标签对应的收藏的**原始**置顶地址；标签没漂离（还在那个地址上）或不是置顶标签时 nil。
    /// 收藏的恢复语义是「最后访问」（标签位），所以漂走了不会自己回去 —— 这条给用户一个主动回去的
    /// 动作。判定和 `currentTabFavorited` 同一套：绑定优先，再按域名兜底（漂到别的站之后只有绑定
    /// 认得出来；按域名兜底是给绑定还没建起来的那一小段时间）。
    func pinnedHomeURL(tabID: Int, clientID: UUID) -> String? {
        guard let scope = favoriteScope(of: clientID),
              let tab = clients[clientID]?.tabs.first(where: { $0.id == tabID }) else { return nil }
        let mine = settings.favorites.filter(scope.contains)
        // 域名兜底只认浏览器自己标了 pinned 的标签：普通标签开着收藏的站、绑定又恰好还没建起来时，
        // 不能给它一条「回到置顶地址」—— 回车会把一个普通标签导到别处
        let fav = mine.first { favoriteTabBindings[$0.id] == tabID }
            ?? (tab.pinned == true ? URL(string: tab.url)?.host : nil).flatMap { host in
                mine.first { fav in
                    favoriteTabBindings[fav.id] == nil
                        && (URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                            || URL(string: fav.url)?.host == host)
                }
            }
        guard let fav, fav.url.hasPrefix("http"),
              Self.samePage(fav.url, tab.url) == false else { return nil }
        return fav.url
    }

    /// 当前标签（活动浏览器的 MRU 首项）的原始置顶地址，状态栏菜单用。
    var currentTabPinnedHome: String? {
        guard let tab = tabs.first, let clientID = activeClientID else { return nil }
        return pinnedHomeURL(tabID: tab.id, clientID: clientID)
    }

    /// 「还在置顶地址上」的判定：忽略尾部斜杠和 # 片段。站内翻页、改了查询串都算漂离 ——
    /// 回去就是回到收藏时那个页面，宽一点的等价只会让「回到置顶地址」在该出现时不出现。
    nonisolated static func samePage(_ a: String, _ b: String) -> Bool {
        func trim(_ s: String) -> Substring {
            var t = s[...]
            if let hash = t.firstIndex(of: "#") { t = t[..<hash] }
            while t.hasSuffix("/") { t = t.dropLast() }
            return t
        }
        return trim(a) == trim(b)
    }

    /// 回到置顶地址：让扩展把这个标签导航回收藏记的原始地址。老扩展没有 navigate 命令，照
    /// `supportsPanelCommands` 那条如实说「太旧」。
    func returnToPinnedURL(tabID: Int, clientID: UUID) {
        guard let url = pinnedHomeURL(tabID: tabID, clientID: clientID) else { return }
        guard supportsPanelCommands(clientID, since: Self.navigateExtensionVersion) else { return }
        log("📌 return to pinned → \(url.prefix(80)) (tabId \(tabID))")
        server.send(["type": "navigate", "tabId": tabID, "url": url], to: clientID)
        // 地址变了扩展要过 ~100ms 才推回来，这期间再按 ⌘W 该归 Chrome（想关标签的人第二下就是关），
        // 先把标志放下，推送到了再按真实数据算
        setEventTapPinnedDrifted(false)
        Toast.show(L10n.t("已回到置顶地址", "Returned to the pinned URL"), detail: url)
    }

    /// ⌘W 接管的依据：当前标签是不是漂离的置顶标签。MRU 推送（地址变了扩展会推）、收藏变化、
    /// 绑定建立时各算一次，event tap 只读结果。
    private func refreshPinnedDriftedFlag() {
        setEventTapPinnedDrifted(currentTabPinnedHome != nil)
    }

    /// 状态栏「回到置顶地址」：对当前标签做。
    func returnCurrentTabToPinnedURL() {
        guard let tab = tabs.first, let clientID = activeClientID else { return }
        returnToPinnedURL(tabID: tab.id, clientID: clientID)
    }

    /// 收藏被移除后撤销对应域名的置顶。取消收藏 = 恢复普通标签。
    /// unpin 只发给该收藏归属浏览器的连接 —— 发错浏览器会把人家
    /// 同域名的置顶也撤了。域名按「最后访问」取（可能已漂移）。
    func unpinRemovedFavorites(_ removed: [FavoriteTab]) {
        for fav in removed {
            favoriteTabBindings.removeValue(forKey: fav.id)
            guard let host = URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host
                    ?? URL(string: fav.url)?.host else { continue }
            // 只发给收藏所属的那个 Profile：发给同浏览器的别的 Profile 会把人家同域名的置顶也撤了
            let owner = FavoriteScope(browser: fav.browser, profile: fav.profile)
            guard let clientID = clients.keys.first(where: { favoriteScope(of: $0) == owner }) else {
                // 浏览器不在线：记账，等它下次连上补做。不记的话它自己的
                // 会话恢复会把置顶带回来，收编扫描再把它加回列表（用户实测：
                // 关着浏览器删掉，重开又回来了）。
                let pending = PendingUnpin(browser: fav.browser, host: host, profile: fav.profile)
                if !settings.pendingUnpins.contains(pending) {
                    settings.pendingUnpins.append(pending)
                }
                log("☆ unpin deferred (\(fav.browser) 未连接): \(host)")
                continue
            }
            log("☆ unpin \(host) [\(fav.browser)]")
            server.send(["type": "unpin", "hosts": [host]], to: clientID)
        }
    }

    /// 收藏 / 取消收藏当前标签（活动浏览器的账本）。
    func toggleFavoriteCurrentTab() {
        guard let current = tabs.first, let scope = activeClientID.flatMap(favoriteScope(of:)) else { return }
        let browser = scope.browser
        let mine = settings.favorites.filter(scope.contains)

        // 取消：绑定命中优先（漂移后域名对不上，绑定还在）
        if let bound = mine.first(where: { favoriteTabBindings[$0.id] == current.id }),
           let index = settings.favorites.firstIndex(where: { $0.id == bound.id }) {
            log("☆ unfavorite: \(settings.favorites[index].title.prefix(50))")
            settings.favorites.remove(at: index)
            return
        }
        guard let host = URL(string: current.url)?.host else { return }
        if let match = mine.first(where: { URL(string: $0.url)?.host == host }),
           let index = settings.favorites.firstIndex(where: { $0.id == match.id }) {
            log("☆ unfavorite: \(settings.favorites[index].title.prefix(50))")
            settings.favorites.remove(at: index)
        } else {
            log("★ favorite: \(current.title.prefix(50)) (\(host)) [\(browser)]")
            let fav = FavoriteTab(url: current.url, title: current.title,
                                  favIconUrl: current.favIconUrl, browser: browser, profile: scope.profile)
            favoriteTabBindings[fav.id] = current.id
            settings.favorites.append(fav)
        }
        // favorites 的 didSet → onChange → 推给扩展，扩展立即核对补齐
    }

    /// 某客户端推送 MRU 后维护绑定：把绑定标签的最新 URL 记为「最后访问」；
    /// 标签没了就解绑（tabId 不复用，失效即永久失效）。
    /// 只处理**该客户端浏览器**账下的收藏 —— tabId 在不同浏览器间会撞号，
    /// 拿别的浏览器的推送对账必然张冠李戴。
    private func syncFavoriteBindings(for clientID: UUID) {
        guard let client = clients[clientID], let scope = favoriteScope(of: clientID) else { return }
        for (favId, tabId) in favoriteTabBindings {
            guard let fav = settings.favorites.first(where: { $0.id == favId }),
                  scope.contains(fav) else { continue }
            guard let tab = client.tabs.first(where: { $0.id == tabId }) else {
                favoriteTabBindings.removeValue(forKey: favId)
                continue
            }
            if tab.url.hasPrefix("http"), settings.favoriteCurrentUrls[favId] != tab.url {
                settings.favoriteCurrentUrls[favId] = tab.url
            }
        }
    }

    // MARK: - 状态栏子菜单

    /// 状态栏菜单里的一个浏览器条目：名称 + 它的全部标签（MRU 顺序）
    /// + 最近关闭的那些。
    struct MenuBrowser {
        let bundleID: String
        /// 这一行对应的连接（`UUID.uuidString`）。菜单里的点选、找回、清空都按它路由 ——
        /// 按 bundle id 路由的话，同一个浏览器开了多个 Profile 时会落到别的 Profile 头上。
        let key: String
        let name: String
        let entries: [(tab: TabInfo, icon: NSImage?)]
        /// 最近关闭的标签，最新在前。子菜单末尾单列一段，点一条即找回。
        let closed: [(tab: ClosedTab, icon: NSImage?)]
        /// 存档里该浏览器的**总**条数 —— `closed` 只是最近 20 条，
        /// 而「清空」清的是全部，两个数字必须都摆出来。
        let closedTotal: Int
    }

    /// 每个已连接浏览器一份菜单数据，活动浏览器排最前。
    var menuBrowsers: [MenuBrowser] {
        let activeID = activeClientID
        let ordered = clients.keys.sorted { a, b in
            if a == activeID { return true }
            if b == activeID { return false }
            return effectiveBrowser(of: a) < effectiveBrowser(of: b)
        }
        return ordered.compactMap { id in
            guard let client = clients[id], !client.tabs.isEmpty else { return nil }
            let bundleID = effectiveBrowser(of: id)
            let browserName = BrowserSupport.displayName(bundleID)
            return MenuBrowser(
                bundleID: bundleID,
                key: id.uuidString,
                name: profileLabel(for: id).map { "\(browserName) · \($0)" } ?? browserName,
                entries: client.tabs.map { ($0, icons.image(for: $0.favIconUrl)?.image) },
                closed: closedTabs.recent(browser: bundleID, profile: client.profileKey, limit: Self.menuClosedTabLimit)
                    .map { ($0, icons.image(for: $0.favIconUrl)?.image) },
                closedTotal: closedTabs.count(browser: bundleID, profile: client.profileKey))
        }
    }

    /// 找回一个已关闭的标签。`via` 是点选时所在的那条连接（状态栏子菜单），没有就按记录
    /// 自己的浏览器 + Profile 找 —— 多 Profile 时开回它原来那个 Profile，不是随便一个。
    func reopenClosedTab(id: String, via clientKey: String? = nil) {
        guard let record = closedTabs.entries.first(where: { $0.id == id }) else { return }
        let bundleID = record.browser
        log("↩︎ reopen: \(record.displayTitle.prefix(50)) [\(bundleID)]")

        let viaClient = clientKey.flatMap(UUID.init(uuidString:)).flatMap { clients[$0] != nil ? $0 : nil }
        let sameProfile = clients.first(where: {
            effectiveBrowser(of: $0.key) == bundleID && $0.value.profileKey == record.profile
        })?.key
        let sameBrowser = clients.first(where: { effectiveBrowser(of: $0.key) == bundleID })?.key
        if let clientID = viaClient ?? sameProfile ?? sameBrowser {
            // 用户是从状态栏点进来的，浏览器多半不在前台 —— 跨 App 的激活
            // 必须 helper 来做（和菜单点选活标签同一条路）。
            _ = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first?
                .activate(options: [])
            server.send(["type": "reopen", "url": record.url], to: clientID)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let url = URL(string: record.url) {
            // 菜单打开之后、点击之前那个浏览器断线了。直接交给 macOS 用它
            // 打开这个地址 —— 找回标签这件事没有「等它重连再补做」的余地。
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }

        // 找回了就该离开回收站，否则用户再点一次会开出重复标签
        closedTabs.remove(id: id)
    }

    /// 清空某个 Profile（状态栏那一行对应的连接）的已关闭记录。
    func clearClosedTabs(client clientKey: String) {
        guard let id = UUID(uuidString: clientKey), let client = clients[id] else { return }
        closedTabs.clear(browser: effectiveBrowser(of: id), profile: client.profileKey)
    }

    /// 状态栏子菜单点选：激活对应浏览器并切到该标签。
    ///
    /// 和 ⌃⇥ 的 commit 不同，走到这里时浏览器多半不在前台：扩展的
    /// windows.update(focused:) 只管浏览器自己窗口之间的焦点，跨 App 的
    /// 激活必须由 helper 在 macOS 层面做。命令点对点发给该浏览器的连接。
    func activateFromMenu(tabId: Int, client clientKey: String) {
        guard let clientID = UUID(uuidString: clientKey),
              let target = clients[clientID]?.tabs.first(where: { $0.id == tabId }) else { return }
        let bundleID = effectiveBrowser(of: clientID)
        _ = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate(options: [])
        log("📎 menu pick → \(target.title.prefix(50)) [\(bundleID)]")
        server.send(["type": "switch", "tabId": tabId], to: clientID)
    }

    private func refreshOverlayImages() {
        var iconMap: [String: IconInfo] = [:]
        var thumbMap: [String: NSImage] = [:]
        for item in overlay.model.items {
            if let info = icons.image(for: item.tab.favIconUrl) { iconMap[item.id] = info }
            if let thumb = thumbnails.image(for: item.tab.url) { thumbMap[item.id] = thumb }
        }
        overlay.model.icons = iconMap
        overlay.model.thumbs = thumbMap
        if search.isVisible { search.model.reloadIcons() }

        // 折射背景的源图：当前标签（MRU 第一个）那张**完整视口**的截图。
        // 浮层会按自己盖住了窗口的哪一块去裁它 —— 裁剪归浮层做，这里只负责
        // 挑对源，并挡住比例不可信的老图。
        overlay.model.backdropSource = overlay.model.items.first.flatMap { item in
            fullViewportThumbs.contains(item.tab.url) ? thumbMap[item.id] : nil
        }
    }

    // MARK: - 保活
    //
    // MV3 的 service worker 空闲 30s 就会被回收。Chrome 116+ 起 WebSocket 上的
    // 收发活动会重置这个计时器，所以由我们定时 ping 把它钉住。

    private func startPinging() {
        guard pingTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.server.broadcast(["type": "ping"])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}
