// Calculator（搜索面板里的计算）的校验：算得对不对、哪些输入算式、哪些照常搜索、结果怎么显示。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/Calculator.swift checks/calculator-check.swift \
//          -o /tmp/calccheck && /tmp/calccheck
//
// 期望值一律手写。

import Foundation

@main
struct CalculatorCheck {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)   // 失败走 fatalError，不关缓冲的话打印全丢在管道里
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1; print("✗ \(name) \(detail())") }
        }
        /// 断言算出来的显示结果（nil = 不算式）
        func expect(_ input: String, _ display: String?, _ name: String? = nil) {
            let got = Calculator.evaluate(input)?.display
            check(name ?? input, got == display, "→ \(got ?? "nil")，应为 \(display ?? "nil")")
        }

        // 四则运算、优先级、括号
        expect("15*12", "180")
        expect("1+2*3", "7", "先乘除后加减")
        expect("(1+2)*3", "9")
        expect("10-4-3", "3", "减法左结合")
        expect("10 - 4 - 3", "3", "带空格")
        expect("100/8", "12.5")
        expect("8/4/2", "1", "除法左结合")
        expect("(1280+356.5)*0.88/3", "480.04")
        expect("0.1+0.2", "0.3", "十进制算，不出 0.30000000000000004")
        expect("1/3", "0.3333333333", "小数留 10 位")
        expect("2/3", "0.6666666667", "四舍五入")
        expect(".5*4", "2", "小数点开头")
        expect("1.50*2", "3", "末尾的 0 去掉")
        expect("3-5", "-2", "负数结果")
        expect("0.1*3-0.3", "0", "零")
        // 正负号、乘方
        expect("-3*-2", "6", "一元负号")
        expect("+3*2", "6", "一元正号")
        expect("2*--3", "6", "双重负号")
        expect("2^10", "1,024")
        expect("-2^2", "-4", "负号比乘方低：-(2^2)")
        expect("2^3^2", "512", "乘方右结合")
        expect("2^-1", "0.5", "负指数")
        expect("4^0.5", "2", "小数指数")
        expect("2^0.5", "1.4142135624")
        expect("(-8)^0.5", nil, "负数开平方算不出")
        expect("2^5000", nil, "指数太大")
        expect("10^30*10^30*10^30*10^30*10^30*10^30", nil, "溢出")
        // 百分号（用户定的：当百分号，不当取余）
        expect("200*15%", "30")
        expect("200+15%", "230", "加一个百分数 = 加它的百分之几")
        expect("200-15%", "170")
        expect("200/50%", "400")
        expect("15%+3", "3.15", "百分数在前就是 0.15")
        expect("50%", nil, "只有一个百分数不算")
        // 全角 / 中文输入法打出来的符号
        expect("15×12", "180")
        expect("15÷4", "3.75")
        expect("１５＊１２", "180", "全角数字和星号")
        expect("（1＋2）×3", "9", "全角括号")
        expect("1。5*2", "3", "中文输入法的句号当小数点")
        expect("10−3", "7", "数学减号")
        // 末尾的等号
        expect("15*12=", "180", "末尾打了等号照样算")
        expect("15*12 = ", "180")
        expect("15*12＝", "180", "全角等号")
        expect("15*12==", "180")
        expect("=", nil)
        expect("1=2", nil, "等号在中间不算")
        expect("=1+2", nil, "等号在开头不算")
        // 字母 x 当乘号
        expect("15x12", "180")
        expect("15 x 12", "180")
        expect("15X12", "180")
        expect("15ｘ12", "180", "全角 x")
        expect("2x(3+1)", "8")
        expect("(1+1)x3", "6")
        expect("50%x2", "1", "百分号后面接 x")
        expect("3x-2", "-6")
        expect("15x12=", "180")
        expect("x5", nil, "x 前面没有数")
        expect("15xx2", nil, "x 前面是运算符")
        expect("15+x2", nil)
        expect("box", nil)
        expect("15x", nil, "末尾的 x 先不算，只剩一个数")
        expect("0x10", nil, "十六进制")
        expect("0x1F", nil)
        expect("0 x 10", "0", "带空格的 0 乘 10 照算")
        expect("10x10", "100", "0 结尾的数后面接 x 照算")
        expect("1920x1080", "2,073,600", "分辨率也会算（用户要 x 当乘号的代价）")
        // 千分位
        expect("1,234*2", "2,468")
        expect("1,234,567+1", "1,234,568")
        expect("1,23*2", nil, "逗号后面不是三位")
        expect("1234,567*2", nil, "逗号前面超过三位")
        expect("1,2345*2", nil, "逗号后面超过三位")
        expect("1,2,3", nil, "逗号分隔的列表")
        // 不算式：照常搜索
        expect("2026", nil, "只有一个数")
        expect("-5", nil, "只有一个负数")
        expect("(5)", nil, "括号里一个数")
        expect("3.14", nil)
        expect("1.2.3", nil, "版本号")
        expect("192.168.1.1", nil, "IP")
        expect("2026-10-28", nil, "日期")
        expect("2026/10/28", nil, "斜杠日期")
        expect("138-1234-5678", nil, "电话")
        expect("010-12345678", nil, "前导零（区号）")
        expect("400-820-8820", nil, "客服电话")
        expect("1-2-3", "-4", "连减但没有四位数：照算")
        expect("1+", nil, "没写完：只剩一个数")
        expect("15*", nil)
        expect("15*12+", "180", "边打边算：末尾的运算符先不算")
        expect("15*12+(", "180", "末尾的左括号也先不算")
        expect("(1+2", "3", "没配对的左括号补上")
        expect("2*(3+", "6")
        expect("1+2)", nil, "右括号多了不算")
        expect("5.", nil, "小数点后没数字")
        expect("5/0", nil, "除以零")
        expect("5/(3-3)", nil)
        expect("abc", nil)
        expect("1+a", nil)
        expect("1e5+1", nil, "不认 e 记数法")
        expect("", nil)
        expect("   ", nil)
        expect("1 000*2", nil, "空格隔开的数字")
        // 日期规则只管「同一个减号 / 斜杠、全是整数、没空格括号」：其他照算
        expect("100-30", "70", "一个减号照算")
        expect("10 - 3 - 2", "5", "带空格的连减照算")
        expect("1.5-0.5-0.5", "0.5", "有小数照算")
        expect("10-3+2", "9", "混了别的运算符照算")
        expect("2026 - 10 - 28", "1,988", "带空格就是在算")
        expect("2026.5-10-28", "1,988.5", "有小数就不是日期")
        // 防御：太长、括号太深
        expect(String(repeating: "1+", count: 200) + "1", nil, "太长")
        expect(String(repeating: "(", count: 100) + "1+1" + String(repeating: ")", count: 100), nil, "括号太深")
        expect(String(repeating: "(", count: 20) + "1+1" + String(repeating: ")", count: 20), "2", "正常的嵌套")
        expect(String(repeating: "-", count: 200) + "1+1", nil, "一串负号")

        // 显示：千分位、科学计数法；拷贝的不带千分位
        let big = Calculator.evaluate("123456*1000")
        check("显示带千分位", big?.display == "123,456,000", big?.display ?? "nil")
        check("拷贝不带千分位", big?.plain == "123456000", big?.plain ?? "nil")
        let negative = Calculator.evaluate("-1234567.5*1")
        check("负数的千分位", negative?.display == "-1,234,567.5" && negative?.plain == "-1234567.5",
              "\(negative?.display ?? "nil") / \(negative?.plain ?? "nil")")
        expect("999+1", "1,000", "四位开始分组")
        expect("99+1", "100")
        expect("2^64", "18,446,744,073,709,551,616", "20 位整数照常写")
        expect("10^21+0", "1e21", "1e21 起写科学计数法")
        expect("2^200", "1.606938044e60")
        expect("1/10^11", "1e-11", "小到 10 位小数放不下")
        expect("1/10^5", "0.00001")

        // 显示用的算式
        func expression(_ input: String, _ expected: String) {
            let got = Calculator.evaluate(input)?.expression
            check("算式「\(input)」", got == expected, "→ \(got ?? "nil")，应为 \(expected)")
        }
        expression("15*12", "15 × 12")
        expression("(1280+356.5)*0.88/3", "(1280 + 356.5) × 0.88 ÷ 3")
        expression("200+15%", "200 + 15%")
        expression("10-3", "10 − 3")
        expression("-3*-2", "−3 × −2")
        expression("2^10", "2^10")
        expression("１５＊１２", "15 × 12")
        expression("1,234*2", "1,234 × 2")
        expression("+3*2", "3 × 2")
        expression("15*12+", "15 × 12")
        expression("(1+2", "(1 + 2)")
        expression("15x12=", "15 × 12")

        if failures > 0 {
            print("\(failures) 处不对")
            fatalError("Calculator 校验未通过")
        }
        print("全部通过")
    }
}
