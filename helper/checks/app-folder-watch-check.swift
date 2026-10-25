// AppFolderWatcher.isRelevant 的校验：哪些 FSEvents 事件路径该让 App 清单作废。
//
//   cd helper && CFFIXED_USER_HOME=/tmp/tabflick-check swiftc -parse-as-library \
//     Sources/tabflick/AppCatalog.swift Sources/tabflick/AppActivity.swift Sources/tabflick/Pinyin.swift \
//     Sources/tabflick/Log.swift checks/app-folder-watch-check.swift -o /tmp/appwatchcheck && \
//     CFFIXED_USER_HOME=/tmp/tabflick-check /tmp/appwatchcheck

import Foundation

@main
struct AppFolderWatchCheck {
    static func main() {
        let roots = ["/Applications", "/Applications/Utilities", "/Users/me/Applications"]
        let known: Set<String> = ["/Applications/Safari.app", "/Applications/Google Chrome.app",
                                  "/Applications/Utilities/Terminal.app", "/Users/me/Applications/Chrome Apps.app"]
        func check(_ path: String, _ expected: Bool, _ why: String) {
            let got = AppFolderWatcher.isRelevant(path, roots: roots, known: known)
            precondition(got == expected, "\(path): expected \(expected), got \(got) — \(why)")
        }

        // 目录本身的条目变了（装上、删掉、改名）：FSEvents 报的目录带尾斜杠
        check("/Applications/", true, "目录本身变了")
        check("/Applications", true, "不带尾斜杠也认")
        check("/Applications/Utilities/", true, "Utilities 自己变了")
        check("/Users/me/Applications/", true, "家目录里的应用目录")
        check("/System/Volumes/Data/Applications/", true, "数据卷前缀要剥掉")

        // 往清单里还没有的 .app 里写：拷贝 / 安装进行中
        check("/Applications/NewApp.app/Contents/", true, "新装的 App 在写")
        check("/Applications/NewApp.app/", true, "新装的 App 包本身")
        check("/Applications/Utilities/NewTool.app/Contents/MacOS/", true, "Utilities 里新装的")
        check("/System/Volumes/Data/Applications/NewApp.app/Contents/", true, "数据卷路径下新装的")

        // 已有 App 自己更新：往包里写的一串事件都不算
        check("/Applications/Google Chrome.app/Contents/Frameworks/", false, "已有 App 自己更新")
        check("/Applications/Safari.app/Contents/", false, "已有 App")
        check("/Applications/Utilities/Terminal.app/Contents/Resources/", false, "Utilities 里已有的要按 Utilities 根算")
        check("/Users/me/Applications/Chrome Apps.app/Contents/", false, "家目录里已有的")

        // 包外的杂物、子文件夹里的（只扫一层，不归清单管）
        check("/Applications/Adobe Photoshop 2025/Photoshop.app/Contents/", false, "子文件夹里的不扫")
        check("/Applications/.DS_Store", false, "目录里的杂物")
        check("/Applications/Xcode-tmp/", false, "不是 .app 的子目录")

        // 不在任何根下面
        check("/Library/Application Support/", false, "别的目录")
        check("/ApplicationsBackup/Foo.app/", false, "前缀相同但不是同一个目录")
        check("/Applications2/New.app/Contents/", false, "前缀只差一个字符的目录，别把它的 App 当成新装的")
        check("/Users/me/ApplicationsOld/", false, "家目录里前缀相同的")

        print("app-folder-watch-check: all passed")
    }
}
