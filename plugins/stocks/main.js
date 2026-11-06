// TabFlick 股票插件（官方）。
//
// 行情来自腾讯的公开接口：qt.gtimg.cn（批量报价，GBK；场外基金给的是最近公布的净值）、smartbox.gtimg.cn（搜索，
// 认拼音首字母）、web.ifzq.gtimg.cn（分时）。这些接口没有官方文档，改了就取不到 —— 取不到时让调用失败，TabFlick
// 会留着上一次的数字并写明「数据未更新」，不拿一句报错盖掉原来的数。
//
// 只用正常请求（2026-11-06 用户定的「不走非正常路子」）：不冒充浏览器或别家 App、不扒 token、不为过防盗链带
// 对方的 Referer。所以撤掉了基金盘中估值 / 净值历史（东方财富要带天天基金 App 的参数）和境外期货（新浪要带
// Referer、腾讯的期货报价停在收盘那一刻）。自选里以前加的期货留着一行，写明数据源已停用、可以移出。
// 概念 / 行业板块（CPO、PCB 这类）走腾讯：proxy.finance.qq.com 的板块排行给名单（pt02GN2211「共封装光模块(CPO）」），
// 一天取一次存本地，搜索在本地比；行情和分时就用上面那两个接口（板块代码和股票一起批量取）。
// 场外基金没有分时：走势线用新浪的基金净值接口（stock.finance.sina.com.cn …getNav，普通请求就给，最近 21 个交易日）。东方财富只给浏览器
// 数据（TabFlick 的普通请求被断开连接，2026-11-06 实测），不用它。
//
// 分工：这里只返回描述（菜单行），怎么画由 TabFlick 决定。纯函数（parseQuotes / parseSmartbox / statusNote）
// 由 tests/stocks.test.js 用 node 测。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"

/** 界面文字：简中 / 繁中 / 其余语言用英文。 */
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** 没设过自选时的默认：大盘三个指数。 */
const DEFAULT_WATCHLIST = [
  { code: "sh000001", name: "上证指数", kind: "index", pinyin: "szzs" },
  { code: "sh000688", name: "科创50", kind: "index", pinyin: "kc50" },
  { code: "sz399006", name: "创业板指", kind: "index", pinyin: "cybz" },
]

function watchlist() {
  const saved = tabflick.storage.get("watchlist")
  return Array.isArray(saved) ? saved.filter(isEntry) : DEFAULT_WATCHLIST
}

function isEntry(x) {
  return x && typeof x.code === "string" && /^[a-zA-Z0-9._]{2,20}$/.test(x.code)
    && ["index", "stock", "fund", "future", "board"].includes(x.kind)
}

// MARK: - 报价

/** 报价用的代码：场外基金加 jj 前缀，其余就是自选里存的（sh600519 / hk00700 / usAAPL）。 */
function quoteKey(entry) {
  return entry.kind === "fund" ? "jj" + entry.code : entry.code
}

/**
 * 解析腾讯的批量报价，返回 { 报价代码: 报价 }。
 * 股票、指数、港美股一行：v_sh600519="1~名字~代码~现价~昨收~今开~…"，第 30 段是时间、31 涨跌额、32 涨跌幅。
 * 场外基金一行：v_jj161725="代码~名字~估值~估值涨幅~~单位净值~累计净值~日涨幅~净值日期~"。
 * 认不出的行跳过。
 */
function parseQuotes(text) {
  const out = {}
  for (const raw of String(text).split("\n")) {
    const m = /^v_([a-zA-Z]+[\w.]*)="(.*)";?$/.exec(raw.trim())
    if (!m) continue
    const key = m[1]
    const f = m[2].split("~")
    if (key.startsWith("jj")) {
      const nav = parseFloat(f[5])
      if (!isFinite(nav) || !f[1]) continue
      const pct = parseFloat(f[7])
      out[key] = { name: f[1], price: nav, pct: isFinite(pct) ? pct : null, date: f[8] || "", fund: true }
      continue
    }
    if (f.length < 33 || !f[1]) continue
    const price = parseFloat(f[3])
    if (!isFinite(price)) continue
    const pct = parseFloat(f[32])
    out[key] = { name: f[1], price, pct: isFinite(pct) ? pct : null, time: parseTime(f[30]) }
  }
  return out
}

