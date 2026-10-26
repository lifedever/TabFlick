import Foundation

/// 快捷搜索首页的「推荐」（2026-10-26 用户要的）：没输入时「最近使用」上面单独一段，最多 3 条。
///
/// 推什么：你在搜索面板里**选过**的东西（App、网页、文件夹；打字找的和首页直接点的都算。内置命令不推：
/// 用户 2026-10-26 说命令的权重没那么高，三条名额留给「东西」），
/// 选得多的在前，越久以前的越不算（半衰期 14 天）；再看时段 —— 这个钟点前后常选的往前提。
/// 至少选过两次才推（衰减后），一条都够不上就没有这一段。
///
/// 不推什么由面板定（`TabSearchModel.suggestionRows`）：当前那一项、「最近使用」最前面那几行
///（回车回到上一个的那几条，推了等于重复）。推出来的从「最近使用」里挪上来，不重复列。
///
/// 为什么不用搜索记忆（`SearchMemory`）那份账：那份按「输入 → 选了什么」记，没输入时直接点的
/// 记不进去 —— 推出来的东西被你从首页点了，它反而不再攒分，慢慢就推不出来了。两份账用途不同：
/// 记忆管「打这几个字时谁在前」，这份管「什么都没打时推什么」。
///
/// 这也是一份使用记录：存本机 Application Support，设置里「搜索记忆」的清除一起清。
/// 纯逻辑是 `nonisolated static`（checks/search-suggestions-check.swift 校验），实例只管存盘。
@MainActor
final class SuggestionStore {
    static let shared = SuggestionStore(seed: SearchMemory.shared.table)

    struct Record: Codable, Equatable {
        /// command 只为读得懂老文件：内置命令已经不记、不推了
        enum Kind: String, Codable { case app, web, folder, command }
        /// 和 `SearchRow.memoryIdentity` 同一个口径：网页是网址，App / 文件夹是路径，命令是 `appcmd:<id>`。
        let identity: String
        var kind: Kind
        /// 选它那一刻的标题。网页没开着时拿它画行。
        var title: String
        /// 次数，衰减到 `last` 那一刻的值。
        var count: Double
        /// 最后一次选它（秒）。
        var last: Double
        /// 一天 24 个钟点各选过几次（和 count 一起衰减，只看占比）。
        var hours: [Double]
    }

    nonisolated static let halfLife: Double = 14 * 86_400
    nonisolated static let maxRecords = 300
    /// 衰减后至少这么多次才推。
    nonisolated static let minCount: Double = 2
    /// 首页最多推几条（用户 2026-10-26：要严格限制数量）。
    nonisolated static let limit = 3

    private(set) var records: [String: Record] = [:]
    private let file: URL?
    private var saveTimer: Timer?
    private var clearObserver: NSObjectProtocol?

