import CoreServices
import Foundation

/// 「最近文件」（2026-11-13 用户要的）：过去 30 天打开过的文件，和访达侧栏「最近使用」同一个来源 ——
/// Spotlight 记的上次打开时间（`kMDItemLastUsedDate`）。只记经系统「打开」流程打开的（访达里双击、App 的
/// 打开对话框）；终端里 vim、编辑器侧边栏点开的不记，访达「最近使用」里没有的这里也没有。
///
/// **不碰文件本身**：文稿、下载、桌面受隐私保护，读文件（连 stat 也算）可能弹「TabFlick 想访问文稿」。
/// 名字、类型、时间全取 Spotlight 索引里记好的，图标按类型取（`type:` 键）；用户点了打开 / 显示才动到文件。
/// 系统自己那份「最近文档」清单（com.apple.sharedfilelist）要完全磁盘访问权限，不用它。
struct RecentFile: Equatable {
    let path: String
    /// 文件名（带扩展名：打「docx」能筛出来，同名不同格式也分得开）
    let name: String
    /// UTI（`kMDItemContentType`），图标按它取
    let contentType: String
    let lastUsed: Date
    /// 第二行写的位置（`RecentFiles.folderLabel`），`organize` 时算好；打字筛选也比它
    var folder = ""
}

enum RecentFiles {
    static let days = 30
    /// 一次最多留这么多（本机 30 天 273 个）
    static let limit = 300
    /// 读 Spotlight 结果最多看这么多条（滤掉不列的之前）：防一个异常的索引把后台线程拖住
    static let scanLimit = 5_000

    /// 30 天内打开过的、不是文件夹（收藏的文件夹另有地方）、不是 App（「应用」里有）。
    static var query: String {
        "kMDItemLastUsedDate >= $time.today(-\(days))"
            + " && kMDItemContentType != \"public.folder\""
            + " && kMDItemContentType != \"com.apple.application-bundle\""
    }

    /// 列不列：在家目录里；不在隐藏目录（.Trash、.git 这类）里；`~/Library` 下只要 iCloud 云盘
    ///（Mobile Documents）和第三方网盘（CloudStorage），别的是 App 自己的数据；不是 App、不在 App 包里。
    static func isListed(_ path: String, home: String) -> Bool {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts[0] == "Library" {
            guard parts.count > 2, parts[1] == "Mobile Documents" || parts[1] == "CloudStorage" else { return false }
        }
        if parts.contains(where: { $0.lowercased().hasSuffix(".app") }) { return false }
        return true
    }

    /// 第二行写的位置：所在目录，家目录写成 ~。iCloud 云盘写「iCloud 云盘/…」（App 自己的 iCloud 文件夹写
    /// 容器名的最后一段，iCloud~md~obsidian → obsidian）；第三方网盘从网盘的文件夹名写起（Dropbox/…）。
    static func folderLabel(_ path: String, home: String, iCloudName: String) -> String {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        let parent = (path as NSString).deletingLastPathComponent
        let mobile = root + "/Library/Mobile Documents/"
        let storage = root + "/Library/CloudStorage/"
        if parent.hasPrefix(mobile) {
            let rest = parent.dropFirst(mobile.count).split(separator: "/", omittingEmptySubsequences: true)
            guard let container = rest.first else { return iCloudName }
            var inner = Array(rest.dropFirst())
            var head = [iCloudName]
            if container != "com~apple~CloudDocs" {
                head.append(String(container.split(separator: "~").last ?? container))
                if inner.first == "Documents" { inner.removeFirst() }
            }
            return (head + inner.map(String.init)).joined(separator: "/")
        }
        if parent.hasPrefix(storage) { return String(parent.dropFirst(storage.count)) }
        if parent == root { return "~" }
        if parent.hasPrefix(root + "/") { return "~/" + parent.dropFirst(root.count + 1) }
        return parent
    }

    /// 整理一批 Spotlight 结果：滤掉不列的、同一路径留最新的、将来的时间（时钟拨过）当现在、
    /// 按打开时间从新到旧（一样新按路径，顺序稳定）、截上限，顺便算好第二行的位置。
    static func organize(_ raw: [RecentFile], home: String, now: Date, iCloudName: String) -> [RecentFile] {
        var newest: [String: RecentFile] = [:]
        for file in raw where isListed(file.path, home: home) {
            let used = min(file.lastUsed, now)
            if let seen = newest[file.path], seen.lastUsed >= used { continue }
            let name = file.name.isEmpty ? (file.path as NSString).lastPathComponent : file.name
            newest[file.path] = RecentFile(path: file.path, name: name, contentType: file.contentType, lastUsed: used,
                                           folder: folderLabel(file.path, home: home, iCloudName: iCloudName))
        }
        let sorted = newest.values.sorted { a, b in
            a.lastUsed != b.lastUsed ? a.lastUsed > b.lastUsed : a.path < b.path
        }
        return Array(sorted.prefix(limit))
    }

    /// 查一次 Spotlight（同步，放后台线程调；本机 30 天 276 个约 25ms）。nil = 查询本身失败（Spotlight 关了也是
    /// 返回空数组，不是 nil）。只读索引里的属性，不碰文件。
    ///
    /// 时间、名字、类型在建查询时就点名要（`valueListAttrs`），随结果一起回来；逐条 `MDItemCopyAttribute`
    /// 每条要跨进程问一次，276 条要 280ms（2026-11-13 实测）。路径不在点名的范围里（点了也取不到），
    /// 但 `MDItemCopyAttribute(kMDItemPath)` 是本地的，276 条 1ms。
    static func spotlight(home: String) -> [RecentFile]? {
        let wanted = [kMDItemLastUsedDate, kMDItemFSName, kMDItemContentType] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, Self.query as CFString, wanted, nil) else { return nil }
        MDQuerySetSearchScope(query, [home] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        func value<T>(_ attribute: CFString, _ index: Int, as: T.Type) -> T? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
            return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue() as? T
        }
        let count = min(MDQueryGetResultCount(query), scanLimit)
        var out: [RecentFile] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, index),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String,
                  let used = value(kMDItemLastUsedDate, index, as: Date.self) else { continue }
            out.append(RecentFile(path: path,
                                  name: value(kMDItemFSName, index, as: String.self) ?? "",
                                  contentType: value(kMDItemContentType, index, as: String.self) ?? "public.data",
                                  lastUsed: used))
        }
        return out
    }
}

/// 后台查 Spotlight、留一份上次的结果（重进列表先画它，不闪一下空的）。只在进「最近文件…」时查，平时不跑。
@MainActor
final class RecentFileLoader {
    private(set) var cached: [RecentFile]?
    private var generation = 0
    private let queue = DispatchQueue(label: "TabFlick.recentFiles", qos: .userInitiated)

    /// 查一次；回调 nil = 查询失败。上一次没回来就又查的，旧的那次回来时丢掉。
    /// `iCloudName` 是第二行里 iCloud 云盘的叫法（跟界面语言，调用方给：这个文件不依赖 L10n，校验脚本单独编得过）。
    func load(iCloudName iCloud: String, _ done: @escaping @MainActor (_ files: [RecentFile]?, _ milliseconds: Int) -> Void) {
        generation += 1
        let current = generation
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        queue.async {
            let started = Date()
            let files = RecentFiles.spotlight(home: home).map {
                RecentFiles.organize($0, home: home, now: Date(), iCloudName: iCloud)
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor in
                guard current == self.generation else { return }
                if let files { self.cached = files }
                done(files, elapsed)
            }
        }
    }

    /// 不在看了（退出列表、面板关了）：还在路上的结果不要了。
    func cancel() { generation += 1 }
}
