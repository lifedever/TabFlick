// 股票插件的回归测试：vm 沙箱加载真实的 main.js，tabflick 用桩。样本是 2026-11-06 收盘后从腾讯抓的真实返回。
//   node plugins/stocks/tests/stocks.test.js
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "main.js"), "utf8")
const fixture = (name) => fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))

/** 起一份插件：locale、存储、fetch 返回什么都由桩给。返回沙箱（能直接调顶层函数）和注册的 handlers。
 *  fetch 按 manifest 核对域名：请求了没声明的直接失败（和 _shared/harness.js 一样）。`smartbox` 传 null 表示搜索失败。 */
/** 腾讯板块排行的桩：概念一页（含 CPO、PCB），行业一页。`rank` 传 null 表示取不到。 */
function rankPage(url) {
  const concept = [{ code: "pt02GN2211", name: "共封装光模块(CPO）" }, { code: "pt02101284", name: "PCB概念" }, { code: "pt02GN2190", name: "光通信" }]
  const industry = [{ code: "pt01801081", name: "电子元件" }]
  const list = url.includes("board_type=gn") ? concept : industry
  return JSON.stringify({ code: 0, msg: "ok", data: { rank_list: list, offset: 0, total: list.length } })
}

function load({ locale = "zh", stored = {}, fetchText = fixture("quotes.txt"), status = 200, smartbox = fixture("smartbox-tx.txt"),
               rank = rankPage } = {}) {
  const requests = []
  const logs = []
  const opened = []
  const storage = { ...stored }
  let handlers = null
  const sandbox = {
    tabflick: {
      locale,
      register: (h) => { handlers = h },
      storage: { get: (k) => storage[k], set: (k, v) => { storage[k] = v; return true }, remove: (k) => { delete storage[k] } },
      fetch: async (url, options) => {
        requests.push({ url, options })
        if (!manifest.hosts.includes(new URL(url).host)) throw new Error("blocked: not in manifest hosts")
        if (url.startsWith("https://proxy.finance.qq.com/")) {
          const text = rank && rank(url)
          if (!text) throw new Error("network")
          return { status: 200, text }
        }
        if (url.includes("q=pt02")) return { status: 200, text: fixture("quotes-boards.txt") }
        if (url.includes("getNav?symbol=021528")) return { status: 200, text: fixture("sina-nav-021528.json") }
        if (url.endsWith("minute/query?code=pt02GN2211")) return { status: 200, text: fixture("minute-pt02GN2211.json") }
        if (url.startsWith("https://smartbox.gtimg.cn/")) {
          if (smartbox === null) throw new Error("network")
          return { status: 200, text: smartbox }
        }
        if (url.startsWith("https://web.ifzq.gtimg.cn/")) {
          // 上证、纳指100 有样本；别的代码回一份空的（接口对不认识的代码也是这样）
          if (url.endsWith("minute/query?code=sh000001")) return { status: 200, text: fixture("minute-sh000001.json") }
          if (url.endsWith("UsMinute/query?code=usNDX")) return { status: 200, text: fixture("minute-usNDX.json") }
          return { status: 200, text: '{"code":0,"data":{}}' }
        }
        return { status, text: fetchText }
      },
      openURL: (url) => { opened.push(url); return true },
      copy: () => {},
      toast: () => {},
    },
  }
  // 真实运行时里有 setTimeout 和 console（JSPluginRuntime 提供），沙箱里补上
  sandbox.setTimeout = (fn, ms) => setTimeout(fn, Math.ceil(ms / 100))   // 按比例缩短，先后关系不变
  sandbox.console = { log: (...args) => logs.push(args.join(" ")) }
  vm.createContext(sandbox)
  vm.runInContext(source, sandbox)
  return { sandbox, handlers, requests, opened, storage, logs }
}

/** 沙箱里建的对象原型和这边的不是同一个，deepStrictEqual 会连原型一起比 —— 先转成普通对象。 */
const plain = (x) => JSON.parse(JSON.stringify(x))

let passed = 0
async function test(name, fn) {
  try { await fn(); passed++ } catch (e) { console.error("✗ " + name + "\n  " + e.message); process.exitCode = 1 }
}

