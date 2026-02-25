import Foundation
import Combine
import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

class ConfigManager: ObservableObject {
    @Published var configs: [VlessConfig] = []
    @Published var activeConfigID: UUID?
    @Published var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: launchKey)
            updateLaunchAtLogin()
        }
    }
    
    private let saveKey = "vless_configs"
    private let activeKey = "vless_active_id"
    private let launchKey = "vless_launch_at_login"
    
    var activeConfig: VlessConfig? {
        guard let id = activeConfigID else { return configs.first }
        return configs.first(where: { $0.id == id }) ?? configs.first
    }
    
    init() {
        load()
        if configs.isEmpty {
            configs.append(.defaultConfig)
            save()
        }
        launchAtLogin = UserDefaults.standard.bool(forKey: launchKey)
    }
    
    func add(_ config: VlessConfig) {
        configs.append(config)
        save()
    }
    
    func update(_ config: VlessConfig) {
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }
    
    func delete(at offsets: IndexSet) {
        configs.remove(atOffsets: offsets)
        save()
    }
    
    func setActive(_ config: VlessConfig) {
        activeConfigID = config.id
        UserDefaults.standard.set(config.id.uuidString, forKey: activeKey)
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? JSONDecoder().decode([VlessConfig].self, from: data) {
            configs = saved
        }
        if let idStr = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: idStr) {
            activeConfigID = id
        }
    }
    
    // ✅ 设置开机自启动
    private func updateLaunchAtLogin() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            // macOS 13+ 使用 SMAppService
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("Failed to \(launchAtLogin ? "enable" : "disable") launch at login: \(error)")
            }
        } else {
            // macOS 12 及以下使用 LSSharedFileList (已弃用但仍可用)
            setLaunchAtLoginLegacy(enabled: launchAtLogin)
        }
        #endif
    }
    
    // macOS 12 及以下的自启动方法
    private func setLaunchAtLoginLegacy(enabled: Bool) {
        #if os(macOS)
        let itemURL = Bundle.main.bundleURL
        
        // ✅ 修复：正确处理可选类型
        guard let loginItemsRef = LSSharedFileListCreate(
            nil,
            kLSSharedFileListSessionLoginItems.takeRetainedValue(),
            nil
        ) else {
            print("Failed to create login items list")
            return
        }
        
        let loginItems = loginItemsRef.takeRetainedValue()
        
        if enabled {
            // 添加到登录项
            LSSharedFileListInsertItemURL(
                loginItems,
                kLSSharedFileListItemLast.takeRetainedValue(),
                nil,
                nil,
                itemURL as CFURL,
                nil,
                nil
            )
        } else {
            // 从登录项移除
            guard let snapshotRef = LSSharedFileListCopySnapshot(loginItems, nil) else {
                print("Failed to get login items snapshot")
                return
            }
            
            let snapshot = snapshotRef.takeRetainedValue() as? [LSSharedFileListItem] ?? []
            
            for item in snapshot {
                guard let itemURLRef = LSSharedFileListItemCopyResolvedURL(item, 0, nil) else {
                    continue
                }
                
                let resolvedURL = itemURLRef.takeRetainedValue() as URL
                
                if resolvedURL == Bundle.main.bundleURL {
                    LSSharedFileListItemRemove(loginItems, item)
                }
            }
        }
        #endif
    }
}
