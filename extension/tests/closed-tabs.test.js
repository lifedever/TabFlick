// 已关闭标签存档的回归测试。
//
// 为什么值得单独测：这条链路上每一个错误都是**静默**的。
//   · 无痕标签漏进存档 —— 不报错，一份无痕浏览记录就这么落到了磁盘上
//   · 关闭原因判错     —— 不报错，用户只是看到「自动」和「手动」贴反了
//   · 元信息取不到     —— 不报错，列表里悄悄少几条
// 而它依赖的两个前提都很脆：onRemoved 拿不到任何元信息（只能靠影子副本），
// 以及「自己动手前先打标记」必须严格发生在 tabs.remove 之前。
//
// 跑法：node extension/tests/closed-tabs.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// 把 background.js 装进带 chrome 桩的沙箱里。
///
/// 和 lifetime-sweep 那份的关键区别：这里必须捕获 onRemoved 的 listener，
/// 并且让 tabs.remove 的桩真的去触发它 —— 「标记是否早于 remove」正是
/// 本文件要验证的东西，桩里省掉这一步的话 lifetime / switcher 两个用例
/// 会双双假通过。
function loadExtension({ tabs, sessionStorage = {}, lifetimeHours = 0 }) {
  const sent = [];
  const logs = [];
  const removed = [];
  const created = [];
  const noopEvent = () => ({ addListener() {} });
  let onRemovedListener = null;

  const liveTabs = tabs.map((t) => ({ ...t }));

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
    Object,
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
        onRemoved: { addListener(fn) { onRemovedListener = fn; } },
        onUpdated: noopEvent(),
        onAttached: noopEvent(),
        onDetached: noopEvent(),
        query: async () => liveTabs.filter((t) => !t.__gone),
        remove: async (ids) => {
          const list = [].concat(ids);
          removed.push(...list);
          for (const id of list) {
            const tab = liveTabs.find((t) => t.id === id);
            if (tab) tab.__gone = true;
            // Chrome 真实行为：remove 之后 onRemoved 才触发，而那时标签
            // 已经查不到了。这正是影子副本存在的理由。
            if (onRemovedListener) await onRemovedListener(id, { isWindowClosing: false });
          }
        },
        get: async (id) => {
          const tab = liveTabs.find((t) => t.id === id && !t.__gone);
          if (!tab) throw new Error(`No tab with id: ${id}`);
          return tab;
        },
        update: async () => {},
        create: async (opts) => { created.push(opts); return { id: 999, windowId: 1 }; },
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: {
        session: {
          get: async (keys) => {
            const out = {};
            for (const k of [].concat(keys)) {
              if (k in sessionStorage) out[k] = sessionStorage[k];
            }
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
     favoritesKnown = true;
     settings.tabLifetimeHours = ${lifetimeHours};
     settings.favorites = [];
     send = (m) => { __sent.push(m); if (m && m.type === "log") __logs.push(m.message); };`,
    Object.assign(sandbox, { __sent: sent, __logs: logs })
  );

  return {
    sandbox,
    sent,
    logs,
    removed,
    created,
    /// 收集到的关闭存档（跨所有批次拍平）
    archived: () => sent.filter((m) => m.type === "tabsClosed").flatMap((m) => m.tabs),
    batches: () => sent.filter((m) => m.type === "tabsClosed"),
    fireRemoved: (id, removeInfo) => {
      const tab = liveTabs.find((t) => t.id === id);
      if (tab) tab.__gone = true;
      return onRemovedListener(id, removeInfo ?? { isWindowClosing: false });
    },
    run: (code) => vm.runInContext(code, sandbox),
  };
}

const HOUR = 3600 * 1000;
const now = Date.now();
const idle = (h) => now - h * HOUR;

/// 等 flushClosed 的 120ms debounce 到点。顺带把「合并」这个行为也测进去 ——
/// 直接调 flushClosed() 会跳过 debounce，那样批次数就永远是对的。
const settle = () => new Promise((r) => setTimeout(r, 200));

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

const tab = (id, url, extra = {}) => ({
  id,
  url,
  windowId: 1,
  title: `T${id}`,
  favIconUrl: `${url}favicon.ico`,
  lastAccessed: now,
  active: false,
  pinned: false,
  ...extra,
});

(async () => {
  // ── 基线 ────────────────────────────────────────────────────────────
  {
    console.log("手动关闭的标签会连元信息一起存档（基线）");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.com/"), tab(2, "https://b.com/")] });
    await ctx.run("pushMRU()");          // 建立影子副本
    await ctx.fireRemoved(1);
    await settle();

    const archived = ctx.archived();
    check("记了一条", archived.length === 1, `archived=${JSON.stringify(archived)}`);
    check("URL 对得上", archived[0]?.url === "https://a.com/");
    check("标题从影子副本里取到了", archived[0]?.title === "T1", `title=${archived[0]?.title}`);
    check("favicon 也带上了", archived[0]?.favIconUrl === "https://a.com/favicon.ico");
    check("原因是手动", archived[0]?.reason === "manual", `reason=${archived[0]?.reason}`);
  }

  // ── 隐私红线 ────────────────────────────────────────────────────────
  {
    console.log("无痕标签绝不进存档");
    const ctx = loadExtension({
      tabs: [
        tab(1, "https://secret.example/", { incognito: true }),
        tab(2, "https://ordinary.example/"),
      ],
    });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1);
    await ctx.fireRemoved(2);
    await settle();

    const archived = ctx.archived();
    // 不只查解析出来的 archived，连整批消息的原文都扫一遍 —— 免得哪天
    // 存档 payload 多带一个字段又把它捎出去。
    //
    // 范围只到存档消息：pushMRU 推给 helper 的**实时**列表里确实会有无痕
    // 标签（用户在 chrome://extensions 开了「在无痕模式下启用」的话），
    // 那是本功能之前就有的行为。这份测试守的是「不落盘」这条线。
    const wire = JSON.stringify(ctx.batches());
    check("无痕的那条没被存档", !archived.some((t) => t.url.includes("secret.example")),
          `archived=${JSON.stringify(archived)}`);
    check("存档消息原文里也没有它", !wire.includes("secret.example"));
    check("同批的普通标签照常存档", archived.some((t) => t.url.includes("ordinary.example")));
  }

  {
    console.log("chrome:// 和扩展页不进存档（找回它们没有意义）");
    const ctx = loadExtension({
      tabs: [tab(1, "chrome://extensions/"), tab(2, "https://ok.example/")],
    });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1);
    await ctx.fireRemoved(2);
    await settle();

    const archived = ctx.archived();
    check("chrome:// 被滤掉", !archived.some((t) => t.url.startsWith("chrome://")),
          `archived=${JSON.stringify(archived)}`);
    check("普通页面还在", archived.length === 1);
  }

  // ── 原因判定 ────────────────────────────────────────────────────────
  {
    console.log("自动清理关掉的标记为 lifetime");
    const ctx = loadExtension({
      tabs: [tab(1, "https://old.example/", { lastAccessed: idle(300) })],
      lifetimeHours: 12,
    });
    await ctx.run("pushMRU()");
    await ctx.run("sweepExpiredTabs()");
    await settle();

    const archived = ctx.archived();
    check("确实关了", ctx.removed.includes(1));
    check("原因是 lifetime", archived[0]?.reason === "lifetime",
          `reason=${archived[0]?.reason}`);
  }

  {
    console.log("切换器 ✕ 关掉的标记为 switcher");
    const ctx = loadExtension({ tabs: [tab(1, "https://x.example/"), tab(2, "https://y.example/")] });
    await ctx.run("pushMRU()");
    await ctx.run(`handleHelperMessage(JSON.stringify({ type: "close", tabId: 1 }))`);
    await settle();

    const archived = ctx.archived();
    check("原因是 switcher", archived[0]?.reason === "switcher",
          `reason=${archived[0]?.reason}`);
  }

  {
    console.log("关窗口连带的标记为 window");
    const ctx = loadExtension({ tabs: [tab(1, "https://w.example/")] });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1, { isWindowClosing: true });
    await settle();

    check("原因是 window", ctx.archived()[0]?.reason === "window",
          `reason=${ctx.archived()[0]?.reason}`);
  }

  // ── 影子副本 ────────────────────────────────────────────────────────
  {
    console.log("service worker 刚被 onRemoved 唤醒时，元信息从 storage.session 取");
    // 关键场景：SW 被回收后，内存里的 tabMeta 是空的，pushMRU 一次都没跑过。
    // 唯一的信息来源是上一轮存进 storage.session 的那份快照。
    const ctx = loadExtension({
      tabs: [],
      sessionStorage: {
        mru: [7],
        tabMeta: {
          7: { url: "https://revived.example/", title: "从存储里恢复的",
               favIconUrl: "https://revived.example/f.ico", incognito: false },
        },
      },
    });
    await ctx.fireRemoved(7);
    await settle();

    const archived = ctx.archived();
    check("照样存档了", archived.length === 1, `archived=${JSON.stringify(archived)}`);
    check("标题来自 storage 里的快照", archived[0]?.title === "从存储里恢复的");
  }

  {
    console.log("影子副本里查无此人时不塞空记录");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(4242);         // 从没被任何一轮 pushMRU 见过
    await settle();

    check("一条都没发", ctx.batches().length === 0,
          `sent=${JSON.stringify(ctx.batches())}`);
  }

  // ── 批量合并 ────────────────────────────────────────────────────────
  {
    console.log("一次关掉多个只发一条消息（自动清理能一口气关几百个）");
    const ctx = loadExtension({
      tabs: [1, 2, 3, 4, 5].map((i) => tab(i, `https://s${i}.example/`, { lastAccessed: idle(300) })),
      lifetimeHours: 12,
    });
    await ctx.run("pushMRU()");
    await ctx.run("sweepExpiredTabs()");
    await settle();

    check("合并成 1 批", ctx.batches().length === 1, `batches=${ctx.batches().length}`);
    check("5 条都在里面", ctx.archived().length === 5, `count=${ctx.archived().length}`);
  }

  // ── 找回 ────────────────────────────────────────────────────────────
  {
    console.log("helper 的 reopen 命令会新开标签");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run(
      `handleHelperMessage(JSON.stringify({ type: "reopen", url: "https://back.example/page" }))`
    );
    await settle();

    check("开了一个", ctx.created.length === 1, `created=${JSON.stringify(ctx.created)}`);
    check("地址对得上", ctx.created[0]?.url === "https://back.example/page");
  }

  {
    console.log("reopen 只认 http(s)（别让 helper 侧的坏数据变成任意 URL 打开）");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run(
      `handleHelperMessage(JSON.stringify({ type: "reopen", url: "javascript:alert(1)" }))`
    );
    await settle();

    check("没有开", ctx.created.length === 0, `created=${JSON.stringify(ctx.created)}`);
  }

  console.log(failures === 0 ? "\n全部通过" : `\n${failures} 项失败`);
  process.exit(failures === 0 ? 0 : 1);
})();
