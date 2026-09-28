import Foundation

/// 记住「搜什么、选了什么」（Alfred / Raycast 那种「越用越懂你」，用户 2026-09-28 要的）：
/// 同一个输入再搜时，上次选的那条往前排；「最佳匹配」也吃这个分。
///
/// 按「输入 → 身份（网址 / 路径）→ 次数 + 最后一次」记账。输入是规范化的小写串，查的时候
/// 存的输入和现在的输入互为前缀就算（打过「github」选了某条，再打「git」也认）。次数随时间
/// 衰减（半衰期 30 天）、加分封顶，免得一条老记录永远霸榜。加分只加在本来就命中了的项上
///（`TabSearch.rankScored`），不会把不相干的东西拉进结果。
///
/// 这也是一份浏览记录：存本机 Application Support，设置里能一键清除。
/// 纯逻辑是 `nonisolated static`（checks/search-memory-check.swift 校验），实例只管存盘。
@MainActor
final class SearchMemory {
    static let shared = SearchMemory()

    struct Entry: Codable, Equatable {
        var count: Double
        /// 最后一次选它的时刻（秒）
        var last: Double
    }
    typealias Table = [String: [String: Entry]]

    private(set) var table: Table = [:]
    private let file: URL?
    private var saveTimer: Timer?

    nonisolated static let maxQueries = 400
    nonisolated static let maxPerQuery = 8
    nonisolated static let halfLife: Double = 30 * 86_400
    nonisolated static let maxBoost = 12

    init(file: URL? = SearchMemory.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(Table.self, from: data) {
            table = decoded
        }
    }

    private nonisolated static var defaultFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-memory.json")
    }

    var count: Int { table.values.reduce(0) { $0 + $1.count } }

    func record(query: String, identity: String) {
        let next = Self.recording(table, query: query, identity: identity, now: Date().timeIntervalSince1970)
        guard next != table else { return }
        table = next
        scheduleSave()
    }

    /// 这个输入下各身份的加分。每次按键调一次：只扫存下的输入（最多 400 条），便宜。
    func boosts(for query: String) -> [String: Int] {
        Self.boosts(table, query: query, now: Date().timeIntervalSince1970)
    }

    func clear() {
        table = [:]
        saveTimer?.invalidate()
        if let file { try? FileManager.default.removeItem(at: file) }
        log("🧠 search memory cleared")
    }

    /// 合并 2 秒再写：连着选几次不必写几次；写在后台线程，不碰主线程。
    private func scheduleSave() {
        guard let file else { return }
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let snapshot = self?.table, let data = try? JSONEncoder().encode(snapshot) else { return }
                DispatchQueue.global(qos: .utility).async { try? data.write(to: file, options: .atomic) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    // MARK: - 纯逻辑

    /// 小写、去首尾空白、连续空白并成一个。
    nonisolated static func normalize(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 衰减后的次数。
    nonisolated static func effective(_ entry: Entry, now: Double) -> Double {
        entry.count * pow(0.5, max(0, now - entry.last) / halfLife)
    }

    /// 选过一次刚好 3 分（够把「标题含词」的顶到「标题开头」前面），封顶 12。
    nonisolated static func boost(_ entry: Entry, now: Double) -> Int {
        Int((min(effective(entry, now: now), 4) * 3).rounded())
    }

    nonisolated static func recording(_ table: Table, query: String, identity: String, now: Double) -> Table {
        let key = normalize(query)
        guard !key.isEmpty, !identity.isEmpty else { return table }
        var next = table
        var entries = next[key] ?? [:]
        let previous = entries[identity].map { effective($0, now: now) } ?? 0
        entries[identity] = Entry(count: previous + 1, last: now)
        // 每个输入只留最有分量的几条
        if entries.count > maxPerQuery {
            let keep = entries.sorted { effective($0.value, now: now) > effective($1.value, now: now) }
                .prefix(maxPerQuery)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        next[key] = entries
        // 输入太多就丢最久没用过的
        if next.count > maxQueries {
            let keep = next.sorted { ($0.value.values.map(\.last).max() ?? 0) > ($1.value.values.map(\.last).max() ?? 0) }
                .prefix(maxQueries)
            next = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return next
    }

    nonisolated static func boosts(_ table: Table, query: String, now: Double) -> [String: Int] {
        let key = normalize(query)
        guard !key.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for (stored, entries) in table where stored.hasPrefix(key) || key.hasPrefix(stored) {
            for (identity, entry) in entries {
                let value = boost(entry, now: now)
                if value > (result[identity] ?? 0) { result[identity] = value }
            }
        }
        return result
    }
}