/** 三种时间写法：A 股 20261106161458、港股 2026/11/06 16:06:02、美股 2026-11-05 16:00:02。 */
function parseTime(s) {
  let m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\d{2}$/.exec(s || "")
  if (!m) m = /^(\d{4})[/-](\d{2})[/-](\d{2}) (\d{2}):(\d{2})/.exec(s || "")
  return m ? { date: `${m[1]}-${m[2]}-${m[3]}`, hm: `${m[4]}:${m[5]}` } : null
}

// MARK: - 板块（腾讯）

/** 腾讯的板块排行：{ code: 0, data: { rank_list: [{ code: "pt02GN2211", name: "共封装光模块(CPO）", … }], total } }。 */
function parseBoardRank(text, type) {
  let d
  try { d = JSON.parse(text) } catch (e) { return null }
  if (!d || d.code !== 0 || !d.data || !Array.isArray(d.data.rank_list)) return null
  return {
    total: Number(d.data.total) || 0,
    list: d.data.rank_list.filter((x) => x && /^pt[0-9A-Za-z]{6,12}$/.test(x.code) && typeof x.name === "string" && x.name)
      .map((x) => ({ code: x.code, name: x.name, type })),
  }
}

const BOARD_LIST_TTL = 24 * 3600 * 1000
const BOARD_PAGE = 100
let boardLoading = null

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * 板块名单：概念（gn）+ 行业（hy2），一页 100 个、一页一页取、间隔 0.3 秒，一天取一次存插件存储（900 多个，
 * 十个请求左右）。取到一半出错就不存，用旧的（没有旧的就是空），下次搜索再取；同时只有一份在取。
 */
async function loadBoards(nowMs = Date.now()) {
  const cached = tabflick.storage.get("boards")
  const usable = cached && Array.isArray(cached.list) ? cached.list : null
  if (usable && nowMs - (cached.at || 0) < BOARD_LIST_TTL) return usable
  if (!boardLoading) {
    boardLoading = (async () => {
      const all = []
      for (const [boardType, type] of [["gn", "concept"], ["hy2", "industry"]]) {
        for (let offset = 0; offset < 3000; offset += BOARD_PAGE) {
          const res = await tabflick.fetch("https://proxy.finance.qq.com/cgi/cgi-bin/rank/pt/getRank?board_type=" + boardType
            + "&sort_type=PriceRatio&direct=down&offset=" + offset + "&count=" + BOARD_PAGE)
          const page = res.status === 200 ? parseBoardRank(res.text, type) : null
          if (!page) throw new Error("board list: HTTP " + res.status)
          all.push(...page.list)
          if (page.list.length < BOARD_PAGE || offset + BOARD_PAGE >= page.total) break
          await sleep(300)
        }
        await sleep(300)
      }
      const seen = new Set()
      const unique = all.filter((b) => !seen.has(b.code) && seen.add(b.code))
      tabflick.storage.set("boards", { at: Date.now(), list: unique })
      return unique
    })().finally(() => { boardLoading = null })
  }
  try {
    return await boardLoading
  } catch (e) {
    console.log("board list unavailable: " + (e && e.message || e))
    return usable || []
  }
}

/** 搜板块：名字包含输入（不分大小写，「cpo」能找到「共封装光模块(CPO）」）。 */
function matchBoards(boards, text) {
  const q = text.toLowerCase()
  return boards.filter((b) => b.name.toLowerCase().includes(q))
    .sort((a, b) => a.name.length - b.name.length)   // 名字短的更像要找的那个
}

// MARK: - 开没开市（决定报价多久重取一次）

