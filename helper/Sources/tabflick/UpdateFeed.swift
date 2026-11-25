import Foundation

/// 一个版本的发布说明（GitHub release 的 body，手写的 markdown）。
struct ReleaseNote: Equatable {
    let version: String
    let body: String
}

/// 检查出来的一次可用更新：装哪一版、装哪个包、这期间各版改了什么。
struct UpdateOffer: Equatable {
    let version: String
    /// 当前架构的 DMG；发布时漏传该架构的包时为 nil，退回发布页手动下载。
    let assetURL: URL?
    let assetSize: Int64
    /// 比当前版本新的各版说明，新的在前，最多 `UpdateFeed.maxNotes` 条。
    /// 发版很密（一天两三版），自动检查按周查的话一次会落下好几版，只给最新那版的说明不够。
    let notes: [ReleaseNote]
}

/// 更新检查的纯逻辑：从 GitHub 发布列表挑出要装的版本、收集说明、给系统通知写摘要。
///
/// 只依赖 Foundation 和 `ReleaseNotesParser`，好脱离 app 单独编译验证
/// （`checks/update-feed-check.swift`）。这里错了都不报错：挑错版本是装错包，
/// 漏挑是「有新版却说已是最新」，说明挑多了用户看到早就装过的改动。
enum UpdateFeed {

    /// 更新窗口里最多列几版的说明。再往前的去 GitHub 看。
    static let maxNotes = 10

    /// `v0.27.3` → `0.27.3`。
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 逐段比较数字版本号。字符串比较会把 "0.10.0" 判成小于 "0.9.0"。
    static func isNewer(_ remote: String, than current: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// GitHub `/releases` 原样解出来的数组 → 要不要更新、更新到哪一版。没有更新的返回 nil。
    ///
    /// 草稿和预发布不算。不靠列表顺序，挑版本号最大的那个（列表按创建时间排，
    /// 补发旧版本的 release 会排到前面）。资产按「文件名含当前架构 + 以 .dmg 结尾」认，
    /// 这是和发版脚本的契约（见 CLAUDE.md「自动更新的两条契约」）。
    static func offer(from releases: [[String: Any]], current: String, arch: String) -> UpdateOffer? {
        let published = releases.filter {
            ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true
        }
        var newest: (version: String, release: [String: Any])?
        var notes: [String: String] = [:]
        for release in published {
            guard let tag = release["tag_name"] as? String else { continue }
            let version = version(fromTag: tag)
            guard isNewer(version, than: current) else { continue }
            if notes[version] == nil { notes[version] = release["body"] as? String ?? "" }
            if newest == nil || isNewer(version, than: newest!.version) {
                newest = (version, release)
            }
        }
        guard let newest else { return nil }

        var assetURL: URL?
        var assetSize: Int64 = 0
        if let assets = newest.release["assets"] as? [[String: Any]],
           let asset = assets.first(where: {
               let name = $0["name"] as? String ?? ""
               return name.contains(arch) && name.hasSuffix(".dmg")
           }) {
            assetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
        }

        let ordered = notes.keys
            .sorted { isNewer($0, than: $1) }
            .prefix(maxNotes)
            .map { ReleaseNote(version: $0, body: notes[$0] ?? "") }
        return UpdateOffer(version: newest.version, assetURL: assetURL, assetSize: assetSize,
                           notes: Array(ordered))
    }

    /// 系统通知的正文：说明里每条列表项取开头加粗的小标题
    /// （「- **新插件：黄金** — 伦敦金…」→「新插件：黄金」），没有加粗的取整条纯文本。
    /// 一行一条，最多 `limit` 条。通知横幅只显示两三行，整条说明塞进去只看得到半句。
    static func summary(of body: String, heading: String, limit: Int = 4) -> String {
        let blocks = ReleaseNotesParser.blocks(from: ReleaseNotesParser.section(from: body, heading: heading))
        var lines: [String] = []
        for block in blocks {
            guard case .bullet(let text) = block else { continue }
            let line = boldLead(text) ?? plain(text)
            if !line.isEmpty { lines.append(line) }
        }
        // 没有列表项的说明：退回第一段
        if lines.isEmpty, let first = blocks.first(where: {
            if case .paragraph = $0 { return true } else { return false }
        }), case .paragraph(let text) = first {
            lines.append(plain(text))
        }
        return lines.prefix(limit).joined(separator: "\n")
    }

    /// `**标题** — 说明` 里的「标题」。不是这种写法的返回 nil。
    private static func boldLead(_ text: String) -> String? {
        guard text.hasPrefix("**") else { return nil }
        let rest = text.dropFirst(2)
        guard let end = rest.range(of: "**") else { return nil }
        let lead = plain(String(rest[..<end.lowerBound]))
        return lead.isEmpty ? nil : lead
    }

    /// 去掉 markdown 记号（加粗、行内代码、链接只留文字），通知里只能放纯文本。
    private static func plain(_ text: String) -> String {
        if let attributed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(attributed.characters).trimmingCharacters(in: .whitespaces)
        }
        return text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
