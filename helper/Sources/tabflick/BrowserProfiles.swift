import Foundation

/// 扩展握手带来的 Profile 标识 / 扩展 id 的格式校验（都是外部输入）。
///
/// 曾经拿它们去浏览器数据目录里认 Profile 名字（`Local State` + 扩展存储），2026-09-27 实测
/// 被 macOS 的隐私保护挡住（读 `~/Library/Application Support/Google/Chrome` 直接
/// Operation not permitted，要「访问其他 App 的数据」权限）—— 为了显示一个名字不值得多要
/// 一个权限，那条路整个撤了。名字改从窗口标题取（见 MRUController `learnProfileName`）。
enum BrowserProfiles {
    /// Chrome 扩展 id：32 个 a–p。
    nonisolated static func isExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    nonisolated static func isProfileKey(_ key: String) -> Bool {
        (8...64).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
