import Foundation
import ServiceManagement

/// 「开机时启动」的封装。
///
/// 这里刻意不缓存状态：`SMAppService.mainApp.status` 是系统托管的外部状态，
/// 用户随时可能在「系统设置 → 通用 → 登录项」里改掉它。菜单每次打开时现读，
/// 显示的就永远是真实值。
///
/// （HealthTick #32：把这个状态接进一个不会被通知到变化的 UI 绑定里，
/// 开关会在重渲染的间隙自由漂移，表现为"随机回跳"。）
enum LoginItem {

    enum State {
        /// 已启用，登录时会自动启动
        case enabled
        /// 未启用
        case disabled
        /// macOS 13+ 注册后待用户在系统设置里批准 —— 登录项已经出现在列表里但尚未生效，
        /// 这种情况必须和「未启用」区分开，否则用户会看到一个"关着"的开关却怎么点都没用
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .disabled
        }
    }

    /// 切换开关。返回切换后的真实状态（不是期望状态）。
    @discardableResult
    static func toggle() -> State {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("Login item toggle failed: \(error.localizedDescription)")
        }
        return state   // 回读，不假设操作成功
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
