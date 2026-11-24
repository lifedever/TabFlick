// TabFlick 黄金插件（官方）。
//
// 现货：伦敦金走腾讯 qt.gtimg.cn（hf_XAU，实时，GBK），同一个请求带上 whUSDCNY 折成人民币每克；上金所 Au99.99、
// Au(T+D) 走招行手机站的行情接口 m.cmbchina.com/api/rate/gold（比交易所晚几分钟）。积存金：工行走网银的公开行情接口
// （POST tranCode=A00622），民生、浙商走京东金融的报价接口（京东卖的就是这两家）。
//
// 没有走势线：伦敦金、工行、浙商拿不到分时（腾讯没有伦敦金的分时，工行行情页本身没有图，京东的当日分时只认民生），
// 只给一部分行画线，列表长短不齐（用户 2026-11-24 看了实物定的），所以都不画。
//
// 这些接口都没有公开文档，只用正常请求（2026-11-24 逐个试过：不带 Referer、不冒充浏览器都给数据）。建行积存金的接口
// 不带 Referer 返回空、招行黄金账户找不到报价，所以没有这两家。一个来源取不到只影响它那几行：有上次的数就接着显示
// （时间停在上次），没有就写「取不到」；全都取不到才让调用失败，TabFlick 留着上一次的结果。
//
// 纯函数（parseTencent / parseCmb / parseIcbc / parseJd / goldOpen / statusNote）由 tests/gold.test.js 用 node 测。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"

/** 界面文字：简中 / 繁中 / 其余语言用英文。 */
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** 1 金衡盎司 = 31.1034768 克。 */
const GRAMS_PER_OUNCE = 31.1034768

// MARK: - 品种

const COMMON_KEYS = ["黄金", "黃金", "gold", "hj", "huangjin"]

/**
 * 全部品种，列表就按这个顺序。id 是存盘的键（放进菜单栏的那几个），发布后别改。
 * source：价格从哪个来源取（一个来源可能给好几个品种）。
 */
const PRODUCTS = [
  { id: "xau", group: "spot", source: "tencent", name: ["伦敦金", "倫敦金", "London Gold"], unit: "usd",
    icon: ["伦", "倫", "LD"], tint: "orange", page: "https://finance.sina.com.cn/futures/quotes/XAU.shtml",
    keys: ["xau", "ldj", "lundunjin", "london", "spot", "现货", "現貨", "xianhuo", "xh", "国际", "國際", "gj"] },
  { id: "xauCny", group: "spot", source: "tencent", name: ["伦敦金 折人民币", "倫敦金 折人民幣", "London Gold in CNY"], unit: "cny",
    icon: ["伦", "倫", "LD"], tint: "orange", page: "https://finance.sina.com.cn/futures/quotes/XAU.shtml",
    keys: ["xau", "ldj", "lundunjin", "london", "人民币", "人民幣", "rmb", "cny", "折算"] },
  { id: "au9999", group: "spot", source: "cmb", name: ["Au99.99", "Au99.99", "Au99.99"], unit: "cny",
    icon: ["上", "上", "SG"], tint: "brown", page: "https://www.sge.com.cn/sjzx/yshqbg",
    keys: ["au9999", "9999", "上金所", "sjs", "sge", "上海黄金交易所", "上海黃金交易所", "现货", "現貨", "xh"] },
  { id: "autd", group: "spot", source: "cmb", name: ["Au(T+D)", "Au(T+D)", "Au(T+D)"], unit: "cny",
    icon: ["上", "上", "SG"], tint: "brown", page: "https://www.sge.com.cn/sjzx/yshqbg",
    keys: ["autd", "au(t+d)", "t+d", "td", "延期", "上金所", "sjs", "sge"] },
  { id: "icbc", group: "plan", source: "icbc", name: ["工行积存金", "工行積存金", "ICBC Gold Accumulation"], unit: "cny",
    icon: ["工", "工", "IC"], tint: "red", page: "https://mybank.icbc.com.cn/icbc/newperbank/perbank3/gold/goldaccrual_query_out.jsp",
    keys: ["工行", "工商银行", "工商銀行", "gh", "gs", "icbc", "积存金", "積存金", "jcj"] },
  { id: "cmbc", group: "plan", source: "jdMs", name: ["民生积存金", "民生積存金", "CMBC Gold Accumulation"], unit: "cny",
    icon: ["民", "民", "MS"], tint: "teal", page: "https://m.jdjygold.com/finance-gold/newgold/index/",
    keys: ["民生", "ms", "cmbc", "京东", "京東", "jd", "积存金", "積存金", "jcj"] },
  // 浙商没找到能直接打开的行情页，回车拷贝价格
  { id: "czb", group: "plan", source: "jdZs", name: ["浙商积存金", "浙商積存金", "CZB Gold Accumulation"], unit: "cny",
    icon: ["浙", "浙", "ZS"], tint: "indigo",
    keys: ["浙商", "zs", "czb", "京东", "京東", "jd", "积存金", "積存金", "jcj"] },
]

