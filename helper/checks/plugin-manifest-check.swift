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

        if failures == 0 { print("全部通过") } else { fatalError("\(failures) 条没过") }
    }
}
