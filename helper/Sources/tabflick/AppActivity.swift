import Foundation

/// App 切到前台的记录，存盘的那份：TabFlick 重启（包括自动更新）之后「最近使用」不失忆
/// （用户 2026-09-29 要的）。不存的话，重启后运行中的 App 只能按启动时间排，装在扫描目录外的
/// App 一退出就找不回来。纯逻辑、零依赖，校验见 checks/app-activity-check.swift。
///
/// 这也是一份使用记录：只存本机 Application Support，只留最近一周、最多 200 条。
enum AppActivity {
    struct Record: Codable, Equatable {
        /// `AppEntry.usageKey`：有 bundle id 用它，没有用路径。
        let key: String
        /// 最近一次切到前台（秒）。
        let at: Double
        let path: String
        let name: String
        let bundleID: String?
        /// 最近一次从前台切走（秒）：「最近使用」行尾写的「x 前」是离开它多久了。老文件里没有，nil。
        var left: Double? = nil
    }

    nonisolated static let retention: Double = 7 * 86_400
    nonisolated static let maxRecords = 200

    /// 整理：同一个 key 留最新的，丢掉一周前的和看着不对的（文件是外部输入，可能被改坏），
    /// 时间在将来的夹到现在（系统时间往回调过），按时间新的在前截到上限。
    nonisolated static func pruned(_ records: [Record], now: Double) -> [Record] {
        var latest: [String: Record] = [:]
        for record in records {
            guard !record.key.isEmpty, !record.name.isEmpty, record.path.hasPrefix("/"),
                  record.at.isFinite, record.at > now - retention else { continue }
            var clamped = record
            if clamped.at > now {
                clamped = Record(key: record.key, at: now, path: record.path, name: record.name,
                                 bundleID: record.bundleID, left: record.left)
            }
            if let left = clamped.left { clamped.left = left.isFinite ? min(left, now) : nil }
            if let existing = latest[clamped.key], existing.at >= clamped.at { continue }
            latest[clamped.key] = clamped
        }
        return latest.values
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.key < $1.key }
            .prefix(maxRecords)
            .map { $0 }
    }

    /// 读文件里的数据；解不开就当没有，不崩。
    nonisolated static func decode(_ data: Data?, now: Double) -> [Record] {
        guard let data, let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return pruned(records, now: now)
    }
}
