# VlessClient Xcode Project

This directory contains a complete Xcode project for the VlessClient macOS app.

## Setup Instructions

### Option A: Create via Xcode (Recommended)

1. Open Xcode → **File → New → Project**
2. Choose **macOS → App**
3. Set:
   - Product Name: `VlessClient`
   - Team: Your Apple ID
   - Bundle ID: `com.yourname.VlessClient`
   - Language: **Swift**
   - Interface: **SwiftUI**
   - Uncheck "Include Tests"
4. Save to a location of your choice
5. **Delete** the auto-generated `ContentView.swift` and `VlessClientApp.swift`
6. **Drag all `.swift` files** from this folder into the Xcode project navigator
7. Add the following **entitlement** in `VlessClient.entitlements`:
   ```xml
   <key>com.apple.security.network.server</key>
   <true/>
   <key>com.apple.security.network.client</key>
   <true/>
   ```

### Option B: Use Swift Package Manager (CLI)

```bash
# Build with swift
cd VlessClient
swift build
.build/debug/VlessClient
```

### Required Entitlements

In Xcode, go to **Signing & Capabilities** and add:
- `Network → Incoming Connections (Server)`
- `Network → Outgoing Connections (Client)`

Or add to `VlessClient.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

> **Note:** For simplest development, disable App Sandbox entirely (the last `false` above). This allows unrestricted network access needed for a proxy.

---

## Architecture

```
VlessClientApp (entry point)
│
├── ConfigManager          — Persistence of VlessConfig objects
├── ProxyServer            — NWListener that dispatches connections  
│   ├── Socks5Connection   — Handles SOCKS5 protocol handshake + relay
│   └── HttpProxyConnection— Handles HTTP CONNECT + plain HTTP proxy
│
├── VlessTunnel            — WebSocket tunnel to remote VLESS server
├── VlessHeaderBuilder     — Builds the VLESS binary protocol header
└── VlessConfig            — Config model + vless:// URI parser/exporter
```

## File Summary

| File | Purpose |
|------|---------|
| `ContentView.swift` | All SwiftUI views (Dashboard, Config list, Logs, Import, Menu bar) |
| `VlessConfig.swift` | Config model + `vless://` URI parsing |
| `VlessHeaderBuilder.swift` | VLESS binary header construction |
| `VlessTunnel.swift` | URLSession WebSocket wrapper |
| `ProxyServer.swift` | NWListener + connection dispatcher |
| `Socks5Connection.swift` | SOCKS5 protocol handler |
| `HttpProxyConnection.swift` | HTTP CONNECT + plain HTTP proxy handler |
| `ConnectionExtensions.swift` | Extra entry points for both connection types |
| `ConfigManager.swift` | UserDefaults-backed config persistence |
