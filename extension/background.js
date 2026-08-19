// TabFlick Bridge — MV3 service worker
//
// 职责：
//   1. 维护全局标签页 MRU 顺序（最近使用的在前）
//   2. 通过本地 WebSocket 把 MRU 列表推给 Swift helper
//   3. 执行 helper 下发的切换指令
//
// MV3 的 service worker 会在 30s 空闲后被回收。Chrome 116+ 起，WebSocket 上的
// 收发活动会重置这个空闲计时器 —— 所以保活由 helper 端定时 ping 驱动，
// 我们只负责回 pong。alarms 只是断线后的兜底唤醒源。

const WS_URL = "ws://127.0.0.1:41573/";
const RECONNECT_ALARM = "tabflick-reconnect";
const STORAGE_KEY = "mru";

/// 用户可在扩展选项页调整。默认按窗口隔离：多窗口时把所有标签混在一张列表里，
/// 列表会长得没法用，切换还会把你甩到另一个窗口去。
const DEFAULT_SETTINGS = {
  scopeToWindow: true,
};

let ws = null;
let mru = [];          // tabId 数组，最近使用的在前，跨窗口全局维护
let mruLoaded = false;
let settings = { ...DEFAULT_SETTINGS };
let settingsLoaded = false;

async function loadSettings() {
  if (settingsLoaded) return;
  settings = { ...DEFAULT_SETTINGS, ...(await chrome.storage.sync.get(DEFAULT_SETTINGS)) };
  settingsLoaded = true;
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "sync") return;
  for (const [key, { newValue }] of Object.entries(changes)) {
    settings[key] = newValue;
  }
  pushMRU();
});

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
  if (ws?.readyState !== WebSocket.OPEN) return;
  await loadMRU();
  await loadSettings();

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

  let visible = allTabs;
  if (settings.scopeToWindow) {
    const windowId = await currentWindowId();
    if (windowId === undefined) return;
    visible = allTabs.filter((t) => t.windowId === windowId);
  }
  if (visible.length === 0) return;

  const byId = new Map(visible.map((t) => [t.id, t]));

  // 已知顺序优先；从没被激活过的标签页（后台打开的、恢复会话带回来的）排在末尾
  const known = mru.filter((id) => byId.has(id));
  const knownSet = new Set(known);
  const unknown = visible.filter((t) => !knownSet.has(t.id)).map((t) => t.id);

  send({
    type: "mru",
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
  if (ws?.readyState !== WebSocket.OPEN) return;
  try {
    const dataUrl = await chrome.tabs.captureVisibleTab(windowId, {
      format: "jpeg",
      quality: 70,
    });
    // 确认这期间用户没又切走 —— 否则会把 B 的截图挂到 A 名下
    const [current] = await chrome.tabs.query({ active: true, windowId });
    if (current?.id !== tabId) return;

    send({ type: "thumb", tabId, data: await downscale(dataUrl) });
  } catch {
    // chrome:// 页面、窗口被遮挡、超过频率限制 —— 都不是错误，跳过就好
  }
}

/// 原图是整个视口，直接传太大。按目标比例居中裁剪后缩到 400×250。
async function downscale(dataUrl) {
  const blob = await (await fetch(dataUrl)).blob();
  const bitmap = await createImageBitmap(blob);

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
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function connect() {
  if (ws?.readyState === WebSocket.OPEN || ws?.readyState === WebSocket.CONNECTING) return;

  try {
    ws = new WebSocket(WS_URL);
  } catch (e) {
    console.warn("[TabFlick] WebSocket 构造失败:", e);
    return;
  }

  ws.onopen = async () => {
    console.log("[TabFlick] 已连接 helper");
    pushMRU();
    // helper 刚起来时它的缩略图缓存是空的，先补上当前这张，
    // 剩下的靠用户后续切换自然攒。
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (tab) scheduleThumbnail(tab.id, tab.windowId);
  };

  ws.onmessage = async (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;   // 不是我们的协议，忽略
    }
    switch (msg.type) {
      case "switch":
        if (typeof msg.tabId === "number") await activateTab(msg.tabId);
        break;
      case "ping":
        // 回 pong 本身就是「活动」，同时重置了 SW 的空闲计时器
        send({ type: "pong" });
        break;
      case "requestMRU":
        await pushMRU();
        break;
    }
  };

  ws.onclose = () => {
    console.log("[TabFlick] 连接断开");
    ws = null;
  };

  ws.onerror = () => {
    // helper 没启动时每次重连都会走到这里，不刷日志
    ws = null;
  };
}

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

// 工具栏图标点击直接开设置页。options_ui 的入口埋在 chrome://extensions
// 的详情页里，太深了没人找得到。
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());

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
