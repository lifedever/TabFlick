import Foundation

/// 搜索面板里的计算（2026-10-28 用户要的）：输入整个是一道算式时，「全部」最上面出一行结果，回车拷贝。
/// 纯函数，checks/calculator-check.swift 校验。
///
/// 自己写的解析器，不用 `NSExpression`：它遇到不合法的输入抛 Objective-C 异常（Swift 接不住，整个 App 崩），
/// 还能调任意函数（`FUNCTION`），拿来算用户打的字不安全。
struct Calculation: Equatable {
    /// 显示用的算式：「15 × 12」「(1280 + 356.5) × 0.88 ÷ 3」
    let expression: String
    let value: Decimal
    /// 显示用：整数部分带千分位「1,234,567.5」；太大太小的写科学计数法
    let display: String
    /// 拷贝 / 粘贴用：不带千分位，贴进表格、输入框直接能用
    let plain: String
}

enum Calculator {
    /// 小数最多留几位（1 ÷ 3 = 0.3333333333）。
    static let fractionDigits = 10
    /// 输入太长不算：粘进来一大段东西不该逐字解析。
    static let maxLength = 256
    /// 括号最多嵌套几层（递归下降，防栈溢出）。
    static let maxDepth = 64
    /// 整数乘方的指数上限：再大不是溢出就是没意义，`pow` 也不该被拿来空转。
    static let maxExponent = 1000

    /// 算得出来就给结果，不是算式（或算不出来：除以零、溢出）给 nil。
    ///
    /// 是不是算式：至少一个二元运算（加减乘除、乘方），只有数字和运算符。以下不算，照常搜索：
    /// 只有一个数（`2026`、`-5`、`50%`）；网址、IP、版本号（`1.2.3` 解析不过）；日期、电话这类
    /// 「同一个减号 / 斜杠连着三串以上整数、其中一串有四位、没有空格括号」（`2026-10-28`、`138-1234-5678`、
    /// `2026/10/28`；`10-4-3` 照算）；带前导零的整数（`010-12345678`）。不然搜日期回车拷走的是 1988。
    ///
    /// 边打边算：末尾还没写完的运算符、左括号先不算，没配对的左括号自动补上 —— 打到 `15*12+` 时
    /// 仍是 `15 × 12 = 180`，结果那一行不会随着每敲一个运算符消失又出现。末尾打了「=」也照样算。
    ///
    /// 乘号除了 `*`、`×` 还认字母 `x`（`15x12`，用户 2026-10-28 要的），只在它前面是一个数、右括号或百分号时；
    /// `0x10` 是十六进制，不算。代价：`1920x1080` 这类分辨率也会算成乘法、结果排在搜索前面。
    static func evaluate(_ input: String) -> Calculation? {
        guard input.count <= maxLength, let tokens = tokenize(input).map(completing), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let result = parser.parse(), parser.binaryOperators > 0,
              !looksLikeDateOrNumberCode(tokens, input: input) else { return nil }
        return Calculation(expression: result.text, value: result.value,
                           display: format(result.value, grouping: true),
                           plain: format(result.value, grouping: false))
    }

    // MARK: 词法

    enum Token: Equatable {
        /// text 是规范化后的原文（全角转半角，千分位逗号留着）
        case number(Decimal, text: String, integer: Bool)
        /// + - * / ^
        case op(Character)
        case percent, open, close
    }

    /// 全角、中文输入法打出来的符号认成半角：不用切英文也能算。
    private static let aliases: [Character: Character] = [
        "×": "*", "✕": "*", "＊": "*", "÷": "/", "／": "/", "＋": "+", "－": "-", "−": "-",
        "（": "(", "）": ")", "％": "%", "＾": "^", "．": ".", "。": ".", "，": ",",
        "＝": "=", "ｘ": "x", "Ｘ": "x",
    ]

