// JS 插件运行时的校验（JSPluginRuntime.swift）：调用和 Promise、异常、联网白名单、storage、执行时限。
//
// 跑法（在 helper/ 下；Log.swift 会写日志文件，家目录指走，别冲掉正在跑的 TabFlick 的日志）：
//   swiftc -parse-as-library Sources/tabflick/PluginManifest.swift Sources/tabflick/JSPluginRuntime.swift \
//          Sources/tabflick/Log.swift checks/plugin-runtime-check.swift -o /tmp/runtimecheck \
//     && CFFIXED_USER_HOME=/tmp/x /tmp/runtimecheck
// 加 CHECK_NETWORK=1 再跑两条真联网的（腾讯行情的 GBK 解码、跳到别的主机的重定向被拦）。

import Foundation

@main
struct PluginRuntimeCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tabflick-runtime-check-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func runtime(_ script: String, hosts: [String] = ["qt.gtimg.cn"], storage: URL? = nil, idle: TimeInterval = 600) -> JSPluginRuntime {
            let dir = root.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            let hostList = hosts.map { "\"\($0)\"" }.joined(separator: ",")
            let manifest = try! PluginManifest.parse(Data("""
                {"id":"check","version":"1.0.0","name":"Check","hosts":[\(hostList)]}
                """.utf8)).get()
            return JSPluginRuntime(manifest: manifest, directory: dir, storageFile: storage, language: "zh", bridge: .init(),
                                   idleUnload: idle)
        }
        /// 调一次，转着主线程的运行循环等结果（回调在主线程）。
        func call(_ rt: JSPluginRuntime, _ name: String, _ args: [Any] = [], timeout: TimeInterval = 5) -> (done: Bool, value: Any?) {
            var result: (Bool, Any?) = (false, nil)
            rt.call(name, args) { value in result = (true, value) }
            let deadline = Date().addingTimeInterval(timeout)
            while !result.0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return result
        }

        // 调用和返回值
        let basic = runtime("""
            tabflick.register({
              add: (a, b) => a + b,
              later: async () => ({ x: 1, list: [1, 2] }),
              boom: () => { throw new Error("boom") },
              nope: () => Promise.reject(new Error("no")),
              locale: () => tabflick.locale,
              features: () => tabflick.features.join(","),
              wait: () => new Promise(r => setTimeout(() => r("done"), 50)),
            })
            """)
        check("同步返回值", (call(basic, "add", [2, 3]).value as? NSNumber)?.intValue == 5)
        let later = call(basic, "later").value as? [String: Any]
        check("Promise 的结果", (later?["x"] as? NSNumber)?.intValue == 1 && (later?["list"] as? [Any])?.count == 2, "\(String(describing: later))")
        let boom = call(basic, "boom")
        check("抛异常回调 nil", boom.done && boom.value == nil)
        let nope = call(basic, "nope")
        check("Promise 拒绝回调 nil", nope.done && nope.value == nil)
        let missing = call(basic, "missing")
        check("没注册的函数回调 nil", missing.done && missing.value == nil)
        check("异常之后还能接着调", (call(basic, "add", [1, 1]).value as? NSNumber)?.intValue == 2)
        check("locale", call(basic, "locale").value as? String == "zh")
        // 插件靠它判断能不能给多层列表、走秒的钟（老版本没有这一项）
        check("features", call(basic, "features").value as? String == "enter,clock")
        check("setTimeout", call(basic, "wait").value as? String == "done")

        // 加载失败
        let silent = runtime("var x = 1")
        let noRegister = call(silent, "anything")
        check("没调 register 回调 nil", noRegister.done && noRegister.value == nil)
        let broken = runtime("tabflick.register({ a: () => 1 }) ; this is not js")
        let brokenCall = call(broken, "a")
        check("语法错回调 nil", brokenCall.done && brokenCall.value == nil)

        // 联网白名单（不出网：被拦的请求根本不发出去）
        let net = runtime("""
            async function attempt(url) {
              // 只传网址（最常见的写法）；回拒绝原因，别把 TypeError 也当成「拦下了」
              try { await tabflick.fetch(url); return "sent" } catch (e) { return String(e) }
            }
            tabflick.register({ attempt })
            """)
        let blocked = "blocked: not in manifest hosts"
        check("没声明的主机被拦", call(net, "attempt", ["https://hq.sinajs.cn/list=sh600519"]).value as? String == blocked)
        check("http 被拦", call(net, "attempt", ["http://qt.gtimg.cn/q=sh600519"]).value as? String == blocked)
        check("子域名被拦", call(net, "attempt", ["https://x.qt.gtimg.cn/"]).value as? String == blocked)
        check("带端口被拦", call(net, "attempt", ["https://qt.gtimg.cn:8443/"]).value as? String == blocked)
        check("借主机名当账号被拦", call(net, "attempt", ["https://qt.gtimg.cn@evil.example/"]).value as? String == blocked)

        // 放行的主机、只传网址：请求要真的发出去（.invalid 是保留域名，一定解析不到，回来的是网络错误）。
        // 只传网址时 options 是 JS 的 undefined，读它的属性会抛 TypeError —— 被拦的地址走不到这一步，得单测
        let unreachable = runtime("""
            tabflick.register({ attempt: async (url) => { try { await tabflick.fetch(url); return "sent" } catch (e) { return String(e) } } })
            """, hosts: ["nonexistent.invalid"])
        let sent = call(unreachable, "attempt", ["https://nonexistent.invalid/"], timeout: 20).value as? String ?? "nil"
        check("只传网址也能发请求", !sent.contains("TypeError") && !sent.contains("blocked") && sent != "nil", sent)

        // storage：存得进、读得回、重开还在；不收 JSON 表示不了的
        let file = root.appendingPathComponent("data/check.json")
        let store = runtime("""
            tabflick.register({
              save: () => tabflick.storage.set("k", { a: [1, 2], s: "股票" }),
              load: () => tabflick.storage.get("k"),
              saveFn: () => tabflick.storage.set("f", () => 1),
              drop: () => { tabflick.storage.remove("k"); return tabflick.storage.get("k") === undefined },
            })
            """, storage: file)
        check("storage.set 返回 true", (call(store, "save").value as? NSNumber)?.boolValue == true)
        let loaded = call(store, "load").value as? [String: Any]
        check("storage.get 读回来", loaded?["s"] as? String == "股票", "\(String(describing: loaded))")
        check("存函数被拒", (call(store, "saveFn").value as? NSNumber)?.boolValue == false)
        let reopened = runtime("tabflick.register({ load: () => tabflick.storage.get(\"k\") })", storage: file)
        check("重开还在", ((call(reopened, "load").value as? [String: Any])?["a"] as? [Any])?.count == 2)
        check("storage.remove", (call(store, "drop").value as? NSNumber)?.boolValue == true)

        // 执行时限：死循环要被掐断，之后插件还能用
        let spin = runtime("tabflick.register({ spin: () => { while (true) {} }, ok: () => 7 })")
        let started = Date()
        let spun = call(spin, "spin", timeout: 10)
        let took = Date().timeIntervalSince(started)
        check("死循环被掐断", spun.done && spun.value == nil && took < JSPluginRuntime.executionLimit + 3, "用了 \(took) 秒")
        check("掐断之后还能调", (call(spin, "ok").value as? NSNumber)?.intValue == 7)

        // 闲置卸载：没调用就卸掉 context，卸完再调自动加载、存储还在；等网络的调用不卸
        let idleFile = root.appendingPathComponent("data/idle.json")
        let idle = runtime("""
            tabflick.register({
              save: () => tabflick.storage.set("k", 1),
              load: () => tabflick.storage.get("k"),
              slow: () => new Promise(r => setTimeout(() => r("late"), 900)),
            })
            """, storage: idleFile, idle: 0.3)
        _ = call(idle, "save")
        check("调过之后是加载着的", idle.isLoaded)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("闲置之后卸掉了", !idle.isLoaded)
        check("卸了再调自动加载、存储还在", (call(idle, "load").value as? NSNumber)?.intValue == 1)
        check("等着的调用不会被卸掉打断", call(idle, "slow", timeout: 3).value as? String == "late")

        if ProcessInfo.processInfo.environment["CHECK_NETWORK"] == "1" {
            let live = runtime("""
                tabflick.register({
                  quote: async () => (await tabflick.fetch("https://qt.gtimg.cn/q=sh600519", { encoding: "gbk" })).text,
                  redirect: async () => (await tabflick.fetch("https://google.com/")).status,
                })
                """, hosts: ["qt.gtimg.cn", "google.com"])
            let quote = call(live, "quote", timeout: 15).value as? String
            check("GBK 解码", quote?.contains("贵州茅台") == true, String(quote?.prefix(80) ?? "nil"))
            let status = (call(live, "redirect", timeout: 15).value as? NSNumber)?.intValue
            check("跳到别的主机的重定向不跟", status.map { (300..<400).contains($0) } == true, "status \(String(describing: status))")
        }

        if failures == 0 { print("全部通过") } else { fatalError("\(failures) 条没过") }
    }
}
