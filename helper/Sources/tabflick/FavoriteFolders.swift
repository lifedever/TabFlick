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

    private static let openerKey = "openerLastUsed"

    private let file: URL

    init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("favorite-folders.json")
        openerLastUsed = UserDefaults.standard
            .dictionary(forKey: Self.openerKey) as? [String: Double] ?? [:]
        load()
    }

    /// 记录一次「用这个 App 打开」——「打开方式」列表按它动态排序。
    func touchOpener(appPath: String) {
        openerLastUsed[appPath] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(openerLastUsed, forKey: Self.openerKey)
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
