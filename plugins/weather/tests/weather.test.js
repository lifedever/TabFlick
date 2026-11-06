// 天气插件：TZ=Asia/Shanghai node plugins/weather/tests/weather.test.js
// 样本是照和风天气文档（2026-11-06）的字段结构手写的：手上没有 Key 拿不到真实返回。用户填了 Key 之后换成真实样本。
process.env.TZ = "Asia/Shanghai"
const assert = require("assert")
const { load, test, done, plain, fixture } = require("../../_shared/harness")
const dir = __dirname + "/.."
const F = (name) => fixture(__dirname, name)
const HOST = "abc123.re.qweatherapi.com"
const settings = { host: HOST, key: "k-123" }
// 2026-11-06 10:30 北京（白天）
const NOW = Date.UTC(2026, 10, 6, 2, 30)

/** 按路径回样本；`status` 覆盖状态码，`fail` 抛网络错误。 */
function routes({ status, fail, lookupEmptyFor } = {}) {
  return (url) => {
    if (fail) throw new Error("The Internet connection appears to be offline.")
    if (status) return { status, text: '{"error":{"status":' + status + '}}' }
    if (url.includes("/geo/v2/city/lookup")) {
      const q = decodeURIComponent(url.split("location=")[1] || "")
      return { status: 200, text: q === lookupEmptyFor ? F("lookup-empty.json") : F("lookup-tianjin.json") }
    }
    if (url.includes("/weather/v1/current/")) return { status: 200, text: F("current.json") }
    if (url.includes("/weather/v1/daily/")) return { status: 200, text: F("daily.json") }
    return { status: 404, text: "" }
  }
}

const tianjin = { name: "天津", adm2: "天津", adm1: "天津市", country: "中国", lat: 39.12559, lon: 117.19019, tz: "Asia/Shanghai",
  link: "https://www.qweather.com/weather/tianjin-101030100.html" }

