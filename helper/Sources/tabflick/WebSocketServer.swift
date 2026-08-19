import Foundation
import Network

/// 只监听回环地址的极简 WebSocket 服务端。
///
/// 用 Network.framework 内置的 `NWProtocolWebSocket` —— 它自己处理 HTTP upgrade
/// 握手和帧编解码，我们不用手写协议。所有收发都走 completion handler，
/// 没有任何阻塞式 syscall，因此不会钉住线程。
final class WebSocketServer {

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.tabflick.websocket")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// 收到文本帧。回调在主线程。
    var onText: ((Data) -> Void)?
    /// 已连接的客户端数变化。回调在主线程。
    var onClientCountChange: ((Int) -> Void)?

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
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.connections[ObjectIdentifier(connection)] = connection
                    self.announceCount()
                }
                self.receive(on: connection)
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ connection: NWConnection) {
        queue.async {
            guard self.connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
            connection.cancel()
            self.announceCount()
        }
    }

    /// 必须在 `queue` 上调用。
    private func announceCount() {
        let count = connections.count
        DispatchQueue.main.async { self.onClientCountChange?(count) }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                if case .posix(.ECANCELED) = error {} else {
                    DispatchQueue.main.async { log("WebSocket receive error: \(error)") }
                }
                self.remove(connection)
                return
            }

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata

            if metadata?.opcode == .close {
                self.remove(connection)
                return
            }

            if metadata?.opcode == .text, let data, !data.isEmpty {
                DispatchQueue.main.async { self.onText?(data) }
            }

            self.receive(on: connection)   // 继续收下一条
        }
    }

    // MARK: - 发送

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
