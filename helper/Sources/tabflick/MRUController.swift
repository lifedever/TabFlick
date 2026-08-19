import AppKit
import Foundation

struct TabInfo: Decodable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let favIconUrl: String
}

/// favicon 的内存缓存。key 用 favIconUrl 本身，同站多个标签页天然复用。
@MainActor
final class IconCache {
    private var images: [String: NSImage] = [:]
    private var inflight: Set<String> = []

    func image(for url: String) -> NSImage? { images[url] }

    func prefetch(_ urls: [String], onLoaded: @escaping () -> Void) {
        for url in urls where !url.isEmpty && images[url] == nil && !inflight.contains(url) {
            guard let parsed = URL(string: url) else { continue }
            inflight.insert(url)
            URLSession.shared.dataTask(with: parsed) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                Task { @MainActor in
                    self.inflight.remove(url)
                    guard let image else { return }   // 拿不到就让视图走 globe 占位
                    self.images[url] = image
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

    /// 扩展推来的网页缩略图，按 tabId 存。
    ///
    /// 缓存放在 helper 而不是扩展侧：MV3 的 service worker 随时会被回收，
    /// 而 helper 进程一直活着，重启浏览器扩展也不会丢图。
    private var thumbs: [Int: NSImage] = [:]

    /// 扩展推来的实时 MRU 顺序，最近使用的在前。index 0 就是当前标签页。
    private var tabs: [TabInfo] = []

    /// 本轮 cycling 的快照，与 `tabs` 隔离。
    private var snapshot: [TabInfo] = []
    private var cursor = 0
    private var cycling = false

    private var connected = false
    private var pingTimer: Timer?

    /// 数据没就绪时让 event tap 放行 Ctrl+Tab，降级到 Chrome 的原生切换。
    private func updateReadiness() {
        setEventTapReady(connected && tabs.count > 1)
    }

    init(server: WebSocketServer) {
        self.server = server
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
            // 标签页关掉后对应的缩略图就没用了，顺手回收，别让缓存无限涨
            let alive = Set(decoded.map(\.id))
            thumbs = thumbs.filter { alive.contains($0.key) }

            icons.prefetch(decoded.map(\.favIconUrl)) { [weak self] in
                self?.refreshOverlayImages()
            }
            updateReadiness()
            if !cycling {
                log("MRU updated: \(tabs.count) tabs, current: \(tabs.first?.title.prefix(40) ?? "?")")
            }

        case "thumb":
            guard let tabId = root["tabId"] as? Int,
                  let base64 = root["data"] as? String,
                  let data = Data(base64Encoded: base64),
                  let image = NSImage(data: data) else { return }
            thumbs[tabId] = image
            refreshOverlayImages()

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

        log("⌃\(backward ? "⇧" : "")⇥  [\(cursor)/\(snapshot.count - 1)] → \(snapshot[cursor].title.prefix(50))")
    }

    func commit() {
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
        var iconMap: [Int: NSImage] = [:]
        var thumbMap: [Int: NSImage] = [:]
        for tab in overlay.model.tabs {
            if let image = icons.image(for: tab.favIconUrl) { iconMap[tab.id] = image }
            if let thumb = thumbs[tab.id] { thumbMap[tab.id] = thumb }
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
