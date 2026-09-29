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
    /// 菜单栏小工具这类没有 Dock 图标的（Info.plist 里 `LSUIElement` / `LSBackgroundOnly`）。
    /// 「最近使用」不列它们：Spotlight 的「上次打开」会把刚退出的小工具带进来。
    var isAgent = false

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
    /// 每个 App 最近一次被切到前台的时间（key 见 `AppEntry.usageKey`）。
    /// Spotlight 的 lastUsed 只在启动 App 时更新，来回切换不算，这份补上「刚刚在用」。
    /// 普通 App 的存盘（`AppActivity`），重启后读回来；其余的只在内存里。
    private var activatedAt: [String: Date] = [:]
    /// 每个 App 最近一次从前台切走的时间（key 同上）：「最近使用」行尾的「x 前」是离开多久了，
    /// 不是切到它多久了（10:00 切进微信聊到 10:29，10:30 看列表该写 1 分钟前，不是 30 分钟前）。
    private var deactivatedAt: [String: Date] = [:]
    /// 最近一周切到过前台的普通 App（key 同上）：退出之后「最近使用」还要列它，得记住它在哪、叫什么。
    /// 装在扫描目录以外的 App 只能靠这份。
    private var seen: [String: AppEntry] = [:]
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private let activityFile: URL?
    private var saveTimer: Timer?
    private var clearObserver: NSObjectProtocol?
    /// 写盘排队：两次写各自丢到并发队列的话，慢的那次可能后落地、把新数据盖回旧的。
    private static let writeQueue = DispatchQueue(label: "TabFlick.app-activity", qos: .utility)

    init(activityFile: URL? = AppCatalog.defaultActivityFile) {
        self.activityFile = activityFile
        let now = Date().timeIntervalSince1970
        for record in AppActivity.decode(activityFile.flatMap { try? Data(contentsOf: $0) }, now: now) {
            activatedAt[record.key] = Date(timeIntervalSince1970: record.at)
            if let left = record.left { deactivatedAt[record.key] = Date(timeIntervalSince1970: left) }
            seen[record.key] = AppEntry(name: record.name, alternateName: nil, path: record.path,
                                        bundleID: record.bundleID)
        }
        let own = Bundle.main.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let key = app.bundleIdentifier ?? app.bundleURL?.standardizedFileURL.path else { return }
            let now = Date()
            // 普通 App 才记下来（菜单栏小工具弹个窗也会切到前台）；TabFlick 自己开设置窗口时也是普通 App，不算
            let entry = app.activationPolicy == .regular && app.bundleIdentifier != own ? app.bundleURL.map { url in
                AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                         alternateName: nil, path: url.standardizedFileURL.path, bundleID: app.bundleIdentifier)
            } : nil
            MainActor.assumeIsolated {
                self?.activatedAt[key] = now
                if let entry {
                    self?.seen[key] = entry
                    self?.scheduleSave()
                }
            }
        }
        observeDeactivation()
        // 设置 → 搜索面板 →「搜索记忆」的清除：切换记录也是使用记录，一起清
        clearObserver = NotificationCenter.default.addObserver(forName: .clearUsageHistory, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.clearActivity() }
        }
    }

    private func clearActivity() {
        saveTimer?.invalidate()
        activatedAt = [:]
        deactivatedAt = [:]
        seen = [:]
        guard let file = activityFile else { return }
        Self.writeQueue.async { try? FileManager.default.removeItem(at: file) }
        log("🧹 app activity cleared")
    }

    /// 存下来的切换记录有几条（设置页判断「清除」能不能点；读一下小文件，只在打开那一页时调）。
    nonisolated static func storedActivityCount() -> Int {
        AppActivity.decode(try? Data(contentsOf: defaultActivityFile), now: Date().timeIntervalSince1970).count
    }

    /// 切走只记普通 App 的，和切到前台那份存在一起。
    private func observeDeactivation() {
        let own = Bundle.main.bundleIdentifier
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, app.bundleIdentifier != own,
                  let key = app.bundleIdentifier ?? app.bundleURL?.standardizedFileURL.path else { return }
            let now = Date()
            MainActor.assumeIsolated {
                self?.deactivatedAt[key] = now
                self?.scheduleSave()
            }
        }
    }

    nonisolated static var defaultActivityFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-activity.json")
    }

    /// 合并 2 秒再写（来回切 App 时不必每次都写）；写在后台线程，不碰主线程。
    private func scheduleSave() {
        guard let file = activityFile else { return }
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let records = self.seen.compactMap { key, entry -> AppActivity.Record? in
                    guard let at = self.activatedAt[key] else { return nil }
                    return AppActivity.Record(key: key, at: at.timeIntervalSince1970, path: entry.path,
                                              name: entry.name, bundleID: entry.bundleID,
                                              left: self.deactivatedAt[key]?.timeIntervalSince1970)
                }
                let kept = AppActivity.pruned(records, now: Date().timeIntervalSince1970)
                // 过期的顺手从内存里也清掉，免得常开几个月越攒越多
                let keys = Set(kept.map(\.key))
                self.seen = self.seen.filter { keys.contains($0.key) }
                guard let data = try? JSONEncoder().encode(kept) else { return }
                Self.writeQueue.async { try? data.write(to: file, options: .atomic) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// 最近一次切到前台的时间（key 见 `AppEntry.usageKey`；普通 App 重启后也在）。
    func lastActivated(_ key: String) -> Date? { activatedAt[key] }
    /// 最近一次从前台切走的时间（只有普通 App）。
    func lastDeactivated(_ key: String) -> Date? { deactivatedAt[key] }

    /// 扫描目录里的那一条（带访达注释、英文原名）；装在别处的没有。
    func entry(atPath path: String) -> AppEntry? { entries.first { $0.path == path } }

    /// `since` 之后用过的 App（不管还在不在运行）：切到过前台的普通 App（存盘的，重启不丢），加上
    /// Spotlight 记的上次打开在这之后的（装上 TabFlick 之前开过的只能靠它）。按路径去重，清单里有的用清单那份。
    func used(since: Date) -> [AppEntry] {
        var result: [String: AppEntry] = [:]
        // 这期间删掉的 App 不列（回车打不开）；清单里的一分钟内扫过，不用再查
        // 切进、切走取新的：切进去连用了一天多再退出的，也算这段时间里用过
        for (key, entry) in seen
        where max(activatedAt[key] ?? .distantPast, deactivatedAt[key] ?? .distantPast) >= since {
            if let listed = self.entry(atPath: entry.path) {
                result[entry.path] = listed
            } else if FileManager.default.fileExists(atPath: entry.path) {
                result[entry.path] = entry
            }
        }
        for entry in entries where !entry.isAgent && (entry.lastUsed ?? .distantPast) >= since {
            result[entry.path] = entry
        }
        return Array(result.values)
    }

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
                let info = bundle?.infoDictionary ?? [:]
                result.append(AppEntry(name: name,
                                       alternateName: raw == name ? nil : raw,
                                       path: path,
                                       bundleID: bundle?.bundleIdentifier,
                                       lastUsed: meta.lastUsed,
                                       comment: meta.comment,
                                       isAgent: Self.flag(info["LSUIElement"]) || Self.flag(info["LSBackgroundOnly"])))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Info.plist 里的布尔值有写成 true、1、"1"、"YES" 的。
    private nonisolated static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return ["1", "yes", "true"].contains(string.lowercased()) }
        return false
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

extension Notification.Name {
    /// 设置里清除搜索记忆时一起清掉 App 切换记录。
    static let clearUsageHistory = Notification.Name("TabFlickClearUsageHistory")
}