/**
 * 按北京时间粗算这一类此刻在不在交易（宽一点：前后各多算一会儿，宁可多取几次也别漏掉开盘）。
 * A 股 9:15–15:05；港股 9:15–16:15；美股 21:00–次日 05:30（夏令时冬令时都盖住）。周末都不开。
 * 节假日不认（多取几次而已）。
 */
function marketOpen(entry, nowMs = Date.now()) {
  const d = new Date(nowMs + 8 * 3600 * 1000)
  const day = d.getUTCDay()   // 0 周日 … 6 周六（北京时间）
  const minutes = d.getUTCHours() * 60 + d.getUTCMinutes()
  const between = (from, to) => minutes >= from && minutes <= to
  if (entry.kind === "future") return false   // 期货的数据源已停用，不取
  const code = entry.code
  if (code.startsWith("us")) {
    // 周一晚上开盘、周六早上收盘
    if (day === 0 || (day === 1 && minutes < 21 * 60) || (day === 6 && minutes > 5 * 60 + 30)) return false
    return minutes >= 21 * 60 || minutes <= 5 * 60 + 30
  }
  if (day === 0 || day === 6) return false
  if (code.startsWith("hk")) return between(9 * 60 + 15, 16 * 60 + 15)
  return between(9 * 60 + 15, 15 * 60 + 5)
}

/** 报价缓存：有一类在交易就 4 秒（面板 5 秒刷一次，每次都是新的），全都休市就 5 分钟（面板照样 5 秒问一次，
 *  但不发请求）。用户 2026-11-06：尽量少占资源。 */
const LIVE_TTL = 4 * 1000
const CLOSED_TTL = 5 * 60 * 1000
let quoteCache = { key: "", at: 0, ttl: 0, quotes: null }

async function cachedQuotes(list, nowMs = Date.now()) {
  const key = list.map(quoteKey).join(",")
  if (quoteCache.quotes && quoteCache.key === key && nowMs - quoteCache.at < quoteCache.ttl) return quoteCache.quotes
  const quotes = await fetchQuotes(list)
  const ttl = list.some((x) => marketOpen(x, nowMs)) ? LIVE_TTL : CLOSED_TTL
  quoteCache = { key, at: nowMs, ttl, quotes }
  return quotes
}

/** 报价：股票、指数、港美股、场外基金净值，腾讯一个批量请求。期货不取（数据源已停用）。 */
async function fetchQuotes(list) {
  const keys = [...new Set(list.filter((x) => x.kind !== "future").map(quoteKey))]
  if (!keys.length) return {}
  const res = await tabflick.fetch("https://qt.gtimg.cn/q=" + keys.join(","), { encoding: "gbk" })
  if (res.status !== 200) throw new Error("HTTP " + res.status)
  return parseQuotes(res.text)
}

// MARK: - 显示

function formatPrice(price, entry) {
  if (entry.kind === "fund") return price.toFixed(4)
  return price < 10 ? price.toFixed(3) : price.toFixed(2)
}

function formatPct(pct) {
  return (pct > 0 ? "+" : "") + pct.toFixed(2) + "%"
}

function tone(pct) {
  if (pct == null) return "secondary"
  return pct > 0 ? "up" : pct < 0 ? "down" : "plain"
}

/** 港 / 美 / 期 小字；A 股和指数不写。 */
function marketBadge(code) {
  if (code.startsWith("hf_")) return t("期", "期", "Fut")
  if (code.startsWith("hk")) return t("港", "港", "HK")
  if (code.startsWith("us")) return t("美", "美", "US")
  return null
}

function monthDay(date) {
  return date ? date.slice(5) : ""
}

/** 北京时间的此刻：{ date: "2026-11-06", hm: "17:20" }（A 股按北京时间开收盘，不看本机时区）。 */
function shanghaiNow(ms = Date.now()) {
  const d = new Date(ms + 8 * 3600 * 1000)
  const p = (n) => String(n).padStart(2, "0")
  return {
    date: `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`,
    hm: `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`,
  }
}

