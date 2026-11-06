// TabFlick 汇率插件（官方）。汇率来自 open.er-api.com（免费、不用注册，每天更新一次），以美元为基准一次取全部币种，
// 在插件存储里缓存 6 小时；取不到就用缓存。换算都在本地算。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** 币种：代码、中文名、繁中名、英文名、别名（都能搜）。 */
const CURRENCIES = [
  ["CNY", "人民币", "人民幣", "Chinese Yuan", ["rmb", "元", "cny", "rmb"]],
  ["USD", "美元", "美元", "US Dollar", ["美金", "刀", "dollar", "$"]],
  ["EUR", "欧元", "歐元", "Euro", ["euro", "€"]],
  ["JPY", "日元", "日圓", "Japanese Yen", ["日币", "円", "yen"]],
  ["HKD", "港币", "港幣", "Hong Kong Dollar", ["港元", "港纸"]],
  ["GBP", "英镑", "英鎊", "British Pound", ["pound", "£"]],
  ["KRW", "韩元", "韓圓", "South Korean Won", ["韩币", "won"]],
  ["TWD", "新台币", "新臺幣", "New Taiwan Dollar", ["台币"]],
  ["MOP", "澳门元", "澳門幣", "Macanese Pataca", ["澳门币"]],
  ["SGD", "新加坡元", "新加坡幣", "Singapore Dollar", ["新币"]],
  ["AUD", "澳元", "澳幣", "Australian Dollar", ["澳币"]],
  ["CAD", "加元", "加幣", "Canadian Dollar", ["加币"]],
  ["CHF", "瑞士法郎", "瑞士法郎", "Swiss Franc", ["瑞郎", "franc"]],
  ["NZD", "新西兰元", "紐西蘭幣", "New Zealand Dollar", ["纽币"]],
  ["THB", "泰铢", "泰銖", "Thai Baht", ["baht"]],
  ["MYR", "马来西亚林吉特", "馬來西亞令吉", "Malaysian Ringgit", ["林吉特", "马币"]],
  ["VND", "越南盾", "越南盾", "Vietnamese Dong", ["dong"]],
  ["PHP", "菲律宾比索", "菲律賓披索", "Philippine Peso", []],
  ["IDR", "印尼盾", "印尼盾", "Indonesian Rupiah", ["rupiah"]],
  ["INR", "印度卢比", "印度盧比", "Indian Rupee", ["卢比", "rupee"]],
  ["RUB", "俄罗斯卢布", "俄羅斯盧布", "Russian Ruble", ["卢布", "ruble"]],
  ["AED", "阿联酋迪拉姆", "阿聯酋迪拉姆", "UAE Dirham", ["迪拉姆"]],
  ["SAR", "沙特里亚尔", "沙烏地里亞爾", "Saudi Riyal", []],
  ["TRY", "土耳其里拉", "土耳其里拉", "Turkish Lira", ["里拉"]],
  ["BRL", "巴西雷亚尔", "巴西雷亞爾", "Brazilian Real", []],
  ["MXN", "墨西哥比索", "墨西哥披索", "Mexican Peso", []],
  ["ZAR", "南非兰特", "南非蘭特", "South African Rand", ["兰特"]],
  ["SEK", "瑞典克朗", "瑞典克朗", "Swedish Krona", []],
  ["NOK", "挪威克朗", "挪威克朗", "Norwegian Krone", []],
  ["DKK", "丹麦克朗", "丹麥克朗", "Danish Krone", []],
]
const BY_CODE = Object.fromEntries(CURRENCIES.map((c) => [c[0], c]))

function currencyName(code) {
  const c = BY_CODE[code]
  if (!c) return code
  return t(c[1], c[2], c[3])
}

/** 一个词认成哪个币种：代码（不分大小写）、中英文名、别名。认不出 null。 */
function findCurrency(word) {
  const w = String(word).trim().toLowerCase()
  if (!w) return null
  for (const [code, zh, hant, en, aliases] of CURRENCIES) {
    if (w === code.toLowerCase() || w === zh || w === hant || w === en.toLowerCase() || aliases.includes(w)) return code
  }
  return null
}

/** 名字里包含这段字的币种（搜索用，比如「克朗」「dollar」）。 */
function searchCurrencies(text) {
  const w = String(text).trim().toLowerCase()
  if (!w) return []
  return CURRENCIES.filter(([code, zh, hant, en, aliases]) =>
    code.toLowerCase().startsWith(w) || zh.includes(w) || hant.includes(w) || en.toLowerCase().includes(w)
      || aliases.some((a) => a.includes(w))).map((c) => c[0])
}

