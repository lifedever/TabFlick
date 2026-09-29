import AppKit

/// 一个已安装的 App（搜索面板「应用」模式的一行）。
struct AppEntry: Identifiable, Equatable {
    /// Finder 里显示的名字（跟系统语言本地化）。
    let name: String
    /// Info.plist 里的原始名（多半是英文），和 name 不同时进索引：打 wechat 和 微信 都要能命中。
    let alternateName: String?
    let path: String
    let bundleID: String?
    /// 上次打开的时间（Spotlight 记的 `kMDItemLastUsedDate`），排序用；Spotlight 关了就是 nil。
    var lastUsed: Date? = nil
    /// 你在访达「简介 → 注释」里写的字（Spotlight 的 `kMDItemFinderComment`）。名字古怪的 App
    /// 靠它起个好认的名字，搜索和显示名同等对待（用户 2026-09-28 要的）。
    var comment: String? = nil

    var id: String { path }
    /// 最近切到时间的记账 key：有 bundle id 用它，没有用路径。
    var usageKey: String { bundleID ?? path }
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
    /// 本次运行里每个 App 最近一次被切到前台的时间（key 见 `AppEntry.usageKey`）。
    /// Spotlight 的 lastUsed 只在启动 App 时更新，来回切换不算，这份补上「刚刚在用」。
    private var activatedAt: [String: Date] = [:]
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let key = app.bundleIdentifier ?? app.bundleURL?.standardizedFileURL.path else { return }
            MainActor.assumeIsolated { self?.activatedAt[key] = Date() }
        }
    }

    /// 这次运行里最近一次切到前台的时间（key 见 `AppEntry.usageKey`）。
    func lastActivated(_ key: String) -> Date? { activatedAt[key] }

    /// 扫描目录里的那一条（带访达注释、英文原名）；装在别处的没有。
    func entry(atPath path: String) -> AppEntry? { entries.first { $0.path == path } }

    /// 面板里的默认顺序（2026-09-27 用户定的）：运行中的在前，两组里都按最近用过排
    ///（最近切到前台和 Spotlight 记的上次打开，取新的那个），都没有记录的按名字。
    /// 有输入时 `TabSearch.rank` 先按匹配度、同分保持这里的顺序（它的排序是稳定的）。
    /// TabFlick 自己不算运行中：它永远在跑，排第一没意义。
    var ordered: [AppEntry] {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let own = Bundle.main.bundleIdentifier
        let keyed = entries.map { entry -> (entry: AppEntry, running: Bool, used: Date?) in
            let isRunning = entry.bundleID.map { $0 != own && runningIDs.contains($0) }
                ?? runningPaths.contains(entry.path)
            let used = [activatedAt[entry.usageKey], entry.lastUsed].compactMap { $0 }.max()
            return (entry, isRunning, used)
        }
        return keyed.sorted { a, b in
            if a.running != b.running { return a.running }
            switch (a.used, b.used) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.entry.name.localizedStandardCompare(b.entry.name) == .orderedAscending
            }
        }.map(\.entry)
    }

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
                let meta = metadata(of: url)
                result.append(AppEntry(name: name,
                                       alternateName: raw == name ? nil : raw,
                                       path: path,
                                       bundleID: bundle?.bundleIdentifier,
                                       lastUsed: meta.lastUsed,
                                       comment: meta.comment))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Spotlight 记的上次打开时间。一个 App 一次元数据读取，后台线程上跑，百来个 App 几十毫秒。
    /// Spotlight 记的上次打开时间和访达注释：同一个元数据对象取两样，后台线程上跑。
    private nonisolated static func metadata(of url: URL) -> (lastUsed: Date?, comment: String?) {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return (nil, nil) }
        let comment = (MDItemCopyAttribute(item, kMDItemFinderComment) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                comment?.isEmpty == false ? comment : nil)
    }
}
