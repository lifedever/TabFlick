// 黄金插件的回归测试：vm 沙箱加载真实的 main.js，tabflick 用桩。样本是 2026-11-24 16:08（北京时间）从各接口抓的真实返回。
//   node plugins/gold/tests/gold.test.js
const assert = require("assert")
const { load, test, done, plain, fixture } = require("../../_shared/harness")
const dir = __dirname + "/.."
const fx = (name) => fixture(__dirname, name)

/** 2026-11-24 周二 16:08 北京时间（样本抓取的时刻）。 */
const NOW = Date.UTC(2026, 10, 24, 8, 8)

/** 每个来源的桩：fail 里点名的来源直接抛（网络失败），status 里点名的回那个状态码。 */
function routesWith({ fail = new Set(), status = {} } = {}) {
  return (url) => {
    const pick = (name, file) => {
      if (fail.has(name)) throw new Error("network")
      return { status: status[name] || 200, text: fx(file) }
    }
    if (url.startsWith("https://qt.gtimg.cn/")) return pick("tencent", "tencent.txt")
    if (url.startsWith("https://m.cmbchina.com/")) return pick("cmb", "cmb.json")
    if (url.startsWith("https://mybank.icbc.com.cn/")) return pick("icbc", "icbc.json")
    if (url.includes("/latestPrice")) return pick("jdMs", "jd-ms.json")
    if (url.includes("/stdLatestPrice")) return pick("jdZs", "jd-zs.json")
    throw new Error("unexpected url " + url)
  }
}

const priceRequests = (p) => p.requests

