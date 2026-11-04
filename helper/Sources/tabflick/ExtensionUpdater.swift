import CryptoKit
import Foundation

// 扩展跟着 app 自动更新（2026-11-04 用户要的：扩展没上架，靠「加载已解压」装，原来每次更新都要
// 下载 zip、覆盖文件夹、点 ↻）。
//
// app 包里带一份扩展（`Contents/Resources/Extension`，build-app.sh 放进去）。连上的扩展比它旧时，
// 找到这个扩展是从哪个文件夹加载的，把那个文件夹换成新文件，再告诉扩展重载自己 —— 解压加载的
// 扩展重载时从磁盘重读，新加的权限直接生效（Chrome for Testing 148 实测）。老扩展不认这条消息，
// 要用户点一次 ↻，之后的更新都是自动的。
//
// 找文件夹靠扩展 ID：解压加载的扩展，ID 是文件夹真实路径算出来的（`ExtensionFolder.id(forPath:)`），
// 扩展握手时报自己的 ID。先比固定目录（「安装扩展」让用户从这里装），再比上次找到的，都不是才用
// Spotlight 搜所有 manifest.json 所在的目录逐个算。
//
// 不往 manifest 里加 key 固定 ID：加了所有人的 ID 都要变一次，扩展的 storage.local 跟着换一份，
// 里面的 Profile 标识（「最近关闭」、置顶按它分账）就丢了。

// MARK: - 纯逻辑（checks/extension-folder-check.swift 校验）

enum ExtensionFolder {
    static let extensionName = "TabFlick Bridge"

    /// Chrome 给解压加载的扩展算的 ID：文件夹**真实路径**（符号链接解开，`/tmp` → `/private/tmp`）的
    /// UTF-8 做 SHA-256，取前 16 字节，每个十六进制位 0–f 换成字母 a–p。
    nonisolated static func id(forPath realPath: String) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in SHA256.hash(data: Data(realPath.utf8)).prefix(16) {
            scalars.append(UnicodeScalar(UInt8(97) + (byte >> 4)))
            scalars.append(UnicodeScalar(UInt8(97) + (byte & 0x0f)))
        }
        return String(scalars)
    }

    /// 真实路径（Chrome 按它算 ID）。不用 `URL.resolvingSymlinksInPath`：它会把 `/private/tmp` 反写回 `/tmp`。
    nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// a 是否比 b 新（按数字逐段比，缺位补 0）。
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    enum Decision: Equatable {
        /// 比 app 带的旧，换
        case write
        /// 已经是 app 带的这一版（换过了，扩展还没重载）
        case current
        /// 不动，原因写日志
        case skip(String)
    }

    /// 动不动这个文件夹。拿不准就不动：动错了是改了用户别的东西。
    /// - manifest 读不到、名字不是 TabFlick Bridge：不是我们的扩展
    /// - 在 git 仓库里、或带 tests 目录：开发用的源码目录（发布的 zip 和 app 里那份都不带 tests），换了是在改源码
    /// - 比 app 带的还新：手动装了更新的，不降级
    nonisolated static func decide(manifestName: String?, folderVersion: String?, bundledVersion: String,
                                   inGitRepo: Bool, hasTests: Bool) -> Decision {
        // 读不到多半是「下载」「文稿」这类目录没给访问权限（拒过一次系统就不再问）
        guard manifestName != nil, let folderVersion else { return .skip("manifest unreadable") }
        guard manifestName == extensionName else { return .skip("not \(extensionName)") }
        if inGitRepo || hasTests { return .skip("developer checkout") }
        if isNewer(bundledVersion, than: folderVersion) { return .write }
        if isNewer(folderVersion, than: bundledVersion) { return .skip("newer than bundled (\(folderVersion))") }
        return .current
    }

    nonisolated static func manifest(at folder: URL) -> (name: String?, version: String?)? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["name"] as? String, object["version"] as? String)
    }

    nonisolated static func isInGitRepo(_ folder: URL) -> Bool {
        var dir = folder.standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }

    /// 把 source 里的文件逐个换进 target，返回换了几个。每个先写临时文件再 rename，manifest.json 最后换：
    /// Chrome 恰好这时启动、读到一半，最多是旧 manifest 配几个新文件，不会读到半截文件。
    /// target 里多出来的文件不删 —— manifest 不引用就不会被加载，删错了是删用户的东西。
    @discardableResult
    nonisolated static func copyContents(from source: URL, to target: URL) throws -> Int {
        let fm = FileManager.default
        let root = source.standardizedFileURL.path
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            files.append(String(path.dropFirst(root.count + 1)))
        }
        guard files.contains("manifest.json") else { throw CocoaError(.fileReadNoSuchFile) }
        files.sort { a, b in a == "manifest.json" ? false : (b == "manifest.json" ? true : a < b) }
        for relative in files {
            let destination = target.appendingPathComponent(relative)
            let directory = destination.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tabflick-new")
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: source.appendingPathComponent(relative), to: temporary)
            if rename(temporary.path, destination.path) != 0 {
                let code = errno
                try? fm.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        return files.count
    }

    /// 用 Spotlight 找所有 manifest.json，所在目录的真实路径算出来等于 id 的就是。只算路径不读文件，
    /// 搜「下载」「文稿」这些受保护的目录也不会弹授权框。Spotlight 关了、目录没被索引就找不到。
    nonisolated static func locate(id: String, timeout: TimeInterval = 15) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "kMDItemFSName == 'manifest.json'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        for chunk in output.split(separator: 0) {
            guard let path = String(data: Data(chunk), encoding: .utf8) else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            if let real = realPath(directory), self.id(forPath: real) == id {
                return URL(fileURLWithPath: real, isDirectory: true)
            }
        }
        return nil
    }
}