    init(file: URL? = SuggestionStore.defaultFile, seed: SearchMemory.Table? = nil) {
        self.file = file
        let now = Date().timeIntervalSince1970
        if let file, let data = try? Data(contentsOf: file) {
            records = Self.decode(data, now: now)
        } else if let seed {
            // 第一次用：从搜索记忆里把选过的东西搬过来，不用从零攒（没有时段，网页没有标题）
            records = Self.seeded(from: seed, now: now)
            if !records.isEmpty { scheduleSave() }
        }
        clearObserver = NotificationCenter.default.addObserver(forName: .clearUsageHistory, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.clear() }
        }
    }

    private nonisolated static var defaultFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-suggestions.json")
    }

    var count: Int { records.count }

    func record(identity: String, kind: Record.Kind, title: String) {
        let date = Date()
        let hour = Calendar.current.component(.hour, from: date)
        records = Self.recording(records, identity: identity, kind: kind, title: title,
                                 now: date.timeIntervalSince1970, hour: hour)
        scheduleSave()
    }

    /// 此刻该推的，按分排好（还没去掉面板里不该推的，那一步面板做）。
    func ranked() -> [Record] {
        let date = Date()
        return Self.ranked(records, now: date.timeIntervalSince1970, hour: Calendar.current.component(.hour, from: date))
    }

    func clear() {
        records = [:]
        saveTimer?.invalidate()
        if let file { try? FileManager.default.removeItem(at: file) }
        log("🧹 search suggestions cleared")
    }

    /// 合并 2 秒再写；写在后台线程，不碰主线程。
    private func scheduleSave() {
        guard let file else { return }
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let snapshot = self?.records,
                      let data = try? JSONEncoder().encode(Array(snapshot.values)) else { return }
                Self.writeQueue.async { try? data.write(to: file, options: .atomic) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }
    private static let writeQueue = DispatchQueue(label: "TabFlick.search-suggestions", qos: .utility)

    // MARK: - 纯逻辑

    nonisolated static func decay(since: Double, now: Double) -> Double {
        pow(0.5, max(0, now - since) / halfLife)
    }

    nonisolated static func effective(_ record: Record, now: Double) -> Double {
        record.count * decay(since: record.last, now: now)
    }

    /// 这个钟点前后一小时（共三个钟点）占它全部选择的几成。没有时段记录（从搜索记忆搬来的）按均匀分布算。
    nonisolated static func hourShare(_ record: Record, hour: Int) -> Double {
        let total = record.hours.reduce(0, +)
        guard record.hours.count == 24, total > 0 else { return 3.0 / 24 }
        let h = ((hour % 24) + 24) % 24
        return (record.hours[(h + 23) % 24] + record.hours[h] + record.hours[(h + 1) % 24]) / total
    }

    /// 推荐分：次数 ×（0.5 + 时段占比）。全在这个钟点选的是均匀分布的 2.4 倍。
    nonisolated static func score(_ record: Record, now: Double, hour: Int) -> Double {
        effective(record, now: now) * (0.5 + hourShare(record, hour: hour))
    }

    nonisolated static func recording(_ records: [String: Record], identity: String, kind: Record.Kind, title: String,
                                      now: Double, hour: Int) -> [String: Record] {
        guard !identity.isEmpty, (0..<24).contains(hour) else { return records }
        var next = records
        var record = next[identity] ?? Record(identity: identity, kind: kind, title: "", count: 0, last: now,
                                              hours: Array(repeating: 0, count: 24))
        let factor = decay(since: record.last, now: now)
        record.count = record.count * factor + 1
        record.hours = (record.hours.count == 24 ? record.hours : Array(repeating: 0, count: 24)).map { $0 * factor }
        record.hours[hour] += 1
        record.last = max(record.last, now)
        record.kind = kind
        if !title.isEmpty { record.title = String(title.prefix(300)) }
        next[identity] = record
        if next.count > maxRecords {
            let keep = next.values.sorted { effective($0, now: now) > effective($1, now: now) }.prefix(maxRecords)
            next = Dictionary(uniqueKeysWithValues: keep.map { ($0.identity, $0) })
        }
        return next
    }

    /// 够格推的（衰减后至少 `minCount` 次），按推荐分从高到低；同分最近选过的在前。
    nonisolated static func ranked(_ records: [String: Record], now: Double, hour: Int) -> [Record] {
        let eligible = records.values.filter { effective($0, now: now) >= minCount }
        let scored: [(record: Record, score: Double)] = eligible.map { ($0, score($0, now: now, hour: hour)) }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.record.last != b.record.last { return a.record.last > b.record.last }
            return a.record.identity < b.record.identity
        }.map(\.record)
    }

    /// 按身份猜是哪一类（从搜索记忆搬过来时用；那份账只有身份）。认不出的（窗口这类）和内置命令不要。
    nonisolated static func kind(of identity: String) -> Record.Kind? {
        if identity.hasPrefix("http://") || identity.hasPrefix("https://") { return .web }
        if identity.hasPrefix("appcmd:") { return nil }
        guard identity.hasPrefix("/") else { return nil }
        return identity.hasSuffix(".app") ? .app : .folder
    }

    /// 从搜索记忆搬：同一个身份在几个输入下的次数衰减到现在再相加。
    nonisolated static func seeded(from memory: SearchMemory.Table, now: Double) -> [String: Record] {
        var out: [String: Record] = [:]
        for (_, entries) in memory {
            for (identity, entry) in entries {
                guard let kind = kind(of: identity) else { continue }
                let value = SearchMemory.effective(entry, now: now)
                guard value.isFinite, value > 0 else { continue }
                var record = out[identity] ?? Record(identity: identity, kind: kind, title: "", count: 0, last: 0,
                                                     hours: Array(repeating: 0, count: 24))
                record.count += value
                record.last = max(record.last, min(entry.last, now))
                out[identity] = record
            }
        }
        // 衰减已经算到现在了，记账时刻也得是现在，否则读的时候会再衰减一遍
        for key in out.keys { out[key]?.last = now }
        if out.count > maxRecords {
            let keep = out.values.sorted { $0.count > $1.count }.prefix(maxRecords)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.identity, $0) })
        }
        return out
    }

    /// 读文件（外部输入，可能被改坏）：解不开当没有；看着不对的条目丢掉，时间在将来的夹到现在，
    /// 时段不是 24 个正常的数就清零。
    nonisolated static func decode(_ data: Data, now: Double) -> [String: Record] {
        guard let list = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        var out: [String: Record] = [:]
        for var record in list {
            guard !record.identity.isEmpty, record.count.isFinite, record.count > 0, record.last.isFinite else { continue }
            record.last = min(record.last, now)
            record.title = String(record.title.prefix(300))
            if record.hours.count != 24 || record.hours.contains(where: { !$0.isFinite || $0 < 0 }) {
                record.hours = Array(repeating: 0, count: 24)
            }
            if let existing = out[record.identity], existing.last >= record.last { continue }
            out[record.identity] = record
        }
        if out.count > maxRecords {
            let keep = out.values.sorted { effective($0, now: now) > effective($1, now: now) }.prefix(maxRecords)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.identity, $0) })
        }
        return out
    }
}