;(async () => {
  const { sandbox } = load()

  await test("解析 A 股、指数、港美股、基金", () => {
    const q = sandbox.parseQuotes(fixture("quotes.txt"))
    assert.deepStrictEqual(plain(Object.keys(q).sort()), ["hk00700", "jj161725", "sh000001", "sh000688", "sh600519", "sz399006", "usAAPL"])
    assert.strictEqual(q.sh000001.name, "上证指数")
    assert.strictEqual(q.sh000001.price, 3649.18)
    assert.strictEqual(q.sh000001.pct, -1.10)
    assert.deepStrictEqual(plain(q.sh000001.time), { date: "2026-11-06", hm: "16:14" })
    assert.strictEqual(q.hk00700.time.date, "2026-11-06", "港股时间是 2026/11/06 写法")
    assert.strictEqual(q.usAAPL.time.date, "2026-11-05", "美股时间是 2026-11-05 写法")
    assert.strictEqual(q.jj161725.price, 0.5926, "基金取单位净值")
    assert.strictEqual(q.jj161725.pct, 1.4205)
    assert.strictEqual(q.jj161725.date, "2026-11-05")
  })

  await test("认不出的行跳过，不抛", () => {
    const q = sandbox.parseQuotes('v_sh600000="1~浦发";\ngarbage\nv_pv_none_match="1";\n')
    assert.deepStrictEqual(plain(Object.keys(q)), [])
  })

  await test("收盘后、开盘前、盘中的那一行", () => {
    const list = [{ code: "sh000001", kind: "index" }]
    const quotes = { sh000001: { time: { date: "2026-11-06", hm: "15:00" } } }
    assert.strictEqual(sandbox.statusNote(quotes, list, { date: "2026-11-06", hm: "17:20" }), "已收盘 · 11-06")
    assert.strictEqual(sandbox.statusNote(quotes, list, { date: "2026-11-07", hm: "09:00" }), "收盘价 · 11-06", "第二天开盘前（或周末）是上一个收盘价")
    const live = { sh000001: { time: { date: "2026-11-06", hm: "14:32" } } }
    assert.strictEqual(sandbox.statusNote(live, list, { date: "2026-11-06", hm: "14:33" }), "更新于 14:32")
    assert.strictEqual(sandbox.statusNote({}, list, { date: "2026-11-06", hm: "14:33" }), null, "没有报价不写")
    const usOnly = [{ code: "usAAPL", kind: "stock" }]
    assert.strictEqual(sandbox.statusNote({ usAAPL: { time: { date: "2026-11-05", hm: "16:00" } } }, usOnly), null, "只看 A 股")
  })

  await test("北京时间：UTC 16:30 已经是北京第二天 00:30", () => {
    assert.deepStrictEqual(plain(sandbox.shanghaiNow(Date.UTC(2026, 10, 6, 16, 30))), { date: "2026-11-07", hm: "00:30" })
  })

  await test("菜单：默认三个指数 + 底下一行", async () => {
    const { handlers, requests } = load()
    const rows = await handlers.menu()
    assert.strictEqual(requests.length, 1)
    assert.strictEqual(requests[0].options.encoding, "gbk", "腾讯行情是 GBK")
    assert.ok(requests[0].url.endsWith("q=sh000001,sh000688,sz399006"))
    assert.deepStrictEqual(plain(rows[0]), { type: "header", text: "指数" })
    assert.deepStrictEqual(plain(rows[1]), { title: "上证指数", badge: null, value: "3649.18", detail: "-1.10%", tone: "down", action: "open:index:sh000001" })
    assert.strictEqual(rows[rows.length - 1].type, "note")
  })

  await test("菜单：自选、港美股小字、基金净值日期、涨跌颜色", async () => {
    const watch = [
      { code: "sh600519", name: "贵州茅台", kind: "stock" },
      { code: "hk00700", name: "腾讯控股", kind: "stock" },
      { code: "usAAPL", name: "苹果", kind: "stock" },
      { code: "161725", name: "白酒", kind: "fund" },
    ]
    const { handlers, requests } = load({ stored: { watchlist: watch } })
    const rows = await handlers.menu()
    assert.ok(requests[0].url.endsWith("q=sh600519,hk00700,usAAPL,jj161725"), "基金加 jj 前缀")
    assert.strictEqual(requests.length, 1, "基金净值也在腾讯那一个请求里，不另外问")
    const byTitle = Object.fromEntries(rows.filter((r) => r.title).map((r) => [r.title, r]))
    assert.strictEqual(byTitle["贵州茅台"].tone, "up")
    assert.strictEqual(byTitle["贵州茅台"].detail, "+0.07%")
    assert.strictEqual(byTitle["腾讯控股"].badge, "港")
    assert.strictEqual(byTitle["苹果"].badge, "美")
    assert.strictEqual(byTitle["招商中证白酒指数A"].value, "0.5926", "基金净值 4 位")
    assert.ok(rows.some((r) => r.type === "header" && r.text === "基金 · 净值 11-05"))
    assert.ok(!rows.some((r) => r.type === "header" && r.text === "指数"), "没有指数就没有这一段")
  })

  await test("平盘不涨不跌、没数据灰色", () => {
    assert.strictEqual(sandbox.tone(0), "plain")
    assert.strictEqual(sandbox.tone(null), "secondary")
    assert.strictEqual(sandbox.tone(0.01), "up")
    assert.strictEqual(sandbox.tone(-0.01), "down")
    assert.strictEqual(sandbox.formatPct(0), "0.00%", "平盘不带 +")
  })

  await test("取不到行情就失败（让 TabFlick 留着快照），不回一行报错", async () => {
    const { handlers } = load({ status: 503 })
    await assert.rejects(handlers.menu())
  })

  await test("坏掉的自选项不进菜单，也不进请求", async () => {
    const { handlers, requests } = load({ stored: { watchlist: [{ code: "sh600519", kind: "stock" }, { code: "x;evil", kind: "stock" }, { code: "sz000001" }] } })
    await handlers.menu()
    assert.ok(requests[0].url.endsWith("q=sh600519"))
  })

  await test("英文界面", async () => {
    const { handlers } = load({ locale: "en" })
    const rows = await handlers.menu()
    assert.strictEqual(rows[0].text, "Indices")
  })

  await test("搜索：拼音首字母、港美股代码、指数、没结果", () => {
    const hits = sandbox.parseSmartbox(fixture("smartbox-tx.txt"))
    assert.deepStrictEqual(plain(hits[0]), { code: "hk00700", name: "腾讯控股", pinyin: "txkg", kind: "stock" })
    assert.ok(hits.some((h) => h.code === "usTX" && h.kind === "stock"), "美股 tx.n → usTX")
    assert.ok(hits.some((h) => h.code === "sh000847" && h.kind === "index"), "ZS 是指数")
    assert.deepStrictEqual(plain(sandbox.parseSmartbox(fixture("smartbox-none.txt"))), [])
    assert.deepStrictEqual(plain(sandbox.parseSmartbox("garbage")), [])
  })

  await test("点一行打开行情页；认不出的动作不动", () => {
    const { handlers, opened } = load()
    handlers.action("open:stock:sh600519")
    handlers.action("open:fund:161725")
    handlers.action("open:stock:javascript:alert(1)")
    assert.deepStrictEqual(opened, ["https://gu.qq.com/sh600519", "https://fund.eastmoney.com/161725.html"])
  })

  await test("面板列表：自选带现价、走势线、动作", async () => {
    const { handlers } = load()
    const rows = await handlers.list("")
    assert.strictEqual(rows.length, 3)
    const sh = rows[0]
    assert.strictEqual(sh.id, "index:sh000001")
    assert.strictEqual(sh.value, "3649.18")
    assert.strictEqual(sh.tone, "down")
    assert.strictEqual(sh.spark.length, 242, "上证一天 242 个分钟点")
    assert.strictEqual(sh.spark[0], 3612.15)
    assert.strictEqual(rows[1].spark.length, 0, "没样本的回空，不抛")
    assert.deepStrictEqual(plain(sh.icon), { text: "指", tint: "indigo" })
    assert.deepStrictEqual(plain(sh.actions.map((a) => a.id)), ["open", "copy", "remove"], "回车打开，移出放最后")
    assert.strictEqual(sh.actions[2].destructive, true)
    assert.strictEqual(sh.actions[2].stay, true, "移出自选面板不关")
  })

  await test("走势线 60 秒内不重取，过了再取", async () => {
    const { sandbox, handlers, requests } = load()
    await handlers.list("")
    await handlers.list("")
    assert.strictEqual(requests.filter((r) => r.url.includes("minute")).length, 3, "三只各取一次")
    assert.strictEqual(requests.filter((r) => r.url.includes("qt.gtimg.cn")).length, 1, "报价有缓存（开市 4 秒、休市 5 分钟）")
    // 休市时（周六）取到过的就一直用；开市后（下周一 10:00）过了 60 秒重取
    await sandbox.sparkFor({ code: "sh000001", kind: "index" }, Date.UTC(2026, 10, 7, 4))
    assert.strictEqual(requests.filter((r) => r.url.includes("minute")).length, 3, "休市不重取")
    const later = await sandbox.sparkFor({ code: "sh000001", kind: "index" }, Date.UTC(2026, 10, 9, 2))
    assert.strictEqual(later.length, 242)
    assert.strictEqual(requests.filter((r) => r.url.includes("minute")).length, 4, "开市了、过期了重取")
  })

  await test("面板搜索：结果带现价，不在自选的回车是加入", async () => {
    const { handlers, requests } = load()
    const rows = await handlers.list(" tx ")
    assert.ok(requests.some((r) => r.url.endsWith("&q=tx")), "去掉首尾空白再搜")
    assert.ok(rows.length <= 8)
    assert.strictEqual(rows[0].id, "stock:hk00700")
    assert.strictEqual(rows[0].title, "腾讯控股")
    assert.strictEqual(rows[0].value, "419.80", "≥10 两位小数")
    assert.strictEqual(rows[0].actions[0].id, "add")
    assert.strictEqual(rows[0].actions[0].stay, true)
    assert.deepStrictEqual(plain(rows[0].icon), { text: "港", tint: "purple" })
    assert.ok(rows.some((r) => r.id === "index:sh000847"))
  })

  await test("加入自选、再搜回车变打开、移出、全部移出后是空的", async () => {
    const { handlers, storage } = load()
    await handlers.list("tx")
    handlers.perform("add", "stock:hk00700")
    assert.deepStrictEqual(plain(storage.watchlist.map((x) => x.code)), ["sh000001", "sh000688", "sz399006", "hk00700"], "默认的留着、新的接在后面")
    assert.strictEqual(storage.watchlist[3].name, "腾讯控股", "名字从搜索结果里取")
    handlers.perform("add", "stock:hk00700")
    assert.strictEqual(storage.watchlist.length, 4, "不重复加")
    const again = await handlers.list("tx")
    assert.strictEqual(again[0].actions[0].id, "open", "已在自选的回车是打开")
    for (const id of ["index:sh000001", "index:sh000688", "index:sz399006", "stock:hk00700"]) handlers.perform("remove", id)
    assert.deepStrictEqual(plain(storage.watchlist), [])
    assert.deepStrictEqual(plain(await handlers.list("")), [], "全移出了就是空的，不回到默认")
  })

  await test("动作：认不出的 id 不动；打开、拷贝", () => {
    const { handlers, storage, opened } = load()
    handlers.perform("remove", "stock:x;evil")
    handlers.perform("remove", "garbage")
    assert.strictEqual(storage.watchlist, undefined, "没动过存储")
    handlers.perform("open", "fund:161725")
    assert.deepStrictEqual(opened, ["https://fund.eastmoney.com/161725.html"])
  })

  await test("搜索：自选里的排最前、回车是打开", async () => {
    const { handlers } = load()
    const rows = await handlers.list("szzs")
    assert.strictEqual(rows[0].id, "index:sh000001", "默认自选带拼音")
    assert.strictEqual(rows[0].actions[0].id, "open")
    const byName = await handlers.list("创业")
    assert.strictEqual(byName[0].id, "index:sz399006")
  })

  await test("腾讯搜索失败：本地有就列本地的，都没有才失败", async () => {
    const { handlers } = load({ smartbox: null })
    const rows = await handlers.list("上证")
    assert.strictEqual(rows[0].id, "index:sh000001")
    await assert.rejects(load({ smartbox: null }).handlers.list("zzzzqqq"))
  })

  await test("场外基金搜得到（市场是 jj）", () => {
    const hits = sandbox.parseSmartbox(fixture("smartbox-ndx.txt"))
    assert.ok(hits.some((h) => h.kind === "fund" && /^\d{6}$/.test(h.code)), JSON.stringify(hits))
    assert.ok(hits.some((h) => h.code === "usNDX" && h.kind === "index"), "纳斯达克100")
  })

  await test("美股、港股也有走势线", async () => {
    const { handlers, requests } = load({ stored: { watchlist: [{ code: "usNDX", name: "纳斯达克100", kind: "index" }, { code: "hk00700", name: "腾讯", kind: "stock" }] } })
    const rows = await handlers.list("")
    assert.strictEqual(rows[0].spark.length, 391)
    assert.ok(requests.some((r) => r.url.endsWith("hkMinute/query?code=hk00700")))
  })

  await test("开没开市（北京时间）", () => {
    const bj = (y, mo, d, h, mi) => Date.UTC(y, mo - 1, d, h - 8, mi)   // 北京时间 → 毫秒
    const a = { code: "sh600519", kind: "stock" }, hk = { code: "hk00700", kind: "stock" }
    const us = { code: "usAAPL", kind: "stock" }, fu = { code: "hf_NQ", kind: "future" }
    // 2026-11-06 是周五
    assert.strictEqual(sandbox.marketOpen(a, bj(2026, 11, 6, 10, 0)), true)
    assert.strictEqual(sandbox.marketOpen(a, bj(2026, 11, 6, 15, 30)), false, "A 股收盘后")
    assert.strictEqual(sandbox.marketOpen(hk, bj(2026, 11, 6, 15, 30)), true, "港股还没收")
    assert.strictEqual(sandbox.marketOpen(us, bj(2026, 11, 6, 22, 0)), true, "美股夜里")
    assert.strictEqual(sandbox.marketOpen(us, bj(2026, 11, 7, 3, 0)), true, "周六凌晨还是周五的美股")
    assert.strictEqual(sandbox.marketOpen(us, bj(2026, 11, 7, 10, 0)), false)
    assert.strictEqual(sandbox.marketOpen(us, bj(2026, 11, 9, 3, 0)), false, "周一凌晨美股没开（周日没盘）")
    assert.strictEqual(sandbox.marketOpen(fu, bj(2026, 11, 6, 18, 0)), false, "期货的数据源已停用，不取")
    assert.strictEqual(sandbox.marketOpen(a, bj(2026, 11, 7, 10, 0)), false, "周六")
  })

  await test("休市时报价 5 分钟内不重取，开市时 4 秒", async () => {
    const closedSat = Date.UTC(2026, 10, 7, 4)    // 北京周六 12:00：A 股不开
    const p = load()
    await p.sandbox.cachedQuotes(p.sandbox.watchlist(), closedSat)
    await p.sandbox.cachedQuotes(p.sandbox.watchlist(), closedSat + 4 * 60 * 1000)
    assert.strictEqual(p.requests.filter((r) => r.url.includes("qt.gtimg.cn")).length, 1)
    await p.sandbox.cachedQuotes(p.sandbox.watchlist(), closedSat + 6 * 60 * 1000)
    assert.strictEqual(p.requests.filter((r) => r.url.includes("qt.gtimg.cn")).length, 2)
    const openFri = Date.UTC(2026, 10, 6, 2)      // 北京周五 10:00
    const q = load()
    await q.sandbox.cachedQuotes(q.sandbox.watchlist(), openFri)
    await q.sandbox.cachedQuotes(q.sandbox.watchlist(), openFri + 5000)
    assert.strictEqual(q.requests.filter((r) => r.url.includes("qt.gtimg.cn")).length, 2)
  })

  await test("以前加的期货：写明数据源已停用、只能移出，不发请求，菜单里不列", async () => {
    const p = load({ stored: { watchlist: [{ code: "hf_NQ", kind: "future", name: "小型纳指当月连续" }, { code: "sh000001", name: "上证指数", kind: "index" }] } })
    const rows = await p.handlers.list("")
    assert.strictEqual(rows[0].title, "小型纳指当月连续")
    assert.ok(rows[0].subtitle.includes("已停用"))
    assert.deepStrictEqual(plain(rows[0].actions.map((a) => a.id)), ["remove"])
    assert.ok(!p.requests.some((r) => r.url.includes("hf_NQ")), "不再为它发请求")
    const menu = await p.handlers.menu()
    assert.ok(!menu.some((r) => r.title === "小型纳指当月连续"))
    p.handlers.perform("remove", "future:hf_NQ")
    assert.deepStrictEqual(plain(p.storage.watchlist.map((x) => x.code)), ["sh000001"])
  })

  await test("只用正常请求：不带 Referer、不碰东方财富和新浪", async () => {
    const p = load({ stored: { watchlist: [{ code: "161725", name: "白酒", kind: "fund" }, { code: "sh000001", name: "上证指数", kind: "index" }] } })
    await p.handlers.list("")
    await p.handlers.menu()
    await p.handlers.list("tx")
    assert.ok(p.requests.every((r) => !(r.options && r.options.headers)), "不带额外的请求头")
    assert.ok(p.requests.every((r) => manifest.hosts.includes(new URL(r.url).host)), p.requests.map((r) => r.url).join("\n"))
    assert.ok(p.requests.every((r) => !/[?&](ut|token)=/.test(r.url)), "不带 token")
  })

  await test("板块：搜「CPO」「pcb」找得到（腾讯），排在腾讯搜到的股票前面", async () => {
    const p = load()
    const rows = await p.handlers.list("CPO")
    assert.strictEqual(rows[0].id, "board:pt02GN2211")
    assert.strictEqual(rows[0].title, "共封装光模块(CPO）")
    assert.ok(rows[0].subtitle.startsWith("概念板块"))
    assert.ok(/^\d+\.\d{2}$/.test(rows[0].value), rows[0].value)
    assert.deepStrictEqual(plain(rows[0].icon), { text: "板", tint: "pink" })
    assert.strictEqual(rows[0].actions[0].id, "add")
    const pcb = await p.handlers.list("pcb")
    assert.strictEqual(pcb[0].id, "board:pt02101284", "不分大小写")
  })

  await test("板块名单一天取一次（存插件存储），取不到时搜索照常列股票", async () => {
    const p = load()
    await p.handlers.list("CPO")
    await p.handlers.list("PCB")
    assert.strictEqual(p.requests.filter((r) => r.url.includes("getRank")).length, 2, "概念一页、行业一页，第二次搜不再取")
    assert.strictEqual(p.storage.boards.list.length, 4)
    const again = load({ stored: { boards: p.storage.boards } })
    await again.handlers.list("CPO")
    assert.ok(!again.requests.some((r) => r.url.includes("getRank")), "今天取过就不取")
    const down = load({ rank: null })
    const rows = await down.handlers.list("tx")
    assert.strictEqual(rows[0].id, "stock:hk00700", "名单取不到，股票照常")
    assert.strictEqual(down.storage.boards, undefined, "取不到不存")
  })

  await test("一进列表就在后台取板块名单，之后搜「CPO」不用等", async () => {
    const p = load()
    await p.handlers.list("")
    await new Promise((r) => setTimeout(r, 50))
    assert.ok(p.storage.boards && p.storage.boards.list.length === 4, "进列表时已经取好了")
    const before = p.requests.filter((r) => r.url.includes("getRank")).length
    const rows = await p.handlers.list("CPO")
    assert.strictEqual(rows[0].id, "board:pt02GN2211")
    assert.strictEqual(p.requests.filter((r) => r.url.includes("getRank")).length, before, "搜索时不再取")
  })

  await test("基金的走势线：新浪的近一月净值（普通请求），6 小时取一次", async () => {
    const nav = sandbox.parseSinaNav(fixture("sina-nav-021528.json"))
    assert.strictEqual(nav.length, 21)
    assert.strictEqual(nav[nav.length - 1], 2.317, "最新的在最后")
    assert.deepStrictEqual(plain(sandbox.parseSinaNav("x")), [])
    const p = load({ stored: { watchlist: [{ code: "021528", kind: "fund", name: "财通成长优选混合C" }] } })
    const rows = await p.handlers.list("")
    assert.strictEqual(rows[0].spark.length, 21)
    assert.ok(rows[0].subtitle.includes("近一月走势"))
    const navRequest = p.requests.find((r) => r.url.includes("getNav"))
    assert.ok(!(navRequest.options && navRequest.options.headers), "不带额外请求头")
    await p.sandbox.sparkFor({ code: "021528", kind: "fund" }, Date.now() + 3 * 3600 * 1000)
    assert.strictEqual(p.requests.filter((r) => r.url.includes("getNav")).length, 1, "6 小时内不重取")
  })

  await test("市场图标的颜色：美股不用灰（灰留给没数据）", () => {
    assert.strictEqual(plain(sandbox.iconOf({ code: "usAAPL", kind: "stock" })).tint, "teal")
    assert.strictEqual(plain(sandbox.iconOf({ code: "bj430047", kind: "stock" })).tint, "cyan")
    const tints = ["sh600519", "sz000001", "bj430047", "hk00700", "usAAPL"].map((c) => sandbox.iconOf({ code: c, kind: "stock" }).tint)
    assert.strictEqual(new Set(tints).size, tints.length, "各市场颜色不重复")
  })

  await test("翻页：每页都满时按总数停", async () => {
    const pages = []
    const full = (url) => {
      const offset = parseInt(/offset=(\d+)/.exec(url)[1], 10)
      if (url.includes("hy2")) return JSON.stringify({ code: 0, data: { rank_list: [{ code: "pt01801081", name: "电子元件" }], total: 1 } })
      pages.push(offset)
      const list = Array.from({ length: 100 }, (_, i) => ({ code: "pt0200" + String(offset + i).padStart(4, "0"), name: "板块" + (offset + i) }))
      return JSON.stringify({ code: 0, data: { rank_list: list, total: 200 } })
    }
    const p = load({ rank: full })
    await p.handlers.list("CPO")
    assert.deepStrictEqual(plain(pages), [0, 100], "总数 200：取两页就停，不去取第三页")
    assert.strictEqual(p.storage.boards.list.length, 201)
  })

  await test("取到一半返回不对（不是 JSON）：整份不存", async () => {
    const half = (url) => (url.includes("hy2") ? "<html>busy</html>" : rankPage(url))
    const p = load({ rank: half })
    await p.handlers.list("CPO")
    assert.strictEqual(p.storage.boards, undefined)
  })

  await test("加进自选的板块：和股票一个批量请求取行情，有走势线，菜单里一段「板块」", async () => {
    const p = load({ stored: { watchlist: [{ code: "pt02GN2211", kind: "board", name: "共封装光模块(CPO）", type: "concept" }] } })
    const rows = await p.handlers.list("")
    assert.ok(/^\d+\.\d{2}$/.test(rows[0].value))
    assert.strictEqual(rows[0].spark.length, 242)
    assert.ok(p.requests.some((r) => r.url.startsWith("https://qt.gtimg.cn/q=") && r.url.includes("pt02GN2211")))
    const menu = await p.handlers.menu()
    assert.deepStrictEqual(plain(menu[0]), { type: "header", text: "板块" })
    p.handlers.perform("open", "board:pt02GN2211")
    assert.deepStrictEqual(p.opened, ["https://gu.qq.com/pt02GN2211"])
  })

  console.log(process.exitCode ? "有失败" : `全部通过（${passed} 条）`)
})()