// MARK: - 更新

@MainActor
final class ExtensionUpdater {
    /// app 包里那份扩展。`swift run` 的开发版没有，整个功能不工作。
    let bundled: URL?
    let bundledVersion: String?
    /// 「安装扩展」让用户从这里装的固定目录，跟着 app 带的版本走。
    let managed: URL
    /// 换好文件之后调，MRUController 据此通知对应的连接重载。
    var onFilesUpdated: ((_ extensionID: String, _ version: String) -> Void)?
    /// 这次运行里已经换成 app 带的那一版的扩展（ID → 文件夹）。老扩展要用户点一次 ↻，提示据此改说法。
    private(set) var updated: [String: URL] = [:]

    private let queue = DispatchQueue(label: "com.lifedever.TabFlick.extension-files", qos: .utility)
    /// 这次运行里不再处理的（找不到、不能动、写失败），免得每次重连都搜一遍 Spotlight。
    private var settled: Set<String> = []
    private var inFlight: Set<String> = []
    /// 上次找到的文件夹（ID → 路径），下次启动先比它。
    private static let foldersKey = "extensionFolders"

    init(bundle: Bundle = .main) {
        let candidate = bundle.resourceURL?.appendingPathComponent("Extension", isDirectory: true)
        if let candidate, let version = ExtensionFolder.manifest(at: candidate)?.version {
            bundled = candidate
            bundledVersion = version
        } else {
            bundled = nil
            bundledVersion = nil
        }
        managed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabFlick/TabFlick Bridge", isDirectory: true)
    }

    var isAvailable: Bool { bundled != nil }

