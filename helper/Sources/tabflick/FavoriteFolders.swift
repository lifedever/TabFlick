import AppKit
import Combine
import Foundation

/// 一条收藏的文件夹。
struct FavoriteFolder: Codable, Equatable {
    /// 标准化后的绝对路径（见 `FavoriteFolderStore.normalized`）。
    let path: String
    /// 收藏时刻（ms epoch，口径同 `ClosedTab.closedAt`）。
    let addedAt: Double
    /// 最近一次从菜单打开的时刻（ms epoch）。首版存档没有这个字段 →
    /// 解码成 nil，排序退回 addedAt，升级无缝。
    let openedAt: Double?

    init(path: String, addedAt: Double, openedAt: Double? = nil) {
        self.path = path
        self.addedAt = addedAt
        self.openedAt = openedAt
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// 菜单里的名字：目录名本身。
    var name: String { url.lastPathComponent }
    /// 排序键：打开过按打开时间，没打开过按收藏时间 —— 刚收藏的东西
    /// 就是正在忙的东西，理应先占平铺区。
    var lastUsedAt: Double { openedAt ?? addedAt }
}

/// 收藏的文件夹（状态栏「收藏的文件夹」一节的数据源）。
///
/// 和 ClosedTabStore 同一个目录、同一套「整份 JSON 原子重写」：条目最多
/// 几十个，一次全量写换来绝不会出现半截记录。
@MainActor
final class FavoriteFolderStore: ObservableObject {

    /// 存储顺序 = 收藏顺序（先收藏的在前）。菜单展示时再按 `byRecency` 排。
    /// @Published：设置窗口的「文件夹」页直接观察它，删一条立刻消失。
    @Published private(set) var entries: [FavoriteFolder] = []

    /// 「打开方式」各 App 的最近点击时刻（key = App 的标准化路径）。
    /// 纯排序数据，丢了只是顺序重置 —— 存 UserDefaults 就够，不进收藏
    /// JSON（改它的 schema 会触发老文件的 salvage 分支）。
    private(set) var openerLastUsed: [String: Double]

    /// 用户手动加进「打开方式」的 App（标准化路径）。终端点名 + LS 枚举
    /// 都不保证全（不登记 public.folder 又不在终端名单里的就漏），
    /// 漏网的从设置页手动补。
    @Published private(set) var openerExtras: [String]
    /// 用户从「打开方式」里关掉的 App（标准化路径）。只对发现来源生效；
    /// 手动添加的关掉即从 extras 移除，不进这份名单。
    @Published private(set) var openerHidden: Set<String>

    private static let openerKey = "openerLastUsed"
    private static let openerExtrasKey = "openerExtras"
    private static let openerHiddenKey = "openerHidden"

    private let file: URL

    init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("favorite-folders.json")
        openerLastUsed = UserDefaults.standard
            .dictionary(forKey: Self.openerKey) as? [String: Double] ?? [:]
        openerExtras = UserDefaults.standard.stringArray(forKey: Self.openerExtrasKey) ?? []
        openerHidden = Set(UserDefaults.standard.stringArray(forKey: Self.openerHiddenKey) ?? [])
        load()
    }

    /// 记录一次「用这个 App 打开」——「打开方式」列表按它动态排序。
    func touchOpener(appPath: String) {
        openerLastUsed[appPath] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(openerLastUsed, forKey: Self.openerKey)
    }

    /// 设置页手动添加打开方式。之前被关掉过的话顺带解除隐藏 ——
    /// 连同这个 App 的变体（key 形如 `<path>#<variant>`，见 OpenerApp.id）
    /// 一起解除：用户选的是 Claude.app，没法单独指名「Claude Code」。
    func addOpenerExtra(appPath: String) {
        let unhidden = openerHidden.filter { $0 == appPath || $0.hasPrefix(appPath + "#") }
        if !unhidden.isEmpty {
            openerHidden.subtract(unhidden)
            UserDefaults.standard.set(Array(openerHidden), forKey: Self.openerHiddenKey)
        }
        guard !openerExtras.contains(appPath) else { return }
        openerExtras.append(appPath)
        UserDefaults.standard.set(openerExtras, forKey: Self.openerExtrasKey)
        log("📁 opener added: \(appPath)")
    }

