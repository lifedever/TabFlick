// TabFlick 天气插件（官方）。数据来自和风天气（QWeather）：每个人用自己的 API Host + API Key（设置 → 插件 → 天气）。
//   城市搜索 /geo/v2/city/lookup（中文到区县，带不带「市」「区」都行）
//   实况     /weather/v1/current/{lat}/{lon}
//   逐日     /weather/v1/daily/{lat}/{lon}（取今天的最高最低）
// 免费额度每月 5 万次（城市搜索也算）：实况 15 分钟、最高最低 3 小时内不重取，面板和菜单关着不取。
// 和风要求显示数据的地方注明「天气服务由和风天气驱动」并链到 qweather.com：列表和菜单最后一行就是它。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** 和风的 lang 参数：天气文字、地名按界面语言给。 */
const QW_LANG = { zh: "zh", "zh-Hant": "zh-hant", en: "en", ja: "ja", ko: "ko", es: "es", fr: "fr", de: "de" }[LANG] || "en"
const CONSOLE_URL = "https://console.qweather.com/"
const ATTRIBUTION_URL = "https://www.qweather.com/"
const CURRENT_MS = 15 * 60 * 1000
const DAILY_MS = 3 * 60 * 60 * 1000

// MARK: - 账号

/** 用户填的 API Host：去掉协议头、路径、大小写。不是 xxx.qweatherapi.com 返回 null，没填返回 ""。 */
function normalizeHost(raw) {
  const s = String(raw || "").trim().toLowerCase().replace(/^https?:\/\//, "").split(/[\/?#\s]/)[0]
  if (!s) return ""
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.qweatherapi\.com$/.test(s) ? s : null
}

function credentials() {
  const get = (k) => (tabflick.settings && tabflick.settings.get(k)) || ""
  return { host: normalizeHost(get("host")), key: String(get("key")).trim() }
}

/** 取不到数据的几种原因，各说各的（「取不到」不说为什么，用户没法自己修）。 */
function problem(kind, detail) {
  const e = new Error(kind + (detail ? ": " + detail : ""))
  e.kind = kind
  return e
}

function problemText(kind) {
  switch (kind) {
    case "setup": return [t("填上和风天气的 API Host 和 API Key", "填上和風天氣的 API Host 和 API Key", "Enter your QWeather API Host and API Key"),
                          t("免费注册，每月 5 万次。回车去设置里填。", "免費註冊，每月 5 萬次。按 ↩ 去設定裡填。", "Free to sign up, 50,000 calls a month. ↩ opens Settings.")]
    case "host": return [t("API Host 不对", "API Host 不對", "API Host looks wrong"),
                         t("和风控制台「设置」里那个，形如 abc123.re.qweatherapi.com", "和風控制台「設定」裡那個，形如 abc123.re.qweatherapi.com", "Find it under Settings in the QWeather console, like abc123.re.qweatherapi.com")]
    case "auth": return [t("API Key 不对", "API Key 不對", "API Key was rejected"),
                         t("或者和 API Host 不是同一个账号的", "或者和 API Host 不是同一個帳號的", "Or it belongs to a different account than the API Host")]
    case "quota": return [t("和风天气的请求额度用完了", "和風天氣的請求額度用完了", "QWeather quota used up"),
                          t("免费额度每月 5 万次，控制台里能看用量", "免費額度每月 5 萬次，控制台裡能看用量", "The free plan has 50,000 calls a month; check usage in the console")]
    default: return [t("连不上和风天气", "連不上和風天氣", "Couldn't reach QWeather"),
                     t("检查网络和 API Host", "檢查網路和 API Host", "Check your connection and API Host")]
  }
}

async function qweather(path) {
  const c = credentials()
  if (c.host === null) throw problem("host")
  if (!c.host || !c.key) throw problem("setup")
  let res
  try {
    res = await tabflick.fetch("https://" + c.host + path, { headers: { "X-QW-Api-Key": c.key } })
  } catch (e) {
    throw problem("network", String(e && e.message || e))
  }
  if (res.status === 401 || res.status === 403) throw problem("auth", "HTTP " + res.status)
  if (res.status === 429) throw problem("quota")
  return res
}

// MARK: - 数据

function cities() {
  const saved = tabflick.storage.get("cities")
  return Array.isArray(saved) ? saved.filter(isCity) : []
}

function isCity(c) {
  return c && typeof c.name === "string" && c.name && isFinite(c.lat) && isFinite(c.lon) && Math.abs(c.lat) <= 90 && Math.abs(c.lon) <= 180
}

/** 城市的 id：坐标（同名的区县很多；老版本存的 Open-Meteo 城市也只有坐标）。 */
function cityID(c) {
  return `${Number(c.lat).toFixed(3)},${Number(c.lon).toFixed(3)}`
}

/** 城市搜索：{ code: "200", location: [{ name, id, lat, lon, adm2, adm1, country, tz, fxLink }] }，坐标是字符串。 */
function parseLookup(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return [] }
  return ((d && Array.isArray(d.location) && d.location) || [])
    .map((r) => r && ({
      name: String(r.name || ""), adm2: String(r.adm2 || ""), adm1: String(r.adm1 || ""), country: String(r.country || ""),
      lat: parseFloat(r.lat), lon: parseFloat(r.lon), tz: typeof r.tz === "string" ? r.tz : "",
      link: typeof r.fxLink === "string" && /^https:\/\//.test(r.fxLink) ? r.fxLink : "",
    }))
    .filter(isCity)
}

