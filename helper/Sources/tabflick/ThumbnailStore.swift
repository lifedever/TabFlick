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
    private var memory: [String: NSImage] = [:]

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
        if let cached = memory[key] { return cached }

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: file),
              let image = NSImage(data: data) else { return nil }
        memory[key] = image
        return image
    }

    func store(_ data: Data, for url: String) {
        guard let image = NSImage(data: data) else { return }
        let key = Self.key(for: url)
        memory[key] = image

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        try? data.write(to: file, options: .atomic)
    }

    /// 启动时把已有的图读进内存，这样第一次按 ⌃⇥ 就有画面。
    func warmUp() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for file in files where file.pathExtension == "jpg" {
            guard let data = try? Data(contentsOf: file),
                  let image = NSImage(data: data) else { continue }
            memory[file.deletingPathExtension().lastPathComponent] = image
        }
        if !memory.isEmpty {
            log("🖼  loaded \(memory.count) cached thumbnails from disk")
        }
        prune(files: files)
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
            memory.removeValue(forKey: file.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - 键

    /// URL 不能直接当文件名（长度、斜杠、大小写敏感性都有坑），取哈希。
    private static func key(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
