import AppKit
import CoreImage
import Foundation

struct TabInfo: Decodable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let favIconUrl: String
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

    /// 扩展推来的实时 MRU 顺序，最近使用的在前。index 0 就是当前标签页。
    private var tabs: [TabInfo] = []

    /// 本轮 cycling 的快照，与 `tabs` 隔离。
    private var snapshot: [TabInfo] = []
    private var cursor = 0
    private var cycling = false

    /// 本轮 cycling 中是否用 ✕ 关过标签。关过的话，松开 Ctrl 时即使游标
    /// 停在 0 也要提交切换 —— 原来的「起点」标签可能已经被关掉了，
    /// Chrome 自动激活的是相邻标签而不是 MRU 上一个，不显式切一下的话
    /// 落点会和面板高亮对不上。切到本来就活跃的标签是无害的幂等操作。
    private var closedTabThisRound = false

    private var connected = false
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

    /// 连接状态或标签数变化，供菜单栏更新显示。
    var onStatusChange: ((Bool, Int) -> Void)?

    /// 需要向扩展补推一份设置。
    var onNeedSettingsPush: (() -> Void)?

    private func publishStatus() {
        onStatusChange?(connected, tabs.count)
    }

    /// 扩展请求打开 app 的设置窗口（点了浏览器工具栏图标）。
    var onExtensionRequestedSettings: (() -> Void)?

    /// 把当前设置推给扩展。扩展不持久化配置，只执行 —— 事实源在 app。
    func pushSettings(_ payload: [String: Any]) {
        server.broadcast(payload)
    }

    /// 数据没就绪时让 event tap 放行 Ctrl+Tab，降级到 Chrome 的原生切换。
    private func updateReadiness() {
        setEventTapReady(connected && tabs.count > 1)
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
        server.broadcast(["type": "close", "tabId": target.id])
        closedTabThisRound = true

        snapshot.remove(at: index)
        // 本地同步剔除，不等扩展的 onRemoved 推送 —— 窗口期里如果开始
        // 新一轮 cycling，快照里不该出现已关掉的标签。
        tabs.removeAll { $0.id == target.id }
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

    func handleMessage(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
        case "mru":
            guard let raw = root["tabs"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([TabInfo].self, from: payload) else { return }
            tabs = decoded
            icons.prefetch(decoded.map(\.favIconUrl)) { [weak self] in
                self?.refreshOverlayImages()
            }
            updateReadiness()
            publishStatus()
            if !cycling {
                log("MRU updated: \(tabs.count) tabs, current: \(tabs.first?.title.prefix(40) ?? "?")")
            }

        case "thumb":
            guard let url = root["url"] as? String, !url.isEmpty,
                  let base64 = root["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            thumbnails.store(data, for: url)
            refreshOverlayImages()

        case "requestSettings":
            // 扩展（重）连上了，向我们要一份当前配置
            onNeedSettingsPush?()

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

    func handleClientCountChange(_ count: Int) {
        connected = count > 0
        if connected {
            log("✅ Extension connected (\(count) client(s))")
            startPinging()
        } else {
            log("⚠️  Extension disconnected — ⌃⇥ now falls through to Chrome")
            stopPinging()
            tabs = []
            cycling = false
            overlay.hide()
        }
        updateReadiness()
        publishStatus()
    }

    // MARK: - 来自 EventTap

    func step(backward: Bool) {
        if !cycling {
            cycling = true
            snapshot = tabs
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
        server.broadcast(["type": "switch", "tabId": target.id])
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
