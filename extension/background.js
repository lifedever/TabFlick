// TabFlick Bridge — MV3 service worker
//
// 职责：
//   1. 维护全局标签页 MRU 顺序（最近使用的在前）
//   2. 通过本地 WebSocket 把 MRU 列表推给 Swift helper
//   3. 执行 helper 下发的切换指令
//
// 连接本身不在这里：MV3 的 service worker 空闲 30s 就被回收，被回收后无法
// 主动重连，只能等浏览器事件唤醒 —— 那正是「开完 app 第一次按 ⌃⇥ 不生效」
// 的原因。WebSocket 交给 offscreen document 常驻持有（offscreen.js），
// 这边只通过 runtime 消息收发；消息到达时 SW 会被自动唤醒。

const OFFSCREEN_PATH = "offscreen.html";
const RECONNECT_ALARM = "tabflick-reconnect";
const STORAGE_KEY = "mru";

/// 配置的事实源在 macOS app 那边（它有原生设置窗口，且进程一直活着）。
/// 这里的值只是内存里的一份副本：每次连上 helper 都会重新要一份，
/// 所以 service worker 被回收也不会导致两边不一致。
const DEFAULT_SETTINGS = {
  scopeToWindow: true,
  // 标签存活小时数，0 = 不清理。超时未使用的标签由 sweepExpiredTabs 关闭。
  // 默认 0：service worker 重启后 helper 不在线时就是这份默认值，
  // 清理这种破坏性动作的失败方向必须是「不动手」。
  tabLifetimeHours: 0,
  // 收藏的标签 [{url, title}]，连上时核对补齐（ensureFavorites）。
  favorites: [],
};

// 诊断探针 + 降噪（与 offscreen.js 同款）：未捕获的 promise 拒绝把完整
// 堆栈写进 helper 日志，并阻止分支浏览器（夸克）把它渲染成错误卡片。
self.addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  const reason = event.reason;
  const detail = (reason && (reason.stack || reason.message)) || String(reason);
  // 浏览器退出时挂起的 API 调用会成批拒绝，属正常噪音，不进日志
  if (detail.includes("browser is shutting down")) return;
  send({ type: "log", message: `sw unhandled rejection: ${detail}` });
});

let connected = false;   // offscreen 报上来的连接状态
let mru = [];          // tabId 数组，最近使用的在前，跨窗口全局维护
let mruLoaded = false;
let settings = { ...DEFAULT_SETTINGS };

// ── MRU 维护 ────────────────────────────────────────────────────────────

// service worker 随时可能被回收，MRU 必须能从 storage.session 恢复。
// storage.session 存在内存里，浏览器关闭即清空，正好符合「本次浏览会话」语义。
async function loadMRU() {
  if (mruLoaded) return;
  const stored = await chrome.storage.session.get(STORAGE_KEY);
  mru = stored[STORAGE_KEY] ?? [];
  mruLoaded = true;
}

async function persistMRU() {
  await chrome.storage.session.set({ [STORAGE_KEY]: mru });
}

async function touchTab(tabId) {
  await loadMRU();
  const i = mru.indexOf(tabId);
  if (i === 0) return;               // 已经在最前，无需变动
  if (i > 0) mru.splice(i, 1);
  mru.unshift(tabId);
  await persistMRU();
  await pushMRU();
}

async function forgetTab(tabId) {
  await loadMRU();
  const i = mru.indexOf(tabId);
  if (i === -1) return;
  mru.splice(i, 1);
  await persistMRU();
  await pushMRU();
}

