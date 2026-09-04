// FavoriteFolderStore 纯函数的规则校验。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/FavoriteFolders.swift \
//          Sources/tabflick/L10n.swift Sources/tabflick/Log.swift \
//          checks/favorite-folder-check.swift -o /tmp/foldercheck && /tmp/foldercheck
//
// 为什么单独校验：路径标准化 + 去重写错都是**静默**的 —— 同一目录收藏出
// 两条、或「取消收藏点了没反应」，没有任何报错。重名消歧写错则是两个
// 同名目录在菜单里完全无法区分。
//
// 只测静态纯函数，绝不实例化 FavoriteFolderStore —— 那会直接读写用户
// 真实的 ~/Library/Application Support/TabFlick/favorite-folders.json。

import Foundation

let NOW: Double = 1_700_000_000_000

func folders(_ paths: [String]) -> [FavoriteFolder] {
    paths.map { FavoriteFolder(path: $0, addedAt: NOW) }
}

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  ✗ \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

@main
struct Check {
static func main() {

// ── 标准化 ──────────────────────────────────────────────────────────────
print("路径标准化")
do {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check("~ 展开", FavoriteFolderStore.normalized("~/Documents") == home + "/Documents",
          "得到 \(FavoriteFolderStore.normalized("~/Documents"))")
    check(".. 消解", FavoriteFolderStore.normalized("/Users/x/dev/../proj") == "/Users/x/proj",
          "得到 \(FavoriteFolderStore.normalized("/Users/x/dev/../proj"))")
    check("尾斜杠去掉", FavoriteFolderStore.normalized("/Users/x/proj/") == "/Users/x/proj",
          "得到 \(FavoriteFolderStore.normalized("/Users/x/proj/"))")
    check("空串保持空", FavoriteFolderStore.normalized("") == "")
}

// ── 追加与去重 ──────────────────────────────────────────────────────────
print("追加保序，去重按标准化后的路径")
do {
    var list = FavoriteFolderStore.adding([], path: "/a/one", addedAt: NOW)
    list = FavoriteFolderStore.adding(list, path: "/a/two", addedAt: NOW + 1)
    check("按收藏顺序排", list.map(\.path) == ["/a/one", "/a/two"], "得到 \(list.map(\.path))")

    let dup = FavoriteFolderStore.adding(list, path: "/a/one", addedAt: NOW + 2)
    check("原样重复是 no-op", dup.map(\.path) == list.map(\.path), "得到 \(dup.map(\.path))")

    let spelled = FavoriteFolderStore.adding(list, path: "/a/two/", addedAt: NOW + 2)
    check("尾斜杠写法也判成重复", spelled.count == list.count, "得到 \(spelled.map(\.path))")

    let dotted = FavoriteFolderStore.adding(list, path: "/a/x/../one", addedAt: NOW + 2)
    check("带 .. 的写法也判成重复", dotted.count == list.count, "得到 \(dotted.map(\.path))")

    let empty = FavoriteFolderStore.adding(list, path: "", addedAt: NOW + 2)
    check("空路径拒收", empty.count == list.count, "得到 \(empty.map(\.path))")
}

// ── 展示排序 ────────────────────────────────────────────────────────────
print("byRecency：最近打开的在前，没打开过的按收藏时间")
do {
    let a = FavoriteFolder(path: "/a", addedAt: NOW - 3_000)               // 收藏最早，没打开过
    let b = FavoriteFolder(path: "/b", addedAt: NOW - 2_000, openedAt: NOW) // 刚打开
    let c = FavoriteFolder(path: "/c", addedAt: NOW - 1_000)               // 刚收藏，没打开过
    let out = FavoriteFolderStore.byRecency([a, b, c]).map(\.path)
    check("刚打开的最前", out.first == "/b", "得到 \(out)")
    check("没打开过的按收藏时间排", out == ["/b", "/c", "/a"], "得到 \(out)")
}

print("touching：重复收藏 / 打开后浮到展示最前")
do {
    let a = FavoriteFolder(path: "/a", addedAt: NOW - 3_000)
    let b = FavoriteFolder(path: "/b", addedAt: NOW - 2_000)
    let touched = FavoriteFolderStore.touching([a, b], path: "/a", openedAt: NOW)
    check("openedAt 被更新", touched.first?.openedAt == NOW,
          "得到 \(String(describing: touched.first?.openedAt))")
    check("存储顺序不变（只改字段）", touched.map(\.path) == ["/a", "/b"],
          "得到 \(touched.map(\.path))")
    check("展示时浮到最前", FavoriteFolderStore.byRecency(touched).first?.path == "/a",
          "得到 \(FavoriteFolderStore.byRecency(touched).map(\.path))")
    check("陌生路径是 no-op",
          FavoriteFolderStore.touching([a, b], path: "/x", openedAt: NOW) == [a, b])
}

print("首版存档没有 openedAt 字段也能解码（升级兼容）")
do {
    let json = #"[{"path":"/old","addedAt":1}]"#
    let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: Data(json.utf8))
    check("整份解码成功", decoded?.count == 1, "得到 \(decoded?.count ?? -1) 条")
    check("openedAt 退成 nil", decoded?.first?.openedAt == nil)
}

// ── 打开方式排序 ────────────────────────────────────────────────────────
print("openerOrder：点过的按最近点击在前，没点过的保持原序垫底")
do {
    let paths = ["/Finder", "/Terminal", "/VSCode", "/Books"]
    let order = FavoriteFolderStore.openerOrder(
        paths, lastUsed: ["/VSCode": NOW, "/Terminal": NOW - 1_000])
    check("最近点的最前", order == ["/VSCode", "/Terminal", "/Finder", "/Books"],
          "得到 \(order)")
    let untouched = FavoriteFolderStore.openerOrder(paths, lastUsed: [:])
    check("全没点过保持原序", untouched == paths, "得到 \(untouched)")
    check("一个不丢", order.count == paths.count)
}

// ── Claude Code deep link ───────────────────────────────────────────────
print("claudeCodeURL：路径按 encodeURIComponent 规则编码")
do {
    let plain = OpenerCatalog.claudeCodeURL(folder: "/Users/me/dev")?.absoluteString
    check("斜杠也编码", plain == "claude://code/new?folder=%2FUsers%2Fme%2Fdev", "得到 \(plain ?? "nil")")
    let tricky = OpenerCatalog.claudeCodeURL(folder: "/a b/C++ &x=1#y/中文")?.absoluteString
    check("空格 / + / & / = / # 全部编码，对端 URLSearchParams 不会解错",
          tricky == "claude://code/new?folder=%2Fa%20b%2FC%2B%2B%20%26x%3D1%23y%2F%E4%B8%AD%E6%96%87",
          "得到 \(tricky ?? "nil")")
    let keep = OpenerCatalog.claudeCodeURL(folder: "/x-y_z.w~")?.absoluteString
    check("unreserved 字符原样保留", keep == "claude://code/new?folder=%2Fx-y_z.w~", "得到 \(keep ?? "nil")")
}

// ── 重名消歧 ────────────────────────────────────────────────────────────
print("菜单标题：目录名，重名补父目录")
do {
    let unique = FavoriteFolderStore.displayTitles(folders(["/dev/alpha", "/dev/beta"]))
    check("不重名时只显示目录名", unique == ["alpha", "beta"], "得到 \(unique)")

    let clash = FavoriteFolderStore.displayTitles(
        folders(["/dev/myspace/web", "/dev/client/web", "/dev/alpha"]))
    check("重名的带上父目录", clash == ["web — myspace", "web — client", "alpha"],
          "得到 \(clash)")
    check("不重名的不受牵连", clash.last == "alpha")
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
}
}