/**
 * 「100 usd」「100美元」「usd 100」「美元兑日元」「100 usd to jpy」「1.5万 日元」→ { amount, from, to }。
 * 金额支持千分位逗号、小数、k（千）、万；没写金额是 1；没写目标币种 to 是 null。认不出 null。
 */
function parseQuery(text) {
  let s = String(text).trim().toLowerCase().replace(/,/g, "")
  if (!s) return null
  let amount = 1
  const num = /(\d+(?:\.\d+)?)\s*(k|万)?/.exec(s)
  if (num) {
    amount = parseFloat(num[1]) * (num[2] === "k" ? 1000 : num[2] === "万" ? 10000 : 1)
    s = (s.slice(0, num.index) + " " + s.slice(num.index + num[0].length)).trim()
  }
  if (!isFinite(amount) || amount <= 0) return null
  const parts = s.split(/\s*(?:\bto\b|\bin\b|兑换成|兑换|兑|换成|换|转|->|=|→)\s*|\s+/).filter(Boolean)
  if (parts.length === 1 && !findCurrency(parts[0])) {
    // 「美元日元」这种连写：从左往右找一个能认出来的切分
    for (let i = 1; i < parts[0].length; i++) {
      const a = findCurrency(parts[0].slice(0, i)), b = findCurrency(parts[0].slice(i))
      if (a && b) return { amount, from: a, to: b }
    }
  }
  if (parts.length === 0 || parts.length > 2) return null
  const from = findCurrency(parts[0])
  const to = parts[1] ? findCurrency(parts[1]) : null
  if (!from || (parts[1] && !to)) return null
  return { amount, from, to }
}

// MARK: - 汇率

const CACHE_MS = 6 * 3600 * 1000

/** open.er-api.com 的返回：{ result: "success", time_last_update_unix, rates: { CNY: 6.68, … } }，以美元为基准。 */
function parseRates(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return null }
  if (!d || d.result !== "success" || !d.rates || typeof d.rates !== "object") return null
  const rates = {}
  for (const [k, v] of Object.entries(d.rates)) if (/^[A-Z]{3}$/.test(k) && typeof v === "number" && v > 0) rates[k] = v
  if (!rates.USD) return null
  return { rates, updated: (d.time_last_update_unix || 0) * 1000 }
}

/** 先看缓存（6 小时内），过期了去取；取不到就用过期的缓存，一份都没有才失败。 */
async function getRates(now = Date.now()) {
  const cached = tabflick.storage.get("rates")
  if (cached && cached.rates && now - (cached.fetchedAt || 0) < CACHE_MS) return cached
  try {
    const res = await tabflick.fetch("https://open.er-api.com/v6/latest/USD")
    const parsed = res.status === 200 ? parseRates(res.text) : null
    if (!parsed) throw new Error("bad response")
    const fresh = { ...parsed, fetchedAt: now }
    tabflick.storage.set("rates", fresh)
    return fresh
  } catch (e) {
    if (cached && cached.rates) return cached
    throw e
  }
}

function convert(rates, amount, from, to) {
  if (!rates[from] || !rates[to]) return null
  return (amount / rates[from]) * rates[to]
}

/** 显示：大数两位小数带千分位，小数留 4 位有效（日元换人民币 0.04683）。拷贝用 plain（不带千分位）。 */
function plain(value) {
  if (value >= 1) return String(Math.round(value * 100) / 100)
  return String(Number(value.toPrecision(4)))
}
function pretty(value) {
  if (value >= 1) return value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  return String(Number(value.toPrecision(4)))
}

function home() {
  const h = tabflick.storage.get("home")
  return typeof h === "string" && /^[A-Z]{3}$/.test(h) ? h : "CNY"
}

const DEFAULT_FAVORITES = ["USD", "EUR", "JPY", "HKD", "GBP"]
function favorites() {
  const f = tabflick.storage.get("favorites")
  return Array.isArray(f) ? f.filter((c) => typeof c === "string" && /^[A-Z]{3}$/.test(c)) : DEFAULT_FAVORITES
}

function dateOf(ms) {
  const d = new Date(ms)
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
}

// MARK: - 列表、菜单