/// 把 MRU 顺序连同展示所需的元信息推给 helper。
async function pushMRU() {
  if (!connected) return;
  await loadMRU();

  const allTabs = await chrome.tabs.query({});

  // 清理已关闭的标签页（SW 休眠期间关掉的不会走 onRemoved）。
  // 注意这一步必须对**全部窗口**做：按窗口过滤是展示层的事，
  // 拿过滤后的结果回写 mru 会把其他窗口的历史整段抹掉。
  const aliveIds = new Set(allTabs.map((t) => t.id));
  const cleaned = mru.filter((id) => aliveIds.has(id));
  if (cleaned.length !== mru.length) {
    mru = cleaned;
    await persistMRU();
  }

  if (allTabs.length === 0) return;

  // 始终推全量（所有窗口）：helper 的状态栏菜单要列出全部标签。
  // 「只切换当前窗口」的过滤在 helper 侧做（只作用于切换器），
  // 这里附上 currentWindowId 供它过滤。settings.scopeToWindow 不再
  // 影响推送内容。
  const windowId = await currentWindowId();

  const byId = new Map(allTabs.map((t) => [t.id, t]));

  // 已知顺序优先；从没被激活过的标签页（后台打开的、恢复会话带回来的）排在末尾
  const known = mru.filter((id) => byId.has(id));
  const knownSet = new Set(known);
  const unknown = allTabs.filter((t) => !knownSet.has(t.id)).map((t) => t.id);

  send({
    type: "mru",
    currentWindowId: windowId ?? -1,
    tabs: [...known, ...unknown].map((id) => {
      const t = byId.get(id);
      return {
        id: t.id,
        windowId: t.windowId,
        title: t.title ?? "",
        url: t.url ?? "",
        favIconUrl: t.favIconUrl ?? "",
        // 最近一次被使用的时刻（ms epoch，Chrome 121+）。状态栏菜单的
        // 「X 分钟前」和存活时间判定都以它为准。
        lastAccessed: typeof t.lastAccessed === "number" ? t.lastAccessed : 0,
        // 置顶态，切换器卡片的星标用
        pinned: t.pinned ?? false,
      };
    }),
  });
}

/// 节流版 pushMRU，给高频事件用。
///
/// onUpdated 会为一个页面加载过程中 title / favicon 的每次变化各触发一遍，
/// SPA 站点实测能在同一秒内打十几次。关键路径（激活、关闭、跨窗口移动）
/// 仍然直接调 pushMRU，不走这里。
let pushTimer = null;
function schedulePush() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    pushTimer = null;
    pushMRU();
  }, 80);
}

/// 最后聚焦的普通窗口的 id。
///
/// 不用 `windows.getLastFocused` —— 它的 `windowTypes` 过滤已废弃，
/// 焦点落在开发者工具窗口时会返回那个窗口。从活动标签页反查更稳。
async function currentWindowId() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab?.windowId;
}

// ── 缩略图 ──────────────────────────────────────────────────────────────
//
// captureVisibleTab 只能截「当前可见」的标签页，所以策略是：每次标签页被激活
// 就给它截一张。MRU 列表里的标签页按定义都被激活过，缩略图因此天然齐全。
//
// 两个约束：
//   · captureVisibleTab 有每秒调用次数上限，快速连切会报错 → 用 debounce 压住
//   · chrome:// 和 Web Store 页面截不了 → 静默失败，helper 那边降级显示 favicon

const THUMB_DEBOUNCE_MS = 250;   // 等页面画完，也顺便合并连续切换
const THUMB_WIDTH = 400;
const THUMB_HEIGHT = 250;

let thumbTimer = null;

function scheduleThumbnail(tabId, windowId) {
  clearTimeout(thumbTimer);
  thumbTimer = setTimeout(() => captureThumbnail(tabId, windowId), THUMB_DEBOUNCE_MS);
}

async function captureThumbnail(tabId, windowId) {
  if (!connected) return;
  try {
    const dataUrl = await chrome.tabs.captureVisibleTab(windowId, {
      format: "jpeg",
      quality: 70,
    });
    // 确认这期间用户没又切走 —— 否则会把 B 的截图挂到 A 名下
    const [current] = await chrome.tabs.query({ active: true, windowId });
    if (current?.id !== tabId) return;

    // 带上 url：helper 按 URL 持久化缓存，tabId 浏览器一重启就全变了
    send({ type: "thumb", tabId, url: current.url ?? "", data: await downscale(dataUrl) });
  } catch (e) {
    // chrome:// 页面、窗口被遮挡、超过频率限制 —— 都是正常跳过。
    // 但错误必须让 helper 日志看得见：之前这里静默吞错，把「SW 的 fetch
    // 不支持 data: URL」这种 100% 失败也吞了，缩略图从来没发出去过一张。
    send({ type: "log", message: `thumb capture failed: ${e}` });
  }
}

