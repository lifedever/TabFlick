import Foundation

/// 日志同时写 stdout 和文件。文件每次启动截断，保证读到的永远是本次运行。
///
/// 放 macOS 标准日志目录，不要用仓库路径 —— 那样只对开发者本人的机器成立。
let kLogPath: String = {
    let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TabFlick", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("tabflick.log").path
}()

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private let logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: kLogPath, contents: nil)
    return FileHandle(forWritingAtPath: kLogPath)
}()

private let logQueue = DispatchQueue(label: "com.tabflick.log")

/// 当前跑的这个二进制是什么时候编译的。
///
/// 排查「改了代码没生效」时第一眼要看的东西 —— 忘记重启 helper 而对着旧进程
/// 反复试，已经浪费过一轮了。日志第一行写死它，一眼就能判断新鲜度。
func binaryBuildTime() -> String {
    let path = CommandLine.arguments.first ?? ""
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date else { return "未知" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: date)
}

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)"
    print(line)
    fflush(stdout)
    // 写文件放到自己的队列上：event tap 回调链路上不能有同步磁盘 IO
    logQueue.async {
        if let data = (line + "\n").data(using: .utf8) {
            logHandle?.write(data)
        }
    }
}
