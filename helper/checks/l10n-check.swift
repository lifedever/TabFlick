// L10n 查表机制校验：插值字面量必须走模板（不是整句）、多行字面量、繁简兜底、系统语言解析。
//
// 跑法（在 helper/ 下，**不带** L10nTables.swift，本文件自带一份桩表）：
//   swiftc -parse-as-library Sources/tabflick/L10n.swift Sources/tabflick/Log.swift \
//          checks/l10n-check.swift -o /tmp/l10ncheck && /tmp/l10ncheck
//
// 曾经的坑：给 L10n.t 加 (String, String) 重载后，带插值的字面量被挑去那个重载，
// 按带实际值的整句查表，所有带参数的句子静默掉回英文。第一条用例专抓这个。

enum L10nTables {
    static func table(for language: L10n.Language) -> [String: String] {
        language == .ja ? ["Opened “{0}” in {1}": "「{0}」を {1} で開きました", "Plain": "プレーン",
                           "Line one\nline two": "一行目\n二行目"] : [:]
    }
}

import Foundation
@main struct Check {
    static func main() {
        L10n.language = .ja
        let app = "Finder", folder = "Docs"
        var fails = 0
        func expect(_ got: String, _ want: String) { if got != want { fails += 1; print("✗ got \(got) want \(want)") } }
        expect(L10n.t("已在 \(app) 打开「\(folder)」", "Opened “\(folder)” in \(app)"), "「Docs」を Finder で開きました")
        expect(L10n.t("普通", "Plain"), "プレーン")
        let zh = "变量", en = "Plain"
        expect(L10n.t(L10nText(verbatim: zh), L10nText(verbatim: en)), "プレーン")
        expect(L10n.t(
            """
            第一行
            第二行
            """,
            """
            Line one
            line two
            """), "一行目\n二行目")
        expect(L10n.t("缺的 \(1)", "Missing \(1)"), "Missing 1")
        L10n.language = .zhHant
        expect(L10n.t("文件夹", "Folder"), "文件夾")
        L10n.language = .zh
        expect(L10n.t("已在 \(app) 打开「\(folder)」", "Opened “\(folder)” in \(app)"), "已在 Finder 打开「Docs」")
        for (tag, want) in [("zh-Hant-TW", L10n.Language.zhHant), ("zh-HK", .zhHant), ("zh-Hans-CN", .zh), ("ja-JP", .ja), ("pt-BR", .en), ("de-AT", .de)] {
            if L10n.resolve(tag) != want { fails += 1; print("✗ resolve \(tag)") }
        }
        L10n.language = .system
        print(fails == 0 ? "全部通过" : "\(fails) 项失败")
        if fails > 0 { exit(1) }
    }
}
