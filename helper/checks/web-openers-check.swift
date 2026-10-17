import Foundation

// 「用 X 打开」的浏览器清单：从 Launch Services 的结果里挑、按最近用过排。改 WebOpeners 必跑：
//   cd helper && swiftc -parse-as-library Sources/tabflick/WebOpeners.swift \
//     checks/web-openers-check.swift -o /tmp/webopenercheck && /tmp/webopenercheck
// 样本照 2026-10-17 本机 urlsForApplications(toOpen: https://) 的真实输出。
@main
struct WebOpenersCheck {
    static func main() {
        let chrome = "/Applications/Google Chrome.app"
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        let firefox = "/Applications/Firefox.app"
        let fdm = "/Applications/Free Download Manager.app"
        let quark = "/Applications/Quark.app"
        let quarkUpdate = "/Users/me/Library/Application Support/Quark/updates/Quark.app"
        let playwright = "/Users/me/Library/Caches/ms-playwright/chromium-1187/chrome-mac/Chromium.app"
        let nested = "/Applications/Foo.app/Contents/Helpers/Foo Browser.app"
        let userApp = "/Users/me/Applications/Orion.app"
        let selfApp = "/Applications/TabFlick.app"

        let apps: [(path: String, bundleID: String?)] = [
            (chrome, "com.google.Chrome"),
            (safari, "com.apple.Safari"),
            (firefox, "org.mozilla.firefox"),
            (fdm, "org.freedownloadmanager.fdm6"),          // 只接管链接，不开 HTML
            (quark, "com.quark.desktop"),
            (playwright, "org.chromium.Chromium"),            // ~/Library 下的缓存
            (quarkUpdate, "com.quark.desktop"),              // 自更新留的副本
            (nested, "com.foo.browser"),                     // 装在别的 App 包里
            ("/Applications/NoID.app", nil),
            (userApp, "com.kagi.kagimacOS"),
            (selfApp, "com.lifedever.TabFlick"),
            (firefox, "org.mozilla.firefox"),                // 同一份报两次
        ]
        let html: Set<String> = [chrome, safari, firefox, quark, playwright, quarkUpdate, nested,
                                 "/Applications/NoID.app", userApp, selfApp,
                                 "/Applications/Visual Studio Code.app"]   // 只开 HTML、不接链接
        let picked = WebOpeners.select(apps, html: html, excluding: "com.lifedever.TabFlick")

        var failures = 0
        func expect(_ name: String, _ ok: Bool) {
            if !ok { failures += 1; print("✗ \(name)") }
        }
        expect("挑出来的就是这几个浏览器、顺序不变：\(picked.map(\.bundleID))",
               picked.map(\.bundleID) == ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                                          "com.quark.desktop", "com.kagi.kagimacOS"])
        expect("夸克留的是 /Applications 那份", picked.first { $0.bundleID == "com.quark.desktop" }?.path == quark)
        expect("~/Applications 的不算 Library", picked.contains { $0.path == userApp })

        // 排序：点过的按最近点击在前，没点过的保持原顺序
        let ids = ["chrome", "safari", "firefox", "quark"]
        let order = WebOpeners.ordered(ids, lastUsed: ["firefox": 200, "quark": 100])
        expect("点过的在前、最近的最前：\(order.map { ids[$0] })", order.map { ids[$0] } == ["firefox", "quark", "chrome", "safari"])
        let untouched = WebOpeners.ordered(ids, lastUsed: [:])
        expect("都没点过保持原顺序", untouched == [0, 1, 2, 3])

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("WebOpeners 校验未通过") }
    }
}
