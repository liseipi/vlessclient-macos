import Foundation
import Network
import Combine

// MARK: - ProxyLogger

class ProxyLogger: ObservableObject {
    @Published var logs: [LogEntry] = []
    private let maxEntries = 500

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String

        var timeString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: timestamp)
        }
    }

    func log(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxEntries {
                self.logs = Array(self.logs.prefix(self.maxEntries))
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.logs = [] }
    }
}

// MARK: - ProxyServer

class ProxyServer: ObservableObject {
    @Published var isRunning = false
    @Published var connectionCount = 0

    private var listener: NWListener?
    private let logger: ProxyLogger
    private var config: VlessConfig
    private let serverQueue = DispatchQueue(label: "proxy.server", attributes: .concurrent)

    init(config: VlessConfig, logger: ProxyLogger) {
        self.config = config
        self.logger = logger
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(
            using: params,
            on: NWEndpoint.Port(integerLiteral: UInt16(config.listenPort))
        )
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.isRunning = true }
                let addr = "wss://\(self.config.server):\(self.config.port)"
                self.logger.log(LanguageManager.shared.t(.proxyStarted(addr)))
            case .failed(let error):
                DispatchQueue.main.async { self.isRunning = false }
                self.logger.log(LanguageManager.shared.t(.proxyFailed(error.localizedDescription)))
            case .cancelled:
                DispatchQueue.main.async { self.isRunning = false }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: serverQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.connectionCount = 0
        }
        logger.log(LanguageManager.shared.t(.proxyStopped))
    }

    private func handleNewConnection(_ connection: NWConnection) {
        DispatchQueue.main.async { self.connectionCount += 1 }
        connection.start(queue: serverQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8) { [weak self] data, _, _, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                DispatchQueue.main.async { self?.connectionCount = max(0, (self?.connectionCount ?? 1) - 1) }
                return
            }

            let firstByte = data[0]

            if firstByte == 0x05 {
                let handler = MixedConnection(connection: connection,
                                              initialData: data,
                                              config: self.config,
                                              logger: self.logger,
                                              protocol: .socks5)
                handler.start()
            } else if firstByte >= 0x41 && firstByte <= 0x5A {
                let handler = MixedConnection(connection: connection,
                                              initialData: data,
                                              config: self.config,
                                              logger: self.logger,
                                              protocol: .http)
                handler.start()
            } else {
                connection.cancel()
                DispatchQueue.main.async { self.connectionCount = max(0, self.connectionCount - 1) }
            }
        }
    }
}

// MARK: - ProxyProtocol

enum ProxyProtocol { case socks5, http }

// MARK: - MixedConnection

class MixedConnection {
    private let connection: NWConnection
    private var buffer: Data
    private let config: VlessConfig
    private let logger: ProxyLogger
    private let proto: ProxyProtocol
    private var tunnel: VlessTunnel?
    private var selfRetain: MixedConnection?   // 防止 ARC 提前释放

    init(connection: NWConnection, initialData: Data,
         config: VlessConfig, logger: ProxyLogger, protocol proto: ProxyProtocol) {
        self.connection = connection
        self.buffer = initialData
        self.config = config
        self.logger = logger
        self.proto = proto
    }

    func start() {
        selfRetain = self
        switch proto {
        case .socks5: processSocks5Greeting()
        case .http:   processHTTP()
        }
    }

    // MARK: - SOCKS5 握手

    private func processSocks5Greeting() {
        guard buffer.count >= 2 else { readMore { self.processSocks5Greeting() }; return }
        let b = Array(buffer)
        guard b[0] == 0x05 else { cancel(); return }
        let nMethods = Int(b[1])
        guard buffer.count >= 2 + nMethods else { readMore { self.processSocks5Greeting() }; return }
        buffer = Data(buffer.dropFirst(2 + nMethods))
        sendToClient(Data([0x05, 0x00])) { self.processSocks5Request() }
    }

    private func processSocks5Request() {
        guard buffer.count >= 7 else { readMore { self.processSocks5Request() }; return }
        let b = Array(buffer)
        guard b[0] == 0x05, b[1] == 0x01 else { cancel(); return }

        let atyp = b[3]
        var host = ""; var port = 0; var consumed = 0

        switch atyp {
        case 0x01:
            guard b.count >= 10 else { readMore { self.processSocks5Request() }; return }
            host = "\(b[4]).\(b[5]).\(b[6]).\(b[7])"
            port = Int(b[8]) << 8 | Int(b[9]); consumed = 10
        case 0x03:
            let len = Int(b[4])
            guard b.count >= 5 + len + 2 else { readMore { self.processSocks5Request() }; return }
            host = String(bytes: Array(b[5..<(5+len)]), encoding: .utf8) ?? ""
            port = Int(b[5+len]) << 8 | Int(b[5+len+1]); consumed = 5 + len + 2
        case 0x04:
            guard b.count >= 22 else { readMore { self.processSocks5Request() }; return }
            var groups = [String]()
            for i in 0..<8 { groups.append(String(UInt16(b[4+i*2]) << 8 | UInt16(b[5+i*2]), radix: 16)) }
            host = groups.joined(separator: ":"); port = Int(b[20]) << 8 | Int(b[21]); consumed = 22
        default: cancel(); return
        }

        buffer = Data(buffer.dropFirst(consumed))
        logger.log("SOCKS5 \(host):\(port)")

        let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        sendToClient(reply) {
            self.openTunnel(host: host, port: port)
        }
    }