/**
 * 菜单底下那行：看自选里 A 股 / 指数最新的报价时间。
 * 不是今天的（开盘前、周末、节假日）→「收盘价 · 11-05」；今天 15:00 以后 →「已收盘 · 11-06」；盘中 →「更新于 14:32」。
 * 一只 A 股都没有就不写。
 */
function statusNote(quotes, list, now = shanghaiNow()) {
  const times = list
    .filter((x) => x.kind !== "fund" && /^(sh|sz|bj)/.test(x.code))
    .map((x) => quotes[quoteKey(x)])
    .filter((q) => q && q.time)
    .map((q) => q.time)
    .sort((a, b) => (a.date + a.hm < b.date + b.hm ? -1 : 1))
  const latest = times[times.length - 1]
  if (!latest) return null
  if (latest.date < now.date) return t("收盘价 · ", "收盤價 · ", "Close · ") + monthDay(latest.date)
  if (latest.hm >= "15:00") return t("已收盘 · ", "已收盤 · ", "Closed · ") + monthDay(latest.date)
  return t("更新于 ", "更新於 ", "Updated ") + latest.hm
}

/** 菜单行：指数 / 自选 / 基金三段，最后一行写行情是什么时候的。 */
function menuRows(list, quotes, now) {
  const rows = []
  const groups = [
    ["index", t("指数", "指數", "Indices")],
    ["stock", t("自选", "自選", "Watchlist")],
    ["board", t("板块", "板塊", "Sectors")],
    ["fund", t("基金", "基金", "Funds")],
  ]
  for (const [kind, title] of groups) {
    const items = list.filter((x) => x.kind === kind)
    if (!items.length) continue
    let header = title
    if (kind === "fund") {
      const date = items.map((x) => quotes[quoteKey(x)]).find((q) => q && q.date)?.date
      if (date) header += " · " + t("净值 ", "淨值 ", "NAV ") + monthDay(date)
    }
    rows.push({ type: "header", text: header })
    for (const x of items) {
      const q = quotes[quoteKey(x)]
      rows.push({
        title: q ? q.name : x.name,
        badge: marketBadge(x.code),
        value: q ? formatPrice(q.price, x) : "—",
        detail: q && q.pct != null ? formatPct(q.pct) : null,
        tone: tone(q && q.pct),
        action: "open:" + x.kind + ":" + x.code,
      })
    }
  }
  const note = statusNote(quotes, list, now)
  if (note) rows.push({ type: "separator" }, { type: "note", text: note })
  return rows
}

// MARK: - 搜索

/**
 * 解析腾讯的搜索结果：v_hint="市场~代码~名字~拼音首字母~类型^…"，名字是 \uXXXX 转义。没结果时是 "N"。
 * 市场 jj 是场外基金（类型是 QDII、KJ…，2026-11-06 发现第一版把它当认不出的市场跳过了，一只场外基金都搜不到）；
 * 类型 ZS 是指数；其余（GP-A、GP、ETF、LOF…）当股票取实时价。只认沪深京港美和场外基金。
 */
function parseSmartbox(text) {
  const m = /v_hint="(.*)"/.exec(String(text))
  if (!m || m[1] === "N") return []
  let decoded
  try { decoded = JSON.parse('"' + m[1] + '"') } catch (e) { return [] }
  const out = []
  for (const part of decoded.split("^")) {
    const [market, code, name, pinyin, type] = part.split("~")
    if (!market || !code || !name) continue
    if (market === "jj") {
      if (/^\d{6}$/.test(code)) out.push({ code, name, pinyin: pinyin || "", kind: "fund" })
      continue
    }
    let quoteCode
    if (["sh", "sz", "bj", "hk"].includes(market)) quoteCode = market + code
    else if (market === "us") quoteCode = "us" + code.split(".")[0].toUpperCase()
    else continue
    out.push({ code: quoteCode, name, pinyin: pinyin || "", kind: type === "ZS" ? "index" : "stock" })
  }
  return out
}

// MARK: - 面板里的列表

