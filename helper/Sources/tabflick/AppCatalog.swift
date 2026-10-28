import AppKit
import CoreServices

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
    /// Spotlight 记的打开次数（`kMDItemUseCount`，装上以来的总数）：常用度的来源之一，见 `AppRanking`。
    var useCount: Int? = nil
    /// 常用度（0–2 档），`AppCatalog.ordered` 填；有输入时同分的 App 按它排先后（`AppRanking.byPrior`）。
    var prior = 0

    var id: String { path }
    /// 最近切到时间的记账 key：有 bundle id 用它，没有用路径。
    var usageKey: String { bundleID ?? path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// 正在运行（按 bundle id 查，没有 bundle id 的按路径）。
    var isRunning: Bool {
        if let bundleID {
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        return NSWorkspace.shared.runningApplications.contains { AppPaths.installed($0) == path }
    }
}

/// 已安装 App 的清单：扫几个固定目录，一层深（Utilities 单独算一个目录）。
///
/// 不走 Spotlight：`NSMetadataQuery` 要起一次索引查询、回调异步、Spotlight 关掉就
/// 没结果；几个目录 `contentsOfDirectory` 一共几十毫秒，放后台线程扫，够用。
/// 清单每分钟最多重扫一次（打开面板时触发）；应用目录有增删时当场作废（`watchFolders`），
/// 面板开着就立刻重扫，新装的 App 不用关了再开。
@MainActor
final class AppCatalog {
    private(set) var entries: [AppEntry] = []
    private var scannedAt: Date?
    private var scanning = false
    /// 扫的途中目录又变了：那一份可能缺刚装的 App，扫完不算新鲜。
    private var changedDuringScan = false
    private var folderWatcher: AppFolderWatcher?
    private var onFoldersChanged: (() -> Void)?
    /// 每个 App 最近一次被切到前台的时间（key 见 `AppEntry.usageKey`）。
    /// Spotlight 的 lastUsed 只在启动 App 时更新，来回切换不算，这份补上「刚刚在用」。
    /// 普通 App 的存盘（`AppActivity`），重启后读回来；其余的只在内存里。
    private var activatedAt: [String: Date] = [:]
    /// 每个 App 最近一次从前台切走的时间（key 同上）：「最近使用」行尾的「x 前」是离开多久了，
    /// 不是切到它多久了（10:00 切进微信聊到 10:29，10:30 看列表该写 1 分钟前，不是 30 分钟前）。
    private var deactivatedAt: [String: Date] = [:]
    /// 常用度：每个 App 待够几秒的切到前台次数（衰减到 at 那一刻），key 同上。和切换记录存在一起。
    private var sessions: [String: (uses: Double, at: Double)] = [:]
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
            if let uses = record.uses, let usesAt = record.usesAt { sessions[record.key] = (uses, usesAt) }
            // 0.23.1 及之前记下的 iOS App 是运行时挂载里的路径（见 AppPaths），换回装的位置
            let path = record.path.contains("/Wrapper/") ? AppPaths.installed(record.path) : record.path
            seen[record.key] = AppEntry(name: record.name, alternateName: nil, path: path, bundleID: record.bundleID)
        }
        let own = Bundle.main.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let key = app.bundleIdentifier ?? AppPaths.installed(app) else { return }
            let now = Date()
            // 普通 App 才记下来（菜单栏小工具弹个窗也会切到前台）；TabFlick 自己开设置窗口时也是普通 App，不算
            let entry = app.activationPolicy == .regular && app.bundleIdentifier != own ? app.bundleURL.map { url in
                AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                         alternateName: nil, path: AppPaths.installed(url.path), bundleID: app.bundleIdentifier)
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
        sessions = [:]
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
                  let key = app.bundleIdentifier ?? AppPaths.installed(app) else { return }
            let now = Date()
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deactivatedAt[key] = now
                // 在前台待够几秒才算用了一次（⌘Tab 路过的不算）
                if let start = self.activatedAt[key],
                   let next = AppRanking.recordingSession(uses: self.sessions[key]?.uses, usesAt: self.sessions[key]?.at,
                                                          activatedAt: start.timeIntervalSince1970,
                                                          now: now.timeIntervalSince1970) {
                    self.sessions[key] = next
                }
                self.scheduleSave()
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
                                              left: self.deactivatedAt[key]?.timeIntervalSince1970,
                                              uses: self.sessions[key]?.uses, usesAt: self.sessions[key]?.at)
                }
                let kept = AppActivity.pruned(records, now: Date().timeIntervalSince1970)
                // 过期的顺手从内存里也清掉，免得常开几个月越攒越多
                let keys = Set(kept.map(\.key))
                self.seen = self.seen.filter { keys.contains($0.key) }
                self.sessions = self.sessions.filter { keys.contains($0.key) }
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

    /// 面板里的默认顺序：最近用过的在前，一样新的看常用度，都没有记录的按名字（`AppRanking.precedes`）。
    /// 有输入时 `TabSearch.rank` 先按匹配度、同分保持这里的顺序（它的排序是稳定的）。
    /// 顺手把常用度（`AppEntry.prior`）填上，有输入时同分的按它排先后。
    /// 运行中的不再整组排前面（2026-10-26 用户定的，原因见 `AppRanking.precedes`）。
    var ordered: [AppEntry] {
        let now = Date().timeIntervalSince1970
        let keyed = entries.map { entry -> (entry: AppEntry, used: Double?) in
            var entry = entry
            let session = sessions[entry.usageKey]
            entry.prior = AppRanking.prior(level: AppRanking.level(
                sessions: session?.uses, sessionsAt: session?.at,
                spotlightUses: entry.useCount, spotlightLastUsed: entry.lastUsed?.timeIntervalSince1970, now: now))
            let used = [activatedAt[entry.usageKey], entry.lastUsed].compactMap { $0 }.max()
            return (entry, used?.timeIntervalSince1970)
        }
        return keyed.sorted { a, b in
            AppRanking.precedes(usedA: a.used, priorA: a.entry.prior, nameA: a.entry.name,
                                usedB: b.used, priorB: b.entry.prior, nameB: b.entry.name)
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
                self.scanning = false
                self.folderWatcher?.updateKnown(Set(found.map(\.path)))
                Pinyin.prewarm(found.map(\.name))
                completion()
                if self.changedDuringScan {
                    self.changedDuringScan = false
                    self.onFoldersChanged?()
                } else {
                    self.scannedAt = Date()
                }
            }
        }
    }

    /// 盯着应用目录：有 App 装上、删掉、改名，清单当场作废，再调 `onChange`（要不要立刻重扫由调用方定：
    /// 面板开着才扫，关着等下次打开）。不放进 init：官网素材的样例程序也建 AppCatalog，不该盯本机目录。
    func watchFolders(onChange: @escaping () -> Void) {
        guard folderWatcher == nil else { return }
        onFoldersChanged = onChange
        let roots = Self.directories.map(\.path).filter { !$0.hasPrefix("/System/") }   // 系统卷只读
        let watcher = AppFolderWatcher(roots: roots) { [weak self] in
            MainActor.assumeIsolated { self?.foldersChanged() }
        }
        watcher.updateKnown(Set(entries.map(\.path)))
        watcher.start()
        folderWatcher = watcher
    }

    private func foldersChanged() {
        scannedAt = nil
        if scanning { changedDuringScan = true; return }   // 等这一轮扫完再说（见 refreshIfStale）
        onFoldersChanged?()
    }

    private nonisolated static func scan() -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        let fm = FileManager.default
        for dir in directories {
            // 不能用 .skipsHiddenFiles：/Applications/Safari.app 是指向 Cryptex 的符号链接，
            // 系统给它打了 hidden 标志（访达照常显示），跳过隐藏项就搜不到 Safari。只滤点开头的。
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
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
                                       isAgent: Self.flag(info["LSUIElement"]) || Self.flag(info["LSBackgroundOnly"]),
                                       useCount: meta.useCount))
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

    /// Spotlight 记的上次打开时间、打开次数和访达注释：一个 App 一次元数据读取、取三样，
    /// 后台线程上跑，百来个 App 几十毫秒。
    private nonisolated static func metadata(of url: URL) -> (lastUsed: Date?, comment: String?, useCount: Int?) {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return (nil, nil, nil) }
        let comment = (MDItemCopyAttribute(item, kMDItemFinderComment) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 键名没进 Swift 的常量表，字面量照写（mdls 里叫这个）
        let useCount = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
        return (MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                comment?.isEmpty == false ? comment : nil, useCount)
    }
}

