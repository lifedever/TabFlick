import AppKit

/// 一个已安装的 App（搜索面板「应用」模式的一行）。
struct AppEntry: Identifiable, Equatable {
    /// Finder 里显示的名字（跟系统语言本地化）。
    let name: String
    /// Info.plist 里的原始名（多半是英文），和 name 不同时进索引：打 wechat 和 微信 都要能命中。
    let alternateName: String?
    let path: String
    let bundleID: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// 正在运行（按 bundle id 查，没有 bundle id 的按路径）。
    var isRunning: Bool {
        if let bundleID {
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }
}

/// 已安装 App 的清单：扫几个固定目录，一层深（Utilities 单独算一个目录）。
///
/// 不走 Spotlight：`NSMetadataQuery` 要起一次索引查询、回调异步、Spotlight 关掉就
/// 没结果；几个目录 `contentsOfDirectory` 一共几十毫秒，放后台线程扫，够用。
/// 清单每分钟最多重扫一次（进「应用」模式时触发），新装的 App 一分钟内出现。
@MainActor
final class AppCatalog {
    private(set) var entries: [AppEntry] = []
    private var scannedAt: Date?
    private var scanning = false

    private nonisolated static let directories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
    }()

    /// 清单过期（或从没扫过）就重扫，扫完回调；没过期直接回调。
    func refreshIfStale(completion: @escaping () -> Void) {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < 60 { completion(); return }
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            Task { @MainActor in
                self.entries = found
                self.scannedAt = Date()
                self.scanning = false
                Pinyin.prewarm(found.map(\.name))
                completion()
            }
        }
    }

    private nonisolated static func scan() -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        let fm = FileManager.default
        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "app" {
                let path = url.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                var name = fm.displayName(atPath: path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                let bundle = Bundle(url: url)
                let raw = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                result.append(AppEntry(name: name,
                                       alternateName: raw == name ? nil : raw,
                                       path: path,
                                       bundleID: bundle?.bundleIdentifier))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