/** 行首图标块：交易所 / 市场一个字 + 底色。 */
function iconOf(entry) {
  if (entry.kind === "fund") return { text: t("基", "基", "F"), tint: "orange" }
  if (entry.kind === "board") return { text: t("板", "板", "S"), tint: "pink" }
  if (entry.kind === "future") return { text: t("期", "期", "FU"), tint: "teal" }
  if (entry.kind === "index") return { text: t("指", "指", "I"), tint: "indigo" }
  const c = entry.code
  if (c.startsWith("sh")) return { text: t("沪", "滬", "SH"), tint: "red" }
  if (c.startsWith("sz")) return { text: t("深", "深", "SZ"), tint: "blue" }
  if (c.startsWith("bj")) return { text: t("京", "京", "BJ"), tint: "cyan" }
  if (c.startsWith("hk")) return { text: t("港", "港", "HK"), tint: "purple" }
  if (c.startsWith("us")) return { text: t("美", "美", "US"), tint: "teal" }   // 灰色留给「没数据」，用户 2026-11-06 要换
  return { text: "·", tint: "gray" }
}

/** 给人看的代码：去掉市场前缀（sh600519 → 600519，usAAPL → AAPL）。 */
function displayCode(entry) {
  if (entry.kind === "fund") return entry.code
  if (entry.kind === "board") return entry.type === "industry" ? t("行业板块", "行業板塊", "Industry") : t("概念板块", "概念板塊", "Concept")
  if (entry.kind === "future") return entry.code.replace(/^hf_/, "")
  return entry.code.replace(/^(sh|sz|bj|hk|us)/, "")
}

/** 行的 id：类别 + 代码（动作回来时靠它认是哪一只）。 */
function rowID(entry) {
  return entry.kind + ":" + entry.code
}

/** 分时线缓存：A 股、指数、港股、美股（各走一个接口），基金没有分时。60 秒内不重取 —— 面板每 5 秒
 *  刷新报价，走势线跟着每 5 秒每只取一次太浪费。 */
const sparkCache = {}
const SPARK_TTL = 60 * 1000
/** 基金净值一天只变一次 */
const FUND_SPARK_TTL = 6 * 3600 * 1000

/** 分时数据：{ data: { sh000688: { data: { data: ["0930 1221.67 197324 …", …] } } } }，取每分钟的价格。 */
function parseMinutes(text, code) {
  let json
  try { json = JSON.parse(text) } catch (e) { return [] }
  const lines = json && json.data && json.data[code] && json.data[code].data && json.data[code].data.data
  if (!Array.isArray(lines)) return []
  return lines.map((line) => parseFloat(String(line).split(" ")[1])).filter((v) => isFinite(v))
}

/** 新浪的基金净值：{ result: { data: { data: [{ fbrq: "2026-11-06 00:00:00", jjjz: "2.317" }, …] } } }，新的在前 →
 *  按日期正序的净值。 */
function parseSinaNav(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return [] }
  const rows = d && d.result && d.result.data && Array.isArray(d.result.data.data) ? d.result.data.data : []
  return rows.filter((r) => r && typeof r.fbrq === "string")
    .sort((a, b) => (a.fbrq < b.fbrq ? -1 : 1))
    .map((r) => parseFloat(r.jjjz)).filter((v) => isFinite(v))
}

/** 分时接口：A 股、指数、板块 minute，港股 hkMinute，美股 UsMinute；场外基金用新浪的净值（近一个月）；期货没有。 */
function minuteURL(entry) {
  if (entry.kind === "future") return null
  if (entry.kind === "fund") {
    return "https://stock.finance.sina.com.cn/fundInfo/api/openapi.php/CaihuiFundInfoService.getNav?symbol=" + entry.code + "&page=1"
  }
  const base = "https://web.ifzq.gtimg.cn/appstock/app/"
  if (/^(sh|sz|bj|pt)/.test(entry.code)) return base + "minute/query?code=" + entry.code
  if (entry.code.startsWith("hk")) return base + "hkMinute/query?code=" + entry.code
  if (entry.code.startsWith("us")) return base + "UsMinute/query?code=" + entry.code
  return null
}

