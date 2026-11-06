// TabFlick Hacker News 插件（官方）。数据来自 HN 官方合作的 Algolia 搜索接口（hn.algolia.com，不用注册）：
// 首页 search?tags=front_page，最新 search_by_date?tags=story，搜索 search?query=…&tags=story。
// 看首页还是最新、列几条在插件设置里选（tabflick.settings）。5 分钟内不重取。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

const API = "https://hn.algolia.com/api/v1/search"

/** { hits: [{ objectID, title, url, points, num_comments, author, created_at_i }] } → 文章。没标题的跳过。 */
function parseHits(text) {
  let d
  try { d = JSON.parse(text) } catch (e) { return [] }
  return ((d && d.hits) || []).filter((h) => h && typeof h.title === "string" && h.title && /^\d+$/.test(String(h.objectID)))
    .map((h) => ({
      id: String(h.objectID),
      title: h.title,
      url: typeof h.url === "string" && /^https?:\/\//.test(h.url) ? h.url : null,
      points: h.points || 0,
      comments: h.num_comments || 0,
      author: h.author || "",
      time: (h.created_at_i || 0) * 1000,
    }))
}

function discussionURL(id) {
  return "https://news.ycombinator.com/item?id=" + id
}

function domain(url) {
  const m = /^https?:\/\/(?:www\.)?([^/]+)/.exec(url || "")
  return m ? m[1] : "news.ycombinator.com"
}

function ago(ms, nowMs = Date.now()) {
  const minutes = Math.max(0, Math.floor((nowMs - ms) / 60000))
  if (minutes < 60) return t(`${minutes} 分钟前`, `${minutes} 分鐘前`, `${minutes}m ago`)
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return t(`${hours} 小时前`, `${hours} 小時前`, `${hours}h ago`)
  return t(`${Math.floor(hours / 24)} 天前`, `${Math.floor(hours / 24)} 天前`, `${Math.floor(hours / 24)}d ago`)
}

/** 设置：看首页还是最新、列几条（没有设置接口的老版本按默认）。 */
function feed() {
  const v = tabflick.settings && tabflick.settings.get("feed")
  return v === "newest" ? "newest" : "front"
}
function count() {
  const n = parseInt(tabflick.settings && tabflick.settings.get("count"), 10)
  return [5, 10, 20, 30].includes(n) ? n : 10
}

const CACHE_MS = 5 * 60 * 1000
let front = { at: 0, kind: "", stories: [] }
/** 最近列过的文章（按 id 找网址）。 */
let known = {}

async function frontPage(nowMs = Date.now()) {
  const kind = feed()
  if (front.stories.length && front.kind === kind && nowMs - front.at < CACHE_MS) return front.stories
  const url = kind === "newest" ? API + "_by_date?tags=story&hitsPerPage=30" : API + "?tags=front_page&hitsPerPage=30"
  const res = await tabflick.fetch(url)
  if (res.status !== 200) throw new Error("HTTP " + res.status)
  front = { at: nowMs, kind, stories: parseHits(res.text) }
  return front.stories
}

function remember(stories) {
  for (const s of stories) known[s.id] = s
  return stories
}

function storyRow(s) {
  return {
    id: s.id,
    title: s.title,
    subtitle: [t(`${s.points} 分`, `${s.points} 分`, `${s.points} points`), t(`${s.comments} 评论`, `${s.comments} 留言`, `${s.comments} comments`),
               ago(s.time), domain(s.url)].join(" · "),
    value: String(s.points),
    icon: { text: "Y", tint: "orange" },
    actions: [
      { id: "open", title: t("打开文章", "打開文章", "Open Story"), symbol: "safari.fill" },
      { id: "comments", title: t("打开讨论", "打開討論", "Open Discussion"), symbol: "bubble.left.and.bubble.right.fill" },
      { id: "copy", title: t("拷贝链接", "拷貝連結", "Copy Link"), symbol: "doc.on.doc.fill" },
    ],
  }
}

async function list(query) {
  const text = String(query || "").trim()
  if (!text) return remember(await frontPage()).slice(0, count()).map(storyRow)
  const res = await tabflick.fetch(API + "?tags=story&hitsPerPage=20&query=" + encodeURIComponent(text))
  if (res.status !== 200) throw new Error("HTTP " + res.status)
  return remember(parseHits(res.text)).map(storyRow)
}

function perform(action, id) {
  const s = known[id]
  if (!s) return
  const target = s.url || discussionURL(s.id)
  if (action === "open") tabflick.openURL(target)
  else if (action === "comments") tabflick.openURL(discussionURL(s.id))
  else if (action === "copy") {
    tabflick.copy(target)
    tabflick.toast(t("已拷贝链接", "已拷貝連結", "Link copied"), s.title)
  }
}

async function menu() {
  const stories = remember(await frontPage()).slice(0, count())
  const header = feed() === "newest" ? t("最新", "最新", "Newest") : t("首页", "首頁", "Front Page")
  return [{ type: "header", text: header }].concat(stories.map((s) => ({
    title: s.title.length > 60 ? s.title.slice(0, 59) + "…" : s.title,
    value: "▲" + s.points,
    detail: t(`${s.comments} 评论`, `${s.comments} 留言`, `${s.comments}`),
    action: "open:" + s.id,
  })))
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