;(async () => {
  const { sandbox } = load(dir)

  await test("API Host：去协议头和路径、不分大小写；不是 qweatherapi.com 的不认", () => {
    assert.strictEqual(sandbox.normalizeHost(" https://ABC123.re.qweatherapi.com/v7?x=1 "), HOST)
    assert.strictEqual(sandbox.normalizeHost("abc.qweatherapi.com"), "abc.qweatherapi.com")
    assert.strictEqual(sandbox.normalizeHost(""), "")
    assert.strictEqual(sandbox.normalizeHost("devapi.qweather.com"), null, "公共域名在停用，也不在白名单里")
    assert.strictEqual(sandbox.normalizeHost("qweatherapi.com"), null)
    assert.strictEqual(sandbox.normalizeHost("abc.qweatherapi.com.evil.com"), null)
  })

  await test("没填 Key：列表第一行叫去填，回车打开设置；不发请求", async () => {
    const p = load(dir, { routes: routes(), stored: { cities: [tianjin] } })
    const rows = await p.handlers.list("")
    assert.strictEqual(rows[0].id, "problem")
    assert.strictEqual(rows[0].title, "填上和风天气的 API Host 和 API Key")
    assert.strictEqual(rows[1].title, "天津", "收藏的城市照样列着")
    p.handlers.perform(rows[0].actions[0].id, rows[0].id)
    assert.strictEqual(p.settingsOpened, 1)
    p.handlers.perform(rows[0].actions[1].id, rows[0].id)
    assert.deepStrictEqual(p.opened, ["https://console.qweather.com/"])
    assert.strictEqual((await p.handlers.list("天津"))[0].id, "problem")
    const menu = await p.handlers.menu()
    assert.strictEqual(menu[0].type, "note")
    assert.strictEqual(menu[1].action, "settings")
    assert.strictEqual(p.requests.length, 0)
  })

  await test("API Host 填错：说 Host 不对，不发请求", async () => {
    const p = load(dir, { routes: routes(), settings: { host: "api.qweather.com", key: "k" } })
    const rows = await p.handlers.list("天津")
    assert.strictEqual(rows[0].title, "API Host 不对")
    assert.strictEqual(p.requests.length, 0)
  })

  await test("搜城市：带 Key 的请求头、界面语言；「天津市」搜不到时去掉「市」再搜", async () => {
    const p = load(dir, { routes: routes({ lookupEmptyFor: "天津市" }), settings })
    const rows = await p.handlers.list("天津市")
    assert.strictEqual(p.requests.length, 2)
    assert.ok(p.requests[0].url.startsWith("https://" + HOST + "/geo/v2/city/lookup?"))
    assert.ok(p.requests[0].url.includes("lang=zh"))
    assert.ok(p.requests[1].url.endsWith("location=" + encodeURIComponent("天津")))
    assert.deepStrictEqual(plain(p.requests[0].options.headers), { "X-QW-Api-Key": "k-123" })
    assert.deepStrictEqual(plain(rows.map((r) => r.title)), ["天津", "滨海新区", "天气服务由和风天气驱动"])
    assert.strictEqual(rows[1].subtitle, "天津", "上级地名去重、不写中国")
    assert.strictEqual(rows[0].actions[0].id, "add")
  })

  await test("搜得到就不再去后缀；去掉后缀不足两个字不搜", async () => {
    const p = load(dir, { routes: routes(), settings })
    await p.handlers.list("天津市")
    assert.strictEqual(p.requests.length, 1)
    const q = load(dir, { routes: routes({ lookupEmptyFor: "区" }), settings })
    assert.deepStrictEqual(plain(await q.handlers.list("区")), [])
    assert.strictEqual(q.requests.length, 1)
  })

  await test("加入：存城市（含时区、预报页）；加过的排最前、回车是看预报", async () => {
    const p = load(dir, { routes: routes(), settings })
    const rows = await p.handlers.list("天津")
    p.handlers.perform("add", rows[0].id)
    assert.strictEqual(p.storage.cities[0].tz, "Asia/Shanghai")
    assert.deepStrictEqual(p.toasts, ["已添加城市 / 天津"])
    const again = await p.handlers.list("天津")
    assert.strictEqual(again[0].title, "天津")
    assert.strictEqual(again[0].actions[0].id, "open")
    assert.ok(!again.slice(1).some((r) => r.id === rows[0].id))
    p.handlers.perform("open", rows[0].id)
    assert.deepStrictEqual(p.opened, [tianjin.link])
  })

  await test("收藏的城市：气温、天气、最高最低，最后一行注明和风天气", async () => {
    const p = load(dir, { routes: routes(), settings, stored: { cities: [tianjin] } })
    const rows = await p.sandbox.list("", NOW)
    assert.strictEqual(rows[0].value, "13°")
    assert.strictEqual(rows[0].subtitle, "多云 · 最高 16° 最低 4°")
    assert.strictEqual(rows[0].icon.tint, "orange")
    assert.strictEqual(rows[1].id, "attribution")
    p.handlers.perform("attribution", "attribution")
    assert.deepStrictEqual(p.opened, ["https://www.qweather.com/"])
    const paths = p.requests.map((r) => r.url.replace("https://" + HOST, ""))
    assert.ok(paths.includes("/weather/v1/current/39.13/117.19?lang=zh"), JSON.stringify(paths))
    assert.ok(paths.includes("/weather/v1/daily/39.13/117.19?days=1&localTime=true&lang=zh"), JSON.stringify(paths))
  })

  await test("缓存：实况 15 分钟、最高最低 3 小时；存在插件存储里，重新加载不重取", async () => {
    const p = load(dir, { routes: routes(), settings, stored: { cities: [tianjin] } })
    await p.sandbox.list("", NOW)
    await p.sandbox.list("", NOW + 10 * 60 * 1000)
    await p.sandbox.menu(NOW + 14 * 60 * 1000)
    assert.strictEqual(p.requests.length, 2, "15 分钟内不重取")
    await p.sandbox.list("", NOW + 16 * 60 * 1000)
    assert.strictEqual(p.requests.length, 3, "实况过期只重取实况")
    assert.ok(p.requests[2].url.includes("/current/"))
    const reloaded = load(dir, { routes: routes(), settings, stored: plain(p.storage) })
    await reloaded.sandbox.list("", NOW + 20 * 60 * 1000)
    assert.strictEqual(reloaded.requests.length, 0, "插件卸掉再加载，存着的还能用")
    await reloaded.sandbox.list("", NOW + 4 * 3600 * 1000)
    assert.strictEqual(reloaded.requests.length, 2, "3 小时后两样都重取")
    const rewound = load(dir, { routes: routes(), settings, stored: plain(p.storage) })
    await rewound.sandbox.list("", NOW - 3600 * 1000)
    assert.strictEqual(rewound.requests.length, 2, "系统时间往回调了：存的时间在将来，不算新的")
  })

  await test("移出的城市不留缓存", async () => {
    const other = { ...tianjin, name: "滨海新区", lat: 39.03258, lon: 117.71047 }
    const p = load(dir, { routes: routes(), settings, stored: { cities: [tianjin, other] } })
    await p.sandbox.list("", NOW)
    assert.strictEqual(Object.keys(p.storage.cache).length, 2)
    p.handlers.perform("remove", sandbox.cityID(other))
    await p.sandbox.list("", NOW + 16 * 60 * 1000)
    assert.deepStrictEqual(plain(Object.keys(p.storage.cache)), [sandbox.cityID(tianjin)])
  })

  await test("Key 不对、额度用完、网络不通：各说各的，收藏的城市照样列着", async () => {
    for (const [opts, title] of [[{ status: 401 }, "API Key 不对"], [{ status: 403 }, "API Key 不对"],
                                 [{ status: 429 }, "和风天气的请求额度用完了"], [{ fail: true }, "连不上和风天气"]]) {
      const p = load(dir, { routes: routes(opts), settings, stored: { cities: [tianjin] } })
      const rows = await p.handlers.list("")
      assert.strictEqual(rows[0].title, title, JSON.stringify(opts))
      assert.strictEqual(rows[1].title, "天津")
      assert.strictEqual(rows[1].value, null)
      const search = await p.handlers.list("北京")
      assert.strictEqual(search[0].title, title, "搜索也说原因")
    }
  })

  await test("一个城市取不到不连累别的", async () => {
    const other = { ...tianjin, name: "滨海新区", lat: 39.03258, lon: 117.71047 }
    const base = routes()
    const p = load(dir, { settings, stored: { cities: [tianjin, other] },
      routes: (url) => (url.includes("39.03/117.71") ? { status: 500, text: "" } : base(url)) })
    const rows = await p.sandbox.list("", NOW)
    assert.strictEqual(rows[0].value, "13°")
    assert.strictEqual(rows[1].value, null)
  })

  await test("菜单：天气图标、更新时间那行能点开和风；网络不通抛出去（原生留着快照），Key 不对说清楚", async () => {
    const p = load(dir, { routes: routes(), settings, stored: { cities: [tianjin] } })
    const rows = await p.sandbox.menu(NOW)
    assert.deepStrictEqual(plain(rows[0]), { title: "天津", value: "13°", detail: "多云", symbol: "cloud.sun.fill", action: "open:39.126,117.190" })
    assert.strictEqual(rows[1].type, "separator")
    assert.strictEqual(rows[2].action, "attribution")
    assert.strictEqual(rows[2].detail, "更新于 10:30")
    p.handlers.action("open:39.126,117.190")
    p.handlers.action("attribution")
    assert.deepStrictEqual(p.opened, [tianjin.link, "https://www.qweather.com/"])
    await assert.rejects(load(dir, { routes: routes({ fail: true }), settings, stored: { cities: [tianjin] } }).sandbox.menu(NOW))
    const auth = await load(dir, { routes: routes({ status: 401 }), settings, stored: { cities: [tianjin] } }).sandbox.menu(NOW)
    assert.strictEqual(auth[0].text, "API Key 不对")
    assert.strictEqual(auth[2].action, "settings")
  })

  await test("夜里晴、多云换月亮；天气代码对图标", () => {
    const night = Date.UTC(2026, 10, 6, 14, 0) // 北京 22:00
    assert.strictEqual(sandbox.isNight("Asia/Shanghai", night), true)
    assert.strictEqual(sandbox.isNight("Asia/Shanghai", NOW), false)
    assert.strictEqual(sandbox.isNight("", night), false, "老城市没有时区当白天")
    assert.deepStrictEqual(plain(sandbox.look("100", true)), ["moon.stars.fill", "indigo"])
    assert.deepStrictEqual(plain(sandbox.look("101", false)), ["cloud.sun.fill", "orange"])
    const symbol = (code) => sandbox.look(code, false)[0]
    assert.strictEqual(symbol("104"), "cloud.fill")
    assert.strictEqual(symbol("302"), "cloud.bolt.rain.fill")
    assert.strictEqual(symbol("305"), "cloud.drizzle.fill")
    assert.strictEqual(symbol("307"), "cloud.heavyrain.fill")
    assert.strictEqual(symbol("313"), "cloud.sleet.fill")
    assert.strictEqual(symbol("404"), "cloud.sleet.fill")
    assert.strictEqual(symbol("401"), "cloud.snow.fill")
    assert.strictEqual(symbol("501"), "cloud.fog.fill")
    assert.strictEqual(symbol("502"), "sun.haze.fill")
    assert.strictEqual(symbol("507"), "sun.dust.fill")
    assert.strictEqual(symbol("999"), "cloud.fill")
  })

  await test("地名：去掉和城市名、彼此重复的，中国不写，外国写", () => {
    assert.strictEqual(sandbox.place({ name: "东城", adm2: "北京", adm1: "北京市", country: "中国" }), "北京")
    assert.strictEqual(sandbox.place({ name: "西湖", adm2: "杭州", adm1: "浙江省", country: "中国" }), "杭州 · 浙江省")
    assert.strictEqual(sandbox.place({ name: "伦敦", adm2: "伦敦", adm1: "英格兰", country: "英国" }), "英格兰 · 英国")
    assert.strictEqual(sandbox.place({ name: "杭州", admin: "浙江", country: "中国" }), "浙江", "老版本存的城市（admin）")
  })

  await test("老版本（Open-Meteo）存的城市照样能取天气；坏数据不进列表", async () => {
    const old = { name: "杭州", admin: "浙江", country: "中国", lat: 30.29365, lon: 120.16142 }
    const p = load(dir, { routes: routes(), settings, stored: { cities: [old, { name: "x", lat: 999, lon: 0 }, null] } })
    const rows = await p.sandbox.list("", NOW)
    assert.strictEqual(rows.length, 2)
    assert.strictEqual(rows[0].value, "13°")
    p.handlers.perform("open", rows[0].id)
    assert.ok(p.opened[0].startsWith("https://www.bing.com/search?q="), "没有和风的预报页，退回搜索")
  })

  await test("解析：坏 JSON、缺字段", () => {
    assert.strictEqual(sandbox.parseCurrent("<html>"), null)
    assert.strictEqual(sandbox.parseCurrent('{"condition":{"text":"晴"}}'), null)
    assert.strictEqual(sandbox.parseDaily('{"days":[]}'), null)
    assert.deepStrictEqual(plain(sandbox.parseLookup('{"code":"200","location":[{"name":"x","lat":"abc","lon":"1"}]}')), [])
    assert.strictEqual(sandbox.parseLookup(F("lookup-tianjin.json"))[0].link, tianjin.link)
    assert.strictEqual(sandbox.parseLookup('{"location":[{"name":"x","lat":"1","lon":"1","fxLink":"javascript:alert(1)"}]}')[0].link, "", "只认 https 的预报页")
  })

  done()
})()