/// 原图是整个视口，直接传太大。按目标比例居中裁剪后缩到 400×250。
async function downscale(dataUrl) {
  // 不能用 fetch(dataUrl)：MV3 service worker 的 fetch 只认 http/https，
  // 对 data: URL 直接抛异常。手动 atob 解 base64 是 SW 里的标准做法。
  const base64 = dataUrl.slice(dataUrl.indexOf(",") + 1);
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/jpeg" }));

  const canvas = new OffscreenCanvas(THUMB_WIDTH, THUMB_HEIGHT);
  const ctx = canvas.getContext("2d");

  const scale = Math.max(THUMB_WIDTH / bitmap.width, THUMB_HEIGHT / bitmap.height);
  const srcW = THUMB_WIDTH / scale;
  const srcH = THUMB_HEIGHT / scale;
  // 横向居中，纵向取顶部 —— 网页的信息几乎都在上半屏
  ctx.drawImage(bitmap, (bitmap.width - srcW) / 2, 0, srcW, srcH,
                        0, 0, THUMB_WIDTH, THUMB_HEIGHT);
  bitmap.close();

  const out = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.6 });
  return bytesToBase64(new Uint8Array(await out.arrayBuffer()));
}

function bytesToBase64(bytes) {
  let binary = "";
  const CHUNK = 0x8000;   // 一次 apply 太多参数会爆栈
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

// ── 收藏标签（常驻置顶） ─────────────────────────────────────────────────
//
// app 侧维护收藏列表（url + title），每次收到配置就核对一遍：
//   · 该域名一个标签都没有 → 置顶打开（不抢焦点）
//   · 有标签但都没置顶   → 把第一个补成置顶
// 按域名识别：webapp 在站内不断跳转，按完整 URL 匹配会反复开重复标签。
// 只在收到配置时核对（连接建立 / 收藏变更），不做周期性强制 ——
// 用户会话中手动关掉收藏标签是明确意图，等浏览器下次重启再恢复。
//
// 解决的痛点：Chrome 的置顶是窗口级的，关掉带置顶的窗口再退出浏览器，
// 下次启动置顶标签就没了。收藏列表存在 app 侧，跟浏览器会话完全解耦。

let ensuringFavorites = false;

/// 浏览器启动后的安定期：会话恢复（含置顶标签）需要一点时间，核对跑得
/// 太早会「没看到恢复中的置顶 → 再开一个」。onStartup 时设置截止时间，
/// 核对开始前先等到点。
let startupSettleUntil = 0;

/// 我们自己置顶的 tabId：pinned:true 事件里跳过上报，防止「ensure 补置顶
/// → 事件上报 → helper 又添一条」的环。去重不再按域名（同域名允许多个
/// 置顶），这层标记是唯一的防环手段。
const selfPinned = new Set();

/// 我们自己取消置顶的 tabId（helper 的 unpin 命令）：pinned:false 事件里
/// 跳过「用户取消置顶」上报，防止误删同域名的其他置顶记录。
const selfUnpinned = new Set();

function hostOf(url) {
  try {
    return new URL(url).host || null;
  } catch {
    return null;
  }
}

async function ensureFavorites() {
  if (ensuringFavorites) return;
  ensuringFavorites = true;
  try {
    const settleWait = startupSettleUntil - Date.now();
    if (settleWait > 0) await new Promise((r) => setTimeout(r, settleWait));

    const favorites = settings.favorites ?? [];
    const allTabs = await chrome.tabs.query({});
    // 每个收藏认领一个标签，认领过的不再参与后续匹配。
    // 两遍匹配：先做「最后访问 URL」的精确认领，再做域名兜底 ——
    // 同域名的两个收藏若单遍处理，前一个会把后一个的标签按域名抢走，
    // 后一个又去新开一个重复置顶。
    const claimed = new Set();
    const plan = favorites.map((fav) => {
      const targetUrl = fav.currentUrl || fav.url;
      const exact = allTabs.find((t) => !claimed.has(t.id) && (t.url ?? "") === targetUrl);
      if (exact) claimed.add(exact.id);
      return { fav, match: exact ?? null };
    });
    for (const entry of plan) {
      if (entry.match) continue;
      // 恢复以「最后访问」为准（标签位语义：把上次的会话带回来）。
      // 收藏的常常是登录页，登录后重定向到别的域名 —— 只认原始域名
      // 会「找不到 → 再开一个」，每次重开窗口堆一个重复置顶。
      const targetUrl = entry.fav.currentUrl || entry.fav.url;
      const curHost = hostOf(targetUrl);
      const origHost = hostOf(entry.fav.url);
      const free = (t) => !claimed.has(t.id);
      entry.match =
        (curHost ? allTabs.find((t) => free(t) && hostOf(t.url ?? "") === curHost) : null) ??
        (origHost ? allTabs.find((t) => free(t) && hostOf(t.url ?? "") === origHost) : null);
      if (entry.match) claimed.add(entry.match.id);
    }
    // 第三遍：仍没着落的收藏 ↔ 现场没被认领的**置顶**标签，按序配对。
    // 重启恢复的置顶会因登录重定向漂到别的域名（signin…?callback=flow…），
    // 精确/域名两遍全落空 —— 但一个不认识的置顶标签存在，本身就说明它是
    // 某个收藏的化身，直接收编绑定，绝不再开新的（实测：不配对就双置顶）。
    for (const entry of plan) {
      if (entry.match) continue;
      const stray = allTabs.find((t) => t.pinned && !claimed.has(t.id));
      if (stray) {
        claimed.add(stray.id);
        entry.match = stray;
      }
    }

    for (const { fav, match } of plan) {
      const targetUrl = fav.currentUrl || fav.url;
      try {
        if (match) {
          if (!match.pinned) {
            selfPinned.add(match.id);
            await chrome.tabs.update(match.id, { pinned: true });
            send({ type: "log", message: `favorite re-pinned: ${hostOf(match.url ?? "") ?? "?"}` });
          }
          send({ type: "favoriteBound", id: fav.id, tabId: match.id });
        } else {
          const created = await chrome.tabs.create({ url: targetUrl, pinned: true, active: false });
          // 部分 Chromium 分支（实测：夸克）的 tabs.create 可能不按规范
          // 返回 Tab 对象 —— 读 created.id 会抛 undefined 错。拿不到 id
          // 就跳过绑定，下次核对再收编。
          if (created?.id !== undefined) {
            selfPinned.add(created.id);
            claimed.add(created.id);
            send({ type: "favoriteBound", id: fav.id, tabId: created.id });
          }
          send({ type: "log", message: `favorite restored: ${targetUrl}` });
        }
      } catch (e) {
        send({ type: "log", message: `favorite ensure failed (${fav.url}): ${e}` });
      }
    }

    // 收编：列表之外的置顶标签（程序没运行时用户置顶的）也报给 helper
    // 记为收藏 —— 置顶 = 收藏，双向同步。
    for (const t of allTabs) {
      if (t.pinned && !claimed.has(t.id) && (t.url ?? "").startsWith("http")) {
        send({ type: "pinnedTab", tabId: t.id, url: t.url, title: t.title ?? "",
               favIconUrl: t.favIconUrl ?? "" });
      }
    }
  } finally {
    ensuringFavorites = false;
  }
}

// ── 标签存活时间（Arc 式自动清理） ──────────────────────────────────────
//
// 超过设定时限未被使用的标签自动关闭。判定用 tab.lastAccessed
// （最近一次激活的时刻，Chrome 121+；拿不到该字段的标签一律不动）。
//
// 保护名单（宁可漏清不可错杀）：
//   · active  —— 各窗口的当前标签。附带效果：每个窗口至少保住一个标签，
//                绝不会把窗口/浏览器整个关掉
//   · pinned  —— 用户固定 = 明确要留
//   · audible —— 正在出声（后台放歌算「在用」）
//   · 分组内的标签 —— 进了 tab group 是刻意整理过的
// 另外只在连着 helper 时清理：TabFlick 没在运行就不该动用户的标签。

const LIFETIME_ALARM = "tabflick-lifetime";
const LIFETIME_SWEEP_MINUTES = 5;

async function sweepExpiredTabs() {
  const hours = settings.tabLifetimeHours;
  if (!hours || !connected) return;

  const cutoff = Date.now() - hours * 3600 * 1000;
  const allTabs = await chrome.tabs.query({});
  const victims = allTabs.filter((t) =>
    !t.active && !t.pinned && !t.audible &&
    (t.groupId === undefined || t.groupId === -1) &&
    typeof t.lastAccessed === "number" && t.lastAccessed > 0 &&
    t.lastAccessed < cutoff
  );
  if (victims.length === 0) return;

  // 清理留痕：哪些标签、多久没用，都写进 helper 日志，
  // 「我标签怎么没了」必须有处可查
  const detail = victims
    .map((t) => `${(t.title || t.url || "?").slice(0, 40)} (idle ${Math.round((Date.now() - t.lastAccessed) / 3600000)}h)`)
    .join("; ");
  send({ type: "log", message: `lifetime sweep: closing ${victims.length} tab(s) > ${hours}h idle: ${detail}` });

  try {
    await chrome.tabs.remove(victims.map((t) => t.id));
  } catch (e) {
    send({ type: "log", message: `lifetime sweep failed: ${e}` });
  }
}

// ── 执行切换 ────────────────────────────────────────────────────────────

async function activateTab(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.update(tabId, { active: true });
    // 目标可能在别的窗口 —— 光设 active 不会把那个窗口提到前面
    await chrome.windows.update(tab.windowId, { focused: true });
  } catch (e) {
    console.warn("[TabFlick] 切换失败，标签页可能已关闭:", tabId, e);
    await forgetTab(tabId);
  }
}

