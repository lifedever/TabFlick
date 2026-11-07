import Foundation

// 插件商店的目录（plugins/index.json，scripts/plugins/build-index.py 生成）。纯逻辑，checks/plugin-store-index-check.swift 校验。
//
// 它是从网上拉下来的外部输入：文件路径会拼到本机目录上（不许 .. 和绝对路径），大小、sha256 是下载后核对的依据
// （sha256 必须是 64 位十六进制），文件数和总大小有上限。整份格式不对就当拉不到；单个插件不对就跳过它。

struct StoreEntry: Equatable, Identifiable {
    struct File: Equatable {
        let path: String
        let size: Int
        let sha256: String
    }

    let id: String
    let version: String
    let names: [String: String]
    let summaries: [String: String]
    let symbol: String
    let tint: String
    let hosts: [String]
    let minAppVersion: String?
    let files: [File]
    /// 图标在 files 里的哪一个（没装的插件在商店里也画它的图标）。nil = 用 symbol + tint
    var icon: File? = nil
}

enum StoreIndex {
    static let maxFiles = 20
    static let maxBytes = 4 << 20
    /// 同 `PluginIconLoader.maxBytes`（这个文件是纯逻辑，校验程序单独编，不引它）
    static let maxIconBytes = 256 << 10

    /// 文件路径：字母数字和 . _ -，用 / 分段，不许空段、. 和 ..、不许以 / 开头。
    nonisolated static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.count <= 200 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
        }
    }

    nonisolated static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// nil = 整份不对（不是 JSON、schema 不认识）。单个插件不对的跳过。同一个 id 只留第一个。
    nonisolated static func parse(_ data: Data) -> [StoreEntry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema"] as? Int) == 1, let list = object["plugins"] as? [Any] else { return nil }
        var out: [StoreEntry] = []
        for case let item as [String: Any] in list {
            guard let id = item["id"] as? String, PluginManifest.isValidID(id),
                  let version = item["version"] as? String, PluginManifest.isValidVersion(version),
                  !out.contains(where: { $0.id == id }) else { continue }
            var files: [StoreEntry.File] = []
            var total = 0
            var bad = false
            for case let f as [String: Any] in (item["files"] as? [Any]) ?? [] {
                guard let path = f["path"] as? String, isSafePath(path),
                      let size = f["size"] as? Int, size >= 0,
                      let sha = f["sha256"] as? String, isSHA256(sha),
                      !files.contains(where: { $0.path == path }) else { bad = true; break }
                total += size
                files.append(StoreEntry.File(path: path, size: size, sha256: sha))
            }
            guard !bad, !files.isEmpty, files.count <= maxFiles, total <= maxBytes,
                  files.contains(where: { $0.path == "manifest.json" }) else { continue }
            let minApp = item["minAppVersion"] as? String
            out.append(StoreEntry(
                id: id, version: version,
                names: localized(item["name"]), summaries: localized(item["summary"]),
                symbol: (item["symbol"] as? String) ?? "puzzlepiece.fill", tint: (item["tint"] as? String) ?? "gray",
                hosts: ((item["hosts"] as? [Any]) ?? []).compactMap { $0 as? String }.filter(PluginManifest.isValidHost),
                minAppVersion: minApp.flatMap { PluginManifest.isValidVersion($0) ? $0 : nil },
                files: files,
                // 图标必须是包里的一个文件（大小、sha256 才有得核对），路径和后缀不对、太大的当没有
                icon: (item["icon"] as? String).flatMap { path in
                    guard PluginManifest.isValidIcon(path) else { return nil }
                    return files.first { $0.path == path && $0.size <= maxIconBytes }
                }))
        }
        return out
    }

    nonisolated private static func localized(_ value: Any?) -> [String: String] {
        if let text = value as? String, !text.isEmpty { return ["en": text] }
        var out: [String: String] = [:]
        for case let (key, text as String) in (value as? [String: Any]) ?? [:] where !text.isEmpty {
            out[key == "zh-Hans" ? "zh" : key] = text
        }
        return out
    }
}
