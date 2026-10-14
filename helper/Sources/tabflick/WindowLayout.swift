import CoreGraphics

/// 窗口命令（搜索面板里的「居中」「左半屏」……）算出来的目标位置。
///
/// 坐标全用 AX 那一套：全局坐标、原点在主屏左上角、y 向下。NSScreen 是左下原点，调用方换算一次
/// 再传进来（`visibleFrame` 已经去掉了菜单栏和程序坞），这里不再碰坐标系。
///
/// 抽成零依赖的纯函数是为了能单独编译验证（`checks/window-layout-check.swift`）：
/// 算错的表现只是「窗口落到奇怪的地方 / 左右半屏之间差一条缝」，不报错、不写日志。
enum WindowLayout {

    enum Placement: CaseIterable {
        case center, maximize, leftHalf, rightHalf
    }

    /// 移到别的屏幕时，离「最大化 / 左半 / 右半」这么近就当作就是它：终端这类按字符格调尺寸的
    /// App 落不到整数点上，差个十几点是常态。
    static let snapTolerance: CGFloat = 20

    /// 在 `visible` 这块屏幕上按 `placement` 摆好的位置。
    static func frame(_ placement: Placement, window: CGRect, visible: CGRect) -> CGRect {
        switch placement {
        case .maximize:
            return visible
        case .leftHalf:
            // 左半取整、右半拿剩下的：两半严丝合缝，奇数宽度也不留缝、不重叠
            return CGRect(x: visible.minX, y: visible.minY,
                          width: (visible.width / 2).rounded(.down), height: visible.height)
        case .rightHalf:
            let left = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.minX + left, y: visible.minY,
                          width: visible.width - left, height: visible.height)
        case .center:
            // 大小不变；比屏幕大的缩到屏幕那么大
            let width = min(window.width, visible.width)
            let height = min(window.height, visible.height)
            return CGRect(x: visible.minX + ((visible.width - width) / 2).rounded(.down),
                          y: visible.minY + ((visible.height - height) / 2).rounded(.down),
                          width: width, height: height)
        }
    }

    /// 窗口在哪块屏幕上：和它重叠面积最大的那块；一块都不挨着（被拖到屏幕外了）时取中心离得最近的。
    static func screenIndex(of window: CGRect, in screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = window.intersection(screen)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (index, area) }
        }
        if let best { return best.index }
        func distance(_ screen: CGRect) -> CGFloat {
            let dx = screen.midX - window.midX, dy = screen.midY - window.midY
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// 「下一个显示器」：按从左到右（左边对齐的按从上到下）排，最后一块回到第一块。
    /// 不按 `NSScreen.screens` 的顺序 —— 那是系统登记的先后，和屏幕摆在哪无关。
    static func nextScreenIndex(after index: Int, in screens: [CGRect]) -> Int {
        let order = screens.indices.sorted {
            screens[$0].minX != screens[$1].minX ? screens[$0].minX < screens[$1].minX
                                                 : screens[$0].minY < screens[$1].minY
        }
        guard let position = order.firstIndex(of: index) else { return index }
        return order[(position + 1) % order.count]
    }

    /// 把窗口从 `source` 这块屏幕移到 `target`。正好是最大化 / 左半 / 右半 / 居中的，到那边还是；
    /// 别的保持大小（放不下就缩），中心按它在原屏幕里的相对位置落过去。居中也得单独认：两块屏
    /// 尺寸差得多时，按比例换算会把取整误差放大，落到那边偏一两个点。
    static func moved(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        for placement in [Placement.maximize, .leftHalf, .rightHalf, .center]
        where same(window, frame(placement, window: window, visible: source), tolerance: snapTolerance) {
            return frame(placement, window: window, visible: target)
        }
        let width = min(window.width, target.width)
        let height = min(window.height, target.height)
        let rx = source.width > 0 ? (window.midX - source.minX) / source.width : 0.5
        let ry = source.height > 0 ? (window.midY - source.minY) / source.height : 0.5
        let x = (target.minX + rx * target.width - width / 2).rounded()
        let y = (target.minY + ry * target.height - height / 2).rounded()
        // 窗口原来就有一截在屏幕外的话，按比例算出来也会出界：整个夹回屏幕里
        return CGRect(x: min(max(x, target.minX), target.maxX - width),
                      y: min(max(y, target.minY), target.maxY - height),
                      width: width, height: height)
    }

    /// 居中用多大（用户 2026-10-14 要的）：从我们摆的半屏、最大化居中时，要回到挪之前的大小，
    /// 不是把半屏那么大的窗口挪到中间。判据是窗口还停在我们上次摆的地方（`applied`）；
    /// 之后用户自己调过大小，或者没有记录（系统自带的平铺摆的半屏），就按现在的大小。
    static func centerSize(current: CGRect, original: CGRect?, applied: CGRect?) -> CGSize {
        guard let original, let applied, same(applied, current) else { return current.size }
        return original.size
    }

    /// 两个位置算不算同一个。
    static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
