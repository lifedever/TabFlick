import AppKit
import CryptoKit

/// 插件商店（2026-11-06）：从 TabFlick 仓库的 plugins/index.json 列可安装的插件，装、更新、卸载。
///
/// 从哪拉：先 raw.githubusercontent.com（推了马上能拉到），拉不到再 jsDelivr（国内通常更快，但按分支缓存，
/// 推完最长 12 小时才更新）。**一次安装的 index 和文件必须来自同一个地方**：两边版本可能不一样，混着拉 sha256 对不上。
/// 开发时用 UserDefaults `pluginStoreBase` 指到本机仓库（file:///…/TabFlick/plugins/），没推也能走完整个流程。
///
/// 安装：每个文件核对大小和 sha256 → 全部写进临时目录 → 校验 manifest（id、版本要和目录一致）→ 整个换进
/// Plugins/<id>（原来的是软链接也只删链接）→ 注册表重新加载，不用重启。任何一步失败，原来装着的不受影响。
/// 卸载只删插件代码，插件自己存的数据（PluginData/<id>.json：自选、收藏的城市）留着，重装回来还在。
@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    enum Status: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    @Published private(set) var entries: [StoreEntry] = []
    @Published private(set) var status: Status = .idle
    /// 正在装 / 更新的插件
    @Published private(set) var busy: Set<String> = []
    /// 这份目录是从哪拉的（装的时候文件也从这里拉）
    private var source: URL?

    static let overrideKey = "pluginStoreBase"
    static let defaultBases = [
        URL(string: "https://raw.githubusercontent.com/lifedever/TabFlick/main/plugins/")!,
        URL(string: "https://cdn.jsdelivr.net/gh/lifedever/TabFlick@main/plugins/")!,
    ]

    static var bases: [URL] {
        if let text = UserDefaults.standard.string(forKey: overrideKey), !text.isEmpty,
           let url = URL(string: text.hasSuffix("/") ? text : text + "/") {
            return [url]
        }
        return defaultBases
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - 目录

    /// 拉目录。10 分钟内拉过就不再拉（打开插件页时调；「刷新」按钮 force）。
    func refresh(force: Bool = false) {
        if status == .loading { return }
        if !force, case .loaded(let at) = status, Date().timeIntervalSince(at) < 600 { return }
        status = .loading
        Task {
            var lastError = L10n.t("取不到插件列表", "Couldn't load the plugin list")
            for base in Self.bases {
                do {
                    let data = try await fetch(base.appendingPathComponent("index.json"), limit: 1 << 20)
                    guard let parsed = StoreIndex.parse(data) else {
                        lastError = L10n.t("插件列表格式不对", "The plugin list is malformed")
                        continue
                    }
                    entries = parsed
                    source = base
                    status = .loaded(Date())
                    log("🧩 store: \(parsed.count) plugin(s) from \(base.host ?? base.path)")
                    return
                } catch {
                    lastError = error.localizedDescription
                    log("🧩 store: \(base.absoluteString) failed: \(error.localizedDescription)")
                }
            }
            status = .failed(lastError)
        }
    }

    func entry(_ id: String) -> StoreEntry? { entries.first { $0.id == id } }

    /// 已装的插件有没有新版本（目录里的比装着的新）。
    func update(for plugin: Plugin) -> StoreEntry? {
        guard case .official(let installed) = plugin.origin, let entry = entry(plugin.id),
              ExtensionFolder.isNewer(entry.version, than: installed) else { return nil }
        return entry
    }

    /// 这个 app 版本装不了（插件要求更新的 TabFlick）。开发版没有版本号，不拦。
    static func needsNewerApp(_ entry: StoreEntry) -> String? {
        guard let need = entry.minAppVersion,
              let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              ExtensionFolder.isNewer(need, than: app) else { return nil }
        return need
    }

    // MARK: - 装、更新、卸载

    func install(_ entry: StoreEntry) {
        guard !busy.contains(entry.id), let source else { return }
        let name = PluginManifest.pick(entry.names, language: L10n.current.rawValue) ?? entry.id
        let updating = PluginRegistry.shared.plugin(entry.id) != nil
        busy.insert(entry.id)
        Task {
            defer { busy.remove(entry.id) }
            do {
                try await download(entry, from: source)
                PluginRegistry.shared.reloadInstalled()
                log("🧩 store: \(updating ? "updated" : "installed") \(entry.id) \(entry.version)")
                Toast.show(updating ? L10n.t("已更新「\(name)」", "Updated “\(name)”") : L10n.t("已安装「\(name)」", "Installed “\(name)”"),
                           detail: updating ? entry.version : nil)
            } catch {
                log("🧩 store: install \(entry.id) failed: \(error.localizedDescription)")
                Toast.show(L10n.t("没能安装「\(name)」", "Couldn't install “\(name)”"),
                           detail: error.localizedDescription, kind: .failure)
            }
        }
    }

    /// 插件存过数据没有（卸载时据此问要不要留）。
    static func hasData(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: PluginPaths.dataFile(id).path)
    }

    /// 卸载。keepData = 留着插件存的数据（自选、收藏的城市），重装回来还在；否则一起删（用户 2026-11-06：卸载时问一下）。
    func uninstall(_ plugin: Plugin, keepData: Bool) {
        guard case .official = plugin.origin else { return }
        let target = PluginPaths.installed.appendingPathComponent(plugin.id, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: target)
            if !keepData { try? FileManager.default.removeItem(at: PluginPaths.dataFile(plugin.id)) }
            PluginRegistry.shared.reloadInstalled()
            log("🧩 store: uninstalled \(plugin.id)\(keepData ? "" : " and its data")")
            Toast.show(L10n.t("已卸载「\(plugin.title)」", "Removed “\(plugin.title)”"))
        } catch {
            Toast.show(L10n.t("没能卸载「\(plugin.title)」", "Couldn't remove “\(plugin.title)”"),
                       detail: error.localizedDescription, kind: .failure)
        }
    }

    enum InstallError: LocalizedError {
        case checksum(String)
        case badManifest
        var errorDescription: String? {
            switch self {
            case .checksum(let path): return L10n.t("文件校验没通过：\(path)", "File check failed: \(path)")
            case .badManifest: return L10n.t("插件信息不对", "The plugin's manifest doesn't match")
            }
        }
    }

    /// 下载到临时目录、逐个核对、校验 manifest，再整个换进 Plugins/<id>。
    private func download(_ entry: StoreEntry, from base: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PluginPaths.installed, withIntermediateDirectories: true)
        let staging = PluginPaths.installed.appendingPathComponent(".staging-\(entry.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for file in entry.files {
            let data = try await fetch(base.appendingPathComponent(entry.id).appendingPathComponent(file.path), limit: file.size)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == file.size, digest == file.sha256 else { throw InstallError.checksum(file.path) }
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        guard let manifestData = fm.contents(atPath: staging.appendingPathComponent("manifest.json").path),
              case .success(let manifest) = PluginManifest.parse(manifestData),
              manifest.id == entry.id, manifest.version == entry.version,
              fm.fileExists(atPath: staging.appendingPathComponent(manifest.main).path) else { throw InstallError.badManifest }
        let target = PluginPaths.installed.appendingPathComponent(entry.id, isDirectory: true)
        // 原来的（目录或开发时的软链接）先挪开，换进去了再删；换失败挪回来
        let previous = PluginPaths.installed.appendingPathComponent(".previous-\(entry.id)-\(UUID().uuidString)")
        let hadPrevious = (try? fm.attributesOfItem(atPath: target.path)) != nil
        if hadPrevious { try fm.moveItem(at: target, to: previous) }
        do {
            try fm.moveItem(at: staging, to: target)
        } catch {
            if hadPrevious { try? fm.moveItem(at: previous, to: target) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: previous) }
    }

    /// 拉一个文件。file:// 直接读（开发时指到本机仓库）；网络的看状态码。超过 limit 字节当失败。
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            data = body
        }
        guard data.count <= max(limit, 0) else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
