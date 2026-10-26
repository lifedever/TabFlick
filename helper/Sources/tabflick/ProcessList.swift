import AppKit
import Darwin

/// 搜索面板「结束进程…」（2026-10-26 用户要的，照 Raycast 的 Kill Process）：列出你自己的进程，
/// 选中结束。三块：
/// - `ProcessSampler`：libproc 直接读（不起 ps / lsof 子进程），只在列表开着时每 2 秒读一次，后台队列。
///   本机 765 个进程：基本信息 4ms、监听端口 3ms、命令行 8ms（只读新出现的，之后走缓存）。
/// - `ProcessCatalog`：纯函数。按 App 归组、藏掉系统组件、排序（checks/process-catalog-check.swift 校验）。
/// - `ProcessEnder`：动手前再核对一次身份（pid + 启动时间），对不上不动手。
///
/// 只列当前用户的进程（用户定的）：root 和系统账户的进程这个 App 结束不了，列出来只是噪音。
/// 当前用户名下的系统组件（/System、/usr/libexec 下面的 Dock、cfprefsd、loginwindow……）也不列：
/// 结束了要么白干（系统马上拉起来），要么出事（loginwindow 退出 = 注销）。

/// 一次采样里的一个进程。
struct ProcessSample: Equatable {
    let pid: Int32
    /// 启动时刻（微秒）：和 pid 一起认身份，pid 会被新进程复用。
    let start: UInt64
    let name: String
    /// 可执行文件路径；读不到是空串（这种不列：没法核对身份，也看不出是什么）。
    let path: String
    var commandLine: String
    /// 占一个核的百分之几（多线程可以超过 100），和活动监视器一个口径。
    var cpu: Double
    /// 实际占用的内存（`ri_phys_footprint`，活动监视器「内存」那一列）。
    var memory: UInt64
    /// 在监听的 TCP 端口。
    var ports: [UInt16]
}

/// 列表里的一行：一个 App（连同它包里的所有进程），或者一个单独的进程。
struct ProcessItem: Equatable {
    let id: String
    /// App：bundle 路径；进程：可执行文件路径。
    let path: String
    /// App 是主进程的 pid。
    let pid: Int32
    let start: UInt64
    let name: String
    /// 只有单独的进程有。
    let commandLine: String
    let bundleID: String?
    var cpu: Double
    var memory: UInt64
    var ports: [UInt16]
    /// App 名下有几个进程（单独的进程是 1）。
    var memberCount: Int
    /// 是 App（回车走正常退出，不用确认）还是单独的进程（回车要按两次）。
    let isApp: Bool
}

/// 正在运行的 App（主线程从 NSWorkspace 读好再交给后台）。
struct RunningAppInfo: Equatable {
    let pid: Int32
    /// 标准化的 bundle 路径，不带结尾的斜杠。
    let bundlePath: String
    let name: String
    let bundleID: String?
}

enum ProcessSort: String, CaseIterable {
    case cpu, memory

    var label: String {
        switch self {
        case .cpu:    return "CPU"
        case .memory: return L10n.t("内存", "Memory")
        }
    }
}

enum ProcessCatalog {
    /// 系统组件所在的目录：这些下面的进程不列。/usr/bin、/bin 下面的（python3、zsh、ssh）是你自己跑的，照列。
    nonisolated static let hiddenPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// 这个路径是不是系统组件。系统自带的 App（/System/Applications，Safari 在
    /// /System/Volumes/Preboot/Cryptexes/App/System/Applications）不算，照列。
    nonisolated static func isSystem(_ path: String) -> Bool {
        guard hiddenPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        return !path.contains("/System/Applications/")
    }

    /// 两次采样之间用了多少 CPU：占一个核的百分之几。时间倒退（pid 被复用、采样错乱）按 0 算。
    nonisolated static func cpuPercent(previousNs: UInt64, currentNs: UInt64, elapsedNs: UInt64) -> Double {
        guard elapsedNs > 0, currentNs >= previousNs else { return 0 }
        return Double(currentNs - previousNs) / Double(elapsedNs) * 100
    }

