import Foundation

struct VlessConfig: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var server: String
    var port: Int
    var uuid: String
    var path: String
    var sni: String
    var wsHost: String
    var listenPort: Int
    var rejectUnauthorized: Bool
    var security: String // "none", "tls"
    var encryption: String // "none"
    
    static var defaultConfig: VlessConfig {
        VlessConfig(
            name: "broad.aicms.dpdns.org",
            server: "broad.aicms.dpdns.org",
            port: 443,
            uuid: "55a95ae1-4ae8-4461-8484-457279821b40",
            path: "/?ed=2560",
            sni: "broad.aicms.dpdns.org",
            wsHost: "broad.aicms.dpdns.org",
            listenPort: 1088,
            rejectUnauthorized: false,
            security: "none",
            encryption: "none"
        )
    }
    
    /// Parse a vless:// URI into a VlessConfig
    /// Format: vless://uuid@host:port?encryption=none&security=tls&sni=...&type=ws&host=...&path=...#name
    static func parse(from uri: String) throws -> VlessConfig {
        guard uri.hasPrefix("vless://") else {
            throw VlessError.invalidURI("URI must start with vless://")
        }
        
        // Extract fragment (name) first
        var workingURI = uri
        var name = "Unnamed"
        if let hashIdx = workingURI.lastIndex(of: "#") {
            let fragment = String(workingURI[workingURI.index(after: hashIdx)...])
            name = fragment.removingPercentEncoding ?? fragment
            workingURI = String(workingURI[..<hashIdx])
        }
        
        // Remove scheme
        let withoutScheme = String(workingURI.dropFirst("vless://".count))
        
        // Split user-info@host:port from query
        guard let atIdx = withoutScheme.firstIndex(of: "@") else {
            throw VlessError.invalidURI("Missing @ separator")
        }
        let uuidPart = String(withoutScheme[..<atIdx])
        let rest = String(withoutScheme[withoutScheme.index(after: atIdx)...])
        
        // Split host:port from query
        var hostPort = rest
        var queryString = ""
        if let qIdx = rest.firstIndex(of: "?") {
            hostPort = String(rest[..<qIdx])
            queryString = String(rest[rest.index(after: qIdx)...])
        }
        
        // Parse host and port
        var host = hostPort
        var port = 443
        // Handle IPv6
        if hostPort.hasPrefix("[") {
            if let closeIdx = hostPort.firstIndex(of: "]") {
                host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeIdx])
                let afterBracket = hostPort[hostPort.index(after: closeIdx)...]
                if afterBracket.hasPrefix(":"), let p = Int(afterBracket.dropFirst()) {
                    port = p
                }
            }
        } else if let colonIdx = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colonIdx])
            if let p = Int(hostPort[hostPort.index(after: colonIdx)...]) {
                port = p
            }
        }
        
        // Parse query parameters
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                params[key] = value
            }
        }
        
        let sni = params["sni"] ?? host
        let wsHost = params["host"] ?? host
        let path = params["path"] ?? "/"
        let security = params["security"] ?? "none"
        let encryption = params["encryption"] ?? "none"
        
        return VlessConfig(
            name: name,
            server: host,
            port: port,
            uuid: uuidPart,
            path: path,
            sni: sni,
            wsHost: wsHost,
            listenPort: 1088,
            rejectUnauthorized: false,
            security: security,
            encryption: encryption
        )
    }
    
    /// Export as vless:// URI
    func toURI() -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        return "vless://\(uuid)@\(server):\(port)?encryption=\(encryption)&security=\(security)&sni=\(sni)&type=ws&host=\(wsHost)&path=\(encodedPath)#\(encodedName)"
    }
}

enum VlessError: LocalizedError {
    case invalidURI(String)
    case connectionFailed(String)
    case tunnelError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURI(let msg): return "Invalid URI: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .tunnelError(let msg): return "Tunnel error: \(msg)"
        }
    }
}
