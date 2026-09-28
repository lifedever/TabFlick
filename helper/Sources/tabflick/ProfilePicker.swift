import Foundation

/// 同一个浏览器开了多个 Profile 时，按键这一刻该服务哪一条连接。
///
/// 每个 Profile 各跑一份扩展、各连一条 WebSocket，bundle id 都一样。原来按 bundle id 取
/// 字典里第一条匹配的 —— 字典顺序和用户正对着哪个 Profile 的窗口毫无关系，切到另一个
/// Profile 的窗口后切换器还在列原来那个 Profile 的标签（2026-09-27 V2EX 用户报的）。
///
/// 依次看三样，前一样判不出唯一结果才看下一样：
/// 1. 前台窗口的标题（AX，按键时现查）对上哪条连接当前标签的标题 —— Chrome 的窗口
///    标题就是当前标签的标题（可能带「- 正在播放音频」这类后缀，所以认前缀）。立即生效、
///    老扩展也行。当前标签没对上（切窗口的 MRU 推送还在路上）再拿全部标签比一次。
/// 2. 扩展上报的最近获得焦点（`focused` 消息，扩展 0.17.0 起有）。两个 Profile 当前
///    标签标题撞了（都停在新标签页）时靠它。
/// 3. 最近推送者；再没有就按 id 固定挑一个，至少不随机。
enum ProfilePicker {
    struct Candidate {
        let id: UUID
        /// MRU 第一个标签的标题 = 这个 Profile 最后聚焦的窗口里的当前标签。
        let currentTitle: String?
        let allTitles: [String]
        let focusedAt: Date?
    }

    enum Reason: String { case title, anyTitle = "any-title", focus, lastPush = "last-push", fallback }

    nonisolated static func pick(_ candidates: [Candidate], windowTitle: String?,
                                 lastPush: UUID?) -> (id: UUID, reason: Reason)? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return (candidates[0].id, .fallback) }

        if let title = windowTitle, !title.isEmpty {
            func matches(_ tabTitle: String?) -> Bool {
                guard let tabTitle, !tabTitle.isEmpty else { return false }
                return title == tabTitle || title.hasPrefix(tabTitle + " ")
            }
            let current = candidates.filter { matches($0.currentTitle) }
            if current.count == 1 { return (current[0].id, .title) }
            if current.isEmpty {
                let any = candidates.filter { $0.allTitles.contains(where: matches) }
                if any.count == 1 { return (any[0].id, .anyTitle) }
            }
        }
        if let focused = candidates.filter({ $0.focusedAt != nil })
            .max(by: { $0.focusedAt! < $1.focusedAt! }) {
            return (focused.id, .focus)
        }
        if let lastPush, candidates.contains(where: { $0.id == lastPush }) { return (lastPush, .lastPush) }
        return (candidates.map(\.id).min { $0.uuidString < $1.uuidString }!, .fallback)
    }
}