async function sparkFor(entry, now = Date.now()) {
  const url = minuteURL(entry)
  if (!url) return []
  const cached = sparkCache[entry.code]
  // 基金净值 6 小时取一次；别的休市时分时线不会再变：取到过就一直用（直到开市）
  const fund = entry.kind === "fund"
  if (cached && (now - cached.at < (fund ? FUND_SPARK_TTL : SPARK_TTL) || (!fund && cached.points.length && !marketOpen(entry, now)))) {
    return cached.points
  }
  try {
    const res = await tabflick.fetch(url)
    const points = res.status !== 200 ? [] : fund ? parseSinaNav(res.text) : parseMinutes(res.text, entry.code)
    sparkCache[entry.code] = { at: now, points }
    return points
  } catch (e) {
    return cached ? cached.points : []
  }
}

/** 一行：现价、涨跌、走势线；副标题写代码，基金再写净值日期。 */
function listRow(entry, q, spark, inWatchlist) {
  if (entry.kind === "future") return retiredRow(entry)
  const parts = [displayCode(entry)]
  if (q && q.fund && q.date) parts.push(t("净值 ", "淨值 ", "NAV ") + monthDay(q.date))
  // 基金的线是近一个月的每日净值，不是当天分时：写明，免得和股票的线混着看
  if (entry.kind === "fund" && spark.length >= 2) parts.push(t("近一月走势", "近一月走勢", "1-month trend"))
  const open = { id: "open", title: t("打开行情页", "打開行情頁", "Open Quote Page"), symbol: "safari.fill" }
  const actions = inWatchlist
    ? [open,
       { id: "copy", title: t("拷贝代码", "拷貝代碼", "Copy Code"), symbol: "doc.on.doc.fill" },
       { id: "remove", title: t("移出自选", "移出自選", "Remove from Watchlist"), symbol: "star.slash.fill", destructive: true, stay: true }]
    : [{ id: "add", title: t("加入自选", "加入自選", "Add to Watchlist"), symbol: "star.fill", stay: true, clear: true }, open]
  return {
    id: rowID(entry),
    title: q ? q.name : entry.name,
    subtitle: parts.join(" · "),
    value: q ? formatPrice(q.price, entry) : "—",
    detail: q && q.pct != null ? formatPct(q.pct) : null,
    tone: tone(q && q.pct),
    spark,
    icon: iconOf(entry),
    actions,
  }
}

/** 以前加进自选的期货：数据源已停用，只给「移出」。 */
function retiredRow(entry) {
  return {
    id: rowID(entry),
    title: entry.name,
    subtitle: t("期货的数据源已停用，可以移出", "期貨的資料來源已停用，可以移出", "Futures data is no longer available. You can remove it."),
    icon: iconOf(entry),
    actions: [{ id: "remove", title: t("移出自选", "移出自選", "Remove from Watchlist"), symbol: "star.slash.fill", destructive: true, stay: true }],
  }
}

/** 最近一次搜索的结果（加入自选时要它的名字、类别、拼音）。 */
let lastResults = {}

/** 输入认不认自选里的这一项：名字包含它，代码、拼音首字母以它开头（都不分大小写）。在本地比，不用联网。 */
function matches(entry, text) {
  const q = text.toLowerCase()
  const pinyins = [].concat(entry.pinyin || [])
  return String(entry.name || "").toLowerCase().includes(q)
    || displayCode(entry).toLowerCase().startsWith(q)
    || pinyins.some((p) => String(p).toLowerCase().startsWith(q))
}

/** 搜索结果最多这么多行（自选里的、腾讯搜到的合起来）。 */
const MAX_RESULTS = 10

