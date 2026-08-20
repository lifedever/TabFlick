import AppKit
import Foundation
import Network

/// 只监听回环地址的极简 WebSocket 服务端。
///
/// 用 Network.framework 内置的 `NWProtocolWebSocket` —— 它自己处理 HTTP upgrade
/// 握手和帧编解码，我们不用手写协议。所有收发都走 completion handler，
/// 没有任何阻塞式 syscall，因此不会钉住线程。
///
/// 多客户端：每个连接一个 UUID。任何 Chromium 浏览器装了扩展都会连上来，
/// 浏览器之间是物理隔离的主体 —— 谁发的消息、命令发给谁，都必须带身份。
/// 连接归属的浏览器通过「对端端口 → lsof 找 pid → 沿父进程链找到
/// NSRunningApplication → bundle id」解析（扩展的网络请求走浏览器的
/// 网络服务子进程，不能直接拿主进程）。解析失败不致命：单浏览器场景
/// 由上层「唯一连接即生效」兜底。
final class WebSocketServer {

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.tabflick.websocket")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    /// 收到文本帧。回调在主线程，带客户端 id。
    var onText: ((Data, UUID) -> Void)?
    /// 新客户端连上。回调在主线程。
    var onClientConnected: ((UUID) -> Void)?
    /// 客户端断开。回调在主线程。
    var onClientDisconnected: ((UUID) -> Void)?
    /// 客户端归属的浏览器解析完成（bundle id）。回调在主线程。
    var onClientIdentified: ((UUID, String) -> Void)?

    init(port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port \(port)")
        }
        self.port = p
    }

    // MARK: - 生命周期

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环 —— 这个端口不对局域网暴露
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true          // 协议层 ping 自动回，应用层 ping 另算
        params.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                DispatchQueue.main.async {
                    log("❌ WebSocket listener failed: \(error)")
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.connections[id] = connection
                    DispatchQueue.main.async { self.onClientConnected?(id) }
                }
                self.receive(on: connection, id: id)
                self.resolveBrowser(of: connection, id: id)
            case .failed, .cancelled:
                self.remove(id, connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ id: UUID, _ connection: NWConnection) {
        queue.async {
            guard self.connections.removeValue(forKey: id) != nil else { return }
            connection.cancel()
            DispatchQueue.main.async { self.onClientDisconnected?(id) }
        }
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                if case .posix(.ECANCELED) = error {} else {
                    DispatchQueue.main.async { log("WebSocket receive error: \(error)") }
                }
                self.remove(id, connection)
                return
            }

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata

            if metadata?.opcode == .close {
                self.remove(id, connection)
                return
            }

            if metadata?.opcode == .text, let data, !data.isEmpty {
                DispatchQueue.main.async { self.onText?(data, id) }
            }

            self.receive(on: connection, id: id)   // 继续收下一条
        }
    }

    // MARK: - 客户端归属浏览器解析

    private func resolveBrowser(of connection: NWConnection, id: UUID) {
        guard case let .hostPort(_, remotePort) = connection.endpoint else { return }
        let portValue = remotePort.rawValue
        // lsof 是阻塞调用，放 GCD 全局队列（不是 Swift Concurrency 协作池），
        // 十几毫秒的等待无伤大雅；连接建立是低频事件。
        DispatchQueue.global(qos: .utility).async {
            let pids = Self.pidsOnPort(portValue).filter { $0 != getpid() }
            DispatchQueue.main.async {
                for pid in pids {
                    if let bundleID = Self.owningAppBundleID(of: pid) {
                        log("🔎 client \(id.uuidString.prefix(8)) → \(bundleID)")
                        self.onClientIdentified?(id, bundleID)
                        return
                    }
                }
                log("🔎 client \(id.uuidString.prefix(8)) → 浏览器身份未识别（单浏览器场景不受影响）")
            }
        }
    }

    /// 占用了指定 TCP 端口（已建立状态）的进程。会同时列出我们自己
    /// （服务端 socket 的对端就是这个端口），调用方负责排除。
    private static func pidsOnPort(_ port: UInt16) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-t"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// 沿父进程链向上找到第一个「注册为应用」的进程的 bundle id。
    /// 扩展的 socket 属于浏览器的网络服务子进程（Helper），本身不是
    /// NSRunningApplication，必须向上回溯到 .app 主进程。
    private static func owningAppBundleID(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bundleID = app.bundleIdentifier {
                return bundleID
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - 发送

    /// 发给指定客户端。浏览器是隔离主体：switch/close/unpin/settings
    /// 一律点对点，广播只留给 ping 这类无副作用消息。
    func send(_ object: [String: Any], to id: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        queue.async {
            guard let connection = self.connections[id] else { return }
            connection.send(content: data,
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        queue.async {
            for connection in self.connections.values {
                connection.send(content: data,
                                contentContext: context,
                                isComplete: true,
                                completion: .contentProcessed { _ in })
            }
        }
    }
}
