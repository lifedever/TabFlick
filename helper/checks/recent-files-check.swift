// RecentFiles 的校验：哪些 Spotlight 结果列出来、第二行写什么、怎么排。
//
//   cd helper && swiftc -parse-as-library Sources/tabflick/RecentFiles.swift checks/recent-files-check.swift \
//     -o /tmp/recentfilescheck && /tmp/recentfilescheck
//
// 加 CHECK_SPOTLIGHT=1 再真查一次本机的 Spotlight（只打数量、耗时和目录分布，不打文件名）。

import Foundation

@main
struct RecentFilesCheck {
    static func main() {
        let home = "/Users/me"
        func listed(_ path: String, _ expected: Bool, _ why: String) {
            let got = RecentFiles.isListed(path, home: home)
            precondition(got == expected, "\(path): expected \(expected), got \(got) — \(why)")
        }
        listed("/Users/me/Documents/合同.docx", true, "文稿里的文件")
        listed("/Users/me/Downloads/a.pdf", true, "下载里的文件")
        listed("/Users/me/a.txt", true, "家目录根下的文件")
        listed("/Users/me", false, "家目录本身")
        listed("/Users/me/", false, "家目录本身带斜杠")
        listed("/Users/meow/a.txt", false, "前缀相同的别人家目录（前缀要带斜杠）")
        listed("/Applications/Notes.txt", false, "家目录外")
        listed("/Users/me/.Trash/a.pdf", false, "废纸篓")
        listed("/Users/me/Dev/repo/.git/COMMIT_EDITMSG", false, "隐藏目录里")
        listed("/Users/me/Documents/.hidden.md", false, "隐藏文件")
        listed("/Users/me/Library/Preferences/x.plist", false, "App 自己的数据")
        listed("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/简历.pages", true, "iCloud 云盘")
        listed("/Users/me/Library/Mobile Documents/iCloud~md~obsidian/Documents/v/n.md", true, "App 的 iCloud 文件夹")
        listed("/Users/me/Library/Mobile Documents", false, "Mobile Documents 目录本身")
        listed("/Users/me/Library/CloudStorage/Dropbox/a.key", true, "第三方网盘")
        listed("/Users/me/Applications/Foo.app", false, "App 本身")
        listed("/Users/me/Downloads/Foo.APP/Contents/Info.plist", false, "App 包里（不分大小写）")
        listed("/Users/me/Documents/notes.application.md", true, "名字里有 app 但不是 .app 结尾")
        // 家目录参数带尾斜杠也一样
        precondition(RecentFiles.isListed("/Users/me/a.txt", home: "/Users/me/"), "家目录带尾斜杠")

        func label(_ path: String, _ expected: String, _ why: String) {
            let got = RecentFiles.folderLabel(path, home: home, iCloudName: "iCloud 云盘")
            precondition(got == expected, "\(path): expected \(expected), got \(got) — \(why)")
        }
        label("/Users/me/Documents/项目/a.docx", "~/Documents/项目", "家目录写成 ~")
        label("/Users/me/a.txt", "~", "家目录根下")
        label("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/简历.pages", "iCloud 云盘", "iCloud 云盘根下")
        label("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/工作/周报.docx", "iCloud 云盘/工作", "iCloud 云盘子目录")
        label("/Users/me/Library/Mobile Documents/iCloud~md~obsidian/Documents/v/n.md", "iCloud 云盘/obsidian/v",
              "App 的 iCloud 文件夹：容器名最后一段，去掉 Documents")
        label("/Users/me/Library/Mobile Documents/iCloud~com~apple~Pages/Documents/a.pages", "iCloud 云盘/Pages",
              "Pages 的 iCloud 文件夹")
        label("/Users/me/Library/CloudStorage/Dropbox/工作/a.key", "Dropbox/工作", "第三方网盘从网盘名写起")
        label("/Users/meow/a.txt", "/Users/meow", "前缀相同的别人家目录不写成 ~")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func file(_ path: String, _ ago: TimeInterval, name: String = "") -> RecentFile {
            RecentFile(path: path, name: name, contentType: "public.data", lastUsed: now.addingTimeInterval(-ago))
        }
        let organized = RecentFiles.organize([
            file("/Users/me/Documents/old.txt", 3_000, name: "old.txt"),
            file("/Users/me/Documents/new.txt", 10, name: "new.txt"),
            file("/Users/me/Library/Caches/x.db", 1),
            file("/Users/me/Documents/dup.txt", 5_000, name: "dup.txt"),
            file("/Users/me/Documents/dup.txt", 20, name: "dup.txt"),
            file("/Users/me/Documents/future.txt", -86_400, name: "future.txt"),
            file("/Users/me/Documents/b.txt", 100),
            file("/Users/me/Documents/a.txt", 100),
        ], home: home, now: now, iCloudName: "iCloud 云盘")
        let paths = organized.map { ($0.path as NSString).lastPathComponent }
        precondition(paths == ["future.txt", "new.txt", "dup.txt", "a.txt", "b.txt", "old.txt"],
                     "从新到旧、同时间按路径、滤掉 Library、去重：\(paths)")
        precondition(organized[0].lastUsed == now, "将来的时间当现在")
        precondition(organized.first { $0.path.hasSuffix("dup.txt") }?.lastUsed == now.addingTimeInterval(-20),
                     "同一路径留最新的")
        precondition(organized.first { $0.path.hasSuffix("b.txt") }?.name == "b.txt", "没名字用路径最后一段")
        precondition(organized.first?.folder == "~/Documents", "第二行的位置算好了")

        let many = (0..<(RecentFiles.limit + 50)).map { file("/Users/me/Documents/\($0).txt", TimeInterval($0)) }
        let capped = RecentFiles.organize(many, home: home, now: now, iCloudName: "iCloud 云盘")
        precondition(capped.count == RecentFiles.limit, "截到上限")
        precondition(capped.first?.path == "/Users/me/Documents/0.txt", "截掉的是最旧的")

        precondition(RecentFiles.query.contains("$time.today(-30)"), "查 30 天")

        print("recent files check: OK")

        guard ProcessInfo.processInfo.environment["CHECK_SPOTLIGHT"] == "1" else { return }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let started = Date()
        guard let raw = RecentFiles.spotlight(home: realHome) else { fatalError("Spotlight 查询失败") }
        let files = RecentFiles.organize(raw, home: realHome, now: Date(), iCloudName: "iCloud")
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var folders: [String: Int] = [:]
        for f in files {
            folders[f.folder.split(separator: "/").prefix(2).joined(separator: "/"), default: 0] += 1
        }
        print("spotlight: \(raw.count) raw → \(files.count) listed in \(ms) ms")
        for (folder, n) in folders.sorted(by: { $0.value > $1.value }).prefix(8) { print("  \(n)\t\(folder)") }
    }
}