    func removeOpenerExtra(appPath: String) {
        guard openerExtras.contains(appPath) else { return }
        openerExtras.removeAll { $0 == appPath }
        UserDefaults.standard.set(openerExtras, forKey: Self.openerExtrasKey)
        log("📁 opener extra removed: \(appPath)")
    }

    /// 开关某个发现来源的 App 在「打开方式」里的可见性。
    func setOpenerHidden(_ hidden: Bool, appPath: String) {
        if hidden {
            guard openerHidden.insert(appPath).inserted else { return }
        } else {
            guard openerHidden.remove(appPath) != nil else { return }
        }
        UserDefaults.standard.set(Array(openerHidden), forKey: Self.openerHiddenKey)
    }

    enum AddOutcome {
        case added
        /// 已在收藏里 —— 去重，但当一次使用记账浮到展示最前。
        case movedToFront
        case invalid
    }

    /// 收藏一个目录。重复收藏不是失误而是意图（「我现在就要用它」）：
    /// 去重之余更新 openedAt，让它浮到平铺区最前（2026-09-02 用户定的）。
    @discardableResult
    func add(path: String) -> AddOutcome {
        let norm = Self.normalized(path)
        guard !norm.isEmpty else { return .invalid }
        let now = Date().timeIntervalSince1970 * 1000
        if entries.contains(where: { $0.path == norm }) {
            entries = Self.touching(entries, path: norm, openedAt: now)
            persist()
            log("📁 re-favorited folder \(norm) — bumped to front")
            return .movedToFront
        }
        entries = Self.adding(entries, path: norm, addedAt: now)
        persist()
        log("📁 favorited folder \(norm)")
        return .added
    }

    func remove(path: String) {
        guard entries.contains(where: { $0.path == path }) else { return }
        entries.removeAll { $0.path == path }
        persist()
        log("📁 unfavorited folder \(path)")
    }

    /// 记录一次「从菜单打开」—— 该收藏下次浮到平铺区最前。
    /// 存储里仍保持收藏顺序，展示排序在 `byRecency` 里做。
    func touch(path: String) {
        let next = Self.touching(entries, path: path,
                                 openedAt: Date().timeIntervalSince1970 * 1000)
        guard next != entries else { return }
        entries = next
        persist()
    }

    // MARK: - 纯函数（checks/favorite-folder-check.swift 校验这几个）

    /// 路径标准化：展开 ~、消掉 `..`/`.`、去掉尾部斜杠。收藏和取消收藏都以
    /// 这个形态为准 —— 同一目录的两种写法必须判成同一条，否则「重复收藏出现
    /// 两条」「取消收藏点了没反应」都会静默发生。
    nonisolated static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// 追加一条（去重后）。抽成不碰文件系统的静态纯函数，理由同
    /// `ClosedTabStore.merging`：校验脚本不能实例化 store —— 那会直接读写
    /// 用户真实的收藏文件。
    nonisolated static func adding(_ entries: [FavoriteFolder], path: String,
                                   addedAt: Double) -> [FavoriteFolder] {
        let norm = normalized(path)
        guard !norm.isEmpty else { return entries }
        guard !entries.contains(where: { $0.path == norm }) else { return entries }
        return entries + [FavoriteFolder(path: norm, addedAt: addedAt)]
    }

