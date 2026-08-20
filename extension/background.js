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
};

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
      break;
  }
}

// offscreen 转发上来的连接事件与数据
chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "sw") return;

  switch (message.type) {
    case "ws-open":
      if (!connected) {
        connected = true;
        console.log("[TabFlick] 已连接 helper");
        send({ type: "requestSettings" });
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
      handleHelperMessage(message.data);
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
chrome.tabs.onUpdated.addListener((_tabId, changeInfo) => {
  if (changeInfo.title || changeInfo.favIconUrl) schedulePush();
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

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(() => {
  connect();
  chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
});

// 兜底：helper 重启或连接意外断掉时，最多 30s 内恢复。
// 正常情况下连接由 helper 的定时 ping 维持，走不到这里。
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
});

connect();
