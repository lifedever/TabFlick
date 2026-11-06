import Foundation

/// 命令的自定义关键词（2026-11-06 用户要的）：搜索面板里的每条命令（窗口命令、Amphetamine、锁屏、结束进程…、
/// 打开方式…、股票…）可以加几个关键词，默认就是命令名本身。打出关键词时这条命令排在最前、回车就执行
/// （同打出命令全名，`TabSearch.callsByName`）。设置在各个插件页里，「打开方式…」在搜索面板页。
enum CommandKeywords {
    static let maxWords = 10
    static let maxLength = 30

    /// 「kp  杀进程，kill、kp」→ ["kp", "杀进程", "kill"]：空格、中英文逗号、顿号、分号都算分隔，
    /// 不分大小写去重，最多 10 个，每个最多 30 个字。
    nonisolated static func parse(_ raw: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；"))
        var out: [String] = []
        var seen = Set<String>()
        for part in raw.components(separatedBy: separators) where !part.isEmpty {
            let word = String(part.prefix(maxLength))
            guard seen.insert(word.lowercased()).inserted else { continue }
            out.append(word)
            if out.count == maxWords { break }
        }
        return out
    }
}

/// 关键词存在 UserDefaults `commandKeywords`（命令 id → 用户打的原文）。搜索时只读解析好的那份（每键都要读，
/// 不能每次重新拆）。设置页直接绑原文，打一个字存一次。
@MainActor
final class CommandKeywordStore: ObservableObject {
    static let shared = CommandKeywordStore()
    private static let key = "commandKeywords"

    @Published private(set) var raw: [String: String]
    private var parsed: [String: [String]]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        raw = stored
        parsed = stored.mapValues(CommandKeywords.parse)
    }

    func text(for id: String) -> String { raw[id] ?? "" }

    func words(for id: String) -> [String] { parsed[id] ?? [] }

    func setText(_ text: String, for id: String) {
        guard raw[id, default: ""] != text else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw[id] = nil
            parsed[id] = nil
        } else {
            raw[id] = text
            parsed[id] = CommandKeywords.parse(text)
        }
        UserDefaults.standard.set(raw, forKey: Self.key)
    }
}
