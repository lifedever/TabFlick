import AppKit
import SwiftUI

// 插件图标（2026-11-07 用户要的：每个插件一个有代表性的图标，外置插件也能带自己的）。
//
// 插件是一家人，和设置里的系统页一眼分得开（同一天用户定的「浅色底」）：系统页是彩色底 + 白色图形，
// 插件反过来 —— **底由 TabFlick 画**（浅色模式白、深色模式深灰，一圈淡描边，`PluginTileStyle`），
// 插件只交透明背景上的彩色图形（SVG 或 PNG，正方形，四周自己留白）。圆角统一裁（`side × 0.27` 的连续圆角）。
// 没有图标、或者图读不出来，同一块底上画 `symbol`，颜色用 `tint`。
// 老格式（背景画满的图标，0.26.2 那一版）画上去会盖住底，看着和原来一样，不用特别处理。
// SVG 走系统自己的解析（NSImage 认 public.svg-image），不带第三方库。

/// 插件图标块的底：浅色模式白、深色模式深灰（比侧边栏、菜单亮一档），一圈 0.5pt 的淡描边。
enum PluginTileStyle {
    nonisolated static func fill(dark: Bool) -> NSColor { dark ? NSColor(white: 0.26, alpha: 1) : .white }
    nonisolated static func edge(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10) }
    /// 没有图标时画的符号占多大
    nonisolated static let symbolScale: CGFloat = 0.54
}

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

    /// 菜单项用的图标块（菜单里没有 SwiftUI，自己画）：和 `PluginIconTile` 同一个样子。用绘制回调，按屏幕倍数
    /// 和当时的外观现画（菜单每次打开都重建这一项，切深浅色跟得上）。
    nonisolated static func menuImage(icon: NSImage?, symbol: String, tint: NSColor, side: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let radius = side * 0.27
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            PluginTileStyle.fill(dark: dark).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let icon {
                icon.draw(in: rect)
            } else {
                let config = NSImage.SymbolConfiguration(pointSize: side * PluginTileStyle.symbolScale, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let size = glyph.size
                    glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                          width: size.width, height: size.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            PluginTileStyle.edge(dark: dark).setStroke()
            edge.stroke()
            return true
        }
    }

    /// 菜单里插件那一行的图标。
    @MainActor static func menuImage(for plugin: Plugin) -> NSImage {
        menuImage(icon: plugin.icon, symbol: plugin.symbol, tint: NSColor(plugin.tint))
    }
}

/// 插件的图标块（设置、面板、商店共用）：中性底 + 淡描边，上面画插件的图标；没有图标画 `symbol`，颜色用 `tint`。
struct PluginIconTile: View {
    let icon: NSImage?
    let symbol: String
    let tint: Color
    let side: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
        let dark = scheme == .dark
        ZStack {
            shape.fill(Color(nsColor: PluginTileStyle.fill(dark: dark)))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: side * PluginTileStyle.symbolScale, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: PluginTileStyle.edge(dark: dark)), lineWidth: 0.5))
    }
}

/// 内置插件的图标，SVG 源码就在这里（外置插件的放在各自目录的 icon.svg）。
/// 改图标：改这里的 SVG，viewBox 64×64、背景透明、图形用中间调的颜色（白底和深灰底上都要看得清），
/// 在深浅两种底上 16 / 26pt 都看一眼。
@MainActor
enum BuiltinPluginIcons {
    private static func image(svg: String) -> NSImage? { PluginIconLoader.image(svg: svg) }

    static let calculator = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g stroke="#ff9500" stroke-width="4.6" stroke-linecap="round" fill="none"><path d="M21 15v12M15 21h12"/><path d="M37 21h12"/><path d="M16.8 38.8l8.4 8.4M25.2 38.8l-8.4 8.4"/></g>
<circle cx="43" cy="43" r="10" fill="#ff9500"/><path d="M38 40.3h10M38 45.7h10" stroke="#fff" stroke-width="3.4" stroke-linecap="round"/></svg>
"""#)
    static let appCommands = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g stroke="#ff9500" stroke-width="5" stroke-linecap="round" fill="none"><path d="M25 18.5V45.5M39 18.5V45.5M18.5 25H45.5M18.5 39H45.5"/>
<path d="M25 18.5A6.5 6.5 0 1 0 18.5 25"/><path d="M39 18.5A6.5 6.5 0 1 1 45.5 25"/><path d="M25 45.5A6.5 6.5 0 1 1 18.5 39"/><path d="M39 45.5A6.5 6.5 0 1 0 45.5 39"/></g></svg>
"""#)
    static let processes = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M40.4 11.7L52.3 23.6V40.4L40.4 52.3H23.6L11.7 40.4V23.6L23.6 11.7Z" fill="#ff3b30" stroke="#ff3b30" stroke-width="3" stroke-linejoin="round"/>
<path d="M25 25l14 14M39 25l-14 14" stroke="#fff" stroke-width="5" stroke-linecap="round"/></svg>
"""#)
    static let windowCommands = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="10.5" y="14.5" width="43" height="35" rx="6.5" fill="none" stroke="#5e5ce6" stroke-width="3.6"/>
<rect x="15.5" y="19.5" width="15" height="25" rx="2.8" fill="#5e5ce6"/><rect x="33.5" y="19.5" width="15" height="25" rx="2.8" fill="#5e5ce6" fill-opacity=".45"/></svg>
"""#)
    /// 一页文档压一个钟（同计算器：线条画主体、实心圆里画白色的细节）
    static let recentFiles = image(svg: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g stroke="#007aff" stroke-width="3.8" stroke-linejoin="round" stroke-linecap="round" fill="none"><path d="M17 9.5h15.5l11.5 11.5v26a4.5 4.5 0 0 1-4.5 4.5H17a4.5 4.5 0 0 1-4.5-4.5V14a4.5 4.5 0 0 1 4.5-4.5z"/><path d="M32.5 9.5v7a4.5 4.5 0 0 0 4.5 4.5h7"/></g>
<circle cx="44" cy="44" r="12.5" fill="#007aff"/><path d="M44 37.5V44l4.2 2.8" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>
"""#)
}
