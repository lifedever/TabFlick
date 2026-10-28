// ProcessCatalog（「结束进程…」的列表）的纯逻辑校验：哪些进程藏起来、按 App 归组、排序、
// CPU 占用、命令行的显示。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/ProcessList.swift Sources/tabflick/AppPaths.swift Sources/tabflick/L10n.swift \
//          Sources/tabflick/L10nTables.swift Sources/tabflick/Log.swift \
//          checks/process-catalog-check.swift -o /tmp/processcheck && CFFIXED_USER_HOME=/tmp/x /tmp/processcheck
//
// 期望值一律手写。

import Foundation

private typealias C = ProcessCatalog

private func sample(_ pid: Int32, _ path: String, name: String = "", cpu: Double = 0, memory: UInt64 = 0,
                    ports: [UInt16] = [], command: String = "") -> ProcessSample {
    ProcessSample(pid: pid, start: UInt64(pid) * 10, name: name, path: path, commandLine: command,
                  cpu: cpu, memory: memory, ports: ports)
}

@main
struct ProcessCatalogCheck {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }

        // 哪些算系统组件
        check("/System/Library 下的藏", C.isSystem("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
        check("/usr/libexec、/usr/sbin、/sbin、/Library/Apple 下的藏",
              C.isSystem("/usr/libexec/trustd") && C.isSystem("/usr/sbin/cfprefsd") && C.isSystem("/sbin/launchd")
              && C.isSystem("/Library/Apple/System/Library/x"))
        check("系统自带的 App 照列", !C.isSystem("/System/Applications/Calculator.app/Contents/MacOS/Calculator"))
        check("Safari（Cryptex 里）照列",
              !C.isSystem("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"))
        check("自己跑的命令行工具照列", !C.isSystem("/usr/bin/python3") && !C.isSystem("/bin/zsh")
              && !C.isSystem("/opt/homebrew/bin/node"))

        // CPU
        check("两秒用了一秒 = 50%", C.cpuPercent(previousNs: 0, currentNs: 1_000_000_000, elapsedNs: 2_000_000_000) == 50)
        check("时间倒退按 0", C.cpuPercent(previousNs: 5, currentNs: 1, elapsedNs: 10) == 0)
        check("没过时间按 0", C.cpuPercent(previousNs: 0, currentNs: 10, elapsedNs: 0) == 0)

        // 归组
        let chrome = "/Applications/Google Chrome.app"
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        let apps = [
            RunningAppInfo(pid: 100, bundlePath: chrome, name: "Google Chrome", bundleID: "com.google.Chrome"),
            RunningAppInfo(pid: 50, bundlePath: "/System/Library/CoreServices/loginwindow.app", name: "loginwindow", bundleID: nil),
            RunningAppInfo(pid: 999, bundlePath: "/Applications/TabFlick.app", name: "TabFlick", bundleID: nil),
            RunningAppInfo(pid: 300, bundlePath: safari, name: "Safari", bundleID: "com.apple.Safari"),
            // 嵌套：包里还有一个自己也在跑的 App，归最外层
            RunningAppInfo(pid: 401, bundlePath: "/Applications/Setapp.app/Contents/Library/Agent.app", name: "Agent", bundleID: nil),
            RunningAppInfo(pid: 400, bundlePath: "/Applications/Setapp.app", name: "Setapp", bundleID: nil),
        ]
        let samples = [
            sample(100, chrome + "/Contents/MacOS/Google Chrome", cpu: 10, memory: 100),
            sample(101, chrome + "/Contents/Frameworks/F.framework/Helpers/Helper.app/Contents/MacOS/Helper", cpu: 5, memory: 50, ports: [9222]),
            sample(102, chrome + "/Contents/Frameworks/F.framework/Helpers/Helper.app/Contents/MacOS/Helper", cpu: 1, memory: 10, ports: [9222]),
            // 名字是前缀但不是同一个包：不能归到 Chrome
            sample(103, "/Applications/Google Chrome Canary.app/Contents/MacOS/Canary", name: "Canary"),
            sample(50, "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"),
            sample(999, "/Applications/TabFlick.app/Contents/MacOS/TabFlick"),
            sample(500, "/opt/homebrew/bin/node", name: "node", cpu: 3, ports: [3000, 3000], command: "node vite"),
            sample(600, "/usr/sbin/cfprefsd"),
            sample(700, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            sample(1, "/sbin/launchd"),
            sample(800, ""),
            sample(300, safari + "/Contents/MacOS/Safari"),
            sample(400, "/Applications/Setapp.app/Contents/MacOS/Setapp"),
            sample(401, "/Applications/Setapp.app/Contents/Library/Agent.app/Contents/MacOS/Agent"),
        ]
        let built = C.build(samples, apps: apps, ownPID: 999)
        let byID = Dictionary(uniqueKeysWithValues: built.items.map { ($0.id, $0) })
        let chromeItem = byID["app:" + chrome]
        check("Chrome 一行：3 个进程、CPU 和内存相加、端口去重",
              chromeItem?.memberCount == 3 && chromeItem?.cpu == 16 && chromeItem?.memory == 160
              && chromeItem?.ports == [9222] && chromeItem?.pid == 100 && chromeItem?.isApp == true,
              "\(String(describing: chromeItem))")
        check("Chrome 名下的进程都在", built.members["app:" + chrome]?.count == 3)
        check("Canary 不归 Chrome（只是名字前缀一样）", byID["pid:103:1030"]?.isApp == false)
        check("loginwindow 不列（退出 = 注销）", !built.items.contains { $0.path.contains("loginwindow") })
        check("Dock、cfprefsd、launchd 不列", !built.items.contains { [700, 600, 1].contains($0.pid) })
        check("TabFlick 自己不列", !built.items.contains { $0.pid == 999 })
        check("读不到路径的不列", !built.items.contains { $0.pid == 800 })
        check("node 单独一行、端口去重", byID["pid:500:5000"]?.ports == [3000] && byID["pid:500:5000"]?.isApp == false)
        check("Safari 照列", byID["app:" + safari]?.memberCount == 1)
        check("嵌套的归最外层", byID["app:/Applications/Setapp.app"]?.memberCount == 2
              && byID["app:/Applications/Setapp.app/Contents/Library/Agent.app"] == nil)
        check("一共 5 行（Chrome、Canary、node、Safari、Setapp）", built.items.count == 5, "\(built.items.map(\.name))")

        // 边界：路径只是以 bundle 路径开头、不在包里（「Foo.app」和「Foo.apps/…」）
        let boundary = C.build([sample(10, "/Applications/Foo.apps/tool", name: "tool")],
                               apps: [RunningAppInfo(pid: 11, bundlePath: "/Applications/Foo.app", name: "Foo", bundleID: nil)],
                               ownPID: 0)
        check("不在包里的不归它", boundary.items.map(\.id) == ["pid:10:100"], "\(boundary.items.map(\.id))")
        // 开发时 TabFlick 是裸可执行文件，不在任何 App 里：按 pid 认出自己
        let dev = C.build([sample(42, "/Users/me/TabFlick/helper/.build/debug/tabflick", name: "tabflick")], apps: [], ownPID: 42)
        check("开发版的自己也不列", dev.items.isEmpty)
        // 打包后 TabFlick 包里另有进程（比如更新时的辅助进程）：整组不列
        let packaged = C.build([sample(998, "/Applications/TabFlick.app/Contents/Helpers/helper")],
                               apps: [RunningAppInfo(pid: 999, bundlePath: "/Applications/TabFlick.app", name: "TabFlick", bundleID: nil)],
                               ownPID: 999)
        check("自己的包里的进程不列", packaged.items.isEmpty)

        // 运行中 App 的两种路径口径（AppPaths）。iOS App 跑在 /private/var/folders/…/Wrapper 里：归组要对上
        // libproc 给的（带 /private），显示和对清单要换回装的位置。这里拿 /tmp（指向 /private/tmp 的符号链接）
        // 造一个包复现 /private 那一半；挂载那一半（statfs 认 nullfs）造不出来，本机开着 iOS App 时实测过
        let root = "/tmp/processcheck-\(getpid())"
        let bundle = root + "/Wrapper/Foo.app"
        try? FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        check("真实路径：解开符号链接、去掉结尾斜杠", AppPaths.real(bundle + "/") == "/private" + bundle, AppPaths.real(bundle + "/"))
        check("真实路径：包不在了原样去掉结尾斜杠",
              AppPaths.real("/Applications/NoSuch-\(getpid()).app/") == "/Applications/NoSuch-\(getpid()).app")
        let wrapped = C.build([sample(20, "/private" + bundle + "/Foo", name: "Foo")],
                              apps: [RunningAppInfo(pid: 20, bundlePath: AppPaths.real(bundle),
                                                    installedPath: "/Applications/富.app", name: "富", bundleID: nil)],
                              ownPID: 0)
        check("跑在 /private 下的 App 归得上组", wrapped.items.count == 1 && wrapped.items.first?.isApp == true
              && wrapped.items.first?.name == "富", "\(wrapped.items.map(\.id))")
        check("App 行的路径是装的位置（拷贝路径、在访达中显示用它）", wrapped.items.first?.path == "/Applications/富.app",
              "\(String(describing: wrapped.items.first?.path))")
        check("装的位置：直接从包里的 Wrapper 跑的换回外面那个 .app",
              AppPaths.installed("/Applications/新浪财经.app/Wrapper/SinaFinance.app") == "/Applications/新浪财经.app")
        check("装的位置：包里的扩展也归外面那个 .app",
              AppPaths.installed("/Applications/X.app/Wrapper/Y.app/PlugIns/W.appex") == "/Applications/X.app")
        check("装的位置：普通 App 原样", AppPaths.installed("/Applications/Google Chrome.app") == "/Applications/Google Chrome.app")
        check("装的位置：写成清单的口径（/private/tmp → /tmp）", AppPaths.installed("/private" + bundle) == bundle,
              AppPaths.installed("/private" + bundle))

        // 排序
        func item(_ name: String, cpu: Double, memory: UInt64) -> ProcessItem {
            ProcessItem(id: name, path: "/x", pid: 1, start: 0, name: name, commandLine: "", bundleID: nil,
                        cpu: cpu, memory: memory, ports: [], memberCount: 1, isApp: false)
        }
        let list = [item("b", cpu: 1, memory: 9), item("a", cpu: 5, memory: 1), item("c", cpu: 1, memory: 20), item("d", cpu: 1, memory: 20)]
        check("按 CPU：高的在前，一样看内存，再一样按名字",
              C.sorted(list, by: .cpu).map(\.name) == ["a", "c", "d", "b"], "\(C.sorted(list, by: .cpu).map(\.name))")
        check("按内存：高的在前，一样看 CPU，再一样按名字",
              C.sorted(list, by: .memory).map(\.name) == ["c", "d", "b", "a"], "\(C.sorted(list, by: .memory).map(\.name))")

        // 命令行
        check("家目录写成 ~", C.commandLine(["node", "/Users/me/proj/vite.js", "--port", "5173"], home: "/Users/me")
              == "node ~/proj/vite.js --port 5173")
        check("正好是家目录写成 ~", C.commandLine(["cd", "/Users/me"], home: "/Users/me") == "cd ~")
        check("只是前缀一样的别人家目录不动", C.commandLine(["/Users/me2/x"], home: "/Users/me") == "/Users/me2/x")
        let long = C.commandLine([String(repeating: "a", count: 1000)], home: "/Users/me")
        check("太长截到 400 字", long.count == 400 && long.hasSuffix("…"))

        // 显示名
        check("用参数里的名字（Claude Code 的可执行文件叫版本号）",
              C.displayName(argv0: "claude", kernelName: "2.1.310", path: "/x/2.1.310") == "claude")
        check("参数是完整路径取文件名", C.displayName(argv0: "/opt/homebrew/bin/node", kernelName: "node", path: "") == "node")
        check("登录 shell 去掉前面的 -", C.displayName(argv0: "-zsh", kernelName: "zsh", path: "/bin/zsh") == "zsh")
        check("没有参数用内核记的名字", C.displayName(argv0: nil, kernelName: "launchd", path: "/sbin/launchd") == "launchd")
        check("都没有用路径的文件名", C.displayName(argv0: "", kernelName: "", path: "/usr/bin/foo") == "foo")

        // 匹配用的文字带端口和 pid
        let node = byID["pid:500:5000"]!
        check("匹配文字带 :端口 和 pid", C.searchText(node).contains(":3000") && C.searchText(node).contains("pid 500")
              && C.searchText(node).contains("node vite"))

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("ProcessCatalog 校验未通过") }
    }
}
