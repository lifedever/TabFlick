import Foundation

/// 汉字转拼音（给标签搜索用）。走系统 `CFStringTransform`，不引第三方库。
///
/// 逐字转而不是整句转：整句转出来的是「jué jīn - Swift bìng fā」这种带空格的串，
/// 混着拉丁词时没法可靠地拆回「哪个音节对应哪个字」，首字母就取不准。逐字转慢，
/// 所以按字缓存 —— 常用汉字就几千个，缓存很快就热了。多音字取系统给的第一个
/// 读音，搜不到时用户还可以敲汉字。
enum Pinyin {

    /// 字 → 拼音的缓存。加锁是为了让启动时的后台预热（`prewarm`）和主线程的
    /// 搜索刷新能同时碰它。
    nonisolated(unsafe) private static var cache: [Character: String] = [:]
    private static let lock = NSLock()

    /// 在后台把这批标题里的汉字都转一遍，把字缓存填热。
    ///
    /// 逐字转不算便宜（几百条已关闭记录、几千个字，冷启动要一两百毫秒），
    /// 不预热的话第一次敲字时集中发生，输入框会顿一下。
    nonisolated static func prewarm(_ titles: [String]) {
        DispatchQueue.global(qos: .utility).async {
            for title in titles { _ = index(title) }
        }
    }

    /// 返回 (全拼, 首字母)，都是小写、无声调、无分隔。非汉字字符原样小写放进两者。
    /// 例：「掘金 - Swift 并发」→ ("juejin-swiftbingfa", "jj-swiftbf")。
    nonisolated static func index(_ text: String) -> (full: String, initials: String) {
        var full = ""
        var initials = ""
        for ch in text {
            if isHan(ch) {
                let syllable = pinyin(of: ch)
                full += syllable
                if let first = syllable.first { initials.append(first) }
            } else if ch.isWhitespace {
                continue
            } else {
                let lower = String(ch).lowercased()
                full += lower
                initials += lower
            }
        }
        return (full, initials)
    }

    private nonisolated static func isHan(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private nonisolated static func pinyin(of ch: Character) -> String {
        lock.lock()
        let cached = cache[ch]
        lock.unlock()
        if let cached { return cached }
        let mutable = NSMutableString(string: String(ch))
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let result = (mutable as String)
            .lowercased()
            .filter { $0.isLetter }
        lock.lock()
        cache[ch] = result
        lock.unlock()
        return result
    }
}