;(async () => {
  const { sandbox } = load(dir)

  await test("腾讯：伦敦金现价、昨收、涨跌和报价时间", async () => {
    const q = sandbox.parseTencent(fx("tencent.txt"))
    assert.strictEqual(q.xau.price, 3619.59)
    assert.strictEqual(q.xau.prev, 3635.23)
    assert.strictEqual(q.xau.pct.toFixed(2), "-0.43")
    assert.strictEqual(q.xau.date, "2026-11-24")
    assert.strictEqual(q.xau.hm, "16:07")
  })

  await test("腾讯：折人民币按汇率换成每克，涨跌按两边的昨收算", async () => {
    const q = sandbox.parseTencent(fx("tencent.txt"))
    // 3619.59 × 6.6647 ÷ 31.1034768
    assert.strictEqual(q.xauCny.price.toFixed(2), "775.59")
    assert.strictEqual(q.xauCny.rate, 6.6647)
    // 昨收：3635.23 × (6.6647 + 0.0013) ÷ 31.1034768
    const prev = 3635.23 * 6.666 / 31.1034768
    assert.strictEqual(q.xauCny.prev.toFixed(4), prev.toFixed(4))
    assert.strictEqual(q.xauCny.pct.toFixed(2), ((q.xauCny.price / prev - 1) * 100).toFixed(2))
  })

  await test("腾讯：没有伦敦金就什么都不给，没有汇率就没有折人民币", async () => {
    assert.deepStrictEqual(plain(sandbox.parseTencent('v_pv_none_match="1";')), {})
    const onlyGold = fx("tencent.txt").split("\n")[0]
    const q = sandbox.parseTencent(onlyGold)
    assert.ok(q.xau)
    assert.strictEqual(q.xauCny, undefined)
  })

  await test("招行：Au99.99、Au(T+D) 的涨跌按昨收算，不用接口的 upDown", async () => {
    const q = sandbox.parseCmb(fx("cmb.json"))
    assert.strictEqual(q.au9999.price, 777)
    assert.strictEqual(q.au9999.pct.toFixed(2), ((777 / 781.4 - 1) * 100).toFixed(2))
    assert.strictEqual(q.au9999.hm, "15:45")
    assert.strictEqual(q.au9999.date, null)
    // 样本里 Au(T+D) 的 upDown 是 +3.33，现价 777.25 比昨收 780.24 低
    assert.ok(q.autd.pct < 0)
    assert.strictEqual(q.autd.pct.toFixed(2), ((777.25 / 780.24 - 1) * 100).toFixed(2))
  })

  await test("招行：现价 0（当天没成交）当没取到", async () => {
    const zero = fx("cmb.json").replace('"curPrice":"777.00"', '"curPrice":"0.00"')
    const q = sandbox.parseCmb(zero)
    assert.strictEqual(q.au9999, undefined)
    assert.ok(q.autd)
    assert.deepStrictEqual(plain(sandbox.parseCmb("<html>")), {})
  })

  await test("工行：主动积存价、赎回价、最高最低、报价时间；没有涨跌", async () => {
    const q = sandbox.parseIcbc(fx("icbc.json")).icbc
    assert.strictEqual(q.price, 777.22)
    assert.strictEqual(q.sell, 777.22)
    assert.strictEqual(q.high, 789.9)
    assert.strictEqual(q.low, 775.69)
    assert.strictEqual(q.date, "2026-11-24")
    assert.strictEqual(q.hm, "16:08")
    assert.strictEqual(q.pct, null)
    assert.deepStrictEqual(plain(sandbox.parseIcbc('{"rf":[],"TranErrorCode":"x"}')), {})
  })

  await test("京东：民生、浙商的现价和昨收，时间按北京时间", async () => {
    const ms = sandbox.parseJd(fx("jd-ms.json"), "cmbc").cmbc
    assert.strictEqual(ms.price, 777.33)
    assert.strictEqual(ms.prev, 789)
    assert.strictEqual(ms.pct.toFixed(2), "-1.48")
    assert.strictEqual(ms.date, "2026-11-24")
    assert.strictEqual(ms.hm, "16:08")
    const zs = sandbox.parseJd(fx("jd-zs.json"), "czb").czb
    assert.strictEqual(zs.price, 777.38)
    assert.deepStrictEqual(plain(sandbox.parseJd('{"success":false,"resultCode":10000404}', "czb")), {})
    const junk = sandbox.parseJd(fx("jd-zs.json").replace('"time":"1795507710000"', '"time":"9e99"'), "czb").czb
    assert.strictEqual(junk.hm, null)
  })

  await test("开没开市：周末和周一早上 6 点前不算", async () => {
    const at = (day, h, m = 0) => Date.UTC(2026, 10, 22 + day, h - 8, m)   // 11-22 是周日；按北京时间给
    assert.strictEqual(sandbox.goldOpen(at(0, 12)), false)       // 周日
    assert.strictEqual(sandbox.goldOpen(at(1, 5, 59)), false)    // 周一 05:59
    assert.strictEqual(sandbox.goldOpen(at(1, 6)), true)         // 周一 06:00
    assert.strictEqual(sandbox.goldOpen(at(5, 23)), true)        // 周五 23:00（夜盘）
    assert.strictEqual(sandbox.goldOpen(at(6, 2, 30)), true)     // 周六 02:30 上金所夜盘还没收
    assert.strictEqual(sandbox.goldOpen(at(6, 6)), false)        // 周六 06:00
  })

  await test("列表：七个品种按顺序，价格、涨跌、单位；都不画走势线", async () => {
    const p = load(dir, { routes: routesWith() })
    const rows = plain(await p.sandbox.list("", NOW))
    assert.deepStrictEqual(rows.map((r) => r.id), ["xau", "xauCny", "au9999", "autd", "icbc", "cmbc", "czb"])
    const by = Object.fromEntries(rows.map((r) => [r.id, r]))
    assert.strictEqual(by.xau.value, "3619.59")
    assert.strictEqual(by.xau.detail, "-0.43%")
    assert.strictEqual(by.xau.tone, "down")
    assert.strictEqual(by.xau.subtitle, "XAU/USD · 美元/盎司 · 16:07")
    assert.strictEqual(by.xauCny.subtitle, "汇率 6.6647 · 元/克 · 16:07")
    assert.strictEqual(by.au9999.subtitle, "上海黄金交易所 · 元/克 · 15:45")
    assert.strictEqual(by.icbc.value, "777.22")
    assert.strictEqual(by.icbc.detail, null)
    assert.strictEqual(by.icbc.tone, "secondary")
    assert.strictEqual(by.icbc.subtitle, "主动积存价 · 元/克 · 16:08")
    assert.strictEqual(by.cmbc.subtitle, "京东金融 · 元/克 · 16:08")
    assert.strictEqual(by.czb.detail, "-1.44%")
    // 走势线只有一部分品种拿得到，列表长短不齐，一律不画（2026-11-24 用户定的）
    assert.ok(rows.every((r) => !("spark" in r)))
    assert.strictEqual(p.requests.length, 5)
    // 回车：有行情页的打开，浙商没有就拷贝
    assert.strictEqual(by.xau.actions[0].id, "open")
    assert.strictEqual(by.czb.actions[0].id, "copy")
    // 默认全在菜单栏里：都给「移出」
    const last = (r) => r.actions[r.actions.length - 1].id
    assert.ok(rows.every((r) => last(r) === "unpin"))
  })

  await test("工行赎回价和积存价不一样时写在副标题里", async () => {
    const differ = fx("icbc.json").replace('"SellPrice":"777.22"', '"SellPrice":"775.10"')
    const p = load(dir, { routes: (url, o) => (url.startsWith("https://mybank.icbc.com.cn/") ? { status: 200, text: differ } : routesWith()(url, o)) })
    const rows = plain(await p.sandbox.list("工行", NOW))
    assert.strictEqual(rows[0].subtitle, "主动积存价 · 元/克 · 赎回 775.10 · 16:08")
  })

  await test("请求：工行是表单 POST，腾讯按 GBK，全都不带 Referer", async () => {
    const p = load(dir, { routes: routesWith() })
    await p.sandbox.list("", NOW)
    const icbc = p.requests.find((r) => r.url.startsWith("https://mybank.icbc.com.cn/"))
    assert.strictEqual(icbc.options.method, "POST")
    assert.strictEqual(icbc.options.body, "tranCode=A00622")
    assert.ok(/form-urlencoded/.test(icbc.options.headers["Content-Type"]))
    assert.strictEqual(p.requests.find((r) => r.url.startsWith("https://qt.gtimg.cn/")).options.encoding, "gbk")
    for (const r of p.requests) {
      const headers = (r.options && r.options.headers) || {}
      assert.ok(!Object.keys(headers).some((h) => /referer|user-agent|origin|cookie/i.test(h)), r.url)
    }
  })

  await test("缓存：开市 4 秒内不重取，过了再取；周末 5 分钟", async () => {
    const p = load(dir, { routes: routesWith() })
    await p.sandbox.list("", NOW)
    const first = priceRequests(p).length
    assert.strictEqual(first, 5)
    await p.sandbox.list("", NOW + 3000)
    assert.strictEqual(priceRequests(p).length, first)
    await p.sandbox.list("", NOW + 5000)
    assert.strictEqual(priceRequests(p).length, first * 2)

    const sunday = Date.UTC(2026, 10, 22, 4)
    const w = load(dir, { routes: routesWith() })
    await w.sandbox.list("", sunday)
    await w.sandbox.list("", sunday + 4 * 60 * 1000)
    assert.strictEqual(priceRequests(w).length, 5)
    await w.sandbox.list("", sunday + 6 * 60 * 1000)
    assert.strictEqual(priceRequests(w).length, 10)
  })

  await test("同一个来源只请求一次：伦敦金和折人民币共用腾讯那一个", async () => {
    const p = load(dir, { routes: routesWith() })
    await p.sandbox.list("xau", NOW)
    assert.strictEqual(p.requests.filter((r) => r.url.startsWith("https://qt.gtimg.cn/")).length, 1)
    assert.strictEqual(p.requests.length, 1)
  })

  await test("一个来源取不到：那几行写「取不到」，别的照常", async () => {
    const p = load(dir, { routes: routesWith({ fail: new Set(["icbc"]), status: { cmb: 502 } }) })
    const rows = plain(await p.sandbox.list("", NOW))
    const by = Object.fromEntries(rows.map((r) => [r.id, r]))
    assert.strictEqual(by.icbc.value, "—")
    assert.strictEqual(by.icbc.subtitle, "主动积存价 · 元/克 · 取不到")
    assert.strictEqual(by.au9999.value, "—")
    assert.ok(by.au9999.subtitle.endsWith("取不到"))
    assert.strictEqual(by.xau.value, "3619.59")
    assert.strictEqual(by.cmbc.value, "777.33")
  })

  await test("全都取不到：调用失败（TabFlick 留着上次的结果）", async () => {
    const all = new Set(["tencent", "cmb", "icbc", "jdMs", "jdZs"])
    const p = load(dir, { routes: routesWith({ fail: all }) })
    await assert.rejects(() => p.sandbox.list("", NOW))
    await assert.rejects(() => p.sandbox.menu(NOW))
  })

  await test("取过之后再失败：接着显示上次的价格，30 秒内不重试", async () => {
    const fail = new Set()
    const p = load(dir, { routes: routesWith({ fail }) })
    await p.sandbox.list("工行", NOW)
    fail.add("icbc")
    const rows = plain(await p.sandbox.list("工行", NOW + 10 * 1000))
    assert.strictEqual(rows[0].value, "777.22")
    assert.ok(rows[0].subtitle.endsWith("16:08"))
    const tries = p.requests.length
    await p.sandbox.list("工行", NOW + 20 * 1000)
    assert.strictEqual(p.requests.length, tries)
    await p.sandbox.list("工行", NOW + 45 * 1000)
    assert.strictEqual(p.requests.length, tries + 1)
  })

  await test("筛选：在本地比名字和别名，不联网", async () => {
    const p = load(dir, { routes: routesWith() })
    const ids = async (q) => plain(await p.sandbox.list(q, NOW)).map((r) => r.id)
    assert.deepStrictEqual(await ids("工行"), ["icbc"])
    assert.deepStrictEqual(await ids("jcj"), ["icbc", "cmbc", "czb"])
    assert.deepStrictEqual(await ids("积存"), ["icbc", "cmbc", "czb"])
    assert.deepStrictEqual(await ids("T+D"), ["autd"])
    assert.deepStrictEqual(await ids("xau"), ["xau", "xauCny"])
    assert.deepStrictEqual(await ids("Au 99"), ["au9999"])
    assert.deepStrictEqual(await ids("上金所"), ["au9999", "autd"])
    assert.strictEqual((await ids("黄金")).length, 7)
    const before = p.requests.length
    assert.deepStrictEqual(await ids("zzz"), [])
    assert.strictEqual(p.requests.length, before)
  })

  await test("菜单：默认七个全放，分现货 / 积存金两段", async () => {
    const p = load(dir, { routes: routesWith() })
    const rows = plain(await p.sandbox.menu(NOW))
    assert.deepStrictEqual(rows.map((r) => r.type === "header" ? "# " + r.text : r.type ? r.type : r.title),
      ["# 现货", "伦敦金", "伦敦金 折人民币", "Au99.99", "Au(T+D)", "# 积存金", "工行积存金", "民生积存金", "浙商积存金", "separator", "note"])
    assert.strictEqual(rows[1].value, "3619.59")
    assert.strictEqual(rows[1].action, "open:xau")
    assert.strictEqual(rows[rows.length - 1].text, "更新于 16:08")
  })

  await test("菜单：只取放进去的那几个用得到的来源", async () => {
    const p = load(dir, { routes: routesWith(), stored: { menu: ["xau", "au9999", "icbc"] } })
    const rows = plain(await p.sandbox.menu(NOW))
    assert.deepStrictEqual(rows.filter((r) => r.action).map((r) => r.title), ["伦敦金", "Au99.99", "工行积存金"])
    assert.ok(!p.requests.some((r) => r.url.includes("jdjygold")))
  })

  await test("放进 / 移出菜单栏：存下来、按列表顺序、菜单跟着变", async () => {
    const p = load(dir, { routes: routesWith() })
    p.storage.menu = ["xau", "au9999", "icbc"]
    await p.handlers.perform("pin", "czb")
    await p.handlers.perform("unpin", "xau")
    await p.handlers.perform("pin", "nope")
    await p.handlers.perform("copy", "__proto__")
    await p.handlers.action("copy:__proto__")
    assert.deepStrictEqual(p.storage.menu, ["au9999", "icbc", "czb"])
    assert.deepStrictEqual(p.toasts, ["已放进菜单栏 / 浙商积存金", "已移出菜单栏 / 伦敦金"])
    const rows = plain(await p.sandbox.menu(NOW))
    assert.deepStrictEqual(rows.filter((r) => r.action).map((r) => r.action), ["open:au9999", "open:icbc", "copy:czb"])
    // 列表里的动作跟着变
    const list = plain(await p.sandbox.list("浙商", NOW))
    assert.strictEqual(list[0].actions[list[0].actions.length - 1].id, "unpin")
  })

  await test("菜单栏里一个都没有：说怎么放进来", async () => {
    const p = load(dir, { routes: routesWith(), stored: { menu: [] } })
    const rows = plain(await p.sandbox.menu(NOW))
    assert.strictEqual(rows.length, 1)
    assert.strictEqual(rows[0].type, "note")
    assert.strictEqual(p.requests.length, 0)
  })

  await test("菜单底下那行：最新报价不是今天的写收盘价", async () => {
    const quotes = { xau: { hm: "05:59", date: "2026-11-21" }, au9999: { hm: "02:30", date: null } }
    const items = ["xau", "au9999"].map((id) => sandbox.productOf(id))
    assert.strictEqual(sandbox.statusNote(quotes, items, "2026-11-22"), "收盘价 · 11-21")
    assert.strictEqual(sandbox.statusNote({ au9999: { hm: "15:45", date: null } }, items, "2026-11-24"), "更新于 15:45")
    assert.strictEqual(sandbox.statusNote({}, items, "2026-11-24"), null)
  })

  await test("拷贝价格、打开行情页", async () => {
    const p = load(dir, { routes: routesWith() })
    await p.handlers.perform("copy", "icbc")
    assert.deepStrictEqual(p.copied, ["777.22"])
    assert.deepStrictEqual(p.toasts, ["已拷贝价格 / 工行积存金 777.22 元/克"])
    await p.handlers.perform("open", "au9999")
    assert.deepStrictEqual(p.opened, ["https://www.sge.com.cn/sjzx/yshqbg"])
    await p.handlers.action("copy:czb")
    assert.strictEqual(p.copied[1], "777.38")
    const f = load(dir, { routes: routesWith({ fail: new Set(["icbc"]) }) })
    await f.handlers.perform("copy", "icbc")
    assert.deepStrictEqual(f.copied, [])
    assert.deepStrictEqual(f.toasts, ["取不到价格 / 工行积存金"])
  })

  await test("英文界面", async () => {
    const p = load(dir, { locale: "en", routes: routesWith() })
    const rows = plain(await p.sandbox.list("", NOW))
    assert.strictEqual(rows[0].title, "London Gold")
    assert.strictEqual(rows[0].subtitle, "XAU/USD · USD/oz · 16:07")
    assert.strictEqual(rows[4].title, "ICBC Gold Accumulation")
    assert.strictEqual(rows[4].subtitle, "Buy price · CNY/g · 16:08")
    assert.strictEqual(rows[4].icon.text, "IC")
  })

  done()
})()
