// 开发工具箱插件：TZ=Asia/Shanghai node plugins/devtools/tests/devtools.test.js
process.env.TZ = "Asia/Shanghai"
const assert = require("assert")
const { load, test, done, plain } = require("../../_shared/harness")
const dir = __dirname + "/.."

;(async () => {
  const { sandbox } = load(dir)
  const names = (q) => sandbox.conversions(q).map((c) => c.name)
  const value = (q, name) => (sandbox.conversions(q).find((c) => c.name === name) || {}).value

  await test("Base64：中文、补位、URL 安全、解不开的不列", () => {
    assert.strictEqual(sandbox.base64Encode("你好 TabFlick"), Buffer.from("你好 TabFlick").toString("base64"))
    for (const s of ["a", "ab", "abc", "abcd", "✓ ok", "🙂"]) {
      assert.strictEqual(sandbox.base64Encode(s), Buffer.from(s).toString("base64"), s)
      assert.strictEqual(sandbox.base64Decode(Buffer.from(s + "!!").toString("base64")), s + "!!", s)
    }
    assert.strictEqual(sandbox.base64Decode("5L2g5aW9"), "你好", "不带补位")
    assert.strictEqual(sandbox.base64Decode("_-8"), null, "解出来是乱码的不算")
    assert.strictEqual(sandbox.base64Decode("hello world"), null)
  })

  await test("时间戳 ↔ 日期（北京时间）", () => {
    assert.strictEqual(value("1762425000", "时间戳 → 本地时间"), "2025-11-06 18:30:00")
    assert.strictEqual(value("1762425000000", "时间戳 → ISO（UTC）"), "2025-11-06T10:30:00.000Z")
    assert.strictEqual(value("2025-11-06 18:30:00", "日期 → 时间戳（秒）"), "1762425000")
    assert.strictEqual(value("2025/11/06", "日期 → 时间戳（毫秒）") !== undefined, true)
  })

  await test("JSON：格式化、压缩；坏 JSON 说一句、不给拷贝", () => {
    assert.strictEqual(value('{"a":[1,2]}', "JSON 格式化"), '{\n  "a": [\n    1,\n    2\n  ]\n}')
    assert.strictEqual(value('{ "a" : 1 }', "JSON 压缩"), '{"a":1}')
    const p = load(dir)
    const rows = p.sandbox.list("{bad")
    assert.strictEqual(rows[0].subtitle, "JSON 解析不了")
    assert.deepStrictEqual(plain(rows[0].actions), [])
  })

  await test("URL 编解码、命名风格", () => {
    assert.strictEqual(value("a b&c", "URL 编码"), "a%20b%26c")
    assert.strictEqual(value("a%20b%26c", "URL 解码"), "a b&c")
    assert.ok(!names("abc").includes("URL 编码"), "编码后不变的不列")
    assert.strictEqual(value("user id", "驼峰"), "userId")
    assert.strictEqual(value("userId", "下划线"), "user_id")
    assert.strictEqual(value("user_id", "短横线"), "user-id")
    assert.ok(!names("你好").includes("驼峰"), "不像标识符的不给")
  })

  await test("没输入：UUID、当前时间戳", () => {
    const items = sandbox.conversions("", Date.UTC(2026, 10, 6, 10, 30))
    assert.match(items[0].value, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    assert.strictEqual(items[1].value, "1793961000")
  })

  await test("回车拷贝完整的值（行上标题会截短、换行显示成 ⏎）", () => {
    const p = load(dir)
    const long = JSON.stringify({ text: "x".repeat(300) })
    const rows = p.sandbox.list(long)
    const formatted = rows.find((r) => r.subtitle === "JSON 格式化")
    assert.ok(formatted.title.endsWith("…"))
    assert.ok(formatted.title.includes("⏎"))
    p.sandbox.perform("copy", formatted.id)
    assert.strictEqual(p.copied[0], JSON.stringify({ text: "x".repeat(300) }, null, 2))
    p.sandbox.perform("copy", "nope")
    assert.strictEqual(p.copied.length, 1)
  })

  await test("哈希：MD5、SHA-1、SHA-256 和 node 的 crypto 一致（含补位边界、中文、表情）", () => {
    const crypto = require("crypto")
    const samples = ["", "a", "abc", "你好 TabFlick 🙂", "x".repeat(55), "x".repeat(56), "x".repeat(63), "x".repeat(64), "y".repeat(1000)]
    for (const s of samples) {
      for (const [fn, algo] of [["md5", "md5"], ["sha1", "sha1"], ["sha256", "sha256"]]) {
        assert.strictEqual(sandbox[fn](s), crypto.createHash(algo).update(s, "utf8").digest("hex"), algo + " " + JSON.stringify(s.slice(0, 10)) + " len " + s.length)
      }
    }
    assert.strictEqual(value("hello", "MD5"), "5d41402abc4b2a76b9719d911017c592")
  })

  await test("JWT：载荷、头、过期时间", () => {
    const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url")
    const token = enc({ alg: "HS256", typ: "JWT" }) + "." + enc({ sub: "42", name: "张三", exp: 1762425000, iat: 1762338600 }) + ".sig_-x"
    const items = sandbox.conversions(token, Date.UTC(2025, 10, 6, 8, 30))
    assert.strictEqual(items[0].name, "JWT 载荷")
    assert.strictEqual(JSON.parse(items[0].value).name, "张三")
    assert.strictEqual(JSON.parse(items[1].value).alg, "HS256")
    assert.strictEqual(items[2].name, "JWT 过期时间 · 还有 2 小时")
    assert.strictEqual(items[2].value, "2025-11-06 18:30:00")
    assert.strictEqual(items[3].value, "2025-11-05 18:30:00")
    assert.strictEqual(sandbox.conversions(token, Date.UTC(2025, 10, 9, 10, 30))[2].name, "JWT 过期时间 · 已过期 3 天")
    assert.strictEqual(sandbox.decodeJWT("a.b.c"), null)
    assert.strictEqual(sandbox.decodeJWT(enc({ typ: "x" }) + "." + enc({ a: 1 }) + ".s"), null, "头里没有 alg 不算")
    assert.strictEqual(sandbox.decodeJWT("www.example.com"), null)
  })

  await test("进制：十进制、0x、0b、0o，大数和负数", () => {
    assert.strictEqual(value("255", "十六进制"), "0xff")
    assert.strictEqual(value("255", "二进制"), "0b11111111")
    assert.strictEqual(value("255", "八进制"), "0o377")
    assert.strictEqual(value("0xFF", "十进制"), "255")
    assert.strictEqual(value("0b1010", "十进制"), "10")
    assert.strictEqual(value("0o17", "十六进制"), "0xf")
    assert.strictEqual(value("-10", "十六进制"), "-0xa")
    assert.strictEqual(value("18446744073709551615", "十六进制"), "0xffffffffffffffff")
    assert.strictEqual(value("1_000", "十六进制"), "0x3e8")
    assert.ok(!names("0b102").includes("十进制"), "二进制里有 2 不算")
    assert.ok(!names("007").includes("十六进制"), "前导零不算")
    assert.ok(!names("1.5").includes("十六进制"))
    assert.ok(!names("9".repeat(5000)).includes("十六进制"), "太长的不换进制")
    assert.strictEqual(value("0x" + "f".repeat(64), "十进制").length, 78, "64 位十六进制还给")
  })

  await test("人民币大写", () => {
    const cases = {
      "0": "零元整", "1": "壹元整", "10": "壹拾元整", "100.5": "壹佰元伍角", "1005": "壹仟零伍元整", "1050": "壹仟零伍拾元整",
      "10050": "壹万零伍拾元整", "100000": "壹拾万元整", "100001": "壹拾万零壹元整", "1000000.01": "壹佰万元零壹分",
      "10000100": "壹仟万零壹佰元整", "100000000": "壹亿元整", "100010000": "壹亿零壹万元整", "1000010000": "壹拾亿零壹万元整",
      "1234567890.12": "壹拾贰亿叁仟肆佰伍拾陆万柒仟捌佰玖拾元壹角贰分", "0.05": "伍分", "0.5": "伍角", "0.55": "伍角伍分",
      "20.07": "贰拾元零柒分", "1,234.56": "壹仟贰佰叁拾肆元伍角陆分", "¥88": "捌拾捌元整", "999999999999": "玖仟玖佰玖拾玖亿玖仟玖佰玖拾玖万玖仟玖佰玖拾玖元整",
    }
    for (const [input, expected] of Object.entries(cases)) assert.strictEqual(sandbox.chineseAmount(input, false), expected, input)
    assert.strictEqual(sandbox.chineseAmount("1000000000000", false), null, "超过 9999 亿不给")
    assert.strictEqual(sandbox.chineseAmount("1.234", false), null)
    assert.strictEqual(sandbox.chineseAmount("012", false), null)
    assert.strictEqual(sandbox.chineseAmount("23000", true), "貳萬參仟元整")
    assert.strictEqual(value("1005", "人民币大写"), "壹仟零伍元整")
    assert.ok(!load(dir, { locale: "en" }).sandbox.conversions("1005").some((c) => c.name === "Chinese amount"), "英文界面不给")
  })

  await test("颜色：HEX、RGB、HSL 互转，行首画色块", () => {
    assert.strictEqual(value("#ff8800", "颜色 RGB"), "rgb(255, 136, 0)")
    assert.strictEqual(value("#ff8800", "颜色 HSL"), "hsl(32, 100%, 50%)")
    assert.strictEqual(value("#F80", "颜色 HEX"), "#ff8800")
    assert.ok(!names("#ff8800").includes("颜色 HEX"), "和输入一样的不列")
    assert.strictEqual(value("rgb(255, 136, 0)", "颜色 HEX"), "#ff8800")
    assert.strictEqual(value("rgb(255 136 0 / 50%)", "颜色 HEX"), "#ff880080")
    assert.strictEqual(value("hsl(32, 100%, 50%)", "颜色 HEX"), "#ff8800")
    assert.strictEqual(value("hsl(210deg 50% 40%)", "颜色 RGB"), "rgb(51, 102, 153)")
    assert.strictEqual(value("#ff880080", "颜色 RGB"), "rgba(255, 136, 0, 0.5)")
    assert.strictEqual(sandbox.parseColor("rgb(300, 0, 0)"), null)
    assert.strictEqual(sandbox.parseColor("#ggg"), null)
    const row = load(dir).sandbox.list("#ff880080").find((r) => r.subtitle === "颜色 RGB")
    assert.deepStrictEqual(plain(row.icon), { text: " ", tint: "#ff8800" })
  })

  await test("网址参数：解码、+ 当空格、不带 # 后面的", () => {
    const items = sandbox.conversions("https://example.com/s?q=%E4%BD%A0%E5%A5%BD+world&lang=zh&flag#top")
    const params = items.filter((c) => c.name.startsWith("网址参数")).map((c) => [c.name, c.value])
    assert.deepStrictEqual(plain(params), [["网址参数 · q", "你好 world"], ["网址参数 · lang", "zh"], ["网址参数 · flag", ""]])
    assert.ok(!names("https://example.com/").some((n) => n.startsWith("网址参数")))
  })

  await test("Unicode、HTML、JSON 字符串的转义和反转义", () => {
    assert.strictEqual(value("你好 a", "Unicode 转义"), "\\u4f60\\u597d a")
    assert.strictEqual(value("\\u4f60\\u597d \\u{1F642}", "Unicode 反转义"), "你好 🙂")
    assert.ok(!names("abc").includes("Unicode 转义"), "纯 ASCII 不给")
    assert.strictEqual(value("café ©", "Unicode 转义"), "caf\\u00e9 \\u00a9", "拉丁字母扩展也转")
    assert.strictEqual(value("&lt;a href=&quot;x&quot;&gt; &amp;copy; &#20320;&#x597D; &unknown;", "HTML 实体解码"), "<a href=\"x\"> &copy; 你好 &unknown;")
    assert.strictEqual(value("<b>\"Tom\" & 'Jerry'</b>", "HTML 转义"), "&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;")
    assert.strictEqual(value('{\\"a\\":\\"x\\\\ny\\"}', "JSON 字符串反转义"), '{"a":"x\\ny"}')
    assert.strictEqual(value('"line1\\nline2"', "JSON 字符串反转义"), "line1\nline2")
    assert.strictEqual(value('say "hi"\n', "JSON 字符串转义"), 'say \\"hi\\"\\n')
    assert.ok(!names("plain").includes("JSON 字符串转义"))
    assert.ok(!names("bad \\q").includes("JSON 字符串反转义"), "不是合法转义不给")
    assert.ok(!names('"hello"').includes("JSON 字符串反转义"), "没有转义的只是带引号，不算")
  })

  await test("顺序：识别出来的格式在前，通用的编码在后，字数垫底", () => {
    const list = names("1762425000")
    assert.deepStrictEqual(plain(list.slice(0, 2)), ["时间戳 → 本地时间", "时间戳 → ISO（UTC）"])
    assert.ok(list.indexOf("十六进制") < list.indexOf("Base64 编码"))
    assert.ok(list.indexOf("Base64 编码") < list.indexOf("MD5"))
    assert.strictEqual(list[list.length - 1], "字数")
  })

  await test("字数", () => {
    assert.strictEqual(value("你好\nab", "字数"), "5 个字 · 9 字节 · 2 行")
  })

  // 工具目录（用户 2026-11-07：「不知道有啥命令」）
  const NOW = Date.UTC(2026, 10, 6, 10, 30)
  const JWT = [{ alg: "HS256", typ: "JWT" }, { sub: "42", exp: 1793961000 + 3600 }]
    .map((x) => Buffer.from(JSON.stringify(x)).toString("base64url")).join(".") + ".sig"

  await test("没输入：列出全部工具，生成类回车拷贝、别的回车进去", () => {
    const rows = load(dir).sandbox.list("", undefined, NOW)
    const ids = rows.map((r) => r.id)
    assert.deepStrictEqual(plain(ids.slice(0, 2)), ["tool:uuid", "tool:now"])
    for (const id of ["jwt", "json", "time", "base64", "url", "unicode", "html", "jsonstr", "radix", "color", "amount", "case", "hash", "count", "query"]) {
      assert.ok(ids.includes("tool:" + id), id)
    }
    assert.strictEqual(new Set(ids).size, ids.length, "id 不重复")
    const now = rows.find((r) => r.id === "tool:now")
    assert.strictEqual(now.actions[0].id, "copy")
    assert.ok(now.subtitle.endsWith("1793961000"), now.subtitle)
    const jwt = rows.find((r) => r.id === "tool:jwt")
    assert.strictEqual(jwt.actions[0].enter, true)
    assert.strictEqual(jwt.actions[0].placeholder, "粘贴 JWT")
    assert.ok(jwt.actions[0].empty, "进去没输入时有说明")
    assert.ok(rows.every((r) => r.icon && r.icon.text.length <= 2), "行首方块最多两个字")
  })

  await test("老版本 TabFlick（不认 enter）：目录照样列，进不去的不给动作", () => {
    const rows = load(dir, { features: null }).sandbox.list("", undefined, NOW)
    assert.deepStrictEqual(plain(rows.find((r) => r.id === "tool:jwt").actions), [])
    assert.deepStrictEqual(plain(rows.find((r) => r.id === "tool:uuid").actions.map((a) => a.id)), ["copy"])
  })

  await test("英文界面没有人民币大写", () => {
    const ids = load(dir, { locale: "en" }).sandbox.list("", undefined, NOW).map((r) => r.id)
    assert.ok(!ids.includes("tool:amount"))
  })

  await test("有输入：照旧自动识别，名字对得上的工具排最前；粘贴的长内容不找工具", () => {
    const p = load(dir)
    assert.strictEqual(p.sandbox.list("jwt")[0].id, "tool:jwt")
    assert.strictEqual(p.sandbox.list("base64")[0].id, "tool:base64")
    assert.strictEqual(p.sandbox.list("sjc")[0].id, "tool:now", "拼音首字母")
    const pasted = p.sandbox.list(JWT)
    assert.ok(!pasted.some((r) => r.id.startsWith("tool:")))
    assert.strictEqual(pasted[0].subtitle, "JWT 载荷")
  })

  await test("工具那一层：只列这个工具的结果；没输入回空；认不出说一句、不给拷贝", () => {
    const p = load(dir)
    assert.deepStrictEqual(plain(p.sandbox.list("", "tool:jwt", NOW)), [])
    const rows = p.sandbox.list(JWT, "tool:jwt", NOW)
    assert.deepStrictEqual(plain(rows.map((r) => r.subtitle.split(" · ")[0])), ["JWT 载荷", "JWT 头", "JWT 过期时间"])
    const bad = p.sandbox.list("hello", "tool:jwt", NOW)
    assert.strictEqual(bad.length, 1)
    assert.strictEqual(bad[0].title, "不是 JWT")
    assert.deepStrictEqual(plain(bad[0].actions), [])
    assert.deepStrictEqual(plain(p.sandbox.list("255", "tool:radix").map((r) => r.title)), ["255", "0xff", "0b11111111", "0o377"])
    assert.deepStrictEqual(plain(p.sandbox.list("1762425000", "tool:time").map((r) => r.title)), ["2025-11-06 18:30:00", "2025-11-06T10:30:00.000Z"])
    assert.strictEqual(p.sandbox.list("#ff9500", "tool:color")[0].icon.tint, "#ff9500")
    assert.strictEqual(p.sandbox.list("你好", "tool:count")[0].title, "2 个字 · 6 字节 · 1 行")
    assert.strictEqual(p.sandbox.list("x", "tool:nope").length, 0, "不认识的工具回空")
  })

  await test("每个工具：各种输入都不抛错", () => {
    const p = load(dir)
    const samples = ["", " ", "abc", "{", "0xff", "#fff", "1762425000", "a\nb", "%E4%BD%A0", "\\u4f60", "&amp;", "x".repeat(140000)]
    for (const tool of p.sandbox.list("", undefined, NOW)) {
      for (const sample of samples) {
        const rows = p.sandbox.list(sample, tool.id, NOW)
        assert.ok(Array.isArray(rows), tool.id)
      }
    }
    assert.strictEqual(p.sandbox.list("x".repeat(140000), "tool:hash")[0].actions.length, 0, "太长不算哈希")
  })

  await test("当前时间戳那一层；UUID 刷新时不变，拷走之后换新的", () => {
    const p = load(dir)
    assert.deepStrictEqual(plain(p.sandbox.list("", "tool:now", NOW).map((r) => r.title)),
                           ["1793961000", "1793961000000", "2026-11-06T10:30:00.000Z", "2026-11-06 18:30:00"])
    const first = p.sandbox.list("", "tool:uuid")
    assert.strictEqual(p.sandbox.list("", "tool:uuid")[0].title, first[0].title, "定时刷新不换")
    assert.strictEqual(first[1].title, first[0].title.toUpperCase())
    assert.strictEqual(first[2].title, first[0].title.replace(/-/g, ""))
    assert.strictEqual(p.sandbox.list("", undefined)[0].subtitle.split(" · ")[1], first[0].title, "目录里那一行同一个")
    p.sandbox.list("", "tool:uuid")
    p.sandbox.perform("copy", "r2")
    assert.strictEqual(p.copied[0], first[0].title.replace(/-/g, ""))
    assert.notStrictEqual(p.sandbox.list("", "tool:uuid")[0].title, first[0].title, "拷走之后换新的")
  })

  done()
})()
