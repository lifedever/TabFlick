import AppKit
import UniformTypeIdentifiers

/// 搜索面板 ⌘↩ 里「用 X 打开」的一个浏览器：网页类的行（标签、最近关闭、书签、历史）
/// 换个浏览器打开（2026-10-17 加）。
struct WebOpener: Equatable {
    let name: String
    let url: URL
    let bundleID: String
    var path: String { url.path }
}

/// 能拿来打开网页的 App。
///
/// 判据是**同时**登记了 http(s) 链接和 HTML 文档：光按 http(s) 枚举会混进只是接管链接的
/// 下载器（Free Download Manager）、虚拟机（Parallels），光按 HTML 会混进编辑器和 Office，
/// 两个都登记的才是浏览器（本机实测）。再滤掉 `~/Library` 下的副本（Playwright 缓存的
/// Chromium、夸克自更新留的那份）和装在别的 App 包里的。
///
/// 第一次问 Launch Services 要近 100ms，所以打开搜索面板时在后台扫、一分钟内不重扫，
/// ⌘↩ 只读 `current`。
@MainActor
enum WebOpeners {
    /// 按最近用过排好的候选（点过的在前，没点过的保持 Launch Services 的顺序）。
    private(set) static var current: [WebOpener] = []
    private static var scanned: [WebOpener] = []
    private static var scannedAt: Date?
    private static var scanning = false
    /// 各浏览器最近一次被拿来「用 X 打开」的时刻（bundle id → 秒）。纯排序数据，丢了无所谓。
    private static let lastUsedKey = "webOpenerLastUsed"

    static func refreshIfStale() {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < 60 { return }
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = scan()
            Task { @MainActor in
                scanned = found
                scannedAt = Date()
                scanning = false
                reorder()
            }
        }
    }

    /// 记一次「用它打开」，列表跟着重排。
    static func touch(_ opener: WebOpener) {
        var lastUsed = UserDefaults.standard.dictionary(forKey: lastUsedKey) as? [String: Double] ?? [:]
        lastUsed[opener.bundleID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastUsed, forKey: lastUsedKey)
        reorder()
    }

    private static func reorder() {
        let lastUsed = UserDefaults.standard.dictionary(forKey: lastUsedKey) as? [String: Double] ?? [:]
        current = ordered(scanned.map(\.bundleID), lastUsed: lastUsed).map { scanned[$0] }
    }

    private nonisolated static func scan() -> [WebOpener] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: UTType.html)
            .map(\.standardizedFileURL.path))
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .map { (path: $0.standardizedFileURL.path, bundleID: Bundle(url: $0)?.bundleIdentifier) }
        return select(apps, html: html, excluding: Bundle.main.bundleIdentifier).map { app in
            // 显示名剥 `.app`：访达开了「显示所有文件扩展名」时 displayName 会带着它
            var name = FileManager.default.displayName(atPath: app.path)
            if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
            return WebOpener(name: name, url: URL(fileURLWithPath: app.path, isDirectory: true), bundleID: app.bundleID)
        }
    }

    /// Launch Services 的 http(s) 处理程序 → 能列出来的浏览器（纯函数，`checks/web-openers-check.swift`）。
    /// 同一个 bundle id 装了几份只留第一份（Launch Services 把正经装的排在前面）。
    nonisolated static func select(_ apps: [(path: String, bundleID: String?)], html: Set<String>,
                                   excluding selfID: String?) -> [(path: String, bundleID: String)] {
        var seen = Set<String>()
        var result: [(path: String, bundleID: String)] = []
        for app in apps {
            guard let id = app.bundleID, id != selfID, html.contains(app.path),
                  !app.path.contains("/Library/"),
                  !(app.path as NSString).deletingLastPathComponent.contains(".app"),
                  seen.insert(id).inserted else { continue }
            result.append((app.path, id))
        }
        return result
    }

    /// 点过的按最近点击降序在前，没点过的保持原顺序（返回下标）。
    nonisolated static func ordered(_ ids: [String], lastUsed: [String: Double]) -> [Int] {
        ids.indices.sorted { a, b in
            let x = lastUsed[ids[a]] ?? 0, y = lastUsed[ids[b]] ?? 0
            return x != y ? x > y : a < b
        }
    }
}
