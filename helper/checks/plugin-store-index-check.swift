// 插件商店目录的解析（PluginStoreIndex.swift）：路径、sha256、上限、坏条目跳过。外部输入，错了就是往本机任意位置写文件。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/PluginStoreIndex.swift Sources/tabflick/PluginManifest.swift \
//          checks/plugin-store-index-check.swift -o /tmp/indexcheck && /tmp/indexcheck ../plugins/index.json

import Foundation

@main
struct PluginStoreIndexCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        let sha = String(repeating: "a", count: 64)
        func entry(_ id: String = "weather", files: String? = nil) -> String {
            let list = files ?? #"[{"path":"manifest.json","size":10,"sha256":"\#(sha)"},{"path":"main.js","size":10,"sha256":"\#(sha)"}]"#
            return #"{"id":"\#(id)","version":"1.0.0","name":{"zh-Hans":"天气"},"hosts":["api.open-meteo.com","Bad Host"],"files":\#(list)}"#
        }
        func parse(_ plugins: String) -> [StoreEntry]? {
            StoreIndex.parse(Data(#"{"schema":1,"plugins":[\#(plugins)]}"#.utf8))
        }

        // 路径
        for good in ["main.js", "lib/a.js", "icons/a-b_c.png"] { check("路径可以：\(good)", StoreIndex.isSafePath(good)) }
        for bad in ["", "/etc/passwd", "../x.js", "a/../../x", "a//b", "./a", "a/.", "a b.js", "中文.js", "a\\b"] {
            check("路径不行：\(bad)", !StoreIndex.isSafePath(bad))
        }
        check("sha256 64 位小写十六进制", StoreIndex.isSHA256(sha) && !StoreIndex.isSHA256(sha.uppercased()) && !StoreIndex.isSHA256("abc"))

        // 整份
        check("不是 JSON", StoreIndex.parse(Data("x".utf8)) == nil)
        check("不认识的 schema", StoreIndex.parse(Data(#"{"schema":2,"plugins":[]}"#.utf8)) == nil)
        let ok = parse(entry())
        check("正常的", ok?.count == 1 && ok?.first?.names["zh"] == "天气" && ok?.first?.hosts == ["api.open-meteo.com"], "\(String(describing: ok))")

        // 单个插件不对就跳过，别的照收
        check("坏 id 跳过", parse(entry("../evil") + "," + entry())?.map(\.id) == ["weather"])
        check("路径往外走跳过", parse(entry(files: #"[{"path":"manifest.json","size":1,"sha256":"\#(sha)"},{"path":"../../x","size":1,"sha256":"\#(sha)"}]"#))?.isEmpty == true)
        check("sha256 不对跳过", parse(entry(files: #"[{"path":"manifest.json","size":1,"sha256":"xyz"}]"#))?.isEmpty == true)
        check("没有 manifest 跳过", parse(entry(files: #"[{"path":"main.js","size":1,"sha256":"\#(sha)"}]"#))?.isEmpty == true)
        check("负数大小跳过", parse(entry(files: #"[{"path":"manifest.json","size":-1,"sha256":"\#(sha)"}]"#))?.isEmpty == true)
        check("同一个文件写两遍跳过", parse(entry(files: #"[{"path":"manifest.json","size":1,"sha256":"\#(sha)"},{"path":"manifest.json","size":1,"sha256":"\#(sha)"}]"#))?.isEmpty == true)
        let many = (0...StoreIndex.maxFiles).map { #"{"path":"f\#($0).js","size":1,"sha256":"\#(sha)"}"# }.joined(separator: ",")
        check("文件太多跳过", parse(entry(files: #"[{"path":"manifest.json","size":1,"sha256":"\#(sha)"},\#(many)]"#))?.isEmpty == true)
        check("总大小超了跳过", parse(entry(files: #"[{"path":"manifest.json","size":\#(StoreIndex.maxBytes + 1),"sha256":"\#(sha)"}]"#))?.isEmpty == true)
        check("同一个 id 留第一个", parse(entry() + "," + entry())?.count == 1)

        // 仓库里真的那份（build-index.py 生成的）
        if CommandLine.arguments.count > 1, let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) {
            let real = StoreIndex.parse(data)
            check("仓库里的 index.json 全部能解析", (real?.count ?? 0) >= 7, "\(real?.map(\.id) ?? [])")
        }

        if failures == 0 { print("全部通过") } else { fatalError("\(failures) 条没过") }
    }
}