async function list(query) {
  const text = String(query || "").trim()
  const saved = watchlist()
  const savedIDs = new Set(saved.map(rowID))
  if (!text) {
    // 一进列表就在后台把板块名单取好（一天一次，十来个请求、四五秒）：等打字搜「CPO」时已经在本地了
    loadBoards().catch(() => {})
    const [quotes, sparks] = await Promise.all([cachedQuotes(saved), Promise.all(saved.map((x) => sparkFor(x)))])
    return saved.map((x, i) => listRow(x, quotes[quoteKey(x)], sparks[i], true))
  }
  // 自选里的排最前（搜自己加过的，用户 2026-11-06 要的），再是板块（本地名单），最后是腾讯搜到的股票。
  // 板块名单第一次要取（一两秒），最多等 4 秒，等不到这次先不列板块
  const local = saved.filter((x) => matches(x, text))
  const boardList = await Promise.race([loadBoards(), sleep(4000).then(() => [])])
  const boards = matchBoards(boardList, text).slice(0, 5).map((b) => ({ code: b.code, name: b.name, kind: "board", type: b.type }))
  let remote = []
  try {
    const res = await tabflick.fetch("https://smartbox.gtimg.cn/s3/?v=2&t=all&q=" + encodeURIComponent(text))
    if (res.status !== 200) throw new Error("HTTP " + res.status)
    remote = parseSmartbox(res.text).slice(0, 8)
  } catch (e) {
    if (!local.length && !boards.length) throw e   // 什么都没有才算失败；本地有就先列本地的
  }
  const seen = new Set()
  const hits = []
  for (const h of local.concat(boards, remote)) {
    const id = rowID(h)
    if (seen.has(id) || hits.length >= MAX_RESULTS) continue
    seen.add(id)
    hits.push(h)
  }
  lastResults = Object.fromEntries(hits.map((h) => [rowID(h), h]))
  // 搜索结果也带上现价（批量请求）；取不到就只列名字
  let quotes = {}
  try { quotes = await fetchQuotes(hits) } catch (e) { quotes = {} }
  return hits.map((h) => listRow(h, quotes[quoteKey(h)], [], savedIDs.has(rowID(h))))
}

/** 列表里一行的动作。id 是 rowID（类别:代码）。 */
function perform(action, id) {
  const m = /^(index|stock|fund|future|board):([a-zA-Z0-9._]{2,20})$/.exec(String(id))
  if (!m) return
  const [, kind, code] = m
  const saved = watchlist()
  if (action === "open") {
    tabflick.openURL(quoteURL(kind, code))
  } else if (action === "copy") {
    tabflick.copy(displayCode({ kind, code }))
    tabflick.toast(t("已拷贝代码", "已拷貝代碼", "Code copied"), displayCode({ kind, code }))
  } else if (action === "add") {
    if (saved.some((x) => rowID(x) === id)) return
    const hit = lastResults[id]
    // 拼音一起存下来：之后在自选里用拼音首字母也搜得到
    const entry = { code, kind, name: hit ? hit.name : code }
    if (hit && hit.type) entry.type = hit.type
    if (hit && hit.pinyin) entry.pinyin = String(hit.pinyin)
    tabflick.storage.set("watchlist", saved.concat([entry]))
    tabflick.toast(t("已加入自选", "已加入自選", "Added to watchlist"), entry.name)
  } else if (action === "remove") {
    tabflick.storage.set("watchlist", saved.filter((x) => rowID(x) !== id))
  }
}

// MARK: - 动作

/** 行情页：股票、指数去腾讯自选股的网页，基金去天天基金。 */
function quoteURL(kind, code) {
  if (kind === "fund") return `https://fund.eastmoney.com/${code}.html`
  if (kind === "future") return `https://finance.sina.com.cn/futures/quotes/${code.replace(/^hf_/, "")}.shtml`
  return `https://gu.qq.com/${code}`
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    async menu() {
      const list = watchlist()
      return menuRows(list, await cachedQuotes(list), shanghaiNow())
    },
    action(id) {
      const m = /^open:(index|stock|fund|future|board):([a-zA-Z0-9._]+)$/.exec(String(id))
      if (m) tabflick.openURL(quoteURL(m[1], m[2]))
    },
    list,
    perform,
  })
}
