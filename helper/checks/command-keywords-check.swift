// 命令关键词的解析（CommandKeywords.parse）和「打出关键词 = 叫出这条命令」（TabSearch.callsByName）。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/CommandKeywords.swift Sources/tabflick/TabSearch.swift \
//          Sources/tabflick/Pinyin.swift checks/command-keywords-check.swift -o /tmp/kwcheck && /tmp/kwcheck

import Foundation

@main
struct CommandKeywordsCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        check("空格、中英文逗号、顿号、分号都分", CommandKeywords.parse("kp  杀进程，kill、zz;yy；xx,ww") == ["kp", "杀进程", "kill", "zz", "yy", "xx", "ww"],
              "\(CommandKeywords.parse("kp  杀进程，kill、zz;yy；xx,ww"))")
        check("不分大小写去重，留第一次的写法", CommandKeywords.parse("KP kp Kp") == ["KP"])
        check("空的", CommandKeywords.parse("  ，、 ").isEmpty)
        check("最多 10 个", CommandKeywords.parse((1...15).map { "w\($0)" }.joined(separator: " ")).count == 10)
        check("每个最多 30 个字", CommandKeywords.parse(String(repeating: "a", count: 50)) == [String(repeating: "a", count: 30)])
        check("打出关键词算叫出", TabSearch.callsByName("kp", names: ["结束进程…", "kp"]))
        check("关键词不分大小写", TabSearch.callsByName("KP", names: ["结束进程…", "kp"]))
        check("关键词的一半不算", !TabSearch.callsByName("k", names: ["结束进程…", "kp"]))
        if failures == 0 { print("全部通过") } else { fatalError("\(failures) 条没过") }
    }
}
