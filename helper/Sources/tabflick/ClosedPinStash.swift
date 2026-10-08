/// 自己关掉置顶标签时删掉的置顶记录，留着给恢复时原样放回去。
///
/// 自己关掉置顶标签 = 取消置顶（2026-10-03），记录当场就删了。用 ⌘Z / ⇧⌘T 恢复回来的标签在
/// 浏览器里还是固定的，扩展会报一条 `pinnedTab` —— 不认得它的话就按当前网址新建一条：原来的
/// 置顶地址（「回到置顶地址」回去的地方）和在列表里的位置都丢了（2026-10-08 用户要记回来）。
///
/// 只在内存里：helper 重启就忘，Chrome 的最近关闭本来也只跟着浏览器会话走。
/// 泛型是为了让校验脚本不用拖着 `FavoriteTab` 所在的整个设置文件编译
/// （`checks/closed-pin-stash-check.swift`）。
struct ClosedPinStash<Pin> {
    struct Entry {
        let pin: Pin
        /// 删掉之前在置顶列表里的位置
        let index: Int
        /// 原始置顶地址 + 最后访问的地址：恢复回来的标签停在后者，用户手动重新置顶可能是前者
        let urls: Set<String>
        /// 浏览器 + Profile。置顶按它分账，别的 Profile 里同网址的标签不能认领
        let owner: String
    }

    static var limit: Int { 20 }

    private(set) var entries: [Entry] = []

    mutating func remember(_ pin: Pin, index: Int, urls: [String], owner: String) {
        entries.append(Entry(pin: pin, index: index, urls: Set(urls.filter { !$0.isEmpty }), owner: owner))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// 取出最近关掉的、对得上的那一条（取出即删，同一条不会放回两次）
    mutating func take(url: String, owner: String) -> Entry? {
        guard let i = entries.lastIndex(where: { $0.owner == owner && $0.urls.contains(url) }) else { return nil }
        return entries.remove(at: i)
    }
}
