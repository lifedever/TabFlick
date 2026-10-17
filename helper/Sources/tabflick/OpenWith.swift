import Foundation

/// 搜索面板「打开方式…」命令的数据（2026-10-17，照 Raycast 的 Open With）：访达里选中的项目，
/// 和能打开它们的 App（有文件时才要查 Launch Services；全是目录就用收藏文件夹那份打开方式）。
///
/// 读选中项要跑一次 osascript（约 0.16 秒），所以面板在访达前台打开时就在后台预读，回车时列表直接出来。
/// **只在已经允许控制访达时预读**：还没问过的话预读会在打开面板那一刻弹授权框，用户只是想搜点东西。
/// 没预读到就等回车时再读（这时弹授权框是用户自己要的）。
@MainActor
final class FinderSelectionLoader {
    struct Loaded {
        let selection: FileSelection
        /// 有文件（含 .app、.xcodeproj 这类包）时能打开它们的 App；全是普通目录时 nil。
        let handlers: [URL]?
    }
    typealias Outcome = Result<Loaded, FinderFront.FetchError>

    private var outcome: Outcome?
    /// 回车时还没读完：读完再给它们。
    private var waiters: [(Outcome) -> Void] = []
    private var loading = false
    private var onPrefetched: ((FileSelection) -> Void)?
    /// 每次打开面板加一：上一轮没读完的结果回来时丢掉。
    private var generation = 0

    /// 打开面板时调。前台是访达才预读；预读成功回调 `onPrefetched`（副标题写名字用）。
    func reset(finderFront: Bool, onPrefetched: @escaping (FileSelection) -> Void) {
        generation += 1
        outcome = nil
        waiters = []
        loading = false
        self.onPrefetched = onPrefetched
        if finderFront { load(prefetch: true) }
    }

    /// 回车选了「打开方式…」：预读过就直接给，正在读就等它，没读过现在读（可能弹授权框）。
    func get(_ completion: @escaping (Outcome) -> Void) {
        if let outcome { completion(outcome); return }
        waiters.append(completion)
        if !loading { load(prefetch: false) }
    }

    private func load(prefetch: Bool) {
        loading = true
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async {
            // 预读时还没授权：什么都不读，等回车时再说
            let raw = prefetch && !FinderFront.automationGranted() ? nil : Self.read()
            Task { @MainActor in
                guard current == self.generation else { return }
                self.loading = false
                guard let raw else {
                    // 预读跳过了，可回车已经在等：现在正式读（会弹授权框）
                    if !self.waiters.isEmpty { self.load(prefetch: false) }
                    return
                }
                let result = raw.map { Loaded(selection: FileSelection(paths: $0.paths), handlers: $0.handlers) }
                self.outcome = result
                let waiting = self.waiters
                self.waiters = []
                waiting.forEach { $0(result) }
                if prefetch, case .success(let loaded) = result { self.onPrefetched?(loaded.selection) }
            }
        }
    }

    private nonisolated static func read() -> Result<(paths: [String], handlers: [URL]?), FinderFront.FetchError> {
        FinderFront.readSelection().map { paths in
            let plainFolders = paths.allSatisfy { path in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            return (paths, plainFolders ? nil : OpenerCatalog.fileHandlers(for: paths))
        }
    }
}