/** 按 id 找品种。id 来自 TabFlick 转来的行 / 菜单动作，用 find 不用对象下标（「__proto__」会摸到原型）。 */
function productOf(id) {
  return PRODUCTS.find((p) => p.id === id) || null
}

function pick(arr) {
  return LANG === "zh" ? arr[0] : LANG === "zh-Hant" ? arr[1] : arr[2]
}

function nameOf(p) {
  return pick(p.name)
}

function unitText(p) {
  return p.unit === "usd" ? t("美元/盎司", "美元/盎司", "USD/oz") : t("元/克", "元/克", "CNY/g")
}

/** 没设过时菜单栏里全放（一共七个）：只放三个的话另外几个要在列表里按 ⌘↩ 才找得到（用户 2026-11-24 问「怎么这么少」）。
 *  不想看的在列表里移出。 */
const DEFAULT_MENU = PRODUCTS.map((p) => p.id)

/** 放进菜单栏的品种，按列表的顺序（分组头才连得上）。 */
function menuItems() {
  const saved = tabflick.storage.get("menu")
  const ids = new Set(Array.isArray(saved) ? saved : DEFAULT_MENU)
  return PRODUCTS.filter((p) => ids.has(p.id))
}

// MARK: - 解析

function num(v) {
  const n = parseFloat(v)
  return isFinite(n) ? n : null
}

function pctOf(price, prev) {
  return price != null && prev ? (price / prev - 1) * 100 : null
}

/** 北京时间的日期和时分：{ date: "2026-11-24", hm: "15:48" }。 */
function shanghaiTime(ms) {
  const d = new Date(ms + 8 * 3600 * 1000)
  const p = (n) => String(n).padStart(2, "0")
  return {
    date: `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`,
    hm: `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`,
  }
}

/**
 * 腾讯：v_hf_XAU="现价,涨跌幅,买价,卖价,最高,最低,时:分:秒,昨收,今开,…,日期,名字";
 *       v_whUSDCNY="310~美元人民币~USDCNY~现价~…"，第 12 段是涨跌额。
 * 返回 { xau, xauCny }，伦敦金没取到就是空的。折人民币的涨跌按两边的昨收一起算（汇率没涨跌额就只看金价）。
 */
function parseTencent(text) {
  const out = {}
  let gold = null
  let fx = null
  for (const raw of String(text).split("\n")) {
    const m = /^v_(\w+)="(.*)";?$/.exec(raw.trim())
    if (!m) continue
    if (m[1] === "hf_XAU") {
      const f = m[2].split(",")
      const price = num(f[0])
      if (price == null || price <= 0) continue
      const prev = num(f[7])
      const time = /^(\d{2}:\d{2})/.exec(f[6] || "")
      gold = { price, prev, pct: pctOf(price, prev), high: num(f[4]), low: num(f[5]),
               date: /^\d{4}-\d{2}-\d{2}$/.test(f[12] || "") ? f[12] : null, hm: time ? time[1] : null }
    } else if (m[1] === "whUSDCNY") {
      const f = m[2].split("~")
      const rate = num(f[3])
      if (rate != null && rate > 0) fx = { rate, change: num(f[12]) }
    }
  }
  if (!gold) return out
  out.xau = gold
  if (fx) {
    const price = gold.price * fx.rate / GRAMS_PER_OUNCE
    const prevRate = fx.change != null ? fx.rate - fx.change : fx.rate
    const prev = gold.prev ? gold.prev * prevRate / GRAMS_PER_OUNCE : null
    out.xauCny = { price, prev, pct: pctOf(price, prev), rate: fx.rate, date: gold.date, hm: gold.hm }
  }
  return out
}

/**
 * 招行：{ returnCode: "SUC0000", body: { data: [{ goldNo: "AU9999", curPrice, preClose, open, high, low, time: "15:45:00" }, …] } }。
 * 涨跌按 preClose 自己算：Au(T+D) 那一行的 upDown 和现价、昨收对不上（2026-11-24 实测）。现价 0 是当天没成交，当没取到。
 */