    /// 归组：可执行文件在哪个正在运行的 App 的包里，就算那个 App 的（Chrome 的几十个 Helper 归 Chrome）；
    /// 嵌套的取最外层。系统组件、TabFlick 自己、launchd 不列；读不到路径的不列。
    /// 返回列表里的行，和每个 App 名下的进程（搜进程名、命令行时用：App 没命中但它名下某个进程命中，
    /// 那个进程单独列出来）。
    nonisolated static func build(_ samples: [ProcessSample], apps: [RunningAppInfo], ownPID: Int32)
        -> (items: [ProcessItem], members: [String: [ProcessItem]]) {
        // 外层的在前：嵌套时先命中最外层
        let outerFirst = apps.filter { !$0.bundlePath.isEmpty }.sorted { $0.bundlePath.count < $1.bundlePath.count }
        var byPath: [String: RunningAppInfo] = [:]
        for app in outerFirst where byPath[app.bundlePath] == nil { byPath[app.bundlePath] = app }
        var grouped: [String: [ProcessSample]] = [:]
        var standalone: [ProcessSample] = []
        for sample in samples where sample.pid > 1 && sample.pid != ownPID && !sample.path.isEmpty {
            if let app = owner(of: sample.path, in: byPath) {
                grouped[app.bundlePath, default: []].append(sample)
            } else if !isSystem(sample.path) {
                standalone.append(sample)
            }
        }
        var items: [ProcessItem] = []
        var members: [String: [ProcessItem]] = [:]
        var seenBundles = Set<String>()
        for app in outerFirst where !seenBundles.contains(app.bundlePath) {
            seenBundles.insert(app.bundlePath)
            guard app.pid != ownPID, !isSystem(app.bundlePath),
                  let group = grouped[app.bundlePath], !group.isEmpty else { continue }
            let main = group.first { $0.pid == app.pid }
            let id = "app:" + app.bundlePath
            items.append(ProcessItem(id: id, path: app.bundlePath, pid: app.pid, start: main?.start ?? 0,
                                     name: app.name, commandLine: "", bundleID: app.bundleID,
                                     cpu: group.reduce(0) { $0 + $1.cpu },
                                     memory: group.reduce(0) { $0 + $1.memory },
                                     ports: Array(Set(group.flatMap(\.ports))).sorted(),
                                     memberCount: group.count, isApp: true))
            members[id] = group.map(item(for:))
        }
        items += standalone.map(item(for:))
        return (items, members)
    }

    /// 路径落在哪个正在运行的 App 的包里：从前往后找路径里每一个「.app/」，前面那一截是不是某个 App
    /// 的 bundle 路径 —— 先碰到的就是最外层。按路径长度查表，不拿每个 App 去比前缀（几百个进程 ×
    /// 几十个 App 的前缀比较实测 30ms，这样不到 1ms）。
    nonisolated static func owner(of path: String, in apps: [String: RunningAppInfo]) -> RunningAppInfo? {
        var from = path.startIndex
        while let found = path.range(of: ".app/", range: from..<path.endIndex) {
            if let app = apps[String(path[..<found.lowerBound]) + ".app"] { return app }
            from = found.upperBound
        }
        return nil
    }

    /// 进程叫什么：先看启动参数里的第一个（`ps` 也是这么显示的：Claude Code 的可执行文件按版本号
    /// 命名，叫「2.1.310」，参数里是「claude」），登录 shell 前面的「-」去掉；没有参数用内核记的名字。
    nonisolated static func displayName(argv0: String?, kernelName: String, path: String) -> String {
        if var first = argv0.map({ ($0 as NSString).lastPathComponent }), !first.isEmpty {
            while first.hasPrefix("-") { first.removeFirst() }
            if !first.isEmpty { return first }
        }
        if !kernelName.isEmpty { return kernelName }
        return (path as NSString).lastPathComponent
    }

    /// 单独一个进程的行。
    nonisolated static func item(for sample: ProcessSample) -> ProcessItem {
        ProcessItem(id: "pid:\(sample.pid):\(sample.start)", path: sample.path, pid: sample.pid, start: sample.start,
                    name: sample.name.isEmpty ? (sample.path as NSString).lastPathComponent : sample.name,
                    commandLine: sample.commandLine, bundleID: nil, cpu: sample.cpu, memory: sample.memory,
                    ports: Array(Set(sample.ports)).sorted(), memberCount: 1, isApp: false)
    }

