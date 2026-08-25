import AppKit

/// 让浮层拿到 macOS **标准窗口**那一档窗口阴影。
///
/// 系统的窗口阴影分两档，实测（`CGSGetWindowShadowAndRimParameters` 读的本机值）：
///
/// | 窗口 | standardDeviation | density | offsetY |
/// |---|---|---|---|
/// | 标准窗口（活跃） | 32.941 | 0.40 | 18 |
/// | borderless / 面板 / 非活跃 | 13.176 | 0.25 | 4 |
///
/// 我们的浮层两条都不占：它是 borderless，而且**永远不能拿 key**（拿了 key，
/// Ctrl 释放的时机就测不准 —— 见 `NonActivatingPanel`），所以系统只给第二档，
/// 肉眼就是「比别的窗口飘、阴影薄一圈」。
///
/// 试过的两条公开路都不行：
/// - 改 `level`（normal / floating / popUpMenu）—— 三者阴影完全一样，level 不参与。
/// - 加 `.titled` + 隐藏 titlebar —— 可读参数确实变成 32.941 那档，但**实际渲染
///   没变**（屏上截图对比过）。可读参数跟着 styleMask 走，渲染档跟着活跃状态走，
///   两者不是一回事；只看参数会误判。
///
/// 剩下的就是让 WindowServer 直接按给定参数画。`CGSSetWindowShadowParameters`
/// 是私有 SPI：符号一律 `dlsym` 动态查，查不到就**什么都不做** —— 退回系统默认的
/// 小阴影，不崩、不影响任何功能。
@MainActor
enum WindowShadow {

    /// 标准窗口那一档的实测值。
    private static let standardDeviation: Float = 32.941
    private static let density: Float = 0.40
    private static let offsetY: Int32 = 18

    /// 一旦确认这套 SPI 在本机不可用就不再重试 —— 否则每次唤出浮层都要白跑
    /// 一轮定时器。
    private static var unavailable = false

    /// 把标准窗口那档阴影套到这个窗口上。窗口要已经 order 上屏。
    ///
    /// **必须等 WindowServer 先给窗口初始化好阴影再写**：`orderFront` 刚返回时
    /// 参数读回来全是 0，那会儿写进去的值会被随后的初始化覆盖掉（现象就是
    /// 「自己回读是新值、别的进程读到的和屏幕上看到的都还是旧的小阴影」，
    /// 踩过一次）。实测等 ~28ms（2 次）就绪，落在 70ms 的淡入期内，看不到跳变。
    static func applyStandardWindowShadow(to window: NSWindow, attempt: Int = 0) {
        guard !unavailable,
              let cid = connectionID, let set = setShadow, let get = getShadow else { return }
        // windowNumber 在窗口没上屏时可能 ≤ 0，`UInt32(负数)` 会直接崩。
        guard window.windowNumber > 0 else { return }
        let wid = UInt32(window.windowNumber)

        var sd: Float = 0, den: Float = 0
        var offsetX: Int32 = 0, currentOffsetY: Int32 = 0, flags: UInt32 = 0
        let err = get(cid, wid, &sd, &den, &offsetX, &currentOffsetY, &flags)

        // 这一道 guard 同时判两件事：
        // ① 阴影初始化好了没（没好时读回全 0，见上面的说明）；
        // ② ABI 对不对 —— 这几个 SPI 的浮点参数老 header 写 `float`、新 header
        //    写 `CGFloat`。猜错了不崩，但会读写垃圾数，表现成阴影离谱地大或者
        //    整块黑，比阴影小难看得多。读回的数落在合理区间才说明签名对得上。
        //    只判区间、不比对具体数值 —— 具体值会随系统版本变。
        guard err == 0, sd > 0, sd < 200, den > 0, den <= 1 else {
            guard attempt < 30 else {           // ~240ms 还没就绪，当这套 SPI 不可用
                unavailable = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                guard window.isVisible else { return }
                applyStandardWindowShadow(to: window, attempt: attempt + 1)
            }
            return
        }

        _ = set(cid, wid, standardDeviation, density, 0, offsetY)
        invalidate?(cid, wid)
    }

    // MARK: 私有符号（全部动态查，缺一个就整体不生效）

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetShadowFn = @convention(c) (Int32, UInt32, Float, Float, Int32, Int32) -> Int32
    private typealias GetShadowFn = @convention(c) (Int32, UInt32,
        UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>,
        UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<UInt32>) -> Int32
    private typealias InvalidateFn = @convention(c) (Int32, UInt32) -> Int32

    private static let skyLight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = skyLight, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let connectionID: Int32? = symbol("CGSMainConnectionID", as: MainConnectionFn.self)?()
    private static let setShadow = symbol("CGSSetWindowShadowParameters", as: SetShadowFn.self)
    private static let getShadow = symbol("CGSGetWindowShadowAndRimParameters", as: GetShadowFn.self)
    /// 刷新用，缺了不致命（下一次重绘也会生效），所以不参与前面的 guard。
    private static let invalidate = symbol("CGSInvalidateWindowShadow", as: InvalidateFn.self)
}
