import AppKit
import SwiftUI

// 插件图标（2026-11-07 用户要的：每个插件一个有代表性的图标，外置插件也能带自己的）。
//
// 图标是一张正方形的图（SVG 或 PNG），画满整个正方形；圆角由 TabFlick 统一裁（`side × 0.27` 的连续圆角，
// 同 ActionTile / 设置侧边栏），所以设置、搜索面板、菜单栏、商店里的形状都一样。没有图标、或者图读不出来，
// 退回原来的「白色符号 + 底色」方块（`symbol` / `tint`），所以 manifest 里这两项一直要写。
// SVG 走系统自己的解析（NSImage 认 public.svg-image），不带第三方库。

enum PluginIconLoader {
    /// 图标文件上限：一张图标几 KB，超过这个数多半是放错了文件
    nonisolated static let maxBytes = 256 << 10
    /// 加载后统一按这个点数登记：SVG 的原始尺寸是 viewBox（64），SwiftUI 按它栅格化，放到设置页 40pt 的格子里会糊
    nonisolated static let canvas: CGFloat = 128

    /// 读插件目录里的图标。读不到、太大、不是图，都回 nil（调用方退回符号）。
    nonisolated static func load(_ url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return image(data: data)
    }

    nonisolated static func image(data: Data) -> NSImage? {
        guard data.count <= maxBytes, let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        image.size = NSSize(width: canvas, height: canvas)
        return image
    }

    nonisolated static func image(svg: String) -> NSImage? { image(data: Data(svg.utf8)) }

    /// 菜单项用的：裁好圆角的一张图（菜单里没有 SwiftUI，自己画）。用绘制回调，按屏幕的倍数现画，不糊。
    nonisolated static func menuImage(_ icon: NSImage, side: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.27, yRadius: side * 0.27).addClip()
            icon.draw(in: rect)
            return true
        }
    }

    /// 没有图标的插件在菜单里也画成方块：底色渐变 + 白色符号（同设置、面板的退路 `PluginSymbolTile`）。
    /// 直接用单色的 SF Symbol 的话，和旁边有图标的插件一个彩色方块、一个灰色线条（用户 2026-11-07 截图）。
    nonisolated static func menuImage(symbol: String, tint: NSColor, side: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: side * 0.27, yRadius: side * 0.27)
            // 上浅下深：角度 90 = 起始色在下面
            NSGradient(starting: tint, ending: tint.withAlphaComponent(0.85))?.draw(in: shape, angle: 90)
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.56, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
    }

    /// 菜单里插件那一行的图标：有图标画图标，没有画方块。
    @MainActor static func menuImage(for plugin: Plugin) -> NSImage {
        plugin.icon.map { menuImage($0) } ?? menuImage(symbol: plugin.symbol, tint: NSColor(plugin.tint))
    }
}

/// 插件的图标块：有图标画图标，没有画「白色符号 + 底色」（`PluginSymbolTile`）。设置、面板、商店共用。
struct PluginIconTile: View {
    let icon: NSImage?
    let symbol: String
    let tint: Color
    let side: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
        } else {
            PluginSymbolTile(symbol: symbol, tint: tint, side: side)
        }
    }
}

/// 内置插件的图标，SVG 源码就在这里（外置插件的放在各自目录的 icon.svg）。
/// 改图标：改这里的 SVG，viewBox 64×64、背景画满，在深浅两种底上 16 / 26pt 都看一眼。
@MainActor
enum BuiltinPluginIcons {
    private static func image(svg: String) -> NSImage? { PluginIconLoader.image(svg: svg) }

    static let calculator = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#727781"/><stop offset="1" stop-color="#3b3f46"/></linearGradient><linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect width="64" height="64" fill="url(#bg)"/><rect width="64" height="64" fill="url(#hl)"/>
<g fill="#fff" fill-opacity=".17"><circle cx="21.5" cy="21.5" r="9.2"/><circle cx="42.5" cy="21.5" r="9.2"/><circle cx="21.5" cy="42.5" r="9.2"/></g>
<circle cx="42.5" cy="42.5" r="9.2" fill="#ff9f0a"/>
<g stroke="#fff" stroke-width="4" stroke-linecap="round" fill="none">
<path d="M21.5 16v11M16 21.5h11"/><path d="M37 21.5h11"/><path d="M17.6 38.6l7.8 7.8M25.4 38.6l-7.8 7.8"/><path d="M37.5 39.8h10M37.5 45.2h10"/></g></svg>
"""#)
    static let appCommands = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffcb45"/><stop offset="1" stop-color="#f28a00"/></linearGradient><linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect width="64" height="64" fill="url(#bg)"/><rect width="64" height="64" fill="url(#hl)"/>
<g stroke="#fff" stroke-width="4.6" stroke-linecap="round" fill="none">
<path d="M25 18.5V45.5M39 18.5V45.5M18.5 25H45.5M18.5 39H45.5"/>
<path d="M25 18.5A6.5 6.5 0 1 0 18.5 25"/><path d="M39 18.5A6.5 6.5 0 1 1 45.5 25"/>
<path d="M25 45.5A6.5 6.5 0 1 1 18.5 39"/><path d="M39 45.5A6.5 6.5 0 1 0 45.5 39"/></g></svg>
"""#)
    static let processes = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff6f61"/><stop offset="1" stop-color="#d62a2a"/></linearGradient><linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect width="64" height="64" fill="url(#bg)"/><rect width="64" height="64" fill="url(#hl)"/>
<path d="M39.65 13.52L50.48 24.35V39.65L39.65 50.48H24.35L13.52 39.65V24.35L24.35 13.52Z" fill="#fff" stroke="#fff" stroke-width="2" stroke-linejoin="round"/>
<path d="M25.5 25.5l13 13M38.5 25.5l-13 13" stroke="#d62a2a" stroke-width="5.2" stroke-linecap="round"/></svg>
"""#)
    static let windowCommands = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8189ff"/><stop offset="1" stop-color="#4a4ee0"/></linearGradient><linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect width="64" height="64" fill="url(#bg)"/><rect width="64" height="64" fill="url(#hl)"/>
<rect x="11.5" y="15" width="41" height="34" rx="6" fill="#fff" fill-opacity=".14" stroke="#fff" stroke-width="3.4"/>
<rect x="16.5" y="20" width="14" height="24" rx="2.6" fill="#fff"/>
<rect x="33.5" y="20" width="14" height="24" rx="2.6" fill="#fff" fill-opacity=".38"/></svg>
"""#)
}
