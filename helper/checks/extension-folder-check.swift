// ExtensionFolder 的校验：扩展跟着 app 自动更新时，认文件夹、判断动不动、换文件。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/ExtensionUpdater.swift Sources/tabflick/Log.swift \
//          checks/extension-folder-check.swift -o /tmp/extfoldercheck && CFFIXED_USER_HOME=/tmp/x /tmp/extfoldercheck
//
// 错了都不报错：ID 算错 = 永远找不到文件夹（只是不自动更新）；判断错 = 改了用户的源码目录或降级；
// 换文件错 = 扩展下次加载读到半截文件。期望值手写，ID 那条是 Chrome for Testing 148 实测给的。

import Foundation

@main
struct ExtensionFolderCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { return }
        failures += 1
        print("✗ \(name)\(detail().isEmpty ? "" : "：\(detail())")")
    }

    static func main() {
        // ── ID ──
        check("ID 和 Chrome 算的一样（/private/tmp/tfx-feas/ext → Chrome 实测）",
              ExtensionFolder.id(forPath: "/private/tmp/tfx-feas/ext") == "kjiclmoclpbioaaeicfbogapimdcaclf",
              ExtensionFolder.id(forPath: "/private/tmp/tfx-feas/ext"))
        check("ID 是 32 个 a–p", ExtensionFolder.id(forPath: "/Users/x/中文 目录/TabFlick-Extension")
            .allSatisfy { ("a"..."p").contains($0) } && ExtensionFolder.id(forPath: "/a").count == 32)

        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/tmp/extfoldercheck-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: base)
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // ── 真实路径：/tmp 是符号链接，Chrome 按 /private/tmp 算 ──
        let real = ExtensionFolder.realPath(base.path)
        check("真实路径解开 /tmp", real == "/private" + base.path, real ?? "nil")
        check("不存在的路径给 nil", ExtensionFolder.realPath(base.path + "/nope") == nil)

        // ── 版本 ──
        check("0.21.0 比 0.20.0 新", ExtensionFolder.isNewer("0.21.0", than: "0.20.0"))
        check("0.10.0 比 0.9.0 新（按数字）", ExtensionFolder.isNewer("0.10.0", than: "0.9.0"))
        check("0.20 和 0.20.0 一样", !ExtensionFolder.isNewer("0.20", than: "0.20.0") && !ExtensionFolder.isNewer("0.20.0", than: "0.20"))
        check("旧的不算新", !ExtensionFolder.isNewer("0.19.9", than: "0.20.0"))

        // ── 动不动 ──
        let name = ExtensionFolder.extensionName
        check("旧的换", ExtensionFolder.decide(manifestName: name, folderVersion: "0.20.0", bundledVersion: "0.21.0",
                                              inGitRepo: false, hasTests: false) == .write)
        check("一样的不换、等重载", ExtensionFolder.decide(manifestName: name, folderVersion: "0.21", bundledVersion: "0.21.0",
                                                    inGitRepo: false, hasTests: false) == .current)
        if case .skip = ExtensionFolder.decide(manifestName: name, folderVersion: "0.22.0", bundledVersion: "0.21.0",
                                              inGitRepo: false, hasTests: false) {} else { check("比 app 带的新不降级", false) }
        if case .skip = ExtensionFolder.decide(manifestName: "Other", folderVersion: "0.1.0", bundledVersion: "0.21.0",
                                              inGitRepo: false, hasTests: false) {} else { check("别的扩展不动", false) }
        if case .skip = ExtensionFolder.decide(manifestName: nil, folderVersion: nil, bundledVersion: "0.21.0",
                                              inGitRepo: false, hasTests: false) {} else { check("读不到 manifest 不动", false) }
        if case .skip = ExtensionFolder.decide(manifestName: name, folderVersion: "0.20.0", bundledVersion: "0.21.0",
                                              inGitRepo: true, hasTests: false) {} else { check("git 仓库里的不动", false) }
        if case .skip = ExtensionFolder.decide(manifestName: name, folderVersion: "0.20.0", bundledVersion: "0.21.0",
                                              inGitRepo: false, hasTests: true) {} else { check("带 tests 的源码目录不动", false) }

        // ── git 仓库 ──
        let repo = base.appendingPathComponent("repo/extension", isDirectory: true)
        try! fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try! fm.createDirectory(at: base.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        check("上层有 .git 算在仓库里", ExtensionFolder.isInGitRepo(repo))
        let plain = base.appendingPathComponent("plain", isDirectory: true)
        try! fm.createDirectory(at: plain, withIntermediateDirectories: true)
        check("没有 .git 不算", !ExtensionFolder.isInGitRepo(plain))

        // ── 换文件 ──
        let source = base.appendingPathComponent("src", isDirectory: true)
        let target = base.appendingPathComponent("dst", isDirectory: true)
        try! fm.createDirectory(at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: target, withIntermediateDirectories: true)
        func write(_ url: URL, _ text: String) { try! text.write(to: url, atomically: true, encoding: .utf8) }
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        write(source.appendingPathComponent("manifest.json"), #"{"name":"TabFlick Bridge","version":"0.21.0"}"#)
        write(source.appendingPathComponent("background.js"), "new")
        write(source.appendingPathComponent("icons/icon.svg"), "svg")
        write(source.appendingPathComponent(".DS_Store"), "junk")
        write(target.appendingPathComponent("manifest.json"), #"{"name":"TabFlick Bridge","version":"0.20.0"}"#)
        write(target.appendingPathComponent("background.js"), "old")
        write(target.appendingPathComponent("user-notes.txt"), "mine")
        let count = (try? ExtensionFolder.copyContents(from: source, to: target)) ?? -1
        check("换了 3 个文件（不含 .DS_Store）", count == 3, "\(count)")
        check("manifest 换成新的", ExtensionFolder.manifest(at: target)?.version == "0.21.0")
        check("文件内容是新的", read(target.appendingPathComponent("background.js")) == "new")
        check("子目录里的也换了", read(target.appendingPathComponent("icons/icon.svg")) == "svg")
        check("多出来的文件不删", read(target.appendingPathComponent("user-notes.txt")) == "mine")
        check("隐藏文件不拷", !fm.fileExists(atPath: target.appendingPathComponent(".DS_Store").path))
        let leftovers = (try? fm.subpathsOfDirectory(atPath: target.path))?.filter { $0.contains("tabflick-new") } ?? []
        check("没留下临时文件", leftovers.isEmpty, "\(leftovers)")

        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try! fm.createDirectory(at: empty, withIntermediateDirectories: true)
        write(empty.appendingPathComponent("a.js"), "x")
        let untouched = base.appendingPathComponent("untouched", isDirectory: true)
        try! fm.createDirectory(at: untouched, withIntermediateDirectories: true)
        check("来源没有 manifest 就不动", (try? ExtensionFolder.copyContents(from: empty, to: untouched)) == nil
              && (try? fm.contentsOfDirectory(atPath: untouched.path))?.isEmpty == true)

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        if failures > 0 { fatalError("ExtensionFolder 校验未通过") }
    }
}
