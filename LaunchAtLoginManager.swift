import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private init() {}

    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    func toggle() -> String? {
        if isEnabled {
            return disable()
        } else {
            return enable()
        }
    }

    func enable() -> String? {
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return "注册失败: \(error.localizedDescription)"
        }
    }

    func disable() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "取消注册失败: \(error.localizedDescription)"
        }
    }
}
