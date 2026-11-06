import AppKit

extension NSMenuItem {
    /// 菜单项图标的唯一入口。macOS 27 起，链接到 26+ SDK 的 app 由 AppKit
    /// 决定图标显不显示，**默认全部藏掉**（含 favicon、App 图标这类非 symbol
    /// 图，本机实测）。本项目菜单的约定是「图标要么全有要么全无」，所以每个
    /// 设了图的项都显式要求显示。直接写 `.image =` 会在 27 上静默没图。
    var icon: NSImage? {
        get { image }
        set {
            image = newValue
            if #available(macOS 27, *) {
                preferredImageVisibility = newValue == nil ? .automatic : .visible
            }
        }
    }
}
