// TabFlick — offscreen document
//
// 只做一件事：维持到 helper 的 WebSocket 连接，并在它和 service worker 之间
// 转发消息。
//
// 为什么需要这一层：MV3 的 service worker 空闲 30 秒就被回收，被回收之后
// 它无法主动重连 —— 只能等某个浏览器事件把它唤醒。于是「先开 app 再按 ⌃⇥」
// 的第一次必然落空（用户实测：第一次没反应，第二次才正常，因为第一次
// 放行给 Chrome 的切换恰好触发了 tabs.onActivated，把 SW 叫醒了）。
//
// offscreen document 不受那个生命周期约束，可以一直挂着连接；消息到达时
// 用 chrome.runtime.sendMessage 反过来唤醒 SW。

const WS_URL = "ws://127.0.0.1:41573/";

// 固定短间隔重试，不做指数退避。
//
// 退避是为了别把远端服务器敲坏，但这里是回环地址：helper 没起来时连接会
// 立刻收到 ECONNREFUSED，开销可以忽略。而退避的代价很实在 —— 用户打开
// app 后要等上好几秒才连上，这期间按 ⌃⇥ 会因为 gReady=false 被放行，
// 表现就是「第一次按没反应」。
const RETRY_MS = 700;

let ws = null;
let retryTimer = null;

// 诊断探针 + 降噪：夸克等分支浏览器会把未捕获的 promise 拒绝渲染成扩展
// 错误卡片，且归因粗糙（offscreen.html:0 匿名函数），从卡片上根本看不出
// 元凶。这里统一截获：完整堆栈经 WebSocket 写进 helper 日志（tabflick.log
// 里搜 "offscreen unhandled"），并 preventDefault 阻止浏览器再弹卡片。
self.addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  const reason = event.reason;
  const detail = (reason && (reason.stack || reason.message)) || String(reason);
  try {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "log", message: `offscreen unhandled rejection: ${detail}` }));
    }
  } catch {}
});

self.addEventListener("error", (event) => {
  try {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: "log",
        message: `offscreen error: ${event.message} @ ${event.filename}:${event.lineno}`,
      }));
    }
  } catch {}
});

function toWorker(message) {
  // SW 若已被回收，这条消息会把它唤醒。没有接收方时 sendMessage 会 reject，
  // 属正常情况（比如扩展正在卸载），吞掉即可。
  chrome.runtime.sendMessage({ target: "sw", ...message }).catch(() => {});
}

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  clearTimeout(retryTimer);
  try {
    ws = new WebSocket(WS_URL);
  } catch {
    scheduleRetry();
    return;
  }

  ws.onopen = () => {
    toWorker({ type: "ws-open" });
  };

  ws.onmessage = (event) => {
    toWorker({ type: "ws-message", data: event.data });
  };

  ws.onclose = () => {
    ws = null;
    toWorker({ type: "ws-close" });
    scheduleRetry();
  };

  ws.onerror = () => {
    // helper 没启动时每次重试都会走到这里，不刷日志。
    // 关闭逻辑统一交给 onclose。
    try { ws?.close(); } catch {}
  };
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, RETRY_MS);
}

// ── favicon（书签 / 历史行用）────────────────────────────────────────────
//
// Chrome 给扩展的 _favicon 接口在 service worker 里 fetch 拿到的永远是默认图
//（2026-09-26 实测：连刚访问过的站都是 0 hit），官方文档的用法是在扩展页面里
// 用 <img> 加载。offscreen 页就是扩展页面，在这里画到 canvas 取 PNG 字节。
// 没访问过的站 Chrome 会给默认地球图 —— 拿一个假地址取一次做比对，一样的报「缺」。

function faviconURL(pageUrl) {
  return chrome.runtime.getURL(`/_favicon/?pageUrl=${encodeURIComponent(pageUrl)}&size=32`);
}

async function faviconDataURL(pageUrl) {
  const img = new Image();
  // 用 load 事件 + 超时，不用 img.decode()：offscreen 页没有渲染机会时 decode 可能永远
  // 不落定，一个卡住整批都回不去（2026-09-27 helper 那边十几次请求零回包）。
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("favicon timeout")), 3000);
    img.onload = () => { clearTimeout(timer); resolve(); };
    img.onerror = () => { clearTimeout(timer); reject(new Error("favicon load failed")); };
    img.src = faviconURL(pageUrl);
  });
  const canvas = document.createElement("canvas");
  canvas.width = 32;
  canvas.height = 32;
  canvas.getContext("2d").drawImage(img, 0, 0, 32, 32);
  return canvas.toDataURL("image/png");
}

let defaultFavicon;
async function defaultFaviconDataURL() {
  if (defaultFavicon === undefined) {
    try {
      defaultFavicon = await faviconDataURL("http://tabflick-no-such-site.invalid/");
    } catch {
      defaultFavicon = null;
    }
  }
  return defaultFavicon;
}

async function handleFaviconQuery(items) {
  const fallback = await defaultFaviconDataURL();
  const hits = [];
  const missing = [];
  for (const { key, url } of (items ?? []).slice(0, 60)) {
    if (typeof key !== "string" || typeof url !== "string") continue;
    try {
      const dataURL = await faviconDataURL(url);
      if (dataURL && dataURL !== fallback) {
        hits.push({ key, data: dataURL.slice(dataURL.indexOf(",") + 1) });
      } else {
        missing.push(key);
      }
    } catch {
      missing.push(key);
    }
  }
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: "favicons", items: hits, missing }));
    ws.send(JSON.stringify({ type: "log", message: `favicons: ${hits.length} hit, ${missing.length} missing (default ${fallback ? "known" : "unknown"})` }));
  }
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "offscreen") return;

  if (message.type === "ws-send") {
    if (ws?.readyState === WebSocket.OPEN) ws.send(message.data);
  } else if (message.type === "favicon-query") {
    handleFaviconQuery(message.items);
  } else if (message.type === "ws-poke") {
    // SW 想确认连接还在
    if (ws?.readyState === WebSocket.OPEN) {
      toWorker({ type: "ws-open" });
    } else {
      connect();
    }
  }
});

connect();
