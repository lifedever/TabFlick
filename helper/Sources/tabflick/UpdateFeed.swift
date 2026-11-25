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

    // MARK: - 网页侧（API 被限流时）

    /// 网页侧拿到的信息 → 要不要更新。`latestTag` 来自 `/releases/latest` 的跳转（不含草稿、预发布），
    /// 说明来自 `releases.atom`（最近 10 版）。拿不到安装包大小，`assetSize` 是 0（下载时按响应头核对）；
    /// 安装包地址按资产命名契约拼（`TabFlick-<版本>-<架构>.dmg`，见 CLAUDE.md「自动更新的两条契约」）。
    static func offer(latestTag: String, notes: [ReleaseNote], current: String, arch: String,
                      repo: String) -> UpdateOffer? {
        guard isSafeTag(latestTag) else { return nil }
        let version = version(fromTag: latestTag)
        guard isNewer(version, than: current) else { return nil }
        let asset = URL(string: "https://github.com/\(repo)/releases/download/\(latestTag)/TabFlick-\(version)-\(arch).dmg")
        var seen = Set<String>()
        let picked = notes
            .filter { isNewer($0.version, than: current) && !isNewer($0.version, than: version) }
            .sorted { isNewer($0.version, than: $1.version) }
            .filter { seen.insert($0.version).inserted }
            .prefix(maxNotes)
        return UpdateOffer(version: version, assetURL: asset, assetSize: 0, notes: Array(picked))
    }

    /// `https://github.com/<repo>/releases/tag/v0.27.4` → `v0.27.4`。跳到别处（登录页、发布列表）的返回 nil。
    static func tag(fromReleaseURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: "tag"), i > 0, parts[i - 1] == "releases", i + 1 < parts.count,
              isSafeTag(parts[i + 1]) else { return nil }
        return parts[i + 1]
    }

    /// tag 要拼进下载地址、显示在界面上：只收字母数字和 `.-_`。
    private static func isSafeTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= 40 && tag.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
        }
    }

    /// `releases.atom` → 各版说明（HTML 转回 markdown，好和 API 那条路共用 `ReleaseNotesParser`）。
    /// 版本取 `<link href=".../releases/tag/v0.27.4">`，不取标题（标题是 release 名，可以随便起）。
    static func atomNotes(from data: Data) -> [ReleaseNote] {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return [] }
        return reader.entries.compactMap { entry in
            guard let link = entry.link, let url = URL(string: link),
                  let tag = tag(fromReleaseURL: url) else { return nil }
            return ReleaseNote(version: version(fromTag: tag), body: markdown(fromReleaseHTML: entry.content))
        }
    }

    /// GitHub 把发布说明渲染成的 HTML → 发布说明用到的那几种 markdown（小标题、列表、引用、段落，
    /// 行内的加粗、代码、链接）。表格整个丢掉（下载表格，`ReleaseNotesParser` 本来也不要）。
    static func markdown(fromReleaseHTML html: String) -> String {
        var s = html.replacingOccurrences(of: "\r", with: "")
        s = replacing(s, #"<table\b.*?</table>"#) { _ in "\n" }
        s = replacing(s, #"<blockquote\b[^>]*>(.*?)</blockquote>"#) { g in
            var paragraphs: [String] = []
            _ = replacing(g[1], #"<p\b[^>]*>(.*?)</p>"#) { p in paragraphs.append(inline(p[1])); return "" }
            if paragraphs.isEmpty { paragraphs = [inline(g[1])] }
            return "\n" + paragraphs.filter { !$0.isEmpty }.map { "> " + $0 }.joined(separator: "\n") + "\n"
        }
        s = replacing(s, #"<h([1-6])\b[^>]*>(.*?)</h\1>"#) { g in
            "\n" + String(repeating: "#", count: Int(g[1]) ?? 2) + " " + inline(g[2]) + "\n"
        }
        s = replacing(s, #"<li\b[^>]*>(.*?)</li>"#) { g in "\n- " + inline(g[1]) + "\n" }
        s = replacing(s, #"<p\b[^>]*>(.*?)</p>"#) { g in "\n" + inline(g[1]) + "\n" }
        s = replacing(s, #"<[^>]+>"#) { _ in "" }   // 剩下的 ul / 空白之间的标签
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: \.isEmpty)
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// 一个块里面的行内标签 → markdown，换行并成空格。
    private static func inline(_ html: String) -> String {
        var s = html
        s = replacing(s, #"<a\b[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#) { g in "[\(stripTags(g[2]))](\(g[1]))" }
        s = replacing(s, #"</?(strong|b)\b[^>]*>"#) { _ in "**" }
        s = replacing(s, #"</?code\b[^>]*>"#) { _ in "`" }
        s = replacing(s, #"<br\s*/?>"#) { _ in " " }
        s = stripTags(s)
        s = decodeEntities(s)
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func stripTags(_ s: String) -> String {
        replacing(s, #"<[^>]+>"#) { _ in "" }
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        out = replacing(out, #"&#(x?)([0-9a-fA-F]+);"#) { g in
            let value = g[1].isEmpty ? UInt32(g[2]) : UInt32(g[2], radix: 16)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? g[0]
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")   // 最后换，免得「&amp;lt;」变成「<」
    }

    /// 正则替换，回调拿到整段和各个分组（没匹配上的分组是空串）。跨行匹配。
    private static func replacing(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
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

    /// 读 atom：每个 `<entry>` 的 `<link href>` 和 `<content>`（XMLParser 已经把 XML 转义解开，拿到的是 HTML）。
    private final class AtomReader: NSObject, XMLParserDelegate {
        struct Entry { var link: String?; var content = "" }
        var entries: [Entry] = []
        private var current: Entry?
        private var inContent = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "entry": current = Entry()
            case "link" where current != nil && current?.link == nil: current?.link = attributes["href"]
            case "content" where current != nil: inContent = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inContent { current?.content += string }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if inContent, let text = String(data: block, encoding: .utf8) { current?.content += text }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "content": inContent = false
            case "entry":
                if let entry = current { entries.append(entry) }
                current = nil
            default: break
            }
        }
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
