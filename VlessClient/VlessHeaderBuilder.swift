import Foundation
import Network

/// Builds the VLESS protocol request header
/// Format: version(1) + uuid(16) + addon_len(1) + cmd(1) + port(2) + atype(1) + addr
///
/// VLESS 地址类型：
///   0x01 = IPv4 (4字节)
///   0x02 = 域名 (1字节长度 + N字节域名)
///   0x03 = IPv6 (16字节)
struct VlessHeaderBuilder {

    static func build(uuid: String, host: String, port: Int) -> Data {
        let uuidBytes = parseUUID(uuid)

        var header = Data()

        // Version: 0x00
        header.append(0x00)

        // UUID (16 bytes)
        header.append(contentsOf: uuidBytes)

        // Additional info length: 0x00
        header.append(0x00)

        // Command: 0x01 (TCP)
        header.append(0x01)

        // Port (2 bytes big-endian)
        let portBE = UInt16(port).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: portBE) { Array($0) })

        // Address type + address
        let (atype, addrBytes) = encodeAddress(host)
        header.append(atype)
        header.append(contentsOf: addrBytes)

        return header
    }

    private static func parseUUID(_ uuid: String) -> [UInt8] {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<nextIdx], radix: 16) {
                bytes.append(byte)
            }
            idx = nextIdx
        }
        return bytes
    }

    private static func encodeAddress(_ host: String) -> (UInt8, [UInt8]) {
        // ✅ 优先判断 IPv4，避免含点的域名被误判
        if isIPv4(host) {
            let parts = host.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                return (0x01, parts)  // IPv4
            }
        }

        // ✅ 再判断 IPv6（含冒号或方括号包裹）
        // 注意：isIPv6 检测含 ":" 即可，普通域名不含冒号
        if isIPv6(host) {
            let stripped = host.hasPrefix("[") && host.hasSuffix("]")
                ? String(host.dropFirst().dropLast())
                : host
            if let bytes = ipv6ToBytes(stripped) {
                return (0x03, bytes)  // IPv6
            }
        }

        // 域名：0x02 + 1字节长度 + N字节UTF-8
        // ✅ 与 client.js 完全一致：atype=2, abuf=[len, ...domainBytes]
        let domainBytes = Array(host.utf8)
        var result = [UInt8(domainBytes.count)]
        result.append(contentsOf: domainBytes)
        return (0x02, result)  // Domain
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    /// ✅ 修复：只有真正含冒号（IPv6格式）才认为是 IPv6
    /// 避免把 "host:port" 这种带端口的域名误判为 IPv6
    private static func isIPv6(_ host: String) -> Bool {
        // 方括号包裹的 IPv6 字面量，如 [::1]
        if host.hasPrefix("[") && host.hasSuffix("]") { return true }
        // 原始 IPv6：至少含 2 个冒号（区分 host:port）
        return host.filter({ $0 == ":" }).count >= 2
    }

    private static func ipv6ToBytes(_ addr: String) -> [UInt8]? {
        var groups: [String]
        if addr.contains("::") {
            let parts = addr.components(separatedBy: "::")
            let left = parts[0].isEmpty ? [] : parts[0].split(separator: ":").map(String.init)
            let right = parts.count > 1 && !parts[1].isEmpty
                ? parts[1].split(separator: ":").map(String.init)
                : []
            let midCount = 8 - left.count - right.count
            let mid = Array(repeating: "0", count: max(0, midCount))
            groups = left + mid + right
        } else {
            groups = addr.split(separator: ":").map(String.init)
        }

        guard groups.count == 8 else { return nil }

        var bytes = [UInt8]()
        for g in groups {
            guard let val = UInt16(g.isEmpty ? "0" : g, radix: 16) else { return nil }
            let be = val.bigEndian
            bytes.append(contentsOf: withUnsafeBytes(of: be) { Array($0) })
        }
        return bytes
    }
}
