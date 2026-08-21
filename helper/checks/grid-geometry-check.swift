// GridGeometry 的穷举验证。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/GridGeometry.swift \
//          checks/grid-geometry-check.swift -o /tmp/gridcheck && /tmp/gridcheck
//
// 思路：把布局**真的摆出来**（一行一个数组），再按「同列、上一行/下一行、
// 不够宽就夹到行尾」去找答案 —— 这是「视觉相邻」的定义本身。然后拿它跟
// GridGeometry 里那套模运算逐个对。两种实现方式差得够远，边界上的 off-by-one
// 藏不住。

/// 按「每组各自换行」把项目摆成二维；元素是扁平下标。
func layout(groupSizes: [Int], cols: Int) -> [[Int]] {
    var rows: [[Int]] = []
    var base = 0
    for n in groupSizes {
        var i = 0
        while i < n {
            let width = min(cols, n - i)
            rows.append((0..<width).map { base + i + $0 })
            i += width
        }
        base += n
    }
    return rows
}

/// 视觉相邻的定义：同列、相邻行；那一行不够宽就落在行尾。
func expected(cursor: Int, rows: [[Int]], up: Bool) -> Int? {
    guard let row = rows.firstIndex(where: { $0.contains(cursor) }),
          let col = rows[row].firstIndex(of: cursor) else { return nil }
    let target = up ? row - 1 : row + 1
    guard rows.indices.contains(target) else { return nil }
    return rows[target][min(col, rows[target].count - 1)]
}

func starts(of groupSizes: [Int]) -> [Int] {
    var result: [Int] = []
    var base = 0
    for n in groupSizes {
        result.append(base)
        base += n
    }
    return result
}

@main
struct Check {
    static func main() {
        var cases = 0
        var failures = 0

        // 组数 1…3、每组 1…9 个、列数 1…5：覆盖满行、缺一个、只剩一个等所有边界
        var sizeSets: [[Int]] = []
        for a in 1...9 {
            sizeSets.append([a])
            for b in 1...9 {
                sizeSets.append([a, b])
                for c in 1...9 { sizeSets.append([a, b, c]) }
            }
        }

        for sizes in sizeSets {
            for cols in 1...5 {
                let rows = layout(groupSizes: sizes, cols: cols)
                let total = sizes.reduce(0, +)
                let groupStarts = starts(of: sizes)

                for cursor in 0..<total {
                    for up in [true, false] {
                        cases += 1
                        let want = expected(cursor: cursor, rows: rows, up: up)
                        let got = GridGeometry.rowNeighbor(of: cursor,
                                                           groupStarts: groupStarts,
                                                           total: total,
                                                           cols: cols,
                                                           up: up)
                        if want != got {
                            failures += 1
                            if failures <= 10 {
                                print("✗ sizes=\(sizes) cols=\(cols) cursor=\(cursor) "
                                      + "\(up ? "↑" : "↓") 期望 \(want.map(String.init) ?? "nil") "
                                      + "实际 \(got.map(String.init) ?? "nil")")
                            }
                        }
                    }
                }
            }
        }

        // 越界 / 空列表这些异常入参不能崩，也不能给出位置
        let guards: [(Int, [Int], Int, Int)] = [
            (-1, [0], 3, 2), (5, [0], 3, 2), (0, [0], 3, 0), (0, [], 0, 2),
        ]
        for (cursor, gs, total, cols) in guards {
            cases += 1
            for up in [true, false] where GridGeometry.rowNeighbor(
                of: cursor, groupStarts: gs, total: total, cols: cols, up: up) != nil {
                failures += 1
                print("✗ 异常入参应返回 nil：cursor=\(cursor) starts=\(gs) total=\(total) cols=\(cols)")
            }
        }

        print(failures == 0
              ? "全部通过（\(cases) 组）"
              : "\(failures) 项失败（共 \(cases) 组）")
        if failures > 0 { fatalError("GridGeometry 校验未通过") }
    }
}
