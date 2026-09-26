import AppKit
import CryptoKit
import Foundation

/// 网页缩略图的两级缓存：内存 + 磁盘。
///
/// 为什么必须持久化：`captureVisibleTab` 只能截「当前可见」的标签，后台标签
/// 拿不到。所以图是用户正常浏览时一张张攒出来的 —— 只存内存的话，helper
/// 一重启就全没了，切换器会退化成一排空卡片，得再把每个标签都点一遍才恢复。
///
/// 为什么按 URL 而不是 tabId 建索引：tabId 在浏览器重启后全部重新分配，
/// 而 URL 是稳定的。按 URL 存还有个额外好处 —— 同一个页面换个标签重新打开，
/// 缩略图立刻就在。
@MainActor
final class ThumbnailStore {

    private let directory: URL
    /// 内存里只留最近用过的这几十张。`NSImage` 画过一次就会把解码后的位图留在
    /// 身上（900 宽的图一张约 2MB），之前启动时把 400 张全读进来、切换器每画一张
    /// 就多留一张位图，footprint 一路涨到 180MB（2026-09-26 量的）。磁盘才是
    /// 事实源，缺的按需读（一张 1ms 上下）。
    private var memory: [String: NSImage] = [:]
    private var order: [String] = []
    private let maxInMemory = 64
    /// 磁盘上有哪些（启动时只读文件名，不解码）。
    private var onDisk: Set<String> = []

    /// 磁盘上保留的最大张数。单张 400×250 的 JPEG 约 20–40 KB，
    /// 500 张也就十几 MB，但没必要无限涨。
    private let maxEntries = 500

    init() {
        directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TabFlick/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 读写

    func image(for url: String) -> NSImage? {
        let key = Self.key(for: url)
        if let cached = memory[key] { touch(key); return cached }
        guard onDisk.contains(key) else { return nil }

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: file),
              let image = NSImage(data: data) else { return nil }
        remember(key, image)
        return image
    }

    func store(_ data: Data, for url: String) {
        guard let image = NSImage(data: data) else { return }
        let key = Self.key(for: url)
        remember(key, image)
        onDisk.insert(key)

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        try? data.write(to: file, options: .atomic)
    }

    /// 启动时只登记磁盘上有哪些图（不解码），顺便清掉超出上限的。
    func warmUp() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        onDisk = Set(files.filter { $0.pathExtension == "jpg" }
                          .map { $0.deletingPathExtension().lastPathComponent })
        if !onDisk.isEmpty {
            log("🖼  \(onDisk.count) cached thumbnails on disk")
        }
        prune(files: files)
    }

    private func remember(_ key: String, _ image: NSImage) {
        memory[key] = image
        touch(key)
        while order.count > maxInMemory, let oldest = order.first {
            order.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    /// 超出上限时删掉最久没更新的那些。
    private func prune(files: [URL]) {
        guard files.count > maxEntries else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for file in sorted.dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: file)
            let key = file.deletingPathExtension().lastPathComponent
            memory.removeValue(forKey: key)
            onDisk.remove(key)
            order.removeAll { $0 == key }
        }
    }

    // MARK: - 键

    /// URL 不能直接当文件名（长度、斜杠、大小写敏感性都有坑），取哈希。
    private static func key(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
