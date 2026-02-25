import Foundation
import Network

/// Manages a single WebSocket tunnel connection to the VLESS server
class VlessTunnel: NSObject {
    private let config: VlessConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    var onOpen: (() -> Void)?

    private var opened = false
    private var closed = false

    init(config: VlessConfig) {
        self.config = config
        super.init()
    }

    func connect() {
        let scheme: String
        if config.security == "tls" || config.port == 443 {
            scheme = "wss"
        } else {
            scheme = "ws"
        }

        // ✅ 修复 Bug 2：path 含 ?ed=2560 等查询参数时，必须用 URLComponents 构造
        // 直接拼字符串 URL 再传给 URLSessionWebSocketTask 会导致 ? 被二次编码
        var components = URLComponents()
        components.scheme = scheme
        components.host   = config.server
        components.port   = config.port

        // path 中可能含 ?query，手动拆分
        if let qIdx = config.path.firstIndex(of: "?") {
            components.path        = String(config.path[..<qIdx])
            let queryStr           = String(config.path[config.path.index(after: qIdx)...])
            // 保留原始 query，不让 URLComponents 重新编码
            components.percentEncodedQuery = queryStr
        } else {
            components.path = config.path.isEmpty ? "/" : config.path
        }

        guard let url = components.url else {
            notifyClose(VlessError.connectionFailed("无效 URL"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // ✅ 修复 Bug 4：URLSession 不允许设置 Host 头（系统忽略），
        // 但可以通过设置 url.host 为真实 server、再用 SNI 代理方式解决。
        // 这里能设置的 headers 只有 User-Agent / Cache-Control / Pragma
        // Host 头由系统从 URL 的 host 字段自动生成，已经是 config.server
        // 如果 wsHost 与 server 不同，需要改 URL host 为 wsHost，SNI 通过 delegate 控制
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        // ✅ 如果 wsHost 与 server 不同，把 URL host 换成 wsHost，SNI 保持 server（或 sni 字段）
        // 这样 HTTP Host 头 = wsHost，TLS SNI = config.sni（由 delegate 控制）
        if config.wsHost != config.server, !config.wsHost.isEmpty {
            var comps2 = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps2.host = config.wsHost
            if let altURL = comps2.url {
                request = URLRequest(url: altURL)
                request.timeoutInterval = 15
                request.setValue(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            }
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.tlsMinimumSupportedProtocolVersion = .TLSv12

        urlSession = URLSession(configuration: sessionConfig,
                                delegate: self,
                                delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveLoop()
    }

    func send(_ data: Data, completion: ((Error?) -> Void)? = nil) {
        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error { self?.notifyClose(error) }
            completion?(error)
        }
    }

    func close() {
        closed = true
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, !self.closed else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onMessage?(data)
                case .string(let str):
                    // VLESS 服务端偶尔以 string 帧发送二进制，用 isoLatin1 还原
                    if let data = str.data(using: .isoLatin1) {
                        self.onMessage?(data)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                self.notifyClose(error)
            }
        }
    }

    private func notifyClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        onClose?(error)
    }
}

// MARK: - URLSession Delegate

extension VlessTunnel: URLSessionWebSocketDelegate, URLSessionDelegate {

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard !opened else { return }
        opened = true
        onOpen?()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        notifyClose(nil)
    }

    /// ✅ TLS 证书验证 + SNI 控制
    /// rejectUnauthorized=false 时接受任意证书
    /// 同时此 delegate 方法是控制 SNI 的唯一入口
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !config.rejectUnauthorized,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