const num = (x) => (x && isFinite(x.value) ? Number(x.value) : null)

/** 实况：{ condition: { text, code }, temperature: { value }, feelsLike, humidity: 0–1 }。 */
function parseCurrent(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return null }
  if (!d || !d.condition || num(d.temperature) == null) return null
  return { temp: num(d.temperature), feels: num(d.feelsLike), text: String(d.condition.text || ""), code: String(d.condition.code || "") }
}

/** 逐日：{ days: [{ temperatureMax: { value }, temperatureMin: { value } }] }，取第一天（今天）。 */
function parseDaily(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return null }
  const today = d && Array.isArray(d.days) && d.days[0]
  if (!today || num(today.temperatureMax) == null) return null
  return { high: num(today.temperatureMax), low: num(today.temperatureMin) }
}

/** 天气代码 → SF Symbol 和图标底色。夜里（当地 18 点到 6 点）晴、多云换成月亮。 */
function look(code, night) {
  const c = parseInt(code, 10)
  if (c === 100) return night ? ["moon.stars.fill", "indigo"] : ["sun.max.fill", "orange"]
  if (c >= 101 && c <= 103) return night ? ["cloud.moon.fill", "indigo"] : ["cloud.sun.fill", "orange"]
  if (c === 104) return ["cloud.fill", "gray"]
  if (c === 300 || c === 350) return ["cloud.sun.rain.fill", "blue"]
  if (c >= 302 && c <= 304) return ["cloud.bolt.rain.fill", "purple"]
  if (c === 313) return ["cloud.sleet.fill", "cyan"]
  if ([305, 309, 314, 399].includes(c)) return ["cloud.drizzle.fill", "blue"]
  if (c === 306) return ["cloud.rain.fill", "blue"]
  if (c >= 300 && c < 400) return ["cloud.heavyrain.fill", "blue"]
  if (c >= 404 && c <= 406) return ["cloud.sleet.fill", "cyan"]
  if (c >= 400 && c < 500) return ["cloud.snow.fill", "cyan"]
  if ([502, 511, 512, 513].includes(c)) return ["sun.haze.fill", "brown"]
  if ([503, 504, 507, 508].includes(c)) return ["sun.dust.fill", "brown"]
  if (c >= 500 && c < 600) return ["cloud.fog.fill", "gray"]
  if (c === 900) return ["thermometer.sun.fill", "red"]
  if (c === 901) return ["thermometer.snowflake", "cyan"]
  return ["cloud.fill", "gray"]
}