// ── WebSocket ───────────────────────────────────────────────────────────

function send(obj) {
  if (!connected) return;
  chrome.runtime
    .sendMessage({ target: "offscreen", type: "ws-send", data: JSON.stringify(obj) })
    .catch(() => {});
}

/// 确保 offscreen document 存在。它一旦创建就常驻，重复调用是安全的。
async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  try {
    await chrome.offscreen.createDocument({
      url: OFFSCREEN_PATH,
      // 没有哪个 reason 是为「保持 WebSocket」定义的，WORKERS 是最贴近的一项：
      // 我们确实需要一个独立于 service worker 生命周期的执行环境。
      reasons: ["WORKERS"],
      justification: "Maintain a persistent local WebSocket connection to the TabFlick helper.",
    });
  } catch (e) {
    // 并发调用时可能已经被另一次创建抢先，这不是错误
    if (!String(e).includes("Only a single offscreen")) {
      console.warn("[TabFlick] offscreen 创建失败:", e);
    }
  }
}

async function connect() {
  await ensureOffscreen();
  // 让 offscreen 汇报当前状态；没连上的话它会自己重连
  chrome.runtime
    .sendMessage({ target: "offscreen", type: "ws-poke" })
    .catch(() => {});
}

/// 处理 helper 发来的一条消息（由 offscreen 转发）。
async function handleHelperMessage(raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;   // 不是我们的协议，忽略
  }
  switch (msg.type) {
    case "switch":
      if (typeof msg.tabId === "number") await activateTab(msg.tabId);
      break;
    case "unpin":
      // 取消收藏：撤销该域名下所有标签的置顶（收藏核对只补不撤，
      // 撤销必须由 helper 明确指令）
      if (Array.isArray(msg.hosts)) {
        const pinned = await chrome.tabs.query({ pinned: true });
        for (const t of pinned) {
          const h = hostOf(t.url ?? "");
          if (h && msg.hosts.includes(h)) {
            try {
              selfUnpinned.add(t.id);
              await chrome.tabs.update(t.id, { pinned: false });
            } catch (e) {
              selfUnpinned.delete(t.id);
              send({ type: "log", message: `unpin failed (${h}): ${e}` });
            }
          }
        }
      }
      break;
    case "close":
      // 浮层卡片上的 ✕。关闭成功会触发 onRemoved → forgetTab → pushMRU，
      // 不用在这里重复维护 MRU。
      if (typeof msg.tabId === "number") {
        try {
          await chrome.tabs.remove(msg.tabId);
        } catch (e) {
          // 标签可能已经没了（用户手动关掉的竞态），清掉本地记录即可
          send({ type: "log", message: `close failed: ${e}` });
          await forgetTab(msg.tabId);
        }
      }
      break;
    case "ping":
      send({ type: "pong" });
      break;
    case "requestMRU":
      await pushMRU();
      break;
    case "settings":
      // app 推来的配置。范围过滤已移到 helper 侧，这里收下配置后推一份
      // 全量列表即可（helper 换了过滤条件后需要新数据立即生效）。
      if (typeof msg.scopeToWindow === "boolean") {
        settings.scopeToWindow = msg.scopeToWindow;
        pushMRU();
      }
      if (typeof msg.tabLifetimeHours === "number") {
        settings.tabLifetimeHours = msg.tabLifetimeHours;
      }
      if (Array.isArray(msg.favorites)) {
        settings.favorites = msg.favorites;
        ensureFavorites();
      }
      break;
  }
}

