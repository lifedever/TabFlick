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
    private let overlay = OverlayPanel()
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

    init(server: WebSocketServer) {
        self.server = server
        thumbnails.warmUp()   // 磁盘上的图先读进来，第一次按 ⌃⇥ 就有画面
        overlay.model.onPick = { [weak self] index in
            self?.pick(index)
        }
    }

    /// 鼠标点选某张卡片：把游标直接定位过去并立即提交。
    private func pick(_ index: Int) {
        guard cycling, snapshot.indices.contains(index) else { return }
        cursor = index
        // tap 侧的 cycling 也要清，否则用户松开 Ctrl 时会再 commit 一次
        resetEventTapCycling()
        log("🖱 clicked [\(index)] → \(snapshot[index].title.prefix(50))")
        commit()
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

    func commit() {
        disarmWatchdog()
        guard cycling else { return }
        cycling = false
        overlay.hide()

        defer { cursor = 0; snapshot = [] }

        guard cursor != 0, snapshot.indices.contains(cursor) else {
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