    static func tokenize(_ input: String) -> [Token]? {
        var chars: [Character] = []
        for ch in input {
            if ch.isWhitespace { chars.append(" "); continue }
            if let mapped = aliases[ch] { chars.append(mapped); continue }
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
               (0xFF10...0xFF19).contains(scalar.value),
               let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                chars.append(Character(ascii))   // 全角数字
                continue
            }
            chars.append(ch)
        }
        // 末尾的「=」：打完算式习惯性按一下等号，结果照样显示
        while let last = chars.last, last == " " || last == "=" { chars.removeLast() }
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case " ":
                i += 1
            case "+", "-", "*", "/", "^":
                tokens.append(.op(ch)); i += 1
            case "x", "X":
                // 字母 x 当乘号（前面不是运算数的，比如 `x5`，解析时不认）；紧贴着「0」的是十六进制
                if case .number(_, let text, _)? = tokens.last, text == "0", chars[i - 1] != " " { return nil }
                tokens.append(.op("*")); i += 1
            case "%":
                tokens.append(.percent); i += 1
            case "(":
                tokens.append(.open); i += 1
            case ")":
                tokens.append(.close); i += 1
            case "0"..."9", ".":
                guard let (token, next) = number(chars, from: i) else { return nil }
                tokens.append(token)
                i = next
            default:
                return nil
            }
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// 去掉末尾没写完的运算符和左括号，补上没配对的右括号。右括号多了不管，解析时照样不认。
    private static func completing(_ tokens: [Token]) -> [Token] {
        var tokens = tokens
        while let last = tokens.last, last == .open || { if case .op = last { return true } else { return false } }() {
            tokens.removeLast()
        }
        var open = 0
        for token in tokens {
            if token == .open { open += 1 } else if token == .close { open -= 1 }
        }
        if open > 0 { tokens += Array(repeating: .close, count: open) }
        return tokens
    }

    /// 一个数：整数部分可以带千分位（逗号后面必须正好三位），小数点后面必须有数字（`5.` 不算，多半没打完）。
    private static func number(_ chars: [Character], from start: Int) -> (Token, Int)? {
        var i = start
        var digits = ""
        var text = ""
        func isDigit(_ index: Int) -> Bool { index < chars.count && chars[index].isASCII && chars[index].isNumber }
        while isDigit(i) { digits.append(chars[i]); text.append(chars[i]); i += 1 }
        // 千分位：1,234,567
        if !digits.isEmpty, digits.count <= 3, i < chars.count, chars[i] == "," {
            while i < chars.count, chars[i] == "," {
                guard isDigit(i + 1), isDigit(i + 2), isDigit(i + 3), !isDigit(i + 4) else { return nil }
                text.append(","); i += 1
                for _ in 0..<3 { digits.append(chars[i]); text.append(chars[i]); i += 1 }
            }
        } else if i < chars.count, chars[i] == "," {
            return nil
        }
        var integer = true
        if i < chars.count, chars[i] == "." {
            guard isDigit(i + 1) else { return nil }
            integer = false
            digits.append("."); text.append("."); i += 1
            while isDigit(i) { digits.append(chars[i]); text.append(chars[i]); i += 1 }
        }
        guard !digits.isEmpty, digits.count <= 40,
              let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (.number(value, text: text, integer: integer), i)
    }

    /// 日期、电话、编号这类：同一个减号或斜杠连着两次以上、全是整数、有一串四位以上、没有空格和括号；
    /// 或者有带前导零的整数。
    private static func looksLikeDateOrNumberCode(_ tokens: [Token], input: String) -> Bool {
        var ops: [Character] = []
        var allIntegers = true
        var longest = 0
        for token in tokens {
            switch token {
            case .number(_, let text, let integer):
                if !integer { allIntegers = false }
                let digits = text.filter { $0 != "," }
                if integer, digits.count > 1, digits.hasPrefix("0") { return true }
                longest = max(longest, digits.count)
            case .op(let op):
                ops.append(op)
            case .open, .close, .percent:
                return false
            }
        }
        let spaced = input.contains { $0.isWhitespace }
        guard !spaced, allIntegers, ops.count >= 2, longest >= 4, let first = ops.first,
              first == "-" || first == "/" else { return false }
        return ops.allSatisfy { $0 == first }
    }

    // MARK: 语法
    //
    // expr    := term (('+' | '-') term)*
    // term    := unary (('*' | '/') unary)*
    // unary   := ('+' | '-') unary | power
    // power   := postfix ('^' unary)?          右结合；-2^2 = -(2^2)
    // postfix := primary '%'?
    // primary := number | '(' expr ')'
    //
    // 百分号照计算器的习惯：`200 * 15%` = 30（15% 就是 0.15），`200 + 15%` = 230、`200 - 15%` = 170
    //（加减一个百分数是「加减它的百分之几」，算价税、折扣都这么写）。

    struct Operand {
        let value: Decimal
        let text: String
        /// 这一项本身就是「X%」（没再参与乘除）：加减时按「左边的 X%」算
        var percentOf: Decimal?
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0
        private(set) var binaryOperators = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parse() -> Operand? {
            guard let result = expression(), position == tokens.count else { return nil }
            return result
        }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func expression() -> Operand? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Calculator.maxDepth, var left = term() else { return nil }
            while case .op(let op) = current, op == "+" || op == "-" {
                position += 1
                guard let right = term() else { return nil }
                binaryOperators += 1
                // 加减一个百分数：左边的百分之几
                let amount = right.percentOf.map { left.value * $0 / 100 } ?? right.value
                let value = op == "+" ? left.value + amount : left.value - amount
                guard !value.isNaN else { return nil }
                left = Operand(value: value, text: left.text + (op == "+" ? " + " : " − ") + right.text)
            }
            return left
        }

        private mutating func term() -> Operand? {
            guard var left = unary() else { return nil }
            while case .op(let op) = current, op == "*" || op == "/" {
                position += 1
                guard let right = unary() else { return nil }
                binaryOperators += 1
                if op == "/", right.value.isZero { return nil }
                let value = op == "*" ? left.value * right.value : left.value / right.value
                guard !value.isNaN else { return nil }
                left = Operand(value: value, text: left.text + (op == "*" ? " × " : " ÷ ") + right.text)
            }
            return left
        }

        private mutating func unary() -> Operand? {
            if case .op(let op) = current, op == "+" || op == "-" {
                position += 1
                depth += 1
                defer { depth -= 1 }
                guard depth <= Calculator.maxDepth, let operand = unary() else { return nil }
                if op == "+" { return operand }
                return Operand(value: -operand.value, text: "−" + operand.text, percentOf: operand.percentOf.map { -$0 })
            }
            return power()
        }

        private mutating func power() -> Operand? {
            guard let base = postfix() else { return nil }
            guard case .op("^") = current else { return base }
            position += 1
            guard let exponent = unary() else { return nil }
            binaryOperators += 1
            guard let value = Calculator.power(base.value, exponent.value) else { return nil }
            return Operand(value: value, text: base.text + "^" + exponent.text)
        }

        private mutating func postfix() -> Operand? {
            guard let operand = primary() else { return nil }
            guard current == .percent else { return operand }
            position += 1
            return Operand(value: operand.value / 100, text: operand.text + "%", percentOf: operand.value)
        }

        private mutating func primary() -> Operand? {
            switch current {
            case .number(let value, let text, _):
                position += 1
                return Operand(value: value, text: text)
            case .open:
                position += 1
                guard let inner = expression(), current == .close else { return nil }
                position += 1
                return Operand(value: inner.value, text: "(" + inner.text + ")")
            default:
                return nil
            }
        }
    }

    /// 乘方：整数指数走 Decimal（精确），小数指数走 Double（`2^0.5`）；溢出、负数开偶次方给 nil。
    static func power(_ base: Decimal, _ exponent: Decimal) -> Decimal? {
        var rounded = Decimal()
        var exp = exponent
        NSDecimalRound(&rounded, &exp, 0, .plain)
        if rounded == exponent {
            // 先夹范围再转 Int：超出 Int64 的 Decimal 转过去是乱值
            guard abs(rounded) <= Decimal(maxExponent) else { return nil }
            let n = NSDecimalNumber(decimal: rounded).intValue
            if n >= 0 {
                let value = pow(base, n)
                return value.isNaN ? nil : value
            }
            guard !base.isZero else { return nil }
            let value = 1 / pow(base, -n)
            return value.isNaN ? nil : value
        }
        let value = Foundation.pow(NSDecimalNumber(decimal: base).doubleValue, NSDecimalNumber(decimal: exponent).doubleValue)
        guard value.isFinite else { return nil }
        return Decimal(value)
    }

    // MARK: 格式

    private static let scientificFrom = Decimal(sign: .plus, exponent: 21, significand: 1)

    /// 小数最多 10 位、去掉末尾的 0；绝对值到 1e21 以上、或不为 0 却小到 10 位小数里放不下的，写科学计数法。
    /// 小数点一律是「.」，和输入的写法一致。
    static func format(_ value: Decimal, grouping: Bool) -> String {
        if value.isZero { return "0" }
        let magnitude = abs(value)
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, fractionDigits, .plain)
        if magnitude >= scientificFrom || rounded.isZero {
            return scientific(value)
        }
        var text = "\(rounded)"
        if text == "-0" { text = "0" }
        guard grouping else { return text }
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = String(parts[0])
        if integer.count > 3 {
            var grouped = ""
            for (offset, ch) in integer.enumerated() {
                if offset > 0, (integer.count - offset) % 3 == 0 { grouped.append(",") }
                grouped.append(ch)
            }
            integer = grouped
        }
        return (negative ? "-" : "") + integer + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// 「1.606938044e60」：有效数字 10 位，指数不写加号。
    private static func scientific(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        let text = String(format: "%.10g", double)
        guard let e = text.firstIndex(of: "e") else { return text }
        var mantissa = String(text[..<e])
        if mantissa.contains(".") {
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
        }
        var exponent = String(text[text.index(after: e)...])
        if exponent.hasPrefix("+") { exponent.removeFirst() }
        let negative = exponent.hasPrefix("-")
        if negative { exponent.removeFirst() }
        while exponent.count > 1, exponent.hasPrefix("0") { exponent.removeFirst() }
        return mantissa + "e" + (negative ? "-" : "") + exponent
    }
}
