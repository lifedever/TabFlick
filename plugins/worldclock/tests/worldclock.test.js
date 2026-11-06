// 世界时钟插件：TZ=Asia/Shanghai node plugins/worldclock/tests/worldclock.test.js（本机时区固定成北京，期望值才是死的）
process.env.TZ = "Asia/Shanghai"
const assert = require("assert")
const { load, test, done, plain } = require("../../_shared/harness")
const dir = __dirname + "/.."
// 2026-11-06 10:30 UTC = 北京 18:30；纽约 05:30（11 月已经不是夏令时，-5）；伦敦 10:30（+0）
const NOW = Date.UTC(2026, 10, 6, 10, 30)
// 2026-07-01 10:30 UTC：纽约夏令时 -4 → 06:30
const SUMMER = Date.UTC(2026, 6, 1, 10, 30)

;(async () => {
  const { sandbox } = load(dir)

  await test("时间和时差", () => {
    const ny = sandbox.clock(sandbox.cityByID("newyork"), NOW, 480)
    assert.deepStrictEqual(plain(ny), { time: "05:30", diff: -780, dayDiff: 0 })
    assert.strictEqual(sandbox.describeDiff(-780), "比本地晚 13 小时")
    const summer = sandbox.clock(sandbox.cityByID("newyork"), SUMMER, 480)
    assert.strictEqual(summer.time, "06:30", "夏令时")
    assert.strictEqual(summer.diff, -720)
    assert.strictEqual(sandbox.describeDiff(330), "比本地早 5.5 小时")
  })

  await test("跨天：北京 01:00 时纽约是昨天", () => {
    const late = Date.UTC(2026, 10, 5, 17, 0)   // 北京 11-06 01:00
    const ny = sandbox.clock(sandbox.cityByID("newyork"), late, 480)
    assert.strictEqual(ny.dayDiff, -1)
    const akl = sandbox.clock(sandbox.cityByID("auckland"), Date.UTC(2026, 10, 6, 14, 0), 480)
    assert.strictEqual(akl.dayDiff, 1, "北京 22:00 奥克兰是明天")
  })

  await test("列表：默认纽约、伦敦；搜中文、英文、拼音首字母", () => {
    const p = load(dir)
    assert.deepStrictEqual(plain(p.sandbox.list("", NOW).map((r) => r.value)), ["05:30", "10:30"])
    assert.strictEqual(p.sandbox.list("东京", NOW)[0].id, "tokyo")
    assert.strictEqual(p.sandbox.list("tokyo", NOW)[0].id, "tokyo")
    assert.strictEqual(p.sandbox.list("dj", NOW)[0].id, "tokyo")
    assert.strictEqual(p.sandbox.list("lsj", NOW)[0].id, "losangeles")
    assert.strictEqual(p.sandbox.list("伦敦", NOW)[0].actions[0].id, "copy", "收藏过的回车是拷贝")
  })

  await test("搜国家列出它所有的城市：加拿大、jnd、Canada", () => {
    const p = load(dir)
    const canada = ["toronto", "ottawa", "montreal", "vancouver", "calgary", "edmonton", "winnipeg", "halifax", "stjohns"]
    assert.deepStrictEqual(plain(p.sandbox.list("加拿大", NOW).map((r) => r.id)), canada)
    assert.deepStrictEqual(plain(p.sandbox.list("jnd", NOW).map((r) => r.id)), canada)
    assert.deepStrictEqual(plain(p.sandbox.list("canada", NOW).map((r) => r.id)), canada)
    assert.strictEqual(p.sandbox.list("加拿大", NOW)[0].subtitle, "加拿大 · 比本地晚 13 小时")
    const us = p.sandbox.list("美国", NOW).map((r) => r.id)
    assert.ok(us.length >= 15 && us.includes("honolulu") && us.includes("newyork"), "美国全列：" + us.length)
    assert.strictEqual(p.sandbox.list("usa", NOW).length, us.length)
  })

  await test("城市名优先于国家；收藏的城市在同分里靠前", () => {
    const p = load(dir, { stored: { cities: ["vancouver"] } })
    // 「温哥华」是城市名，排第一；国家搜索里收藏的温哥华排最前
    assert.strictEqual(p.sandbox.list("温哥华", NOW)[0].id, "vancouver")
    assert.strictEqual(p.sandbox.list("加拿大", NOW)[0].id, "vancouver")
    // 「中国香港」：香港本身最前，后面跟着中国的城市
    const hk = p.sandbox.list("中国香港", NOW).map((r) => r.id)
    assert.strictEqual(hk[0], "hongkong")
    assert.ok(hk.includes("beijing"))
  })

  await test("带后缀、带「时间」也认：多伦多市、纽约时间、胡志明", () => {
    const p = load(dir)
    assert.strictEqual(p.sandbox.list("多伦多市", NOW)[0].id, "toronto")
    assert.strictEqual(p.sandbox.list("纽约时间", NOW)[0].id, "newyork")
    assert.strictEqual(p.sandbox.list("胡志明", NOW)[0].id, "hochiminh")
    assert.strictEqual(p.sandbox.list("new york", NOW)[0].id, "newyork")
    assert.strictEqual(p.sandbox.list("York", NOW)[0].id, "newyork")
  })

  await test("英文短词不乱匹配：us 不带出俄罗斯、澳大利亚", () => {
    const ids = load(dir).sandbox.list("us", NOW).map((r) => r.id)
    assert.ok(!ids.includes("moscow") && !ids.includes("sydney"), JSON.stringify(ids))
  })

  await test("繁中、英文界面的国家名", () => {
    assert.strictEqual(load(dir, { locale: "zh-Hant" }).sandbox.list("加拿大", NOW)[0].subtitle.split(" · ")[0], "加拿大")
    assert.strictEqual(load(dir, { locale: "en" }).sandbox.list("tokyo", NOW)[0].subtitle.split(" · ")[0], "Japan")
  })

  await test("老版本存的城市 id 都还认得", () => {
    const old = ["beijing", "shanghai", "hongkong", "taipei", "tokyo", "seoul", "singapore", "bangkok", "hanoi", "jakarta",
      "kualalumpur", "manila", "delhi", "mumbai", "dubai", "moscow", "istanbul", "london", "paris", "berlin", "amsterdam",
      "madrid", "rome", "zurich", "stockholm", "cairo", "johannesburg", "newyork", "washington", "toronto", "chicago",
      "denver", "losangeles", "sanfrancisco", "seattle", "vancouver", "mexicocity", "saopaulo", "buenosaires", "honolulu",
      "sydney", "melbourne", "auckland", "utc"]
    const p = load(dir, { stored: { cities: old } })
    assert.strictEqual(p.sandbox.list("", NOW).length, old.length)
  })

  await test("加入、移出、拷贝；认不出的 id 不动", () => {
    const p = load(dir)
    p.sandbox.perform("add", "tokyo", NOW)
    assert.deepStrictEqual(plain(p.storage.cities), ["newyork", "london", "tokyo"])
    p.sandbox.perform("remove", "newyork", NOW)
    p.sandbox.perform("add", "atlantis", NOW)
    assert.deepStrictEqual(plain(p.storage.cities), ["london", "tokyo"])
    p.sandbox.perform("copy", "tokyo", NOW)
    assert.deepStrictEqual(p.copied, ["东京 19:30"])
  })

  await test("菜单", () => {
    const rows = load(dir).sandbox.menu(NOW)
    assert.strictEqual(rows[0].title, "纽约")
    assert.strictEqual(rows[0].value, "05:30")
    assert.strictEqual(rows[0].detail, "比本地晚 13 小时")
  })

  await test("跨天写在副标题末尾", () => {
    const row = load(dir).sandbox.list("奥克兰", Date.UTC(2026, 10, 6, 14, 0))[0]
    assert.strictEqual(row.subtitle, "新西兰 · 比本地早 5 小时 · 明天")
  })

  done()
})()