// offscreen 转发上来的连接事件与数据。
// helper 的消息必须**串行**处理：发送顺序就是语义顺序（先 unpin 后推新
// 配置），async 处理器并发交错会把顺序打乱 —— 收编扫描在置顶撤掉之前
// 跑到，就会把刚取消的置顶又加回列表（取消置顶死循环，实测）。
let helperQueue = Promise.resolve();

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "sw") return;

  switch (message.type) {
    case "ws-open":
      if (!connected) {
        connected = true;
        console.log("[TabFlick] 已连接 helper");
        // 附带扩展版本：helper 核对 major.minor 配套，不一致会提示用户更新扩展
        send({ type: "requestSettings", extVersion: chrome.runtime.getManifest().version });
        pushMRU();
        chrome.tabs
          .query({ active: true, lastFocusedWindow: true })
          .then(([tab]) => { if (tab) scheduleThumbnail(tab.id, tab.windowId); });
      }
      break;
    case "ws-close":
      connected = false;
      console.log("[TabFlick] 连接断开");
      break;
    case "ws-message":
      helperQueue = helperQueue
        .then(() => handleHelperMessage(message.data))
        .catch(() => {});
      break;
  }
});

// ── 事件挂载 ────────────────────────────────────────────────────────────

chrome.tabs.onActivated.addListener(({ tabId, windowId }) => {
  connect();          // 顺带做一次连接自愈
  touchTab(tabId);
  scheduleThumbnail(tabId, windowId);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  forgetTab(tabId);
});

