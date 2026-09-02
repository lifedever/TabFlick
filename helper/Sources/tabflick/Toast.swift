import AppKit

/// 屏幕底部滑出的轻提示（toast）。
///
/// 拷贝路径、收藏、取消收藏这类菜单动作做完菜单就收起了，没有任何回响 ——
/// toast 是唯一的「做成了」信号。
///
/// 面板绝不拿 key（红线同切换器浮层），也不收鼠标事件 —— 纯展示，
/// 出现约 2 秒自己退场。内容用 AppKit 直排（NSVisualEffectView + NSTextField），
/// 文字尺寸用 NSAttributedString 自己量 —— 不碰 NSHostingView 的
/// fittingSize（macOS 15/26 上不可信，见 CLAUDE.md）。
@MainActor
enum Toast {

    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let hPad: CGFloat = 16
    private static let vPad: CGFloat = 10
    private static let maxWidth: CGFloat = 480
    /// 距屏幕可见区底边的高度。
    private static let bottomInset: CGFloat = 64
    private static let slideDistance: CGFloat = 20
    private static let visibleDuration: TimeInterval = 2.0

    static func show(_ text: String) {
        dismissNow()   // 连续动作时新 toast 顶掉旧的，不排队

        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = min(textSize.width.rounded(.up) + hPad * 2, maxWidth)
        let height = textSize.height.rounded(.up) + vPad * 2

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.state = .active
        // 圆角必须走 maskImage —— layer.cornerRadius 裁不住 vibrancy 材质，
        // 窗口阴影也只认 maskImage 的形状（同切换器浮层那条）。
        effect.maskImage = capsuleMask(height: height)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: hPad, y: vPad,
                             width: width - hPad * 2,
                             height: textSize.height.rounded(.up))
        effect.addSubview(label)

        // toast 跟着用户在哪块屏操作走（菜单刚点完，鼠标就在那块屏上）
        guard let screen = screenUnderMouse() else { return }
        let finalOrigin = NSPoint(x: (screen.visibleFrame.midX - width / 2).rounded(),
                                  y: screen.visibleFrame.minY + bottomInset)

        let p = NSPanel(contentRect: NSRect(x: finalOrigin.x,
                                            y: finalOrigin.y - slideDistance,
                                            width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true   // 纯展示，点击穿透
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = effect
        p.alphaValue = 0
        panel = p
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: finalOrigin, size: p.frame.size), display: true)
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: visibleDuration, repeats: false) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { dismiss() } }
        }
    }

    /// 滑回底部并淡出。
    private static func dismiss() {
        guard let p = panel else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        panel = nil
        let target = NSRect(x: p.frame.origin.x, y: p.frame.origin.y - slideDistance,
                            width: p.frame.width, height: p.frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            p.animator().setFrame(target, display: true)
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    private static func dismissNow() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// 胶囊形 maskImage（九宫格拉伸），同时决定材质形状和窗口阴影形状。
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