function parseCmb(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return {} }
  const rows = d && d.body && Array.isArray(d.body.data) ? d.body.data : []
  const out = {}
  for (const [id, no] of [["au9999", "AU9999"], ["autd", "AUTD"]]) {
    const r = rows.find((x) => x && x.goldNo === no)
    const price = r ? num(r.curPrice) : null
    if (price == null || price <= 0) continue
    const prev = num(r.preClose)
    const time = /^(\d{2}:\d{2})/.exec(r.time || "")
    out[id] = { price, prev, pct: pctOf(price, prev), high: num(r.high), low: num(r.low), date: null, hm: time ? time[1] : null }
  }
  return out
}

/**
 * 工行：{ sysdate: "2026-11-24 15:51:23", rf: [{ ActivePrice: 主动积存价, SellPrice: 赎回价, RegPrice: 定期积存价,
 * HighPrice, LowPrice }] }。不给昨收，算不出涨跌。
 */
function parseIcbc(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return {} }
  const r = d && Array.isArray(d.rf) ? d.rf[0] : null
  const price = r ? num(r.ActivePrice) : null
  if (price == null || price <= 0) return {}
  const m = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})/.exec(d.sysdate || "")
  return {
    icbc: { price, prev: null, pct: null, sell: num(r.SellPrice), high: num(r.HighPrice), low: num(r.LowPrice),
            date: m ? m[1] : null, hm: m ? m[2] : null },
  }
}

/** 京东金融：{ success: true, resultData: { datas: { price, yesterdayPrice, time: 毫秒 } } }。 */
function parseJd(text, id) {
  let d
  try { d = JSON.parse(text) } catch (e) { return {} }
  const x = d && d.success && d.resultData && d.resultData.datas
  const price = x ? num(x.price) : null
  if (price == null || price <= 0) return {}
  const prev = num(x.yesterdayPrice)
  const ms = Number(x.time)
  const when = ms > 0 && ms < 4102444800000 ? shanghaiTime(ms) : { date: null, hm: null }   // 2100 年以后的当乱值
  return { [id]: { price, prev, pct: pctOf(price, prev), date: when.date, hm: when.hm } }
}

// MARK: - 取数据

async function getText(url, options) {
  const res = await tabflick.fetch(url, options)
  if (res.status !== 200) throw new Error("HTTP " + res.status)
  return res.text
}

/** 每个来源怎么取，返回 { 品种 id: 报价 }。一个品种都没解析出来算失败。 */
const SOURCES = {
  tencent: async () => parseTencent(await getText("https://qt.gtimg.cn/q=hf_XAU,whUSDCNY", { encoding: "gbk" })),
  cmb: async () => parseCmb(await getText("https://m.cmbchina.com/api/rate/gold")),
  icbc: async () => parseIcbc(await getText("https://mybank.icbc.com.cn/servlet/AsynGetDataServlet", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
    body: "tranCode=A00622",
  })),
  jdMs: async () => parseJd(await getText("https://api.jdjygold.com/gw/generic/hj/h5/m/latestPrice?reqData=%7B%7D"), "cmbc"),
  jdZs: async () => parseJd(await getText("https://api.jdjygold.com/gw2/generic/jrm/h5/m/stdLatestPrice?productSku=1961543816"), "czb"),
}

/**
 * 按北京时间粗算开没开市：伦敦金周一早上开、周六早上收（夏令时冬令时都盖住，宽一点），上金所夜盘到周六 02:30，
 * 银行积存金跟着走。周末之外一律当开着（上金所午间、傍晚休市时伦敦金照样在动），节假日不认，多取几次而已。
 */
function goldOpen(nowMs = Date.now()) {
  const d = new Date(nowMs + 8 * 3600 * 1000)
  const day = d.getUTCDay()   // 0 周日 … 6 周六（北京时间）
  const minutes = d.getUTCHours() * 60 + d.getUTCMinutes()
  if (day === 0) return false
  if (day === 6) return minutes < 6 * 60
  if (day === 1) return minutes >= 6 * 60
  return true
}

/** 开市 4 秒（面板 5 秒问一次，每次都是新的），休市 5 分钟；取失败了 30 秒内不重试（接着用上次的数）。 */
const LIVE_TTL = 4 * 1000
const CLOSED_TTL = 5 * 60 * 1000
const RETRY_AFTER = 30 * 1000

/** 每个来源：{ quotes（上次取到的）, at, ttl, failedAt, error, inflight }。闲置卸载后会清空，重新取就是。 */
const state = {}

