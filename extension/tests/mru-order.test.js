// 扩展侧 MRU 的维护：
//   · ⌘点击开到后台的标签排在当前标签后面（MRU 第二位），⌃⇥ 按一下就到它
//   · SW 刚被唤醒时几个事件同时从 storage.session 读回 MRU，后读回来的不能盖掉先写进去的
//   · 推给 helper 的列表标出哪些标签在 MRU 里（没进过的位置没有意义，时间是创建时间）
//
// 为什么值得测：判错的两个方向都不报错。漏判 —— ⌃⇥ 照旧去上一个用过的标签，用户以为没生效；
// 错判 —— 会话恢复、自己补开的置顶、别处脚本开的标签被插到第二位，⌃⇥ 莫名其妙跳过去；
// 最糟的是 MRU 空着时把它插成第一个，切换器把它当成「当前标签」。
//
// 跑法：node extension/tests/mru-order.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// getDelays：第 n 次读 storage.session 晚多少毫秒返回。返回的是发出请求那一刻的值 ——
/// Chrome 里 get 先于 set 发出就读不到 set 写进去的东西。
function loadExtension({ tabs, sessionStorage = {}, loaded = true, getDelays = [] }) {
  const sent = [];
  const noopEvent = () => ({ addListener() {} });
  let onCreated = null;
  let onActivated = null;
  const liveTabs = tabs.map((t) => ({ ...t }));

  const sandbox = {
    console, setTimeout, clearTimeout, structuredClone, URL, Date, Promise, Set, Map, Array, Object, JSON,
    self: { addEventListener() {} },
    WebSocket: function () {},
    chrome: {
      runtime: {
        onMessage: noopEvent(), onStartup: noopEvent(), onInstalled: noopEvent(),
        getManifest: () => ({ version: "0.0.0" }),
        getURL: (p) => p,
        sendMessage: async () => {},
        lastError: undefined,
      },
      tabs: {
        onActivated: { addListener(fn) { onActivated = fn; } },
        onCreated: { addListener(fn) { onCreated = fn; } },
        onRemoved: noopEvent(), onUpdated: noopEvent(), onAttached: noopEvent(), onDetached: noopEvent(),
        query: async () => liveTabs,
        get: async (id) => liveTabs.find((t) => t.id === id),
        update: async () => {},
        remove: async () => {},
        create: async () => ({ id: 999, windowId: 1 }),
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: {
        local: { get: async () => ({}), set: async () => {}, remove: async () => {} },
        session: {
          get: async (keys) => {
            const out = {};
            for (const k of [].concat(keys)) if (k in sessionStorage) out[k] = structuredClone(sessionStorage[k]);
            const delay = getDelays.shift() ?? 0;
            if (delay > 0) await new Promise((r) => setTimeout(r, delay));
            return out;
          },
          set: async (obj) => { Object.assign(sessionStorage, obj); },
        },
      },
      offscreen: { hasDocument: async () => true, createDocument: async () => {} },
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SOURCE, "utf8"), sandbox, { filename: "background.js" });
  vm.runInContext(
    `connected = true;
     send = (m) => { __sent.push(m); };`,
    Object.assign(sandbox, { __sent: sent })
  );

  const run = (code) => vm.runInContext(code, sandbox);
  return {
    sessionStorage,
    run,
    /// 已在内存里的 MRU（loaded=false 模拟 SW 刚被唤醒、内存是空的，要从 storage.session 读回来）
    seed: (ids) => {
      sessionStorage.mru = ids;
      if (loaded) run(`mru = ${JSON.stringify(ids)}; mruLoaded = true;`);
    },
    mru: () => JSON.parse(run("JSON.stringify(mru)")),
    /// 最后一次推给 helper 的顺序 —— 切换器认的就是这个
    pushed: () => sent.filter((m) => m.type === "mru").at(-1)?.tabs.map((t) => t.id),
    lastPush: () => sent.filter((m) => m.type === "mru").at(-1)?.tabs ?? [],
    create: async (tab) => {
      liveTabs.push({ windowId: 1, title: "", url: "https://new.example/", ...tab });
      await onCreated({ windowId: 1, ...tab });
    },
    activate: async (id) => {
      for (const t of liveTabs) t.active = t.id === id;
      await onActivated({ tabId: id, windowId: 1 });
    },
  };
}

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const tab = (id, extra = {}) => ({
  id, windowId: 1, title: `T${id}`, url: `https://t${id}.example/`, active: false, pinned: false, ...extra,
});

(async () => {
  {
    console.log("当前标签 ⌘点击开出的后台标签排第二（用户报的那个场景）");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: false, openerTabId: 1 });
    check("MRU 里排在当前标签后面", same(ctx.mru(), [1, 2, 3]), `mru=${JSON.stringify(ctx.mru())}`);
    check("推给 helper 的顺序也是", same(ctx.pushed(), [1, 2, 3]), `pushed=${JSON.stringify(ctx.pushed())}`);
    check("写进了 storage.session（SW 回收后还在）", same(ctx.sessionStorage.mru, [1, 2, 3]),
          `stored=${JSON.stringify(ctx.sessionStorage.mru)}`);
  }

  {
    console.log("连开几个：后开的在前，切过去再切回来照常");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: false, openerTabId: 1 });
    await ctx.create({ id: 4, active: false, openerTabId: 1 });
    check("后开的排第二", same(ctx.mru(), [1, 4, 2, 3]), `mru=${JSON.stringify(ctx.mru())}`);
    await ctx.activate(4);
    check("切到它之后当前标签退到第二", same(ctx.mru(), [4, 1, 2, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    console.log("SW 刚被唤醒（内存空、storage 里有）也照样排");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)], loaded: false });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: false, openerTabId: 1 });
    check("从 storage 读回来再插", same(ctx.mru(), [1, 2, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    // SW 被 ⌘点击唤醒时，onCreated 和连上 helper 后的 pushMRU 会同时第一次读 storage。
    // 两次读到的都是旧的 [1, 3]，后回来的那份把插进去的 2 盖掉，再被 pushMRU 写回存档。
    console.log("SW 刚醒时插入和推送同时读存档，插入不能被盖掉");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)], loaded: false, getDelays: [0, 20] });
    ctx.seed([1, 3]);
    await Promise.all([ctx.create({ id: 2, active: false, openerTabId: 1 }), ctx.run("pushMRU()")]);
    await ctx.run("pushMRU()");
    check("内存里还在", same(ctx.mru(), [1, 2, 3]), `mru=${JSON.stringify(ctx.mru())}`);
    check("存档里还在", same(ctx.sessionStorage.mru, [1, 2, 3]),
          `stored=${JSON.stringify(ctx.sessionStorage.mru)}`);
    check("推出去的顺序对", same(ctx.pushed(), [1, 2, 3]), `pushed=${JSON.stringify(ctx.pushed())}`);
  }

  {
    console.log("读存档失败后下一次还会再读（不把失败缓存住）");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)], loaded: false });
    ctx.seed([1, 3]);
    ctx.run(`{ const real = chrome.storage.session.get; let n = 0;
               chrome.storage.session.get = async (k) => { if (n++ === 0) throw new Error("boom"); return real(k); }; }`);
    let threw = false;
    try { await ctx.run("loadMRU()"); } catch { threw = true; }
    await ctx.run("loadMRU()");
    check("第一次的错往上抛了", threw);
    check("第二次读到了", same(ctx.mru(), [1, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    console.log("推送里标出哪些标签在 MRU 里");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3), tab(5)] });
    ctx.seed([1, 3]);
    await ctx.run("pushMRU()");
    const flags = Object.fromEntries(ctx.lastPush().map((t) => [t.id, t.inMRU]));
    check("在 MRU 里的是 true", flags[1] === true && flags[3] === true, JSON.stringify(flags));
    check("没进过的是 false", flags[5] === false, JSON.stringify(flags));
  }

  {
    console.log("TabFlick 没连着时也记下来，连上后推出去的顺序是对的");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    ctx.run("connected = false;");
    await ctx.create({ id: 2, active: false, openerTabId: 1 });
    check("写进了 storage.session", same(ctx.sessionStorage.mru, [1, 2, 3]),
          `stored=${JSON.stringify(ctx.sessionStorage.mru)}`);
  }

  {
    console.log("前台打开的（⇧⌘点击、⌘T）不在这里插，交给激活事件");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: true, openerTabId: 1 });
    check("MRU 不动", same(ctx.mru(), [1, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    console.log("没有 opener 的后台标签（会话恢复、补开的置顶）照旧排末尾");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: false, pinned: true });
    check("MRU 不动", same(ctx.mru(), [1, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    console.log("opener 不是当前标签（别的后台标签里的脚本开的）不插");
    const ctx = loadExtension({ tabs: [tab(1, { active: true }), tab(3)] });
    ctx.seed([1, 3]);
    await ctx.create({ id: 2, active: false, openerTabId: 3 });
    check("MRU 不动", same(ctx.mru(), [1, 3]), `mru=${JSON.stringify(ctx.mru())}`);
  }

  {
    console.log("MRU 还空着（扩展刚重载）不插，免得它被当成当前标签");
    const ctx = loadExtension({ tabs: [tab(1, { active: true })] });
    ctx.seed([]);
    await ctx.create({ id: 2, active: false, openerTabId: 1 });
    check("MRU 仍是空的", same(ctx.mru(), []), `mru=${JSON.stringify(ctx.mru())}`);
  }

  console.log(failures === 0 ? "\n全部通过" : `\n${failures} 条失败`);
  process.exit(failures === 0 ? 0 : 1);
})();