/// 应用目录的 FSEvents 监视（递归，只到目录一级的粒度）。只认两种事件：目录本身的条目变了
/// （装上、删掉、改名），或者往一个清单里还没有的 `.app` 里写东西（拷贝 / 安装进行中）。
/// 已有 App 自己更新时往包里写的一大串事件全滤掉。写完安静 1 秒才报：包拷到一半就去扫，
/// 读到的是没有 Info.plist、没有图标的半成品。
final class AppFolderWatcher {
    private let roots: [String]
    private let onChange: () -> Void
    /// 回调和下面两项只在这条队列上碰。
    private let queue = DispatchQueue(label: "TabFlick.app-folders", qos: .utility)
    private var known: Set<String> = []
    private var pending: DispatchWorkItem?
    private var stream: FSEventStreamRef?

    /// roots：扫描的那几个目录（标准化路径）；`onChange` 在主线程调。
    init(roots: [String], onChange: @escaping () -> Void) {
        self.roots = roots.map(Self.normalized)
        self.onChange = onChange
    }

    func start() {
        // 子目录（Utilities）跟着父目录递归就有，只登记最外层且存在的
        let watched = roots.filter { root in
            FileManager.default.fileExists(atPath: root)
                && !roots.contains { $0 != root && root.hasPrefix($0 + "/") }
        }
        guard stream == nil, !watched.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, appFolderEvents, &context,
                                                watched as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else {
            log("⚠️  app folder watch failed to start")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    /// 扫完一轮后告诉它现在有哪些 App（往这些包里写的事件不算新装）。
    func updateKnown(_ paths: Set<String>) {
        queue.async { self.known = paths }
    }

    fileprivate func handle(_ paths: [String]) {
        guard paths.contains(where: { Self.isRelevant($0, roots: roots, known: known) }) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in DispatchQueue.main.async(execute: onChange) }
        pending = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    /// 这条事件路径要不要管（纯函数，`checks/app-folder-watch-check.swift`）。
    /// 先比长的根：`/Applications/Utilities` 下的事件要按它算，不按 `/Applications`。
    nonisolated static func isRelevant(_ path: String, roots: [String], known: Set<String>) -> Bool {
        let path = normalized(path)
        for root in roots.sorted(by: { $0.count > $1.count }) {
            if path == root { return true }
            guard path.hasPrefix(root + "/") else { continue }
            let top = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard top.hasSuffix(".app") else { return false }   // 目录里的杂物、装在子文件夹里的（不扫一层以下）
            return !known.contains(root + "/" + top)
        }
        return false
    }

    /// 去掉尾斜杠（FSEvents 报的目录带一个），数据卷前缀也剥掉，以防按 `/System/Volumes/Data/…` 报。
    nonisolated static func normalized(_ path: String) -> String {
        var path = path
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// FSEvents 的 C 回调：文件级函数，不捕获任何东西（同 event tap 那条约束）。
private func appFolderEvents(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                             _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                             _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<AppFolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    watcher.handle(list)
}

extension Notification.Name {
    /// 设置里清除搜索记忆时一起清掉 App 切换记录。
    static let clearUsageHistory = Notification.Name("TabFlickClearUsageHistory")
}
