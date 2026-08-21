import Foundation

/// 发布说明的解析。
///
/// 单独成文件、只依赖 Foundation，是为了能脱离 app 单独编译验证
/// （`helper/checks/release-notes-check.swift`）。输入是**手写的 markdown**
/// 而不是结构化数据：挑错段落用户会看到另一种语言，挑漏了会看到一个空窗 ——
/// 两种都不报错，只能靠对着真实发布过的说明跑用例。
enum ReleaseNotesParser {

    enum Block: Equatable {
        case bullet(String)
        case callout(String)
        case paragraph(String)
    }

    /// 从双语说明里挑出一段。
    ///
    /// 发布说明的结构是「## 更新内容 …… ## What's New …… ### Download 表格」。
    /// 挑错段落用户就会看到另一种语言，下载表格则完全没必要出现在 app 里。
    /// 认不出结构时退回整篇（去掉下载表格）—— 宁可排版糙点，也不能白弹一个空窗。
    static func section(from body: String, heading: String) -> String {
        var collected: [String] = []
        var capturing = false
        var sawAnyHeading = false

        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                sawAnyHeading = true
                let title = normalized(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                if title.contains(normalized("Download")) { break }   // 下载表格及其之后一律不要
                capturing = (title == normalized(heading))
                continue
            }
            if capturing { collected.append(raw) }
        }

        if collected.isEmpty {
            // 没认出想要的小标题：整篇拿来用，但仍然砍掉下载表格
            let all = body.components(separatedBy: .newlines)
            if let cut = all.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && normalized($0).contains(normalized("Download"))
            }) {
                collected = Array(all[..<cut])
            } else {
                collected = all
            }
            // 整篇兜底时，小标题自己也留着当分隔
            if sawAnyHeading { collected = collected.filter { !$0.hasPrefix("#") } }
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 弯引号、大小写都归一 —— 说明是手写的，'What's New' 里那撇随时可能变成 ’。
    private static func normalized(_ s: any StringProtocol) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    /// 切成可渲染的块。只认发布说明里真正用到的三种：列表项、引用块、普通段落。
    static func blocks(from section: String) -> [Block] {
        var result: [Block] = []
        for raw in section.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { result.append(.callout(text)) }
            } else if line.hasPrefix("|") || line.hasPrefix("---") {
                continue   // 表格残留，不渲染
            } else {
                result.append(.paragraph(line))
            }
        }
        return result
    }
}
