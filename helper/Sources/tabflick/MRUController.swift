import AppKit
import CoreImage
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

    /// 判断图标整体偏亮还是偏暗。
    ///
    /// favicon 大多带透明背景，直接取平均色会被透明区拉向黑色，所以要按
    /// alpha 反预乘，只看真正画了东西的那部分。
    private static func isLight(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return false }

        let parameters: [String: Any] = [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent),
        ]
        guard let average = CIFilter(name: "CIAreaAverage", parameters: parameters)?.outputImage
        else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else { return false }   // 几乎全透明，无从判断，当作暗的

        // 反预乘后按感知亮度加权
        let r = CGFloat(pixel[0]) / 255 / alpha
        let g = CGFloat(pixel[1]) / 255 / alpha
        let b = CGFloat(pixel[2]) / 255 / alpha
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62
    }

    func prefetch(_ urls: [String], onLoaded: @escaping () -> Void) {
        for url in urls where !url.isEmpty && images[url] == nil && !inflight.contains(url) {
            guard let parsed = URL(string: url) else { continue }
            inflight.insert(url)
            URLSession.shared.dataTask(with: parsed) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
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
    private let icons = IconCache()

    /// 网页缩略图缓存（内存 + 磁盘，按 URL 索引）。
    ///
    /// 放在 helper 而不是扩展侧：MV3 的 service worker 随时会被回收。
    /// 落盘则是因为 `captureVisibleTab` 只能截可见标签，图是一张张攒出来的，
    /// 只存内存的话 helper 一重启就退化成一排空卡片。
    private let thumbnails = ThumbnailStore()

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
    }

    private var clients: [UUID: ClientState] = [:]
    /// 最近一次推送 MRU 的客户端 —— 多连接且身份都没识别出来时的兜底路由。
    private var lastPushClient: UUID?

    /// 当前应该服务的客户端：前台浏览器对应的连接优先；只有一个连接时
    /// 直接用它（单浏览器用户完全不依赖 pid 识别这条链路）；多连接身份
    /// 不明时退回最近推送者。
    private var activeClientID: UUID? {
        if let match = clients.first(where: { $0.value.browser == ChromeWindowLocator.activeBundleID })?.key {
            return match
        }
        if clients.count == 1 { return clients.keys.first }
        if let last = lastPushClient, clients[last] != nil { return last }
        return clients.keys.first
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

    /// 命令只发给活动客户端 —— 广播会命中其他浏览器里碰巧同号的 tabId。
    private func sendToActive(_ object: [String: Any]) {
        guard let id = activeClientID else { return }
        server.send(object, to: id)
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

    /// 本轮 cycling 的快照，与 `tabs` 隔离。
    private var snapshot: [TabInfo] = []
    private var cursor = 0
    private var cycling = false

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
        cycling = false
        cursor = 0
        snapshot = []
        closedTabThisRound = false
        resetEventTapCycling()
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
    static let requiredExtensionVersion = "0.5"

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
        let known = Set(BrowserSupport.installedBrowsers())
            .union(settings.knownBrowsers)
            .union(settings.favorites.map(\.browser))
            .union(connectedByBrowser.keys)
        return known.sorted().map { bundleID in
            let client = connectedByBrowser[bundleID]
            let needsUpdate: Bool = {
                guard let ext = client?.extVersion else { return false }
                return Self.isOlder(ext, than: Self.requiredExtensionVersion)
            }()
            return BrowserStatus(bundleID: bundleID,
                                 name: BrowserSupport.displayName(bundleID),
                                 connected: client != nil,
                                 extVersion: client?.extVersion,
                                 needsUpdate: needsUpdate)
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
        for id in clients.keys { pushSettings(to: id) }
    }

    private func pushSettings(to id: UUID) {
        server.send(settings.payload(favoritesFor: effectiveBrowser(of: id)), to: id)
    }

    /// 数据没就绪时让 event tap 放行 Ctrl+Tab，降级到 Chrome 的原生切换。
    /// 判定基准是切换器视角的列表（按窗口过滤后）：当前窗口只有 1 个标签
    /// 时即便别的窗口还有标签，⌃⇥ 也该放行给 Chrome。
    private func updateReadiness() {
        setEventTapReady(connected && switcherTabs.count > 1)
    }

    init(server: WebSocketServer, settings: AppSettings) {
        self.server = server
        self.settings = settings
        self.overlay = OverlayPanel(settings: settings)
        thumbnails.warmUp()   // 磁盘上的图先读进来，第一次按 ⌃⇥ 就有画面
        overlay.model.onPick = { [weak self] tabId in
            self?.pick(tabId: tabId)
        }
        overlay.model.onHover = { [weak self] tabId in
            self?.hover(tabId: tabId)
        }
        overlay.model.onClose = { [weak self] tabId in
            self?.closeTab(tabId: tabId)
        }
    }

    /// 鼠标悬停：把状态机游标移过去，再回写视觉高亮。
    ///
    /// 游标只有这一份（状态机的），视觉是它的投影 —— 之前 hover 直接改
    /// 视图模型那份，悬停后 ⌃⇥ 从旧位置继续、松开 Ctrl 切到的也是旧游标
    /// 那张（高亮和实际切换对不上）。
    /// source 必须是 .mouse：hover 触发自动滚动会形成正反馈环（见 SwitcherView）。
    ///
    /// 视图回调带来的都是 tab.id，这里按 id 在快照里反查位置 —— 位置索引在
    /// 「渲染 → 点击」之间可能失真（连续关闭时数组在变），id 不会。
    private func hover(tabId: Int) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == tabId }),
              index != cursor else { return }
        cursor = index
        overlay.model.setCursor(index, source: .mouse)
        armWatchdog()
    }

    /// 鼠标点选某张卡片：把游标直接定位过去并立即提交。
    private func pick(tabId: Int) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == tabId }) else { return }
        cursor = index
        // tap 侧的 cycling 也要清，否则用户松开 Ctrl 时会再 commit 一次
        resetEventTapCycling()
        log("🖱 clicked [\(index)] → \(snapshot[index].title.prefix(50))")
        commit()
    }

    /// 点了卡片上的 ✕：关掉那个标签，卡片消失，本轮 cycling 继续。
    ///
    /// 功能默认关闭，由设置项 allowTabClose 打开（视图侧用它控制 ✕ 显隐，
    /// 这里是状态机侧的同一道门）。只在剩 3 张以上时可用：2 张关 1 张就
    /// 只剩单标签，切换器不为单标签出现，关到那一步面板就没意义了。
    /// 这条守卫同时保证 tabs 不会被关到触发 readiness 降级。
    private func closeTab(tabId: Int) {
        guard settings.allowTabClose,
              cycling, snapshot.count > 2,
              let index = snapshot.firstIndex(where: { $0.id == tabId }) else { return }

        let target = snapshot[index]
        log("✕ close [\(index)] → \(target.title.prefix(50)) (tabId \(target.id))")
        sendToActive(["type": "close", "tabId": target.id])
        closedTabThisRound = true

        snapshot.remove(at: index)
        // 本地同步剔除，不等扩展的 onRemoved 推送 —— 窗口期里如果开始
        // 新一轮 cycling，快照里不该出现已关掉的标签。
        if let id = activeClientID {
            clients[id]?.tabs.removeAll { $0.id == target.id }
        }
        publishStatus()

        // 关的在游标前面 → 游标跟着前移一位；关的是游标那张且它是末尾 →
        // 收到新末尾。其余情况游标位置不变（自然落到顶上来的下一张）。
        if index < cursor {
            cursor -= 1
        } else if cursor >= snapshot.count {
            cursor = snapshot.count - 1
        }

        overlay.applyRemoval(tabs: snapshot, cursor: cursor)
        armWatchdog()
    }

    // MARK: - 来自 WebSocket

    func handleMessage(_ data: Data, from clientID: UUID) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
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
            if !cycling, clientID == activeClientID {
                log("MRU updated: \(decoded.count) tabs, current: \(decoded.first?.title.prefix(40) ?? "?")")
            }

        case "thumb":
            guard let url = root["url"] as? String, !url.isEmpty,
                  let base64 = root["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            thumbnails.store(data, for: url)
            refreshOverlayImages()

        case "pinnedTab":
            // 浏览器里被置顶的标签（用户手动置顶，或程序离线期间置顶、
            // 连接后由 ensureFavorites 收编上报）。置顶 = 收藏。
            // 每条记录有独立 id，同域名甚至同 URL 都允许多条 ——
            // 列表如实镜像浏览器的置顶状态。自家 ensure 补的置顶由扩展侧
            // selfPinned 标记拦下，不会走到这里。
            guard let tabId = (root["tabId"] as? NSNumber)?.intValue,
                  let url = root["url"] as? String, url.hasPrefix("http"),
                  let host = URL(string: url)?.host else { return }
            // 只在**这个浏览器**的账本里去重/认领 —— 隔离主体原则
            let browser = effectiveBrowser(of: clientID)
            let mine = settings.favorites.filter { $0.browser == browser }
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
            let title = root["title"] as? String ?? ""
            log("★ browser pin → favorite: \(title.prefix(50)) (\(host)) [\(browser)]")
            let fav = FavoriteTab(url: url, title: title,
                                  favIconUrl: root["favIconUrl"] as? String,
                                  browser: browser)
            favoriteTabBindings[fav.id] = tabId
            settings.favorites.append(fav)

        case "unpinned":
            // 用户在浏览器里主动取消了某个标签的置顶（⌘W 关闭不会来这条）。
            // 收藏的语义就是「常驻置顶」，置顶被主动撤掉 = 用户不想要了，
            // 收藏一并移除。绑定命中优先 —— 漂移后按域名已经判不准了。
            let tabId = (root["tabId"] as? NSNumber)?.intValue
            let host = root["host"] as? String
            let reporter = effectiveBrowser(of: clientID)
            let index = settings.favorites.firstIndex { fav in
                guard fav.browser == reporter else { return false }   // 只动自己浏览器的账
                if let tabId, favoriteTabBindings[fav.id] == tabId { return true }
                guard let host, !host.isEmpty else { return false }
                return URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                    || URL(string: fav.url)?.host == host
            }
            if let index {
                log("☆ browser unpin → unfavorite: \(settings.favorites[index].title.prefix(50))")
                settings.favorites.remove(at: index)
            }

        case "favoriteBound":
            // 扩展核对收藏后上报「这个收藏现在对应哪个活标签」
            guard let favId = root["id"] as? String,
                  let tabId = (root["tabId"] as? NSNumber)?.intValue else { return }
            favoriteTabBindings[favId] = tabId

        case "requestSettings":
            // 扩展（重）连上了，向我们要一份当前配置（按它的浏览器过滤收藏）
            pushSettings(to: clientID)
            // 顺带核对版本配套：扩展和 app 按 major.minor 成对发布。
            // 旧扩展不带 extVersion 字段 → 按 0.1.0 处理，必然提示。
            recordExtensionVersion(clientID, root["extVersion"] as? String ?? "0.1.0")

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
        refreshFrontmostBrowserState()
        // 身份确定后把**属于它的**收藏推过去（初次 requestSettings 时
        // 身份可能还没解析出来，发的是兜底浏览器那份）
        pushSettings(to: id)
        updateReadiness()
        publishStatus()
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
        if wasActive {
            cycling = false
            overlay.hide()
        }
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
        if !cycling {
            cycling = true
            snapshot = switcherTabs
            cursor = 0
            closedTabThisRound = false
            overlay.model.tabs = snapshot
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

        log("⌃\(backward ? "⇧" : "")⇥  [\(cursor)/\(snapshot.count - 1)] → \(snapshot[cursor].title.prefix(50))")
    }

    /// ⌃↑/⌃↓：宫格布局下按行移动游标。
    ///
    /// 长条布局（gridRowStride == 0）没有第二行，忽略；单行宫格同理会被
    /// 下面的越界判断挡住。上下都不回绕 —— 宫格里「从顶行再往上」的预期
    /// 是停住，不是跳到底部。最后一行不满时，从上一行按 ↓ 落到末尾一张。
    func stepRow(up: Bool) {
        guard cycling, snapshot.count > 1 else { return }
        let cols = overlay.gridRowStride
        guard cols > 0 else { return }

        let lastRowStart = (snapshot.count - 1) / cols * cols
        if up {
            guard cursor >= cols else { return }
            cursor -= cols
        } else {
            guard cursor < lastRowStart else { return }
            cursor = min(cursor + cols, snapshot.count - 1)
        }

        overlay.model.setCursor(cursor, source: .keyboard)
        overlay.requestShow()
        armWatchdog()

        log("⌃\(up ? "↑" : "↓")  [\(cursor)/\(snapshot.count - 1)] → \(snapshot[cursor].title.prefix(50))")
    }

    func commit() {
        disarmWatchdog()
        guard cycling else { return }
        cycling = false
        overlay.hide()

        defer { cursor = 0; snapshot = []; closedTabThisRound = false }

        // 关过标签的话 cursor == 0 也要提交（见 closedTabThisRound 的说明）
        guard snapshot.indices.contains(cursor), cursor != 0 || closedTabThisRound else {
            log("⌃ released: cursor back at origin, no switch")
            return
        }

        let target = snapshot[cursor]
        log("⌃ released → switching to: \(target.title.prefix(50)) (tabId \(target.id))")
        sendToActive(["type": "switch", "tabId": target.id])
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
        guard let tab = tabs.first else { return nil }
        let browser = activeBrowser
        let mine = settings.favorites.filter { $0.browser == browser }
        if mine.contains(where: { favoriteTabBindings[$0.id] == tab.id }) { return true }
        guard let host = URL(string: tab.url)?.host else { return nil }
        return mine.contains { fav in
            URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                || URL(string: fav.url)?.host == host
        }
    }

    /// 收藏被移除后撤销对应域名的置顶。取消收藏 = 恢复普通标签。
    /// unpin 只发给该收藏归属浏览器的连接 —— 发错浏览器会把人家
    /// 同域名的置顶也撤了。域名按「最后访问」取（可能已漂移）。
    func unpinRemovedFavorites(_ removed: [FavoriteTab]) {
        for fav in removed {
            favoriteTabBindings.removeValue(forKey: fav.id)
            guard let host = URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host
                    ?? URL(string: fav.url)?.host else { continue }
            guard let clientID = clients.first(where: { effectiveBrowser(of: $0.key) == fav.browser })?.key else {
                log("☆ unpin skipped (\(fav.browser) 未连接): \(host)")
                continue
            }
            log("☆ unpin \(host) [\(fav.browser)]")
            server.send(["type": "unpin", "hosts": [host]], to: clientID)
        }
    }

    /// 收藏 / 取消收藏当前标签（活动浏览器的账本）。
    func toggleFavoriteCurrentTab() {
        guard let current = tabs.first else { return }
        let browser = activeBrowser
        let mine = settings.favorites.filter { $0.browser == browser }

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
                                  favIconUrl: current.favIconUrl, browser: browser)
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
        guard let client = clients[clientID] else { return }
        let browser = effectiveBrowser(of: clientID)
        for (favId, tabId) in favoriteTabBindings {
            guard let fav = settings.favorites.first(where: { $0.id == favId }),
                  fav.browser == browser else { continue }
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

    /// 状态栏菜单里的一个浏览器条目：名称 + 它的全部标签（MRU 顺序）。
    struct MenuBrowser {
        let bundleID: String
        let name: String
        let entries: [(tab: TabInfo, icon: NSImage?)]
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
            return MenuBrowser(
                bundleID: bundleID,
                name: BrowserSupport.displayName(bundleID),
                entries: client.tabs.map { ($0, icons.image(for: $0.favIconUrl)?.image) })
        }
    }

    /// 状态栏子菜单点选：激活对应浏览器并切到该标签。
    ///
    /// 和 ⌃⇥ 的 commit 不同，走到这里时浏览器多半不在前台：扩展的
    /// windows.update(focused:) 只管浏览器自己窗口之间的焦点，跨 App 的
    /// 激活必须由 helper 在 macOS 层面做。命令点对点发给该浏览器的连接。
    func activateFromMenu(tabId: Int, browser bundleID: String) {
        guard let clientID = clients.first(where: { effectiveBrowser(of: $0.key) == bundleID })?.key,
              let target = clients[clientID]?.tabs.first(where: { $0.id == tabId }) else { return }
        _ = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate(options: [])
        log("📎 menu pick → \(target.title.prefix(50)) [\(bundleID)]")
        server.send(["type": "switch", "tabId": tabId], to: clientID)
    }

    private func refreshOverlayImages() {
        var iconMap: [Int: IconInfo] = [:]
        var thumbMap: [Int: NSImage] = [:]
        for tab in overlay.model.tabs {
            if let info = icons.image(for: tab.favIconUrl) { iconMap[tab.id] = info }
            if let thumb = thumbnails.image(for: tab.url) { thumbMap[tab.id] = thumb }
        }
        overlay.model.icons = iconMap
        overlay.model.thumbs = thumbMap
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
