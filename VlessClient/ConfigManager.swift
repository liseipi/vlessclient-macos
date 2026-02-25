import Foundation
import Combine
import SwiftUI

class ConfigManager: ObservableObject {
    @Published var configs: [VlessConfig] = []
    @Published var activeConfigID: UUID?
    
    private let saveKey = "vless_configs"
    private let activeKey = "vless_active_id"
    
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
}