async function loadSource(name, now) {
  const s = state[name] || (state[name] = {})
  if (s.quotes && now - s.at < s.ttl) return s.quotes
  if (s.failedAt && now - s.failedAt < RETRY_AFTER) {
    if (s.quotes) return s.quotes
    throw s.error
  }
  if (!s.inflight) {
    s.inflight = SOURCES[name]().then((quotes) => {
      if (!Object.keys(quotes).length) throw new Error("no price in response")
      Object.assign(s, { quotes, at: now, ttl: goldOpen(now) ? LIVE_TTL : CLOSED_TTL, failedAt: 0, error: null })
      return quotes
    }, (e) => {
      console.log(`${name} unavailable: ${e && e.message || e}`)
      Object.assign(s, { failedAt: now, error: e })
      if (s.quotes) return s.quotes   // 用上次的，时间停在上次
      throw e
    }).finally(() => { s.inflight = null })
  }
  return s.inflight
}

/** 这几个品种的报价（只取用得到的来源）。全部来源都失败才抛。 */
async function quotesFor(products, now = Date.now()) {
  const names = [...new Set(products.map((p) => p.source))]
  if (!names.length) return {}
  const results = await Promise.allSettled(names.map((n) => loadSource(n, now)))
  const out = {}
  let firstError = null
  for (const r of results) {
    if (r.status === "fulfilled") Object.assign(out, r.value)
    else firstError = firstError || r.reason
  }
  if (!Object.keys(out).length && firstError) throw firstError
  return out
}

// MARK: - 显示

function formatPrice(price) {
  return price.toFixed(2)
}

function formatPct(pct) {
  return (pct > 0 ? "+" : "") + pct.toFixed(2) + "%"
}

function tone(pct) {
  if (pct == null) return "secondary"
  return pct > 0 ? "up" : pct < 0 ? "down" : "plain"
}

/** 报价时间：今天的写「15:48」，不是今天的写「11-21 05:59」。 */
function timeText(q, today) {
  if (!q || !q.hm) return null
  return q.date && q.date !== today ? q.date.slice(5) + " " + q.hm : q.hm
}

/** 副标题：来源或价格类型 · 单位 · 时间。取不到时把时间换成「取不到」。 */
function subtitle(p, q, today) {
  const parts = []
  if (p.id === "xau") parts.push("XAU/USD")
  else if (p.id === "xauCny") parts.push(q && q.rate ? t("汇率 ", "匯率 ", "Rate ") + q.rate.toFixed(4) : t("按美元汇率折算", "按美元匯率折算", "Converted at USD/CNY"))
  else if (p.source === "cmb") parts.push(t("上海黄金交易所", "上海黃金交易所", "Shanghai Gold Exchange"))
  else if (p.id === "icbc") parts.push(t("主动积存价", "主動積存價", "Buy price"))
  else parts.push(t("京东金融", "京東金融", "JD Finance"))
  parts.push(unitText(p))
  if (p.id === "icbc" && q && q.sell != null && Math.abs(q.sell - q.price) >= 0.005) {
    parts.push(t("赎回 ", "贖回 ", "Sell ") + formatPrice(q.sell))
  }
  parts.push(q ? timeText(q, today) || "" : t("取不到", "取不到", "Unavailable"))
  return parts.filter(Boolean).join(" · ")
}

function rowActions(p, inMenu) {
  const actions = []
  if (p.page) actions.push({ id: "open", title: t("打开行情页", "打開行情頁", "Open Quote Page"), symbol: "safari.fill" })
  actions.push({ id: "copy", title: t("拷贝价格", "拷貝價格", "Copy Price"), symbol: "doc.on.doc.fill" })
  actions.push(inMenu
    ? { id: "unpin", title: t("移出菜单栏", "移出選單列", "Remove from Menu Bar"), symbol: "minus.circle.fill", destructive: true, stay: true }
    : { id: "pin", title: t("放进菜单栏", "放進選單列", "Show in Menu Bar"), symbol: "menubar.rectangle", stay: true })
  return actions
}

function listRow(p, q, inMenu, today) {
  return {
    id: p.id,
    title: nameOf(p),
    subtitle: subtitle(p, q, today),
    value: q ? formatPrice(q.price) : "—",
    detail: q && q.pct != null ? formatPct(q.pct) : null,
    tone: tone(q && q.pct),
    icon: { text: pick(p.icon), tint: p.tint },
    actions: rowActions(p, inMenu),
  }
}

