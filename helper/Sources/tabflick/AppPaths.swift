import AppKit
import Darwin

/// 运行中 App 的路径有两种口径，各有用处，别混：
/// - `real`：内核给的真实路径，和 libproc 读到的可执行文件路径对得上（「结束进程…」归组用）。
/// - `installed`：装在哪，和 `AppCatalog` 清单同一个口径（对清单、显示、拷贝路径、在访达中显示用）。
///
/// 两者分开是因为 iOS App（Mac 上装的 iPhone / iPad App）：装在 /Applications/新浪财经.app，里面是
/// Wrapper/SinaFinance.app；运行时系统把 Wrapper 只读挂到 /private/var/folders/…/X/<UUID> 下（nullfs），
/// `NSRunningApplication.bundleURL` 给的是挂载里那份 …/d/Wrapper/SinaFinance.app。拿它去对清单对不上，
/// `standardizedFileURL` 还会把 /private/var 写成 /var、和 libproc 的路径也对不上（2026-10-28 用户报的：
/// 结束进程里搜「新浪」搜不到新浪财经）。
enum AppPaths {
    /// 真实路径：解开符号链接、不带结尾的斜杠。路径已经不在了（解不开）就原样去掉结尾的斜杠。
    nonisolated static func real(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// 这个 bundle 装在哪，写成清单的口径（`AppCatalog.scan` 存的是 `standardizedFileURL.path`）：
    /// iOS App 换回外面那个 .app。要碰文件系统（`standardizedFileURL` 也要），一次几微秒，
    /// 别在主线程上的循环里对所有 App 反复调。
    nonisolated static func installed(_ path: String) -> String {
        URL(fileURLWithPath: wrapperApp(path) ?? path).standardizedFileURL.path
    }

    nonisolated static func installed(_ app: NSRunningApplication) -> String? {
        app.bundleURL.map { installed($0.path) }
    }

    /// 是不是 iOS App。它们不接 `NSRunningApplication.terminate()` 也不接退出的 Apple Event
    /// （2026-10-28 实测：terminate 返回 true、10 秒不退，Apple Event 超时），退出只能发信号（`ProcessEnder.quit`）。
    /// 信号不给 Mac App 问「要不要保存」的机会，所以认错的方向必须是「不是」：包里有 Contents/Info.plist 的
    /// 一律当 Mac App（iOS App 的包是平的，Info.plist 在根上）。
    nonisolated static func isIOSApp(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, wrapperApp(url.path) != nil else { return false }
        return !FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    /// iOS App 外面那个 .app（直接从 /Applications/X.app/Wrapper/Y.app 跑的、从挂载里跑的都认）；不是 iOS App 给 nil。
    /// 只有路径里带「/Wrapper/」的才去问挂载，普通 App 零开销。
    nonisolated static func wrapperApp(_ path: String) -> String? {
        guard path.contains("/Wrapper/") else { return nil }
        if let owner = wrapperOwner(path) { return owner }
        var info = statfs()
        guard statfs(path, &info) == 0, fixedString(info.f_fstypename) == "nullfs" else { return nil }
        return wrapperOwner(fixedString(info.f_mntfromname) + "/")
    }

    /// 「/Applications/X.app/Wrapper/…」→「/Applications/X.app」。
    nonisolated static func wrapperOwner(_ path: String) -> String? {
        guard let range = path.range(of: ".app/Wrapper/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private nonisolated static func fixedString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
