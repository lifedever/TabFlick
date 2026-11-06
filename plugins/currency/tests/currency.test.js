// 汇率插件：node plugins/currency/tests/currency.test.js（样本是 2026-11-06 open.er-api.com 的真实返回）
const assert = require("assert")
const { load, test, done, plain, fixture } = require("../../_shared/harness")
const dir = __dirname + "/.."
const usd = fixture(__dirname, "usd.json")
const ok = (url) => ({ status: 200, text: usd })

;(async () => {
  const { sandbox } = load(dir)
  const p = (s) => plain(sandbox.parseQuery(s))

  await test("各种写法", () => {
    assert.deepStrictEqual(p("100 usd"), { amount: 100, from: "USD", to: null })
    assert.deepStrictEqual(p("100USD"), { amount: 100, from: "USD", to: null })
    assert.deepStrictEqual(p("100美元"), { amount: 100, from: "USD", to: null })
    assert.deepStrictEqual(p("usd 100"), { amount: 100, from: "USD", to: null })
    assert.deepStrictEqual(p("1,000 usd to jpy"), { amount: 1000, from: "USD", to: "JPY" })
    assert.deepStrictEqual(p("美元兑日元"), { amount: 1, from: "USD", to: "JPY" })
    assert.deepStrictEqual(p("美元日元"), { amount: 1, from: "USD", to: "JPY" }, "连写也认")
    assert.deepStrictEqual(p("1.5万 日元"), { amount: 15000, from: "JPY", to: null })
    assert.deepStrictEqual(p("2k eur in gbp"), { amount: 2000, from: "EUR", to: "GBP" })
    assert.strictEqual(sandbox.parseQuery("hello"), null)
    assert.strictEqual(sandbox.parseQuery("100 usd to xyz"), null, "目标认不出不硬算")
    assert.strictEqual(sandbox.parseQuery("0 usd"), null)
  })

  await test("换算和显示", () => {
    const r = sandbox.parseRates(usd)
    assert.ok(r.rates.CNY > 6 && r.rates.CNY < 8)
    const v = sandbox.convert(r.rates, 100, "USD", "CNY")
    assert.strictEqual(sandbox.plain(v), String(Math.round(100 * r.rates.CNY * 100) / 100))
    assert.strictEqual(sandbox.pretty(12345.678), "12,345.68")
    assert.strictEqual(sandbox.pretty(0.046832), "0.04683")
    assert.strictEqual(sandbox.parseRates('{"result":"error"}'), null)
    assert.strictEqual(sandbox.parseRates("<html>"), null)
  })

  await test("列表：100 usd 换成人民币在最前，再是常用的", async () => {
    const { handlers } = load(dir, { routes: ok })
    const rows = await handlers.list("100 usd")
    assert.strictEqual(rows[0].id, "USD>CNY@100")
    assert.ok(!rows.some((r) => r.id.startsWith("USD>USD")), "不换成自己")
    assert.deepStrictEqual(plain(rows.map((r) => r.id.split("@")[0])), ["USD>CNY", "USD>EUR", "USD>JPY", "USD>HKD", "USD>GBP"])
    assert.strictEqual(rows[0].actions[0].id, "copy", "回车拷贝结果")
  })

  await test("列表：指定目标 = 正反两行；没输入 = 常用对人民币；搜名字", async () => {
    const { handlers } = load(dir, { routes: ok })
    assert.deepStrictEqual(plain((await handlers.list("usd to jpy")).map((r) => r.id)), ["USD>JPY@1", "JPY>USD@1"])
    assert.deepStrictEqual(plain((await handlers.list("")).map((r) => r.id)), ["USD>CNY@1", "EUR>CNY@1", "JPY>CNY@1", "HKD>CNY@1", "GBP>CNY@1"])
    assert.deepStrictEqual(plain((await handlers.list("克朗")).map((r) => r.id.split(">")[0])), ["SEK", "NOK", "DKK"])
  })

  await test("缓存：6 小时内不重取；取不到用旧的；一份都没有才失败", async () => {
    const a = load(dir, { routes: ok })
    await a.handlers.list("")
    await a.handlers.list("100 usd")
    assert.strictEqual(a.requests.length, 1)
    const stale = { ...a.storage.rates, fetchedAt: 0 }
    const b = load(dir, { stored: { rates: stale }, routes: () => { throw new Error("network") } })
    assert.ok((await b.handlers.list("")).length > 0, "过期的缓存也比没有强")
    await assert.rejects(load(dir).handlers.list(""))
  })

  await test("常用：设为常用、移出；拷贝结果不带千分位", async () => {
    const { handlers, storage, copied } = load(dir, { routes: ok })
    await handlers.perform("fav", "THB>CNY@1")
    assert.deepStrictEqual(plain(storage.favorites), ["USD", "EUR", "JPY", "HKD", "GBP", "THB"])
    await handlers.perform("unfav", "USD>CNY@1")
    assert.ok(!storage.favorites.includes("USD"))
    await handlers.perform("copy", "USD>JPY@10000")
    assert.ok(/^\d+(\.\d+)?$/.test(copied[0]), copied[0])
    await handlers.perform("copy", "garbage")
    assert.strictEqual(copied.length, 1)
  })

  await test("菜单：常用的对人民币", async () => {
    const { handlers } = load(dir, { routes: ok })
    const rows = await handlers.menu()
    assert.strictEqual(rows[0].text, "1 外币 = 人民币")
    assert.strictEqual(rows[1].title, "美元")
    assert.strictEqual(rows[1].badge, "USD")
  })

  done()
})()