/** 输入认不认这个品种：名字包含它（去掉空格、不分大小写），或某个别名以它开头。在本地比，不联网。 */
function matches(p, text) {
  const q = text.toLowerCase().replace(/\s+/g, "")
  if (!q) return true
  return p.name.some((n) => n.toLowerCase().replace(/\s+/g, "").includes(q))
    || p.keys.concat(COMMON_KEYS).some((k) => k.toLowerCase().startsWith(q))
}

async function list(query, now = Date.now()) {
  const text = String(query || "").trim()
  const shown = PRODUCTS.filter((p) => matches(p, text))
  if (!shown.length) return []
  const quotes = await quotesFor(shown, now)
  const inMenu = new Set(menuItems().map((p) => p.id))
  const today = shanghaiTime(now).date
  return shown.map((p) => listRow(p, quotes[p.id], inMenu.has(p.id), today))
}

/**
 * 菜单底下那行：看报价里最新的时间。不是今天的（周末、节假日）→「收盘价 · 11-21」；今天的 →「更新于 15:48」。
 * 没日期的（招行只给时分）只在没有别的时才用。
 */
function statusNote(quotes, items, today) {
  const qs = items.map((p) => quotes[p.id]).filter((q) => q && q.hm)
  const dated = qs.filter((q) => q.date).sort((a, b) => (a.date + a.hm < b.date + b.hm ? -1 : 1))
  const latest = dated[dated.length - 1] || qs.slice().sort((a, b) => (a.hm < b.hm ? -1 : 1))[qs.length - 1]
  if (!latest) return null
  if (latest.date && latest.date < today) return t("收盘价 · ", "收盤價 · ", "Close · ") + latest.date.slice(5)
  return t("更新于 ", "更新於 ", "Updated ") + latest.hm
}

async function menu(now = Date.now()) {
  const items = menuItems()
  if (!items.length) {
    return [{ type: "note", text: t("还没有放进菜单栏的品种。在黄金列表里按 ⌘↩ 放进来。",
                                    "還沒有放進選單列的品種。在黃金列表裡按 ⌘↩ 放進來。",
                                    "Nothing in the menu bar yet. Press ⌘↩ on a row in the Gold list to add it.") }]
  }
  const quotes = await quotesFor(items, now)
  const rows = []
  for (const [group, title] of [["spot", t("现货", "現貨", "Spot")], ["plan", t("积存金", "積存金", "Gold Accumulation")]]) {
    const inGroup = items.filter((p) => p.group === group)
    if (!inGroup.length) continue
    rows.push({ type: "header", text: title })
    for (const p of inGroup) {
      const q = quotes[p.id]
      rows.push({
        title: nameOf(p),
        value: q ? formatPrice(q.price) : "—",
        detail: q && q.pct != null ? formatPct(q.pct) : null,
        tone: tone(q && q.pct),
        action: (p.page ? "open:" : "copy:") + p.id,
      })
    }
  }
  const note = statusNote(quotes, items, shanghaiTime(now).date)
  if (note) rows.push({ type: "separator" }, { type: "note", text: note })
  return rows
}

// MARK: - 动作

async function perform(action, id) {
  const p = productOf(id)
  if (!p) return
  if (action === "open") {
    if (p.page) tabflick.openURL(p.page)
  } else if (action === "copy") {
    let q = null
    try { q = (await quotesFor([p]))[p.id] } catch (e) { q = null }
    if (!q) {
      tabflick.toast(t("取不到价格", "取不到價格", "Price unavailable"), nameOf(p))
      return
    }
    tabflick.copy(formatPrice(q.price))
    tabflick.toast(t("已拷贝价格", "已拷貝價格", "Price copied"), `${nameOf(p)} ${formatPrice(q.price)} ${unitText(p)}`)
  } else if (action === "pin" || action === "unpin") {
    const ids = new Set(menuItems().map((x) => x.id))
    if (action === "pin") ids.add(p.id)
    else ids.delete(p.id)
    tabflick.storage.set("menu", PRODUCTS.filter((x) => ids.has(x.id)).map((x) => x.id))
    tabflick.toast(action === "pin" ? t("已放进菜单栏", "已放進選單列", "Added to menu bar") : t("已移出菜单栏", "已移出選單列", "Removed from menu bar"),
                   nameOf(p))
  }
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    menu: () => menu(),
    action(id) {
      const m = /^(open|copy):(\w+)$/.exec(String(id))
      if (m) return perform(m[1], m[2])
    },
    list: (query) => list(query),
    perform,
  })
}
