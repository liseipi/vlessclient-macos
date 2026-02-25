import Foundation
import Network

/// Handles HTTP CONNECT and plain HTTP proxy requests over a single TCP connection
class HttpProxyConnection {
    let connection: NWConnection
    let config: VlessConfig
    let logger: ProxyLogger

    var tunnel: VlessTunnel?
    var receiveBuffer = Data()

    init(connection: NWConnection, config: VlessConfig, logger: ProxyLogger) {
        self.connection = connection
        self.config = config
        self.logger = logger
    }

    func start() {
        connection.start(queue: .global())
        readHTTPRequest()
    }

    private func readHTTPRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self = self, let data = data else { self?.terminate(); return }
            self.receiveBuffer.append(data)
            if let headerEnd = self.findHeaderEnd(in: self.receiveBuffer) {
                let headerData = self.receiveBuffer[..<headerEnd]
                let body = self.receiveBuffer[headerEnd...]
                self.receiveBuffer = Data()
                self.handleHTTPRequest(headerData: Data(headerData), body: Data(body))
            } else {
                self.readHTTPRequest()
            }
        }
    }

    func findHeaderEnd(in data: Data) -> Data.Index? {
        let needle = Data([0x0D, 0x0A, 0x0D, 0x0A])
        return data.range(of: needle)?.upperBound
    }

    func handleHTTPRequest(headerData: Data, body: Data) {
        guard let headerStr = String(data: headerData, encoding: .utf8) else { terminate(); return }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { terminate(); return }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { terminate(); return }

        let method = parts[0]
        let urlStr = parts[1]

        if method.uppercased() == "CONNECT" {
            handleConnect(target: urlStr)
        } else {
            handlePlainHTTP(method: method, urlStr: urlStr, headers: parseHeaders(lines), body: body)
        }
    }

    // MARK: - HTTP CONNECT

    private func handleConnect(target: String) {
        let (host, port) = splitHostPort(target, defaultPort: 443)
        logger.log("HTTP CONNECT → \(host):\(port)")
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { [weak self] _ in
            self?.openTunnel(host: host, port: port, initialData: Data())
        })
    }

    // MARK: - Plain HTTP Proxy

    private func handlePlainHTTP(method: String, urlStr: String, headers: [String: String], body: Data) {
        guard let url = URL(string: urlStr) else { terminate(); return }
        let host = url.host ?? ""
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        logger.log("HTTP \(method) → \(host):\(port)")

        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        var rawRequest = "\(method) \(path)\(query) HTTP/1.1\r\n"
        for (k, v) in headers where k.lowercased() != "proxy-connection" {
            rawRequest += "\(k): \(v)\r\n"
        }
        rawRequest += "\r\n"
        var requestData = rawRequest.data(using: .utf8)!
        requestData.append(body)
        openTunnel(host: host, port: port, initialData: requestData, isHTTP: true)
    }

    // MARK: - Tunnel

    func openTunnel(host: String, port: Int, initialData: Data, isHTTP: Bool = false) {
        let tunnel = VlessTunnel(config: config)
        self.tunnel = tunnel

        var pendingData = [Data]()
        var tunnelReady = false

        if !isHTTP {
            startReceivingClientData { [weak self] data in
                guard let self = self else { return }
                if tunnelReady { tunnel.send(data) }
                else { pendingData.append(data) }
            }
        }

        var firstResponse = true
        tunnel.onMessage = { [weak self] data in
            guard let self = self else { return }
            var toSend = data
            if firstResponse {
                firstResponse = false
                guard toSend.count > 2 else { return }
                toSend = toSend.dropFirst(2)
            }
            self.connection.send(content: toSend, completion: .idempotent)
        }

        tunnel.onClose = { [weak self] _ in self?.terminate() }

        tunnel.onOpen = { [weak self] in
            guard let self = self else { return }
            tunnelReady = true
            let vlessHdr = VlessHeaderBuilder.build(uuid: self.config.uuid, host: host, port: port)
            var combined = vlessHdr
            if !initialData.isEmpty { combined.append(initialData) }
            pendingData.forEach { combined.append($0) }
            tunnel.send(combined)
        }

        tunnel.connect()
    }

    func startReceivingClientData(callback: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { callback(data) }
            if !isComplete && error == nil {
                self.startReceivingClientData(callback: callback)
            } else {
                self.terminate()
            }
        }
    }

    func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }
        return headers
    }

    func splitHostPort(_ str: String, defaultPort: Int) -> (String, Int) {
        if let idx = str.lastIndex(of: ":"), let port = Int(str[str.index(after: idx)...]) {
            return (String(str[..<idx]), port)
        }
        return (str, defaultPort)
    }

    func terminate() {
        tunnel?.close()
        tunnel = nil
        connection.cancel()
    }
}