    /// 从大到小；一样大的看另一项，再一样按名字。
    nonisolated static func sorted(_ items: [ProcessItem], by sort: ProcessSort) -> [ProcessItem] {
        items.sorted { a, b in
            switch sort {
            case .cpu:
                if a.cpu != b.cpu { return a.cpu > b.cpu }
                if a.memory != b.memory { return a.memory > b.memory }
            case .memory:
                if a.memory != b.memory { return a.memory > b.memory }
                if a.cpu != b.cpu { return a.cpu > b.cpu }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 命令行：参数用空格连起来，家目录写成 ~，太长截断（Chrome 的 Helper 一行几 KB）。
    nonisolated static func commandLine(_ arguments: [String], home: String) -> String {
        let shown = arguments.map { arg -> String in
            guard !home.isEmpty else { return arg }
            if arg == home { return "~" }
            return arg.hasPrefix(home + "/") ? "~" + arg.dropFirst(home.count) : arg
        }
        let joined = shown.joined(separator: " ")
        return joined.count > 400 ? String(joined.prefix(399)) + "…" : joined
    }

    /// 匹配用的文字（标题之外的那一栏）：bundle id、可执行文件名、命令行、端口（写成 :3000）、pid。
    nonisolated static func searchText(_ item: ProcessItem) -> String {
        ([item.bundleID, (item.path as NSString).lastPathComponent, item.commandLine].compactMap { $0 }
            + item.ports.map { ":\($0)" } + ["pid \(item.pid)"]).joined(separator: " ")
    }

    nonisolated static func formatMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    nonisolated static func formatCPU(_ cpu: Double) -> String {
        String(format: cpu >= 100 ? "%.0f%%" : "%.1f%%", cpu)
    }
}

/// 采样（后台队列上调）。记着上一次每个进程的 CPU 时间，算两次之间的占用；命令行按进程缓存。
final class ProcessSampler: @unchecked Sendable {
    private var previous: [String: UInt64] = [:]
    private var previousTime: UInt64 = 0
    /// 命令行和显示名，按进程缓存（参数不会变）。
    private var commandLines: [String: (command: String, name: String)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()
    private let uid = getuid()
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// 新开一轮：丢掉上一轮的基准（几分钟前的基准会把这段时间的平均当成现在的占用）。
    func reset() {
        previous = [:]
        previousTime = 0
    }

    /// 读一遍当前用户的全部进程。第一次（或 reset 之后）CPU 都是 0。
    func sample() -> [ProcessSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTime == 0 ? 0 : now - previousTime
        var next: [String: UInt64] = [:]
        var out: [ProcessSample] = []
        let owned = Self.allPIDs().compactMap { pid -> (Int32, proc_bsdinfo)? in
            guard pid > 0, let info = Self.bsdInfo(pid), info.pbi_uid == uid else { return nil }
            return (pid, info)
        }
        let ports = listeningPorts(owned.map(\.0))
        for (pid, info) in owned {
            let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
            let key = "\(pid):\(start)"
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            guard ok else { continue }
            // Apple 芯片上 rusage 的 CPU 时间是 mach 时钟的刻度，不是纳秒（timebase 125/3），要换算
            let cpuNs = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            next[key] = cpuNs
            let cpu = previous[key].map {
                ProcessCatalog.cpuPercent(previousNs: $0, currentNs: cpuNs, elapsedNs: elapsed)
            } ?? 0
            let path = Self.path(pid)
            let described: (command: String, name: String)
            if let cached = commandLines[key] {
                described = cached
            } else {
                let arguments = Self.arguments(pid)
                let kernelName = Self.string(from: info.pbi_name)
                described = (ProcessCatalog.commandLine(arguments, home: home),
                             ProcessCatalog.displayName(argv0: arguments.first,
                                                        kernelName: kernelName.isEmpty ? Self.string(from: info.pbi_comm) : kernelName,
                                                        path: path))
                commandLines[key] = described
            }
            out.append(ProcessSample(pid: pid, start: start, name: described.name,
                                     path: path, commandLine: described.command, cpu: cpu,
                                     memory: usage.ri_phys_footprint, ports: ports[pid] ?? []))
        }
        // 退出了的进程，命令行缓存跟着丢
        commandLines = commandLines.filter { next[$0.key] != nil }
        previous = next
        previousTime = now
        return out
    }

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func path(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 命令行参数（KERN_PROCARGS2：argc，然后可执行文件路径，然后各个参数）。读不到是空。
    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // 可执行文件路径
        while index < size, buffer[index] == 0 { index += 1 }
        var out: [String] = []
        while out.count < Int(argc), index < size {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            out.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return out
    }

    /// 当前用户的进程各自在监听哪些 TCP 端口。只认 LISTEN 的那一端：连到这个端口的客户端不算，
    /// 按端口结束进程时不能把客户端一起带走。
    private func listeningPorts(_ pids: [Int32]) -> [Int32: [UInt16]] {
        var out: [Int32: [UInt16]] = [:]
        for pid in pids {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            guard used > 0 else { continue }
            for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                      socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socket.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                if port != 0, !(out[pid]?.contains(port) ?? false) { out[pid, default: []].append(port) }
            }
        }
        return out
    }
}

/// 列表开着时定时采样，结果交回主线程。面板关了、退出列表就停（性能第一：没在看就一点不花）。
@MainActor
final class ProcessMonitor {
    private let sampler = ProcessSampler()
    private let queue = DispatchQueue(label: "TabFlick.processes", qos: .userInitiated)
    private var timer: Timer?
    /// 每开一轮加一：上一轮还在路上的结果回来时丢掉。
    private var generation = 0
    var onUpdate: (([ProcessItem], [String: [ProcessItem]]) -> Void)?

    var isRunning: Bool { timer != nil }

    /// 开始：先连读两次（隔 0.3 秒）算出第一份 CPU 再交出去，之后每 2 秒一次。
    func start() {
        stop()
        generation += 1
        let current = generation
        let apps = Self.runningApps()
        let sampler = self.sampler
        let own = getpid()
        queue.async {
            sampler.reset()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.3)
            let built = ProcessCatalog.build(sampler.sample(), apps: apps, ownPID: own)
            Task { @MainActor in
                guard current == self.generation else { return }
                self.onUpdate?(built.items, built.members)
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let current = generation
        let apps = Self.runningApps()
        let sampler = self.sampler
        let own = getpid()
        queue.async {
            let built = ProcessCatalog.build(sampler.sample(), apps: apps, ownPID: own)
            Task { @MainActor in
                guard current == self.generation else { return }
                self.onUpdate?(built.items, built.members)
            }
        }
    }

    /// 普通 App 和菜单栏 App（有 bundle 的）。
    private static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, let url = app.bundleURL else { return nil }
            var path = url.standardizedFileURL.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return RunningAppInfo(pid: app.processIdentifier, bundlePath: path,
                                  name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                  bundleID: app.bundleIdentifier)
        }
    }
}

/// 结束进程。动手前再核对一次身份：列表是几秒前读的，那个 pid 可能已经退了、又被别的进程用上。
enum ProcessEnder {
    enum Outcome: Equatable {
        /// 信号发出去了 / App 答应退出了（真退没退等下一次采样）
        case sent
        /// 已经不在了（或者 pid 已经换了人）
        case gone
        /// 没有权限
        case denied
        case failed
    }

    /// App 走正常退出（有没存的文档它自己会问），强制是 forceTerminate；单独的进程发 SIGTERM，强制是 SIGKILL。
    @MainActor static func end(_ item: ProcessItem, force: Bool) -> Outcome {
        if item.isApp {
            guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
                  app.bundleURL?.standardizedFileURL.path == item.path else { return .gone }
            let accepted = force ? app.forceTerminate() : app.terminate()
            log("💀 \(force ? "force-quit" : "quit") app \(item.name) (pid \(item.pid)) → \(accepted)")
            return accepted ? .sent : .failed
        }
        guard let info = ProcessSampler.bsdInfo(item.pid) else { return .gone }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        guard start == item.start, info.pbi_uid == getuid() else { return .gone }
        let result = kill(item.pid, force ? SIGKILL : SIGTERM)
        let error = errno
        log("💀 \(force ? "SIGKILL" : "SIGTERM") \(item.name) (pid \(item.pid)) → \(result == 0 ? "ok" : "errno \(error)")")
        if result == 0 { return .sent }
        switch error {
        case ESRCH: return .gone
        case EPERM: return .denied
        default:    return .failed
        }
    }

    /// 等它退出：每 0.2 秒看一次，退了回调 true，到时间还活着回调 false。
    @MainActor static func waitForExit(_ item: ProcessItem, timeout: TimeInterval,
                                       completion: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !isAlive(item) { completion(true); return }
            if Date() >= deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { poll() } }
        }
        poll()
    }

    /// 还活着没有（同一个 pid + 启动时间）。App 看 NSRunningApplication。
    @MainActor static func isAlive(_ item: ProcessItem) -> Bool {
        if item.isApp {
            guard let app = NSRunningApplication(processIdentifier: item.pid) else { return false }
            return !app.isTerminated
        }
        guard let info = ProcessSampler.bsdInfo(item.pid) else { return false }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec) == item.start
    }
}