function isNight(tz, nowMs) {
  if (!tz) return false
  try {
    const hour = parseInt(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", hour: "2-digit" }).format(new Date(nowMs)), 10)
    return hour < 6 || hour >= 18
  } catch (e) {
    return false
  }
}

/** 一个城市的天气：实况 15 分钟、最高最低 3 小时内用存着的（存在插件存储里，插件闲置卸掉再加载也不重取）。 */
async function weatherFor(c, nowMs) {
  const id = cityID(c)
  const store = tabflick.storage.get("cache") || {}
  const entry = store[id] || {}
  const where = Number(c.lat).toFixed(2) + "/" + Number(c.lon).toFixed(2)
  const fresh = (part, ms) => part && nowMs - part.at < ms && nowMs >= part.at
  const jobs = []
  if (!fresh(entry.current, CURRENT_MS)) {
    jobs.push(qweather("/weather/v1/current/" + where + "?lang=" + QW_LANG).then((res) => {
      const data = res.status === 200 ? parseCurrent(res.text) : null
      if (!data) throw problem("network", "current HTTP " + res.status)
      entry.current = { at: nowMs, data }
    }))
  }
  if (!fresh(entry.daily, DAILY_MS)) {
    jobs.push(qweather("/weather/v1/daily/" + where + "?days=1&localTime=true&lang=" + QW_LANG).then((res) => {
      const data = res.status === 200 ? parseDaily(res.text) : null
      if (data) entry.daily = { at: nowMs, data }
    }))
  }
  if (jobs.length) {
    await Promise.all(jobs)
    const latest = tabflick.storage.get("cache") || {}
    // 只留收藏着的城市，移出的不占地方
    const keep = new Set(cities().map(cityID))
    const next = {}
    for (const k of Object.keys(latest)) if (keep.has(k)) next[k] = latest[k]
    next[id] = entry
    tabflick.storage.set("cache", next)
  }
  return { ...entry.current.data, ...(entry.daily ? entry.daily.data : {}), at: entry.current.at }
}

/** 所有收藏城市的天气。一个城市取不到不连累别的；全都因为同一个账号问题失败时把原因抛出去。 */
async function forecasts(list, nowMs = Date.now()) {
  const results = await Promise.all(list.map((c) => weatherFor(c, nowMs).then((w) => ({ w }), (e) => ({ e }))))
  const failed = results.filter((r) => r.e)
  if (list.length && failed.length === list.length) {
    const kinds = failed.map((r) => r.e.kind)
    if (kinds.every((k) => k === kinds[0])) throw failed[0].e
  }
  if (failed.length) console.log("weather: " + failed.map((r) => String(r.e && r.e.message)).join("; "))
  return results.map((r) => r.w || null)
}

// MARK: - 显示

function degrees(v) {
  return v != null && isFinite(v) ? Math.round(v) + "°" : "—"
}

/** 「西湖 · 杭州 · 浙江省」：上级地名去掉和城市名、彼此重复的（北京 / 北京市），中国不写国家。 */
function place(c) {
  const parts = []
  const same = (a, b) => a.startsWith(b) || b.startsWith(a)
  for (const p of [c.adm2, c.adm1 || c.admin, c.country]) {
    if (!p || same(p, c.name) || parts.some((q) => same(p, q))) continue
    if (["中国", "中國", "China"].includes(p)) continue
    parts.push(p)
  }
  return parts.join(" · ")
}

/** 和风给的预报页；老版本存的城市（Open-Meteo 时代）没有，退回搜索。 */
function forecastURL(c) {
  return c.link || "https://www.bing.com/search?q=" + encodeURIComponent(c.name + " " + t("天气", "天氣", "weather"))
}

function attributionRow() {
  return {
    id: "attribution",
    title: t("天气服务由和风天气驱动", "天氣服務由和風天氣驅動", "Weather by QWeather"),
    subtitle: "qweather.com",
    icon: { text: t("和", "和", "Q"), tint: "cyan" },
    actions: [{ id: "attribution", title: t("打开和风天气", "打開和風天氣", "Open QWeather"), symbol: "safari.fill" }],
  }
}

function problemRow(kind) {
  const [title, subtitle] = problemText(kind)
  const settings = { id: "settings", title: t("打开天气设置", "打開天氣設定", "Open Weather Settings"), symbol: "gearshape.fill" }
  const console_ = { id: "console", title: t("打开和风天气控制台", "打開和風天氣控制台", "Open QWeather Console"), symbol: "safari.fill" }
  return {
    id: "problem",
    title,
    subtitle,
    icon: { text: "!", tint: kind === "network" ? "gray" : "orange" },
    actions: kind === "network" ? [settings] : [settings, console_],
  }
}

let lastResults = {}

function cityRow(c, w, saved, nowMs) {
  const tint = w ? look(w.code, isNight(c.tz, nowMs))[1] : "gray"
  const parts = [place(c)]
  if (w) {
    parts.push(w.text)
    if (w.high != null) parts.push(t(`最高 ${degrees(w.high)} 最低 ${degrees(w.low)}`, `最高 ${degrees(w.high)} 最低 ${degrees(w.low)}`, `H ${degrees(w.high)} L ${degrees(w.low)}`))
  }
  const open = { id: "open", title: t("看天气预报", "看天氣預報", "Open Forecast"), symbol: "safari.fill" }
  return {
    id: cityID(c),
    title: c.name,
    subtitle: parts.filter(Boolean).join(" · "),
    value: w ? degrees(w.temp) : null,
    icon: { text: w ? w.text.slice(0, 1) || c.name.slice(0, 1) : c.name.slice(0, 1), tint },
    actions: saved
      ? [open, { id: "remove", title: t("移出", "移出", "Remove"), symbol: "minus.circle.fill", destructive: true, stay: true }]
      : [{ id: "add", title: t("加入", "加入", "Add"), symbol: "plus.circle.fill", stay: true, clear: true }, open],
  }
}

/** 搜城市。没结果、而且带着「市 / 区 / 县 / 省」这类后缀时去掉后缀再搜一次。 */
async function lookup(text) {
  const ask = async (q) => {
    const res = await qweather("/geo/v2/city/lookup?number=10&lang=" + QW_LANG + "&location=" + encodeURIComponent(q))
    if (res.status === 404 || res.status === 204) return []
    if (res.status !== 200) throw problem("network", "lookup HTTP " + res.status)
    return parseLookup(res.text)
  }
  const found = await ask(text)
  const stripped = text.replace(/(特别行政区|自治州|自治县|地区|新区|市|区|县|省|旗|盟)$/, "")
  if (found.length || stripped === text || stripped.length < 2) return found
  return ask(stripped)
}

async function list(query, nowMs = Date.now()) {
  const saved = cities()
  const text = String(query || "").trim()
  const c = credentials()
  if (c.host === null) return [problemRow("host")].concat(saved.map((x) => cityRow(x, null, true, nowMs)))
  if (!c.host || !c.key) return [problemRow("setup")].concat(saved.map((x) => cityRow(x, null, true, nowMs)))
  if (!text) {
    if (!saved.length) return []
    try {
      const w = await forecasts(saved, nowMs)
      return saved.map((x, i) => cityRow(x, w[i], true, nowMs)).concat([attributionRow()])
    } catch (e) {
      return [problemRow(e.kind || "network")].concat(saved.map((x) => cityRow(x, null, true, nowMs)))
    }
  }
  const local = saved.filter((x) => x.name.toLowerCase().includes(text.toLowerCase()))
  let found
  try {
    found = await lookup(text)
  } catch (e) {
    return [problemRow(e.kind || "network")].concat(local.map((x) => cityRow(x, null, true, nowMs)))
  }
  const savedIDs = new Set(saved.map(cityID))
  const fresh = found.filter((x) => !savedIDs.has(cityID(x)))
  lastResults = Object.fromEntries(fresh.map((x) => [cityID(x), x]))
  const rows = local.map((x) => cityRow(x, null, true, nowMs)).concat(fresh.map((x) => cityRow(x, null, false, nowMs)))
  return rows.length ? rows.concat([attributionRow()]) : rows
}

function perform(action, id) {
  if (action === "settings") return tabflick.openSettings && tabflick.openSettings()
  if (action === "console") return tabflick.openURL(CONSOLE_URL)
  if (action === "attribution") return tabflick.openURL(ATTRIBUTION_URL)
  const saved = cities()
  const city = saved.find((c) => cityID(c) === id) || lastResults[id]
  if (!city) return
  if (action === "open") tabflick.openURL(forecastURL(city))
  else if (action === "add" && !saved.some((c) => cityID(c) === id)) {
    tabflick.storage.set("cities", saved.concat([city]))
    tabflick.toast(t("已添加城市", "已新增城市", "City added"), city.name)
  }
  else if (action === "remove") tabflick.storage.set("cities", saved.filter((c) => cityID(c) !== id))
}

function timeOf(ms) {
  const d = new Date(ms)
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
}

async function menu(nowMs = Date.now()) {
  const saved = cities()
  const c = credentials()
  if (!c.host || !c.key) {
    const [title] = problemText(c.host === null ? "host" : "setup")
    return [{ type: "note", text: title }, { title: t("打开天气设置", "打開天氣設定", "Open Weather Settings"), symbol: "gearshape.fill", action: "settings" }]
  }
  if (!saved.length) return [{ type: "note", text: t("还没有城市", "還沒有城市", "No cities yet") }]
  let w
  try {
    w = await forecasts(saved, nowMs)
  } catch (e) {
    // 账号问题说清楚；网络问题让原生留着上次的快照
    if (e.kind === "network") throw e
    const [title, detail] = problemText(e.kind)
    return [{ type: "note", text: title }, { type: "note", text: detail },
            { title: t("打开天气设置", "打開天氣設定", "Open Weather Settings"), symbol: "gearshape.fill", action: "settings" }]
  }
  const rows = saved.map((city, i) => {
    const x = w[i]
    const [symbol] = x ? look(x.code, isNight(city.tz, nowMs)) : ["cloud.fill"]
    return { title: city.name, value: x ? degrees(x.temp) : "—", detail: x ? x.text : null, symbol, action: "open:" + cityID(city) }
  })
  const times = w.filter(Boolean).map((x) => x.at)
  rows.push({ type: "separator" })
  rows.push({ title: t("天气服务由和风天气驱动", "天氣服務由和風天氣驅動", "Weather by QWeather"),
              detail: times.length ? t("更新于 ", "更新於 ", "Updated ") + timeOf(Math.min(...times)) : null,
              symbol: "info.circle", action: "attribution" })
  return rows
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    menu: () => menu(),
    list: (q) => list(q),
    perform: (a, id) => perform(a, id),
    action(id) {
      const m = /^open:(.+)$/.exec(String(id))
      if (m) perform("open", m[1])
      else if (id === "settings" || id === "attribution") perform(id, "")
    },
  })
}