/** 列表一行：from → to。id 带上金额，动作回来时靠它重算。 */
function row(rates, amount, from, to, updated) {
  const value = convert(rates, amount, from, to)
  if (value == null) return null
  const isFav = favorites().includes(from === home() ? to : from)
  const foreign = from === home() ? to : from
  return {
    id: `${from}>${to}@${amount}`,
    title: `${currencyName(to)} ${to}`,
    // 金额是整数就不补小数（100 USD，不写 100.00 USD）
    subtitle: `${Number.isInteger(amount) ? amount.toLocaleString("en-US") : pretty(amount)} ${from} = ${pretty(value)} ${to} · ${t("更新于 ", "更新於 ", "Updated ")}${dateOf(updated)}`,
    value: pretty(value),
    icon: { text: to.slice(0, 1), tint: "green" },
    actions: [
      { id: "copy", title: t("拷贝结果", "拷貝結果", "Copy Result"), symbol: "doc.on.doc.fill" },
      { id: "copyAll", title: t("拷贝算式", "拷貝算式", "Copy Conversion"), symbol: "text.quote" },
      foreign === home() ? null
        : isFav ? { id: "unfav", title: t("移出常用", "移出常用", "Remove from Favorites"), symbol: "star.slash.fill", destructive: true, stay: true }
        : { id: "fav", title: t("设为常用", "設為常用", "Add to Favorites"), symbol: "star.fill", stay: true },
    ].filter(Boolean),
  }
}

async function list(query) {
  const r = await getRates()
  const h = home()
  const text = String(query || "").trim()
  if (!text) return favorites().map((c) => row(r.rates, 1, c, h, r.updated)).filter(Boolean)
  const q = parseQuery(text)
  if (q && q.to) {
    // 指定了目标：正着一行，反过来一行
    return [row(r.rates, q.amount, q.from, q.to, r.updated), row(r.rates, 1, q.to, q.from, r.updated)].filter(Boolean)
  }
  if (q) {
    // 只写了一个币种：换成本币 + 常用的几种
    const targets = [h].concat(favorites()).filter((c, i, all) => c !== q.from && all.indexOf(c) === i)
    return targets.map((c) => row(r.rates, q.amount, q.from, c, r.updated)).filter(Boolean)
  }
  // 认不出金额 + 币种：按名字搜币种（「克朗」「dollar」）
  return searchCurrencies(text).slice(0, 10).map((c) => row(r.rates, 1, c, c === h ? "USD" : h, r.updated)).filter(Boolean)
}

/** 动作的 id 是「USD>CNY@100」。 */
function parseRowID(id) {
  const m = /^([A-Z]{3})>([A-Z]{3})@(\d+(?:\.\d+)?)$/.exec(String(id))
  return m ? { from: m[1], to: m[2], amount: parseFloat(m[3]) } : null
}

async function perform(action, id) {
  const p = parseRowID(id)
  if (!p) return
  const h = home()
  const foreign = p.from === h ? p.to : p.from
  if (action === "fav" || action === "unfav") {
    const f = favorites().filter((c) => c !== foreign)
    tabflick.storage.set("favorites", action === "fav" ? f.concat([foreign]) : f)
    return
  }
  const r = await getRates()
  const value = convert(r.rates, p.amount, p.from, p.to)
  if (value == null) return
  if (action === "copy") {
    tabflick.copy(plain(value))
    tabflick.toast(t("已拷贝结果", "已拷貝結果", "Result copied"), plain(value))
  } else if (action === "copyAll") {
    const line = `${p.amount} ${p.from} = ${plain(value)} ${p.to}`
    tabflick.copy(line)
    tabflick.toast(t("已拷贝算式", "已拷貝算式", "Conversion copied"), line)
  }
}

async function menu() {
  const r = await getRates()
  const h = home()
  const rows = [{ type: "header", text: t(`1 外币 = ${currencyName(h)}`, `1 外幣 = ${currencyName(h)}`, `1 unit in ${h}`) }]
  for (const c of favorites()) {
    const v = convert(r.rates, 1, c, h)
    if (v != null) rows.push({ title: currencyName(c), badge: c, value: pretty(v), action: "copy:" + c })
  }
  rows.push({ type: "separator" }, { type: "note", text: t("更新于 ", "更新於 ", "Updated ") + dateOf(r.updated) })
  return rows
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    menu,
    list,
    perform,
    action(id) {
      const m = /^copy:([A-Z]{3})$/.exec(String(id))
      if (m) return perform("copy", `${m[1]}>${home()}@1`)
    },
  })
}
