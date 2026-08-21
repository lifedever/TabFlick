// 标签存活时间清理的回归测试。
//
// 为什么值得单独测：自动关标签是**不可逆**的破坏性动作，而它唯一的安全网
// 是一组过滤条件。条件里少一项、或者某个字段名写错，表现是「用户的标签
// 悄悄没了」——没有报错、没有崩溃，等发现时数据早就没了。
//
// 跑法：node extension/tests/lifetime-sweep.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// 把 background.js 装进一个带 chrome 桩的沙箱里跑起来。
/// 返回沙箱本身 —— 顶层的 function 声明会挂到它上面，可以直接调。
function loadExtension({ tabs, favorites, lifetimeHours, connected, favoritesKnown }) {
  const removed = [];
  const logs = [];
  const noopEvent = () => ({ addListener() {} });

  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    URL,
    Date,
    Promise,
    Set,
    Map,
    Array,
    JSON,
    self: { addEventListener() {} },
    WebSocket: function () {},
    chrome: {
      runtime: {
        onMessage: noopEvent(),
        onStartup: noopEvent(),
        onInstalled: noopEvent(),
        getManifest: () => ({ version: "0.0.0" }),
        getURL: (p) => p,
        sendMessage: async () => {},
        lastError: undefined,
      },
      tabs: {
        onActivated: noopEvent(),
        onRemoved: noopEvent(),
        onUpdated: noopEvent(),
        onAttached: noopEvent(),
        onDetached: noopEvent(),
        query: async () => tabs,
        remove: async (ids) => { removed.push(...[].concat(ids)); },
        get: async (id) => tabs.find((t) => t.id === id),
        update: async () => {},
        create: async () => ({ id: 999 }),
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: { session: { get: async () => ({}), set: async () => {} } },
      offscreen: { hasDocument: async () => true, createDocument: async () => {} },
    },
  };
  sandbox.globalThis = sandbox;

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SOURCE, "utf8"), sandbox, { filename: "background.js" });

  // 把被测状态摆到位。这些都是 background.js 的顶层 let/const，
  // 沙箱里能直接改（vm 的顶层 let 不挂 global，所以用一段脚本改）。
  vm.runInContext(
    `settings.tabLifetimeHours = ${lifetimeHours};
     settings.favorites = ${JSON.stringify(favorites)};
     connected = ${connected};
     favoritesKnown = ${favoritesKnown};
     send = (m) => { if (m && m.type === "log") __logs.push(m.message); };`,
    Object.assign(sandbox, { __logs: logs })
  );

  return { sandbox, removed, logs };
}

const HOUR = 3600 * 1000;
const now = Date.now();
const idle = (h) => now - h * HOUR;

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

async function run(title, setup, assert) {
  console.log(title);
  const ctx = loadExtension(setup);
  await vm.runInContext("sweepExpiredTabs()", ctx.sandbox);
  await new Promise((r) => setTimeout(r, 0));
  assert(ctx.removed, ctx.logs);
}

(async () => {
  // 基线：确实会清理超期的普通标签，否则下面的「没被清理」都是假通过
  await run(
    "超期的普通标签会被关闭（基线）",
    {
      tabs: [
        { id: 1, url: "https://a.com/", lastAccessed: idle(30), active: false, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: idle(1), active: false, pinned: false },
      ],
      favorites: [],
      lifetimeHours: 24,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("关掉闲置 30h 的", removed.includes(1));
      check("留下闲置 1h 的", !removed.includes(2), `removed=${removed}`);
    }
  );

  await run(
    "置顶标签永不被清理（主防线）",
    {
      tabs: [
        { id: 1, url: "https://mail.google.com/", lastAccessed: idle(500), active: false, pinned: true },
        { id: 2, url: "https://x.com/", lastAccessed: idle(500), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://mail.google.com/", currentUrl: "https://mail.google.com/" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("置顶的收藏标签还在", !removed.includes(1), `removed=${removed}`);
      check("同样超期的普通标签被清掉", removed.includes(2));
    }
  );

  await run(
    "收藏还没被置顶时，按域名兜住（第二道防线）",
    {
      // ensureFavorites 还没来得及补置顶 / 分支浏览器没照做 pinned
      tabs: [
        { id: 1, url: "https://notion.so/page", lastAccessed: idle(300), active: false, pinned: false },
        { id: 2, url: "https://x.com/", lastAccessed: idle(300), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://notion.so/", currentUrl: "https://notion.so/page" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("未置顶的收藏标签没被关掉", !removed.includes(1), `removed=${removed}`);
      check("无关的超期标签照常清理", removed.includes(2));
    }
  );

  await run(
    "收藏已正常置顶时，同域名的其他标签不获豁免（别搞无差别保护）",
    {
      tabs: [
        { id: 1, url: "https://github.com/me", lastAccessed: idle(300), active: false, pinned: true },
        { id: 2, url: "https://github.com/other", lastAccessed: idle(300), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://github.com/me", currentUrl: "https://github.com/me" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("置顶本尊留着", !removed.includes(1));
      check("同域名的闲置标签该清就清", removed.includes(2), `removed=${removed}`);
    }
  );

  await run(
    "收藏清单还没到（身份识别中）时一律不动手",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(300), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: false,
    },
    (removed) => check("一个都没关", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "helper 没连上时不清理",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(300), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 12,
      connected: false,
      favoritesKnown: true,
    },
    (removed) => check("一个都没关", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "存活时间为「永久」时不清理",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(9000), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 0,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => check("一个都没关", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "当前标签、出声的标签、分组内的标签都不动",
    {
      tabs: [
        { id: 1, url: "https://a.com/", lastAccessed: idle(300), active: true, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: idle(300), active: false, pinned: false, audible: true },
        { id: 3, url: "https://c.com/", lastAccessed: idle(300), active: false, pinned: false, groupId: 7 },
        { id: 4, url: "https://d.com/", lastAccessed: idle(300), active: false, pinned: false, groupId: -1 },
      ],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("active 保住", !removed.includes(1));
      check("audible 保住", !removed.includes(2));
      check("分组内保住", !removed.includes(3));
      check("其余照常清理", removed.includes(4), `removed=${removed}`);
    }
  );

  await run(
    "拿不到 lastAccessed 的标签一律不动（旧 Chrome / 新开未激活）",
    {
      tabs: [
        { id: 1, url: "https://a.com/", active: false, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: 0, active: false, pinned: false },
      ],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => check("一个都没关", removed.length === 0, `removed=${removed}`)
  );

  console.log(failures === 0 ? "\n全部通过" : `\n${failures} 项失败`);
  process.exit(failures === 0 ? 0 : 1);
})();
