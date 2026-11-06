// V2EX 插件：node plugins/v2ex/tests/v2ex.test.js（样本是 2026-11-06 /api/topics/hot.json 的真实返回）
const assert = require("assert")
const { load, test, done, plain, fixture } = require("../../_shared/harness")
const dir = __dirname + "/.."
const hot = fixture(__dirname, "hot.json")
const latest = JSON.stringify([{ id: 1, title: "Swift 还是 Rust", replies: 3, node: { title: "程序员" }, member: { username: "a" } }])
const routes = (url) => ({ status: 200, text: url.includes("hot") ? hot : latest })

;(async () => {
  const { sandbox } = load(dir)

  await test("解析", () => {
    const topics = sandbox.parseTopics(hot)
    assert.ok(topics.length > 0)
    assert.ok(topics[0].url.startsWith("https://www.v2ex.com/t/"))
    assert.deepStrictEqual(plain(sandbox.parseTopics('[{"id":"x","title":"bad"},{"id":1}]')), [])
    assert.deepStrictEqual(plain(sandbox.parseTopics('{"error":1}')), [])
  })

  await test("列表：没输入是热议；打字在热议 + 最新里按标题、节点过滤", async () => {
    const p = load(dir, { routes })
    const rows = await p.handlers.list("")
    assert.strictEqual(rows.length, sandbox.parseTopics(hot).length)
    const found = await p.handlers.list("swift")
    assert.deepStrictEqual(plain(found.map((r) => r.id)), ["1"])
    const byNode = await p.handlers.list("程序员")
    assert.ok(byNode.some((r) => r.id === "1"))
  })

  await test("5 分钟内不重取；动作", async () => {
    const p = load(dir, { routes })
    const rows = await p.handlers.list("")
    await p.handlers.menu()
    assert.strictEqual(p.requests.length, 1)
    p.handlers.perform("open", rows[0].id)
    p.handlers.perform("open", "nope")
    assert.strictEqual(p.opened.length, 1)
  })

  await test("菜单：前 10 条，节点写小字", async () => {
    const rows = await load(dir, { routes }).handlers.menu()
    assert.strictEqual(rows[0].text, "今日热议")
    assert.ok(rows.length <= 11)
  })

  await test("设置：看最新、条数", async () => {
    const latestRows = JSON.stringify(Array.from({ length: 30 }, (_, i) => ({ id: 100 + i, title: "t" + i, replies: i, node: { title: "n" } })))
    const routes2 = (url) => ({ status: 200, text: url.includes("hot") ? hot : latestRows })
    const p = load(dir, { routes: routes2, settings: { feed: "latest", count: "20" } })
    const rows = await p.handlers.list("")
    assert.strictEqual(rows.length, 20)
    assert.ok(p.requests[0].url.endsWith("/latest.json"))
    const menu = await p.handlers.menu()
    assert.strictEqual(menu[0].text, "最新主题")
    assert.strictEqual(menu.length, 21)
    const five = await load(dir, { routes: routes2, settings: { count: "5" } }).handlers.list("")
    assert.strictEqual(five.length, 5)
    const bad = await load(dir, { routes: routes2, settings: { feed: "weird", count: "999" } }).handlers.menu()
    assert.strictEqual(bad[0].text, "今日热议", "认不出的值按默认")
  })

  done()
})()
