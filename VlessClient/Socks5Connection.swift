import Foundation
import Network

/// Handles a single SOCKS5 client connection
class Socks5Connection {
    let connection: NWConnection
    let config: VlessConfig
    let logger: ProxyLogger

    var tunnel: VlessTunnel?
    var targetHost: String = ""
    var targetPort: Int = 0
    var clientDataCallback: ((Data) -> Void)?

    init(connection: NWConnection, config: VlessConfig, logger: ProxyLogger) {
        self.connection = connection
        self.config = config
        self.logger = logger
    }

    func start() {
        connection.start(queue: .global())
        readSocks5Greeting()
    }

    // MARK: - SOCKS5 Handshake

    private func readSocks5Greeting() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 512) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count >= 2 else {
                self?.terminate()
                return
            }
            guard data[0] == 0x05 else { self.terminate(); return }
            self.connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [weak self] _ in
                self?.readSocks5Request()
            })
        }
    }

    func readSocks5Request() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count >= 4 else {
                self?.terminate()
                return
            }
            guard data[0] == 0x05, data[1] == 0x01 else { self.terminate(); return }

            let atyp = data[3]
            var host = ""
            var port = 0

            do {
                switch atyp {
                case 0x01:
                    guard data.count >= 10 else { throw VlessError.invalidURI("Short IPv4") }
                    host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
                    port = Int(data[8]) << 8 | Int(data[9])
                case 0x03:
                    let len = Int(data[4])
                    guard data.count >= 5 + len + 2 else { throw VlessError.invalidURI("Short domain") }
                    host = String(data: data[5..<(5 + len)], encoding: .utf8) ?? ""
                    port = Int(data[5 + len]) << 8 | Int(data[5 + len + 1])
                case 0x04:
                    guard data.count >= 22 else { throw VlessError.invalidURI("Short IPv6") }
                    var groups = [String]()
                    for i in 0..<8 {
                        let val = UInt16(data[4 + i * 2]) << 8 | UInt16(data[5 + i * 2])
                        groups.append(String(val, radix: 16))
                    }
                    host = groups.joined(separator: ":")
                    port = Int(data[20]) << 8 | Int(data[21])
                default:
                    throw VlessError.invalidURI("Unknown address type")
                }
            } catch {
                self.terminate()
                return
            }

            self.targetHost = host
            self.targetPort = port
            self.logger.log("SOCKS5 → \(host):\(port)")

            let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            self.connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
                self?.openTunnel()
            })
        }
    }

    // MARK: - Tunnel

    func openTunnel() {
        let tunnel = VlessTunnel(config: config)
        self.tunnel = tunnel

        var pendingData = [Data]()
        var tunnelReady = false
        var relayStarted = false

        startReceivingClientData { [weak self] data in
            guard let self = self else { return }
            if tunnelReady && !relayStarted {
                relayStarted = true
                self.startRelay(tunnel: tunnel, pendingData: pendingData + [data])
            } else if !tunnelReady {
                pendingData.append(data)
            } else {
                tunnel.send(data)
            }
        }

        tunnel.onOpen = { [weak self] in
            guard let self = self else { return }
            tunnelReady = true
            let vlessHdr = VlessHeaderBuilder.build(uuid: self.config.uuid,
                                                    host: self.targetHost,
                                                    port: self.targetPort)
            if pendingData.isEmpty {
                tunnel.send(vlessHdr)
            } else {
                var combined = vlessHdr
                pendingData.forEach { combined.append($0) }
                tunnel.send(combined)
            }
            if !relayStarted {
                relayStarted = true
                self.startRelay(tunnel: tunnel, pendingData: [])
            }
        }

        tunnel.onClose = { [weak self] _ in self?.terminate() }
        tunnel.connect()
    }

    func startReceivingClientData(callback: @escaping (Data) -> Void) {
        clientDataCallback = callback
        receiveFromClient()
    }

    private func receiveFromClient() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.clientDataCallback?(data)
            }
            if !isComplete && error == nil {
                self.receiveFromClient()
            } else {
                self.terminate()
            }
        }
    }

    func startRelay(tunnel: VlessTunnel, pendingData: [Data]) {
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
        for chunk in pendingData {
            tunnel.send(chunk)
        }
    }

    func terminate() {
        tunnel?.close()
        tunnel = nil
        connection.cancel()
    }
}