// 切换浏览器窗口时，那个窗口的当前标签页才是「最近使用」的
chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  if (!tab) return;
  await touchTab(tab.id);
  scheduleThumbnail(tab.id, windowId);
});

// 标题 / favicon 变了要让 overlay 显示最新的。走节流版：这是全场最吵的事件。
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.title || changeInfo.favIconUrl) schedulePush();
  // 置顶状态变化也要刷新推送 —— 切换器卡片的星标跟着它走
  if (changeInfo.pinned !== undefined) schedulePush();

  // 用户主动取消置顶（⌘W 关闭走的是 onRemoved，不会触发这里）。
  // 是否命中收藏由 helper 判定（绑定优先、域名兜底）—— 收藏的事实源
  // 在 app，SW 重启后本地副本可能还是空的。我们自己发的 unpin 命令也会
  // 走到这里，但那时收藏已被移除，helper 查无此项、不会成环。
  //
  // ⚠️ 必须延迟核实：窗口/浏览器关闭的 teardown 也会给置顶标签发一次
  // pinned:false（实测：上报后 33ms 连接就断了，收藏被误删）。400ms 后
  // 标签还活着且仍未置顶，才算用户主动取消；标签没了就是关闭，忽略。
  // 浏览器整体退出时 SW 一起死，这个回调根本不会跑 —— 天然安全。
  // 用户置顶了一个标签 → 收编进收藏列表（置顶 = 收藏）。
  // 自家 ensure 补的置顶（selfPinned 标记）跳过，防环。
  if (changeInfo.pinned === true) {
    if (selfPinned.has(tabId)) {
      selfPinned.delete(tabId);
    } else if ((tab?.url ?? "").startsWith("http")) {
      send({ type: "pinnedTab", tabId, url: tab.url, title: tab?.title ?? "",
             favIconUrl: tab?.favIconUrl ?? "" });
    }
  }

  if (changeInfo.pinned === false) {
    if (selfUnpinned.has(tabId)) {
      // 自家 unpin 命令的回声，不当作用户动作
      selfUnpinned.delete(tabId);
      return;
    }
    const fallbackHost = hostOf(tab?.url ?? "") ?? "";
    setTimeout(async () => {
      try {
        const live = await chrome.tabs.get(tabId);
        if (!live.pinned) {
          send({ type: "unpinned", host: hostOf(live.url ?? "") ?? fallbackHost, tabId });
        }
      } catch {
        // 标签已不存在 —— 是关闭不是取消置顶
      }
    }, 400);
  }
});

// 标签页被拖到别的窗口 —— 按窗口过滤时列表内容会变。
// tabId 不变，所以 mru 里的历史position 自动跟着走，不用特殊处理。
chrome.tabs.onAttached.addListener(() => pushMRU());
chrome.tabs.onDetached.addListener(() => pushMRU());

// 工具栏图标点击 → 让 app 打开它的原生设置窗口。
// 设置只有一个入口，浏览器这边不再单开一个页面。
chrome.action.onClicked.addListener(() => {
  connect();
  send({ type: "openSettings" });
});

function ensureAlarms() {
  chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
  chrome.alarms.create(LIFETIME_ALARM, { periodInMinutes: LIFETIME_SWEEP_MINUTES });
}

chrome.runtime.onStartup.addListener(() => {
  startupSettleUntil = Date.now() + 2500;
  connect();
  ensureAlarms();
});
chrome.runtime.onInstalled.addListener(() => {
  connect();
  ensureAlarms();
});

// 兜底：helper 重启或连接意外断掉时，最多 30s 内恢复。
// 正常情况下连接由 helper 的定时 ping 维持，走不到这里。
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
  if (alarm.name === LIFETIME_ALARM) sweepExpiredTabs();
});

connect();
