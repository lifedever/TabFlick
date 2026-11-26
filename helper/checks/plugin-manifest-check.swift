// JS 插件 manifest 解析和联网白名单的校验（PluginManifest.swift）。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/PluginManifest.swift checks/plugin-manifest-check.swift \
//          -o /tmp/manifestcheck && /tmp/manifestcheck
//
// manifest 是外部输入，hosts 是联网白名单：这里每一条错了都不报错，只是白名单放进了不该放的地址、
// 或者坏插件被当成好插件装上。期望值一律手写。

import Foundation

@main
struct PluginManifestCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        func parse(_ json: String) -> Result<PluginManifest, PluginManifest.Problem> {
            PluginManifest.parse(Data(json.utf8))
        }
        func problem(_ json: String) -> PluginManifest.Problem? {
            if case .failure(let p) = parse(json) { return p }
            return nil
        }

        // 正常的 manifest
        let good = """
        {"id": "stocks", "version": "1.0.0", "name": {"zh-Hans": "股票", "en": "Stocks", "ja": "株価"},
         "summary": {"zh-Hans": "行情", "en": "Quotes"}, "symbol": "chart.line.uptrend.xyaxis", "tint": "red",
         "minAppVersion": "0.26.0", "hosts": ["qt.gtimg.cn", "web.ifzq.gtimg.cn", "qt.gtimg.cn"],
         "contributes": {"menu": true, "search": true, "mode": false}}
        """
        if case .success(let m) = parse(good) {
            check("id", m.id == "stocks")
            check("zh-Hans 当 zh", m.names["zh"] == "股票" && m.names["zh-Hans"] == nil, "\(m.names)")
            check("hosts 去重保序", m.hosts == ["qt.gtimg.cn", "web.ifzq.gtimg.cn"], "\(m.hosts)")
            check("只收值为 true 的接入点", m.contributes == [.menu, .search], "\(m.contributes)")
            check("main 默认 main.js", m.main == "main.js")
            check("minAppVersion", m.minAppVersion == "0.26.0")
            check("挑名字：当前语言", PluginManifest.pick(m.names, language: "ja") == "株価")
            check("挑名字：繁中退简中", PluginManifest.pick(m.names, language: "zh-Hant") == "股票")
            check("挑名字：没有的语言退英文", PluginManifest.pick(m.names, language: "de") == "Stocks")
        } else {
            check("正常 manifest 能解析", false, "\(parse(good))")
        }
        check("只有一个字符串的名字当英文",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"Hello"}"#) { return m.names == ["en": "Hello"] }; return false }())
        check("挑名字：只有别的语言时取固定的一个",
              PluginManifest.pick(["ja": "株", "de": "Aktie"], language: "fr") == "Aktie")

        // 列表接入点：对象带名字、关键词、占位、空状态；true 也算开
        let listJSON = """
        {"id":"stocks","version":"1","name":"Stocks","contributes":{"list":{"title":{"zh-Hans":"股票","en":"Stocks"},
         "keywords":["gp"," gp ","stock","",1,"\(String(repeating: "x", count: 40))"],"placeholder":"Search","empty":{"en":"Nothing"}}}}
        """
        if case .success(let m) = parse(listJSON) {
            check("list 对象算开", m.contributes == [.list])
            check("list 名字", m.listTitles == ["zh": "股票", "en": "Stocks"], "\(m.listTitles)")
            check("关键词去空白去重、丢非字符串、截长", m.listKeywords == ["gp", "stock", String(repeating: "x", count: 30)], "\(m.listKeywords)")
            check("占位一个字符串当英文", m.listPlaceholders == ["en": "Search"])
            check("空状态", m.listEmpty == ["en": "Nothing"])
        } else {
            check("list 能解析", false, "\(parse(listJSON))")
        }
        check("list: true 也算开",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x","contributes":{"list":true}}"#) { return m.contributes == [.list] && m.listTitles.isEmpty }; return false }())
        check("list: false 不算",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x","contributes":{"list":false}}"#) { return m.contributes.isEmpty }; return false }())

        // 设置项（下拉框）
        let choiceJSON = #"""
        {"id":"ab","version":"1","name":"x","settings":{"upDownColors":true,"choices":[
          {"key":"feed","title":{"zh-Hans":"看什么","en":"Show"},"default":"latest",
           "options":[{"value":"hot","title":"Hot"},{"value":"latest","title":{"zh-Hans":"最新"}},{"value":"hot","title":"dup"}]},
          {"key":"count","title":"Items","default":"99","options":[{"value":"5"},{"value":"10"}]},
          {"key":"bad key","title":"x","options":[{"value":"a"},{"value":"b"}]},
          {"key":"one","title":"x","options":[{"value":"a"}]},
          {"key":"feed","title":"dup","options":[{"value":"a"},{"value":"b"}]}
        ]}}
        """#
        if case .success(let m) = parse(choiceJSON) {
            check("upDownColors", m.usesUpDownColors)
            check("只留合规的设置项", m.choices.map(\.key) == ["feed", "count"], "\(m.choices.map(\.key))")
            check("选项去重", m.choices.first?.options.map(\.value) == ["hot", "latest"])
            check("默认值", m.choices.first?.defaultValue == "latest")
            check("默认值不在选项里用第一个", m.choices.last?.defaultValue == "5")
            check("没写标题的选项用值", m.choices.last?.options.first?.titles == ["en": "5"])
            check("标题 zh-Hans 当 zh", m.choices.first?.titles["zh"] == "看什么")
        } else {
            check("设置项能解析", false, "\(parse(choiceJSON))")
        }

        // 要用户填的文字 + 链接
        let inputJSON = #"""
        {"id":"ab","version":"1","name":"x","settings":{
          "choices":[{"key":"unit","title":"Unit","options":[{"value":"c"},{"value":"f"}]}],
          "inputs":[
            {"key":"host","title":{"zh-Hans":"API Host","en":"API Host"},"placeholder":"abc.qweatherapi.com","note":{"zh-Hans":"控制台里看"}},
            {"key":"key","title":"API Key","secret":true},
            {"key":"unit","title":"和下拉框撞了"},
            {"key":"no title"},
            {"key":"notitle"},
            {"key":"host","title":"dup"}
          ],
          "links":[
            {"title":"Console","url":"https://console.qweather.com/"},
            {"title":"http","url":"http://console.qweather.com/"},
            {"title":"account","url":"https://user:pw@evil.com/"},
            {"url":"https://no-title.com/"},
            {"title":"js","url":"javascript:alert(1)"}
          ]}}
        """#
        if case .success(let m) = parse(inputJSON) {
            check("只留合规的输入项", m.inputs.map(\.key) == ["host", "key"], "\(m.inputs.map(\.key))")
            check("密码框", m.inputs.map(\.secret) == [false, true])
            check("占位、说明", m.inputs.first?.placeholders == ["en": "abc.qweatherapi.com"] && m.inputs.first?.notes == ["zh": "控制台里看"])
            check("链接只留 https、不带账号、有标题的", m.links.map(\.url.absoluteString) == ["https://console.qweather.com/"],
                  "\(m.links.map(\.url.absoluteString))")
        } else {
            check("输入项能解析", false, "\(parse(inputJSON))")
        }

        // 坏输入
        check("不是 JSON", problem("not json") == .notJSON)
        check("顶层是数组", problem("[1,2]") == .notJSON)
        check("缺 id", problem(#"{"version":"1","name":"x"}"#) == .missing("id"))
        check("id 带斜杠（会变成目录穿越）", problem(#"{"id":"../evil","version":"1","name":"x"}"#) == .badID("../evil"))
        check("id 大写", problem(#"{"id":"Stocks","version":"1","name":"x"}"#) == .badID("Stocks"))
        check("id 数字开头", problem(#"{"id":"1stocks","version":"1","name":"x"}"#) == .badID("1stocks"))
        check("id 一个字", problem(#"{"id":"a","version":"1","name":"x"}"#) == .badID("a"))
        check("版本带字母", problem(#"{"id":"ab","version":"1.0.0-beta","name":"x"}"#) == .badVersion("1.0.0-beta"))
        check("版本空段", problem(#"{"id":"ab","version":"1..0","name":"x"}"#) == .badVersion("1..0"))
        check("版本全角数字", problem(#"{"id":"ab","version":"１.0","name":"x"}"#) == .badVersion("１.0"))
        check("没有名字", problem(#"{"id":"ab","version":"1","name":{"en":""}}"#) == .noName)
        check("主机带协议", problem(#"{"id":"ab","version":"1","name":"x","hosts":["https://a.com"]}"#) == .badHost("https://a.com"))
        check("主机带端口", problem(#"{"id":"ab","version":"1","name":"x","hosts":["a.com:8080"]}"#) == .badHost("a.com:8080"))
        check("主机带路径", problem(#"{"id":"ab","version":"1","name":"x","hosts":["a.com/x"]}"#) == .badHost("a.com/x"))
        check("通配整个顶级域", problem(#"{"id":"ab","version":"1","name":"x","hosts":["*.com"]}"#) == .badHost("*.com"))
        check("通配在中间", problem(#"{"id":"ab","version":"1","name":"x","hosts":["a.*.com"]}"#) == .badHost("a.*.com"))
        check("两层通配", problem(#"{"id":"ab","version":"1","name":"x","hosts":["*.*.a.com"]}"#) == .badHost("*.*.a.com"))
        check("通配不带点", problem(#"{"id":"ab","version":"1","name":"x","hosts":["*a.com"]}"#) == .badHost("*a.com"))
        check("子域名通配可以",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x","hosts":["*.qweatherapi.com"]}"#) { return m.hosts == ["*.qweatherapi.com"] }; return false }())
        check("主机只有一段", problem(#"{"id":"ab","version":"1","name":"x","hosts":["localhost"]}"#) == .badHost("localhost"))
        check("主机大写", problem(#"{"id":"ab","version":"1","name":"x","hosts":["A.com"]}"#) == .badHost("A.com"))
        check("主机空段", problem(#"{"id":"ab","version":"1","name":"x","hosts":["a..com"]}"#) == .badHost("a..com"))
        check("不认识的接入点", problem(#"{"id":"ab","version":"1","name":"x","contributes":{"tray":true}}"#) == .unknownContribution("tray"))
        check("入口往上走", problem(#"{"id":"ab","version":"1","name":"x","main":"../x.js"}"#) == .missing("main"))
        check("入口绝对路径", problem(#"{"id":"ab","version":"1","name":"x","main":"/tmp/x.js"}"#) == .missing("main"))
        check("入口不是 js", problem(#"{"id":"ab","version":"1","name":"x","main":"x.sh"}"#) == .missing("main"))
        // 图标：写了就得是插件目录里的 .svg / .png
        check("图标可以",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x","icon":"icons/icon.SVG"}"#) { return m.icon == "icons/icon.SVG" }; return false }())
        check("没写图标是 nil",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x"}"#) { return m.icon == nil }; return false }())
        check("图标往上走", problem(#"{"id":"ab","version":"1","name":"x","icon":"../icon.svg"}"#) == .badIcon("../icon.svg"))
        check("图标绝对路径", problem(#"{"id":"ab","version":"1","name":"x","icon":"/tmp/icon.png"}"#) == .badIcon("/tmp/icon.png"))
        check("图标不是 svg / png", problem(#"{"id":"ab","version":"1","name":"x","icon":"icon.gif"}"#) == .badIcon("icon.gif"))
        check("图标空段", problem(#"{"id":"ab","version":"1","name":"x","icon":"a//icon.svg"}"#) == .badIcon("a//icon.svg"))
        check("图标不是字符串", problem(#"{"id":"ab","version":"1","name":"x","icon":1}"#) == .badIcon("1"))
        check("入口在子目录可以",
              { if case .success(let m) = parse(#"{"id":"ab","version":"1","name":"x","main":"lib/x.js"}"#) { return m.main == "lib/x.js" }; return false }())

        // 联网白名单
        let hosts = ["qt.gtimg.cn", "fundmobapi.eastmoney.com"]
        func allows(_ s: String) -> Bool { PluginNetPolicy.allows(URL(string: s)!, hosts: hosts) }
        check("放行声明过的 https", allows("https://qt.gtimg.cn/q=sh600519"))
        check("主机不分大小写", allows("https://QT.gtimg.cn/q=1"))
        check("http 不放", !allows("http://qt.gtimg.cn/q=1"))
        check("子域名不放（不认通配）", !allows("https://x.qt.gtimg.cn/"))
        check("父域名不放", !allows("https://gtimg.cn/"))
        check("后缀相同的别家不放", !allows("https://evilqt.gtimg.cn/"))
        check("借白名单主机名做账号不放", !allows("https://qt.gtimg.cn@evil.com/"))
        check("带账号不放", !allows("https://user:pw@qt.gtimg.cn/"))
        check("指定端口不放", !allows("https://qt.gtimg.cn:8443/"))
        check("file 不放", !allows("file:///etc/passwd"))
        check("没声明的不放", !allows("https://hq.sinajs.cn/list=sh600519"))

        // 子域名通配（和风天气每个账号一个域名）
        func allowsWild(_ s: String) -> Bool { PluginNetPolicy.allows(URL(string: s)!, hosts: ["*.qweatherapi.com"]) }
        check("通配放子域名", allowsWild("https://abc123.re.qweatherapi.com/geo/v2/city/lookup"))
        check("通配放一层子域名", allowsWild("https://abc.qweatherapi.com/"))
        check("通配不放它自己", !allowsWild("https://qweatherapi.com/"))
        check("通配不放后缀相同的别家", !allowsWild("https://evilqweatherapi.com/"))
        check("通配不放拿它当前缀的别家", !allowsWild("https://abc.qweatherapi.com.evil.com/"))
        check("通配照样不放 http", !allowsWild("http://abc.qweatherapi.com/"))
        check("通配照样不放端口", !allowsWild("https://abc.qweatherapi.com:8443/"))

        // App 插件（2026-11-26）：app、commands、固定脚本。这些决定插件能指挥谁、能跑什么，写错了就是放进了病毒
        let appGood = #"""
        {"id":"amphetamine","version":"1.0.0","name":"Amphetamine","hosts":[],
         "app":{"bundleId":"com.if.Amphetamine","schemes":["amphetamine"],
                "scripts":{"start":"start new session","end":"if session is active then\nend session\nreturn \"ended\"\nend if\nreturn \"none\""}},
         "contributes":{"menu":true,"commands":[
           {"id":"start","title":{"zh-Hans":"开始新会话","en":"Start New Session"},"keywords":["start"," 开始 ","start"],"symbol":"play.fill"},
           {"id":"end","title":"End Current Session"}]}}
        """#
        if case .success(let m) = parse(appGood) {
            check("app bundleId", m.app?.bundleID == "com.if.Amphetamine")
            check("app schemes", m.app?.schemes == ["amphetamine"])
            check("app scripts", m.app?.scripts["start"] == "start new session" && m.app?.scripts.count == 2)
            check("commands 顺序", m.commands.map(\.id) == ["start", "end"])
            check("命令关键词去空白去重", m.commands.first?.keywords == ["start", "开始"], "\(m.commands.first?.keywords ?? [])")
            check("commands 记进 contributes", m.contributes.contains(.commands) && m.contributes.contains(.menu))
            check("命令标题只给字符串当英文", m.commands.last?.titles == ["en": "End Current Session"])
        } else {
            check("App 插件 manifest 解析", false, "\(parse(appGood))")
        }
        func withApp(_ app: String, commands: String = #"[{"id":"a","title":"A"}]"#, hosts: String = "[]") -> String {
            #"{"id":"ab","version":"1","name":"x","hosts":\#(hosts),"app":\#(app),"contributes":{"commands":\#(commands)}}"#
        }
        func script(_ body: String) -> String { withApp(#"{"bundleId":"com.x.y","scripts":{"s":"\#(body)"}}"#) }
        check("命令要有 app", problem(#"{"id":"ab","version":"1","name":"x","contributes":{"commands":[{"id":"a","title":"A"}]}}"#)
              == .badCommand("commands need an app"))
        check("commands 不是数组拦下", problem(#"{"id":"ab","version":"1","name":"x","app":{"bundleId":"com.x.y"},"contributes":{"commands":true}}"#) != nil)
        check("苹果自己的 App 拦下", problem(withApp(#"{"bundleId":"com.apple.Terminal"}"#)) != nil)
        check("苹果自己的 App 不分大小写", problem(withApp(#"{"bundleId":"COM.APPLE.systemevents"}"#)) != nil)
        check("bundleId 带引号拦下", problem(withApp(#"{"bundleId":"com.x\"y"}"#)) != nil)
        check("bundleId 只有一段拦下", problem(withApp(#"{"bundleId":"xyz"}"#)) != nil)
        check("file scheme 拦下", problem(withApp(#"{"bundleId":"com.x.y","schemes":["file"]}"#)) != nil)
        check("http scheme 拦下", problem(withApp(#"{"bundleId":"com.x.y","schemes":["https"]}"#)) != nil)
        check("系统设置 scheme 拦下", problem(withApp(#"{"bundleId":"com.x.y","schemes":["x-apple.systempreferences"]}"#)) != nil)
        check("大写 scheme 拦下", problem(withApp(#"{"bundleId":"com.x.y","schemes":["CleanShot"]}"#)) != nil)
        check("命令 id 重复拦下", problem(withApp(#"{"bundleId":"com.x.y"}"#, commands: #"[{"id":"a","title":"A"},{"id":"a","title":"B"}]"#)) != nil)
        check("命令没标题拦下", problem(withApp(#"{"bundleId":"com.x.y"}"#, commands: #"[{"id":"a"}]"#)) != nil)
        check("命令 id 带点拦下", problem(withApp(#"{"bundleId":"com.x.y"}"#, commands: #"[{"id":"a.b","title":"A"}]"#)) != nil)
        check("能跑脚本的插件不许联网", problem(withApp(#"{"bundleId":"com.x.y","scripts":{"s":"start"}}"#, hosts: #"["a.com"]"#)) != nil)
        check("不跑脚本的 App 插件可以联网", problem(withApp(#"{"bundleId":"com.x.y"}"#, hosts: #"["a.com"]"#)) == nil)
        check("正常脚本放行", problem(script("start new session")) == nil)
        for (name, body) in [("do shell script", "do shell script \\\"ls\\\""), ("tell 别的 App", "tell application \\\"Finder\\\""),
                             ("run script", "run script \\\"x\\\""), ("原始事件", "«event sysoexec»"),
                             ("竖线标识符", "|tell| x"), ("反斜杠", "a \\\\ b"), ("全角伪装", "ｔｅｌｌ x"),
                             ("弹框", "display dialog \\\"pw\\\""), ("me", "me"), ("path to", "path to desktop"),
                             ("字符串里的也拦", "return \\\"shell\\\""), ("大写也拦", "DO SHELL SCRIPT"), ("空脚本", "  ")] {
            check("脚本拦下：\(name)", problem(script(body)) != nil, body)
        }
        check("脚本超长拦下", problem(script(String(repeating: "a ", count: 1001))) != nil)
        check("脚本名不合规拦下", problem(withApp(#"{"bundleId":"com.x.y","scripts":{"a b":"start"}}"#)) != nil)
        check("包脚本：外面套 tell application id", PluginScriptPolicy.wrapped("a\nb", bundleID: "com.x.y")
              == ["tell application id \"com.x.y\"", "a", "b", "end tell"])

        if failures == 0 { print("全部通过") } else { fatalError("\(failures) 条没过") }
    }
}