    // MARK: - HTTP

    private func processHTTP() {
        let needle = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = buffer.range(of: needle) else { readMore { self.processHTTP() }; return }

        let headerData = Data(buffer[..<range.upperBound])
        let body       = Data(buffer[range.upperBound...])
        buffer = Data()

        guard let headerStr = String(data: headerData, encoding: .utf8) else { cancel(); return }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { cancel(); return }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { cancel(); return }

        let method = parts[0].uppercased()
        let urlStr  = parts[1]

        if method == "CONNECT" {
            let (host, port) = splitHostPort(urlStr, defaultPort: 443)
            logger.log("CONNECT \(host):\(port)")
            sendToClient("HTTP/1.1 200 Connection Established\r\n\r\n".data(using: .utf8)!) {
                self.openTunnel(host: host, port: port)
            }
        } else {
            guard let url = URL(string: urlStr) else { cancel(); return }
            let host = url.host ?? ""
            let port = url.port ?? (url.scheme == "https" ? 443 : 80)
            logger.log("HTTP \(method) \(host):\(port)")

            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard !line.isEmpty else { break }
                if let idx = line.firstIndex(of: ":") {
                    let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                    let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    if k.lowercased() != "proxy-connection" { headers[k] = v }
                }
            }
            let path  = url.path.isEmpty ? "/" : url.path
            let query = url.query.map { "?\($0)" } ?? ""
            var rawReq = "\(method) \(path)\(query) HTTP/1.1\r\n"
            headers.forEach { rawReq += "\($0.key): \($0.value)\r\n" }
            rawReq += "\r\n"
            var initialData = rawReq.data(using: .utf8)!
            initialData.append(body)
            openTunnel(host: host, port: port, initialData: initialData)
        }
    }

    // MARK: - 核心隧道逻辑

    private func openTunnel(host: String, port: Int, initialData: Data = Data()) {
        let tunnel = VlessTunnel(config: config)
        self.tunnel = tunnel

        let q = DispatchQueue(label: "conn-\(host)-\(port)")
        var earlyData: [Data] = []
        var isOpen = false

        var respBuf      = Data()
        var respSkipped  = false
        var respHdrSize  = -1

        tunnel.onMessage = { [weak self] data in
            guard let self = self else { return }

            guard !respSkipped else {
                self.connection.send(content: data, completion: .idempotent)
                return
            }

            respBuf.append(data)
            guard respBuf.count >= 2 else { return }

            if respHdrSize == -1 {
                respHdrSize = 2 + Int(respBuf[1])
            }
            guard respBuf.count >= respHdrSize else { return }

            respSkipped = true
            let payload = Data(respBuf.dropFirst(respHdrSize))
            respBuf = Data()
            if !payload.isEmpty {
                self.connection.send(content: payload, completion: .idempotent)
            }
        }

        tunnel.onOpen = { [weak self] in
            guard let self = self else { return }
            q.async {
                isOpen = true
                let vlessHdr = VlessHeaderBuilder.build(uuid: self.config.uuid, host: host, port: port)
                var pkt = vlessHdr
                if !initialData.isEmpty { pkt.append(initialData) }
                earlyData.forEach { pkt.append($0) }
                earlyData.removeAll()
                tunnel.send(pkt)
            }
        }

        tunnel.onClose = { [weak self] error in
            if let error = error {
                self?.logger.log("⚠️ \(host):\(port) \(error.localizedDescription)")
            }
            self?.cancel()
        }

        receiveFromClient { [weak self] data in
            guard let self = self else { return }
            q.async {
                if isOpen { tunnel.send(data) }
                else       { earlyData.append(data) }
            }
        }

        tunnel.connect()
    }

    // MARK: - 工具

    private func readMore(then cont: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data) }
            if error != nil { self.cancel(); return }
            cont()
        }
    }

    private func receiveFromClient(callback: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { callback(data) }
            if !isComplete && error == nil {
                self.receiveFromClient(callback: callback)
            } else {
                self.cancel()
            }
        }
    }

    private func sendToClient(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel(); return }
            completion()
        })
    }

    private func splitHostPort(_ str: String, defaultPort: Int) -> (String, Int) {
        if let idx = str.lastIndex(of: ":"), let p = Int(str[str.index(after: idx)...]) {
            return (String(str[..<idx]), p)
        }
        return (str, defaultPort)
    }

    private func cancel() {
        tunnel?.close()
        tunnel = nil
        connection.cancel()
        selfRetain = nil
    }
}