    /// 给某条收藏记一次使用（更新 openedAt）。路径必须已标准化；
    /// 不在收藏里则原样返回。
    nonisolated static func touching(_ entries: [FavoriteFolder], path: String,
                                     openedAt: Double) -> [FavoriteFolder] {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return entries }
        var next = entries
        next[index] = FavoriteFolder(path: entries[index].path,
                                     addedAt: entries[index].addedAt,
                                     openedAt: openedAt)
        return next
    }

    /// 「打开方式」的展示顺序：点过的按最近点击降序在前，没点过的保持
    /// 传入顺序（Finder → 终端 → 枚举）垫底 —— 常用编辑器自己浮上来，
    /// Books / QuickTime 这类从没点过的噪音自然沉底。
    nonisolated static func openerOrder(_ paths: [String],
                                        lastUsed: [String: Double]) -> [String] {
        let used = paths.filter { lastUsed[$0] != nil }
            .sorted { (lastUsed[$0] ?? 0) > (lastUsed[$1] ?? 0) }
        return used + paths.filter { lastUsed[$0] == nil }
    }

    /// 菜单展示顺序：最近打开的在前，没打开过的按收藏时间。平铺区取这个
    /// 顺序的前几个 ——「正在忙的项目自动浮在手边」，凉了的自己沉下去，
    /// 和状态栏里浏览器标签的 MRU 排序一脉相承。
    nonisolated static func byRecency(_ entries: [FavoriteFolder]) -> [FavoriteFolder] {
        entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// 菜单标题：目录名；重名时补上父目录名区分 —— 两个 `web` 并排放着
    /// 根本猜不出哪个是哪个。
    nonisolated static func displayTitles(_ entries: [FavoriteFolder]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.name, default: 0] += 1 }
        return entries.map { entry in
            guard counts[entry.name, default: 0] > 1 else { return entry.name }
            let parent = entry.url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty || parent == "/" ? entry.name : "\(entry.name) — \(parent)"
        }
    }

    // MARK: - 落盘（同 ClosedTabStore：坏文件挪走留证据，绝不原地覆盖）

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else {
            let salvage = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: file, to: salvage)
            log("⚠️  favorite-folders.json 解析失败，已另存为 \(salvage.lastPathComponent)，本次以空列表启动")
            return
        }
        entries = decoded
        if !entries.isEmpty {
            log("📁 loaded \(entries.count) favorite folder(s)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// 「打开方式」里的一个 App。
struct OpenerApp: Identifiable, Equatable {
    /// 怎么把目录交给 App。同一个 App 可以有多种交法（Claude 桌面版：
    /// 当文档交过去进 Cowork，走 deep link 进 Code），所以是 App 之外的
    /// 一个独立维度，不能只靠 url 区分条目。
    enum Launch: Equatable {
        /// 常规：NSWorkspace 把目录当文档交给 App。
        case document
        /// Claude 桌面版的 Code 模式：目录当文档交过去只会进「Chat and
        /// Cowork」，没有开关可改；它自己给 Finder 快捷操作用的是
        /// `claude://code/new?folder=<路径>` 这条 deep link，照走。
        case claudeCode
    }

    let name: String
    let url: URL
    let launch: Launch

    init(name: String, url: URL, launch: Launch = .document) {
        self.name = name
        self.url = url
        self.launch = launch
    }

    /// extras / hidden / lastUsed 三份账都用它当 key：常规条目就是 App
    /// 标准化路径（老账本原样兼容），变体拼 `#<variant>` 后缀——同一个
    /// App 的两种交法各记各的账，最近使用互不串。
    var id: String {
        switch launch {
        case .document: return path
        case .claudeCode: return path + "#claude-code"
        }
    }
    /// App 标准化路径。
    var path: String { url.standardizedFileURL.path }
}

/// 「打开方式」候选 App 的发现与组装。菜单和设置页共用同一份逻辑 ——
/// 同一个组装在所有入口共用，别复制半套。
@MainActor
enum OpenerCatalog {

    /// 终端类 App 是**没法枚举的**：Terminal / iTerm 这些不向 Launch Services
    /// 登记 public.folder（本机实测 `urlsForApplications(toOpen:)` 连系统自带
    /// Terminal 都不返回），而「是不是终端」没有任何 UTI / API 可查 ——
    /// 只能按 bundle id（反向 DNS，永不本地化）点名，装了才显示。
    /// 这是硬编码规则明文允许的场景：无法从 API 推导的列表。
    /// 名单外的漏网 App 由用户在设置页手动补（openerExtras）。
    static let terminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    /// App 显示名。Finder 开了「显示所有文件扩展名」时 `displayName` 会带
    /// `.app` 尾巴，菜单里不需要它。
    static func appDisplayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Claude 桌面版。它登记了 public.folder，会被 LS 枚举出来（当文档
    /// 交过去进 Cowork）；Code 模式要另走 deep link，所以是唯一一个在
    /// 「打开方式」里占两行的 App（2026-09-04 用户定的「Claude 和
    /// Claude Code 并存」）。bundle id 点名属于针对特定 App 行为的绕道。
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Claude Code 的 deep link。编码照 Claude 自家 Finder 快捷操作的
    /// `encodeURIComponent`：只放行 RFC 3986 unreserved 字符——
    /// `URLComponents.queryItems` 不编码 `+`，而对端 `URLSearchParams`
    /// 会把 `+` 解成空格，「C++ projects」这种目录名就打不开。
    nonisolated static func claudeCodeURL(folder path: String) -> URL? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        return URL(string: "claude://code/new?folder=\(encoded)")
    }

    /// 完整候选（含被关掉的）：Finder → 已装终端 → LS 枚举 → 手动添加。
    /// 设置页用它列全量；菜单走 `menuOpeners`（过滤 + MRU）。
    static func candidates(extras: [String]) -> [OpenerApp] {
        var seen = Set<URL>()
        var result: [OpenerApp] = []
        let claude = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: claudeBundleID)?.standardizedFileURL

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { return }
            result.append(OpenerApp(name: appDisplayName(url), url: url))
            // Claude 的 Code 变体紧跟在它后面，绕过 seen（同一个 url）
            if standardized == claude {
                result.append(OpenerApp(name: "Claude Code", url: url, launch: .claudeCode))
            }
        }

        if let finder = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.finder") {
            append(finder)
        }
        for id in terminalBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                append(url)
            }
        }

        // 查询用哪个目录都一样（按 public.folder 匹配），拿主目录当代表
        let claimed = NSWorkspace.shared
            .urlsForApplications(toOpen: FileManager.default.homeDirectoryForCurrentUser)
            .map { (appDisplayName($0), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        for (_, url) in claimed { append(url) }

        // 手动添加的排最后（已被前面来源覆盖的会被 seen 去重掉）；
        // 已卸载的不列出，但不动 extras 账本 —— 装回来自动恢复
        for path in extras where FileManager.default.fileExists(atPath: path) {
            append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return result
    }

    /// 菜单里的最终列表：滤掉被关掉的，点过的按最近点击排前。
    static func menuOpeners(store: FavoriteFolderStore) -> [OpenerApp] {
        // 账本 key 一律用 id 而不是 path：Claude 和 Claude Code 同 path，
        // 按 path 建字典会撞 key（uniqueKeysWithValues 直接崩）
        let visible = candidates(extras: store.openerExtras)
            .filter { !store.openerHidden.contains($0.id) }
        guard !store.openerLastUsed.isEmpty else { return visible }
        let keys = visible.map(\.id)
        let byKey = Dictionary(uniqueKeysWithValues: zip(keys, visible))
        return FavoriteFolderStore.openerOrder(keys, lastUsed: store.openerLastUsed)
            .compactMap { byKey[$0] }
    }
}

/// 读取 Finder 最前面那个窗口正在看的目录。
///
/// 用子进程 osascript 而不是 NSAppleScript：首次调用会弹「自动化」授权对话框，
/// NSAppleScript 同步等在主线程上 —— 用户盯着对话框想的那几秒主线程全程卡死，
/// event tap 会连续超时被系统禁用，甚至触发「键盘钩子已放弃」的误报链。
/// 子进程在后台队列里等，主线程毫发无损。
///
/// 打包后 TCC 归因走 responsible process（TabFlick 本体），
/// `packaging/Info.plist` 的 `NSAppleEventsUsageDescription` 是配套契约 ——
/// 缺了它 macOS 直接拒绝，连授权框都不弹。`swift run` 开发时归因到终端，
/// 弹的是终端的授权框，属正常现象。
enum FinderFront {

    enum FetchError: Error {
        /// 「自动化」权限被拒（或用户没允许就关了对话框）。
        case notAuthorized
        /// Finder 没有窗口，或前窗口不是普通目录（废纸篓、AirDrop 等）。
        case noFolder
    }

    /// 回调回到主线程。
    static func fetchFolder(completion: @escaping (Result<String, FetchError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // 「front Finder window」只匹配普通浏览窗口，简介面板 / 桌面不算。
            proc.arguments = ["-e",
                "tell application \"Finder\" to POSIX path of (target of front Finder window as alias)"]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err

            let result: Result<String, FetchError>
            do {
                try proc.run()
                proc.waitUntilExit()
                let path = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0, !path.isEmpty {
                    result = .success(path)
                } else {
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                        encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    log("⚠️  Finder front-folder fetch failed: \(stderr)")
                    // -1743 = errAEEventNotPermitted：自动化权限被拒
                    result = .failure(stderr.contains("-1743") ? .notAuthorized : .noFolder)
                }
            } catch {
                log("⚠️  osascript launch failed: \(error)")
                result = .failure(.noFolder)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
