/// 全局卡片布局的「视觉相邻」几何。
///
/// 抽成没有任何依赖的纯函数，是为了能单独编译验证（`helper/checks/`）：
/// 全局卡片是**每个浏览器各自换行**的，每组最后一行都可能不满，扁平的
/// `cursor ± cols` 会算到别的组里去。这类索引算术在边界上极易出错，而出错的
/// 表现只是「按方向键跳到了奇怪的地方」—— 不崩溃、不报错、不写日志，
/// 全靠人肉发现。
enum GridGeometry {

    /// 视觉上正上方 / 正下方那一项的位置；已经在最顶行或最底行时返回 nil（不回绕）。
    ///
    /// 跨组是**有意**的：方向键走的是眼睛看到的相邻，跟标签属于哪个浏览器无关。
    /// 在本组最后一行按 ↓ 会进入下一组的第一行、同列；该行不够宽就夹到行尾。
    ///
    /// - Parameters:
    ///   - cursor: 当前位置（扁平下标）。
    ///   - groupStarts: 每个分组第一项的扁平下标，升序，首项为 0。
    ///   - total: 项目总数。
    ///   - cols: 每行列数。
    ///   - up: true 向上、false 向下。
    static func rowNeighbor(of cursor: Int,
                            groupStarts: [Int],
                            total: Int,
                            cols: Int,
                            up: Bool) -> Int? {
        guard cols > 0, cursor >= 0, cursor < total,
              let groupIndex = groupStarts.lastIndex(where: { $0 <= cursor }) else { return nil }

        let groupStart = groupStarts[groupIndex]
        let groupEnd = groupIndex + 1 < groupStarts.count ? groupStarts[groupIndex + 1] : total
        let local = cursor - groupStart
        let col = local % cols
        let rowStart = local - col

        if up {
            if rowStart >= cols {
                // 组内上一行。它不是本组最后一行，必然是满的，同列一定存在。
                return groupStart + rowStart - cols + col
            }
            // 本组第一行 → 上一组的最后一行
            guard groupIndex > 0 else { return nil }
            let prevStart = groupStarts[groupIndex - 1]
            let prevCount = groupStart - prevStart
            let prevLastRowStart = (prevCount - 1) / cols * cols
            let width = min(cols, prevCount - prevLastRowStart)
            return prevStart + prevLastRowStart + min(col, width - 1)
        }

        let count = groupEnd - groupStart
        let nextRowStart = rowStart + cols
        if nextRowStart < count {
            // 组内下一行，可能不满 —— 夹到该行最后一张
            return groupStart + nextRowStart + min(col, min(cols, count - nextRowStart) - 1)
        }
        // 本组最后一行 → 下一组的第一行
        guard groupIndex + 1 < groupStarts.count else { return nil }
        let nextStart = groupStarts[groupIndex + 1]
        let nextEnd = groupIndex + 2 < groupStarts.count ? groupStarts[groupIndex + 2] : total
        return nextStart + min(col, min(cols, nextEnd - nextStart) - 1)
    }
}
