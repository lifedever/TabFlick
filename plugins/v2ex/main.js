// TabFlick V2EX 插件（官方）。数据来自 V2EX 的公开接口：/api/topics/hot.json（今天的热议，一天十条左右）、
// /api/topics/latest.json（最新）。看哪个、列几条在插件设置里选（tabflick.settings）。V2EX 没有公开的搜索接口，
// 打字只在这两份里按标题、节点过滤。5 分钟内不重取。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** [{ id, title, url, replies, node: { title }, member: { username }, created }] → 主题。 */
function parseTopics(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return [] }
  return (Array.isArray(d) ? d : []).filter((x) => x && Number.isInteger(x.id) && typeof x.title === "string")
    .map((x) => ({
      id: String(x.id),
      title: x.title,
      url: "https://www.v2ex.com/t/" + x.id,
      replies: x.replies || 0,
      node: (x.node && x.node.title) || "",
      author: (x.member && x.member.username) || "",
    }))
}

const CACHE_MS = 5 * 60 * 1000
const cache = {}

async function topics(kind, nowMs = Date.now()) {
  const c = cache[kind]
  if (c && nowMs - c.at < CACHE_MS) return c.topics
  const res = await tabflick.fetch(`https://www.v2ex.com/api/topics/${kind}.json`)
  if (res.status !== 200) throw new Error("HTTP " + res.status)
  const parsed = parseTopics(res.text)
  cache[kind] = { at: nowMs, topics: parsed }
  return parsed
}

let known = {}

/** 设置：看热议还是最新、列几条（没有设置接口的老版本按默认）。 */
function feed() {
  const v = tabflick.settings && tabflick.settings.get("feed")
  return v === "latest" ? "latest" : "hot"
}
function count() {
  const n = parseInt(tabflick.settings && tabflick.settings.get("count"), 10)
  return [5, 10, 20, 30].includes(n) ? n : 10
}

function topicRow(x) {
  known[x.id] = x
  return {
    id: x.id,
    title: x.title,
    subtitle: [x.node, t(`${x.replies} 回复`, `${x.replies} 回覆`, `${x.replies} replies`), x.author].filter(Boolean).join(" · "),
    value: String(x.replies),
    icon: { text: (x.node || "V").slice(0, 1), tint: "gray" },
    actions: [
      { id: "open", title: t("打开主题", "打開主題", "Open Topic"), symbol: "safari.fill" },
      { id: "copy", title: t("拷贝链接", "拷貝連結", "Copy Link"), symbol: "doc.on.doc.fill" },
    ],
  }
}

async function list(query) {
  const text = String(query || "").trim().toLowerCase()
  if (!text) return (await topics(feed())).slice(0, count()).map(topicRow)
  const hot = await topics("hot")
  // 热议 + 最新，按标题、节点、作者过滤，热议在前、去重
  const latest = await topics("latest").catch(() => [])
  const seen = new Set()
  return hot.concat(latest).filter((x) => {
    if (seen.has(x.id)) return false
    seen.add(x.id)
    return x.title.toLowerCase().includes(text) || x.node.toLowerCase().includes(text) || x.author.toLowerCase() === text
  }).slice(0, 30).map(topicRow)
}

function perform(action, id) {
  const x = known[id]
  if (!x) return
  if (action === "open") tabflick.openURL(x.url)
  else if (action === "copy") {
    tabflick.copy(x.url)
    tabflick.toast(t("已拷贝链接", "已拷貝連結", "Link copied"), x.title)
  }
}

async function menu() {
  const kind = feed()
  const items = (await topics(kind)).slice(0, count())
  const header = kind === "latest" ? t("最新主题", "最新主題", "Latest") : t("今日热议", "今日熱議", "Hot Today")
  return [{ type: "header", text: header }].concat(items.map((x) => {
    topicRow(x)
    return {
      title: x.title.length > 40 ? x.title.slice(0, 39) + "…" : x.title,
      badge: x.node || null,
      value: String(x.replies),
      action: "open:" + x.id,
    }
  }))
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    menu,
    list,
    perform,
    action(id) {
      const m = /^open:(\d+)$/.exec(String(id))
      if (m) perform("open", m[1])
    },
  })
}
