// Hacker News 插件：node plugins/hackernews/tests/hackernews.test.js（样本是 2026-11-06 hn.algolia.com 的真实返回）
const assert = require("assert")
const { load, test, done, plain, fixture } = require("../../_shared/harness")
const dir = __dirname + "/.."
const front = fixture(__dirname, "front.json")
const search = fixture(__dirname, "search-swift.json")
const routes = (url) => ({ status: 200, text: url.includes("front_page") ? front : search })

;(async () => {
  const { sandbox } = load(dir)

  await test("解析：标题、分数、评论；没网址的去讨论页", () => {
    const hits = sandbox.parseHits(front)
    assert.ok(hits.length >= 10)
    assert.ok(hits.every((h) => h.title && /^\d+$/.test(h.id)))
    const noURL = sandbox.parseHits('{"hits":[{"objectID":"42","title":"Ask HN: x","url":null}]}')[0]
    assert.strictEqual(noURL.url, null)
    assert.deepStrictEqual(plain(sandbox.parseHits('{"hits":[{"objectID":"x","title":"bad id"},{"objectID":"1"}]}')), [])
    assert.strictEqual(sandbox.parseHits('{"hits":[{"objectID":"1","title":"t","url":"javascript:alert(1)"}]}')[0].url, null, "只认 http(s)")
  })

  await test("列表：没输入是首页，5 分钟内不重取；有输入是搜索", async () => {
    const p = load(dir, { routes })
    const rows = await p.handlers.list("")
    await p.handlers.list("")
    await p.handlers.menu()
    assert.strictEqual(p.requests.length, 1)
    assert.strictEqual(rows[0].actions[0].id, "open")
    const found = await p.handlers.list("swift")
    assert.ok(p.requests[1].url.endsWith("query=swift"))
    assert.ok(found.some((r) => /swift/i.test(r.title)))
  })

  await test("动作：打开文章 / 讨论、拷贝链接", async () => {
    const p = load(dir, { routes })
    const rows = await p.handlers.list("")
    p.handlers.perform("comments", rows[0].id)
    assert.strictEqual(p.opened[0], "https://news.ycombinator.com/item?id=" + rows[0].id)
    p.handlers.perform("open", "999999999999")
    assert.strictEqual(p.opened.length, 1, "没列过的 id 不动")
  })

  await test("菜单：首页前 10 条", async () => {
    const rows = await load(dir, { routes }).handlers.menu()
    assert.strictEqual(rows[0].text, "首页")
    assert.strictEqual(rows.length, 11)
    assert.ok(rows[1].value.startsWith("▲"))
  })

  await test("时间", () => {
    const now = Date.UTC(2026, 10, 6, 12)
    assert.strictEqual(sandbox.ago(now - 5 * 60000, now), "5 分钟前")
    assert.strictEqual(sandbox.ago(now - 3 * 3600000, now), "3 小时前")
    assert.strictEqual(sandbox.ago(now - 50 * 3600000, now), "2 天前")
  })

  await test("设置：看最新、条数", async () => {
    const p = load(dir, { routes, settings: { feed: "newest", count: "5" } })
    const rows = await p.handlers.list("")
    assert.ok(p.requests[0].url.includes("search_by_date?tags=story"), p.requests[0].url)
    assert.strictEqual(rows.length, 5)
    assert.strictEqual((await p.handlers.menu())[0].text, "最新")
    const def = await load(dir, { routes }).handlers.list("")
    assert.strictEqual(def.length, 10, "默认 10 条")
  })

  done()
})()