    /// 固定目录同步成 app 带的那份（启动时、「安装扩展」前）。回调在主线程，失败给 nil。
    func prepareManaged(_ completion: ((URL?) -> Void)? = nil) {
        guard let bundled, let bundledVersion else {
            completion?(nil)
            return
        }
        let managed = self.managed
        queue.async {
            var ok = true
            if ExtensionFolder.manifest(at: managed)?.version != bundledVersion {
                do {
                    let count = try ExtensionFolder.copyContents(from: bundled, to: managed)
                    log("🧩 extension folder → v\(bundledVersion) (\(count) files)")
                } catch {
                    ok = false
                    log("🧩 extension folder sync failed: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { completion?(ok ? managed : nil) }
        }
    }

    /// 握手时报上来的扩展比 app 带的旧：找到它加载的文件夹、换成新文件、通知它重载。
    func extensionConnected(id: String, version: String) {
        guard let bundled, let bundledVersion, ExtensionFolder.isNewer(bundledVersion, than: version) else { return }
        // 换过了：老扩展没重载，重连上来还是旧版本，再提醒一次（新扩展收到就重载，老扩展忽略）
        if updated[id] != nil {
            onFilesUpdated?(id, bundledVersion)
            return
        }
        guard !settled.contains(id), !inFlight.contains(id) else { return }
        inFlight.insert(id)
        let managed = self.managed
        let cached = (UserDefaults.standard.dictionary(forKey: Self.foldersKey) as? [String: String])?[id]
        queue.async {
            let outcome = Self.update(id: id, bundled: bundled, bundledVersion: bundledVersion,
                                      candidates: [managed.path, cached].compactMap { $0 })
            DispatchQueue.main.async { [weak self] in self?.finish(id: id, version: bundledVersion, outcome: outcome) }
        }
    }

    private enum Outcome {
        case updated(URL, files: Int)
        case current(URL)
        case skipped(URL, String)
        case notFound
        case failed(URL, String)
    }

    nonisolated private static func update(id: String, bundled: URL, bundledVersion: String,
                                           candidates: [String]) -> Outcome {
        let known = candidates.lazy.compactMap { ExtensionFolder.realPath($0) }
            .first { ExtensionFolder.id(forPath: $0) == id }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let folder = known ?? ExtensionFolder.locate(id: id) else { return .notFound }
        let info = ExtensionFolder.manifest(at: folder)
        let decision = ExtensionFolder.decide(
            manifestName: info?.name, folderVersion: info?.version, bundledVersion: bundledVersion,
            inGitRepo: ExtensionFolder.isInGitRepo(folder),
            hasTests: FileManager.default.fileExists(atPath: folder.appendingPathComponent("tests").path))
        switch decision {
        case .write:
            do {
                return .updated(folder, files: try ExtensionFolder.copyContents(from: bundled, to: folder))
            } catch {
                return .failed(folder, error.localizedDescription)
            }
        case .current:
            return .current(folder)
        case .skip(let reason):
            return .skipped(folder, reason)
        }
    }

    private func finish(id: String, version: String, outcome: Outcome) {
        inFlight.remove(id)
        let tag = id.prefix(6)
        switch outcome {
        case .updated(let folder, let files):
            log("🧩 extension \(tag) at \(folder.path) → v\(version) (\(files) files)")
            remember(id, folder)
            updated[id] = folder
            onFilesUpdated?(id, version)
        case .current(let folder):
            log("🧩 extension \(tag) at \(folder.path) already v\(version), waiting for reload")
            remember(id, folder)
            updated[id] = folder
            onFilesUpdated?(id, version)
        case .skipped(let folder, let reason):
            log("🧩 extension \(tag) at \(folder.path) left alone: \(reason)")
            settled.insert(id)
        case .notFound:
            log("🧩 extension \(tag): folder not found")
            settled.insert(id)
        case .failed(let folder, let message):
            log("🧩 extension \(tag) at \(folder.path) update failed: \(message)")
            settled.insert(id)
        }
    }

    private func remember(_ id: String, _ folder: URL) {
        var folders = UserDefaults.standard.dictionary(forKey: Self.foldersKey) as? [String: String] ?? [:]
        // 只有找到过的文件夹才记，一个装扩展的位置一条，不用截
        folders[id] = folder.path
        UserDefaults.standard.set(folders, forKey: Self.foldersKey)
    }
}
