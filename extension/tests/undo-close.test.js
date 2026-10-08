// ⌘Z 恢复刚关闭的标签的回归测试。
//
// 两半各有各的静默失败：
//   · 网页脚本（undo-close.js）误报 —— 用户在输入框 / Figma 里按 ⌘Z 想撤销，
//     撤销照常发生，同时还多弹出来一个旧标签。不报错，只是让人莫名其妙
//   · 后台（background.js）挑错 —— 自动清理刚关了一批，⌘Z 恢复的是其中一个，
//     用户自己关的那个反而回不来
//
// 跑法：node extension/tests/undo-close.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const CONTENT_SOURCE = path.join(__dirname, "..", "undo-close.js");
const BACKGROUND_SOURCE = path.join(__dirname, "..", "background.js");

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

const tick = () => new Promise((r) => setTimeout(r, 5));

// ── 网页脚本 ─────────────────────────────────────────────────────────────

/// 一个够用的假页面：window 上的 keydown 监听按注册顺序跑（和浏览器一样），
/// 页面自己的监听可以在我们之后 preventDefault。
function loadPage() {
  const listeners = [];
  const messages = [];
  const el = (tagName, extra = {}) => ({ nodeType: 1, tagName, isContentEditable: false, ...extra });
  const body = el("BODY");
  const document = { activeElement: body, designMode: "off" };
  const runtime = {
    id: "ext",
    sendMessage: (m) => { messages.push(m); return Promise.resolve(); },
  };
  const window = {
    addEventListener(type, fn) { if (type === "keydown") listeners.push(fn); },
    removeEventListener(type, fn) {
      const i = listeners.indexOf(fn);
      if (type === "keydown" && i !== -1) listeners.splice(i, 1);
    },
  };
  const sandbox = { window, document, chrome: { runtime }, setTimeout, Set, String };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  const inject = () => vm.runInContext(fs.readFileSync(CONTENT_SOURCE, "utf8"), sandbox);
  inject();

  return {
    el,
    body,
    document,
    runtime,
    messages,
    listeners,
    inject,
    /// pageHandler：页面自己挂的监听（排在我们后面），可以 preventDefault
    async press(init = {}, pageHandler) {
      let prevented = false;
      const target = init.target ?? document.activeElement;
      const event = {
        isTrusted: true,
        repeat: false,
        isComposing: false,
        metaKey: true,
        ctrlKey: false,
        altKey: false,
        shiftKey: false,
        key: "z",
        code: "KeyZ",
        ...init,
        target,
        composedPath: () => [target],
        preventDefault() { prevented = true; },
        get defaultPrevented() { return prevented; },
      };
      for (const fn of [...listeners]) fn(event);
      if (pageHandler) pageHandler(event);
      await tick();
      return messages.length;
    },
  };
}

(async () => {
  {
    console.log("焦点在网页空白处按 ⌘Z → 报一声（基线）");
    const page = loadPage();
    await page.press();
    check("报了一次", page.messages.length === 1, `messages=${JSON.stringify(page.messages)}`);
    check("发给 SW 的 undoCloseTab", page.messages[0]?.target === "sw" && page.messages[0]?.type === "undoCloseTab");
  }

  {
    console.log("焦点在能输入的地方 → 不报（那是撤销输入）");
    for (const [name, focused] of [
      ["文本框", { tagName: "INPUT", type: "text" }],
      ["没写 type 的 input", { tagName: "INPUT" }],
      ["密码框", { tagName: "INPUT", type: "password" }],
      ["textarea", { tagName: "TEXTAREA" }],
      ["可编辑区域", { tagName: "DIV", isContentEditable: true }],
      ["内嵌页面", { tagName: "IFRAME" }],
    ]) {
      const page = loadPage();
      page.document.activeElement = page.el(focused.tagName, focused);
      await page.press();
      check(name, page.messages.length === 0, `messages=${page.messages.length}`);
    }
  }

  {
    console.log("shadow DOM 里的输入框也认得出");
    const page = loadPage();
    const inner = page.el("INPUT", { type: "search" });
    const host = page.el("MY-SEARCH", { shadowRoot: { activeElement: inner } });
    page.document.activeElement = host;
    await page.press({ target: host });
    check("不报", page.messages.length === 0, `messages=${page.messages.length}`);
  }

  {
    console.log("焦点停在复选框、按钮上不算在输入");
    for (const type of ["checkbox", "submit"]) {
      const page = loadPage();
      page.document.activeElement = page.el("INPUT", { type });
      await page.press();
      check(type, page.messages.length === 1, `messages=${page.messages.length}`);
    }
    const page = loadPage();
    page.document.activeElement = page.el("BUTTON");
    await page.press();
    check("button", page.messages.length === 1, `messages=${page.messages.length}`);
  }

  {
    console.log("网页自己用了 ⌘Z（preventDefault）→ 不报");
    const page = loadPage();
    await page.press({}, (e) => e.preventDefault());
    check("不报", page.messages.length === 0, `messages=${page.messages.length}`);
  }

  {
    console.log("整页处于编辑模式（designMode）→ 不报");
    const page = loadPage();
    page.document.designMode = "on";
    await page.press();
    check("不报", page.messages.length === 0, `messages=${page.messages.length}`);
  }

  {
    console.log("不是用户真按的 / 连发 / 组字中 → 不报");
    for (const [name, init] of [
      ["网页脚本伪造的按键", { isTrusted: false }],
      ["按住不放的连发", { repeat: true }],
      ["输入法组字中", { isComposing: true }],
    ]) {
      const page = loadPage();
      await page.press(init);
      check(name, page.messages.length === 0, `messages=${page.messages.length}`);
    }
  }

  {
    console.log("只认 ⌘Z 本身");
    for (const [name, init, expected] of [
      ["⇧⌘Z（重做）", { shiftKey: true }, 0],
      ["⌃Z", { metaKey: false, ctrlKey: true }, 0],
      ["⌥⌘Z", { altKey: true }, 0],
      ["⌘X", { key: "x", code: "KeyX" }, 0],
      ["大写锁定时的 ⌘Z", { key: "Z" }, 1],
      ["俄语布局（key 是本地字符，看物理键位）", { key: "я", code: "KeyZ" }, 1],
      ["Dvorak 布局的 Z（物理键位在别处）", { key: "z", code: "Slash" }, 1],
      ["Dvorak 布局按到 QWERTY 的 Z 位（那是分号）", { key: ";", code: "KeyZ" }, 0],
    ]) {
      const page = loadPage();
      await page.press(init);
      check(name, page.messages.length === expected, `messages=${page.messages.length}`);
    }
  }

  {
    console.log("同一页面注入两次（更新扩展后补注入）→ 一次按键只报一次");
    const page = loadPage();
    page.inject();
    await page.press();
    check("只报一次", page.messages.length === 1, `messages=${page.messages.length}`);
    check("只留一个监听", page.listeners.length === 1, `listeners=${page.listeners.length}`);
  }

  {
    console.log("扩展被更新 / 卸载后留在页面上的旧脚本 → 不报、不抛错、自己摘掉");
    const page = loadPage();
    page.runtime.id = undefined;
    let threw = null;
    try { await page.press(); } catch (e) { threw = e; }
    check("没抛错", threw === null, String(threw));
    check("不报", page.messages.length === 0, `messages=${page.messages.length}`);
    check("监听摘掉了", page.listeners.length === 0, `listeners=${page.listeners.length}`);
  }

  // ── 后台：恢复哪一个 ──────────────────────────────────────────────────

  const NOW_S = Math.floor(Date.now() / 1000);

  function loadBackground({ tabs = [], recent = [], local = {}, offscreenOpen = true, connectedFlag = true, lifetimeHours = 0 } = {}) {
    const sent = [];
    const toHelper = [];
    const restored = [];
    const removed = [];
    let nextLiveId = 5000;
    const sessionStorage = {};
    const localStorage = { ...local };
    const noopEvent = () => ({ addListener() {} });
    let onMessage = null;
    let onRemoved = null;
    const liveTabs = tabs.map((t) => ({ ...t }));
    // Chrome 的最近关闭：新的在前，restore 之后那条就没了
    const closed = recent.map((e) => ({ ...e }));

    const storageArea = (store) => ({
      get: async (keys) => {
        const out = {};
        for (const k of [].concat(keys)) if (k in store) out[k] = store[k];
        return out;
      },
      set: async (obj) => { Object.assign(store, obj); },
    });

    const sandbox = {
      console, setTimeout, clearTimeout, URL, Date, Promise, Set, Map, Array, Object, JSON, Math,
      self: { addEventListener() {} },
      WebSocket: function () {},
      chrome: {
        runtime: {
          id: "ext",
          onMessage: { addListener(fn) { onMessage = fn; } },
          onStartup: noopEvent(),
          onInstalled: noopEvent(),
          getManifest: () => ({ version: "0.0.0" }),
          getURL: (p) => p,
          sendMessage: async (m) => {
            if (m?.target === "offscreen" && m.type === "ws-state") return { open: offscreenOpen };
            if (m?.target === "offscreen" && m.type === "ws-send") toHelper.push(JSON.parse(m.data));
          },
        },
        tabs: {
          onActivated: noopEvent(),
          onRemoved: { addListener(fn) { onRemoved = fn; } },
          onUpdated: noopEvent(),
          onAttached: noopEvent(),
          onDetached: noopEvent(),
          query: async () => liveTabs.filter((t) => !t.__gone),
          remove: async (ids) => {
            for (const id of [].concat(ids)) {
              removed.push(id);
              const t = liveTabs.find((x) => x.id === id);
              if (t) {
                t.__gone = true;
                closed.unshift({ lastModified: Math.floor(Date.now() / 1000), tab: { url: t.url, sessionId: `s-${id}` } });
              }
              if (onRemoved) await onRemoved(id, { isWindowClosing: false });
            }
          },
          get: async (id) => liveTabs.find((t) => t.id === id && !t.__gone),
          update: async () => {},
          create: async () => ({ id: 999, windowId: 1 }),
        },
        sessions: {
          getRecentlyClosed: async () => closed.map((e) => ({ ...e })),
          // 实测（Chrome for Testing 148）：返回恢复出来的活标签 / 窗口，带新 id，固定状态保留
          restore: async (sessionId) => {
            restored.push(sessionId);
            const i = closed.findIndex((e) => (e.tab ?? e.window)?.sessionId === sessionId);
            if (i === -1) throw new Error(`no session ${sessionId}`);
            const [entry] = closed.splice(i, 1);
            const live = (t) => ({ ...t, id: nextLiveId++, sessionId: undefined });
            return entry.tab
              ? { lastModified: entry.lastModified, tab: live(entry.tab) }
              : { lastModified: entry.lastModified, window: { ...entry.window, tabs: (entry.window.tabs ?? []).map(live) } };
          },
        },
        windows: { onFocusChanged: noopEvent(), update: async () => {} },
        action: { onClicked: noopEvent() },
        alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
        storage: { session: storageArea(sessionStorage), local: storageArea(localStorage) },
        offscreen: { hasDocument: async () => true, createDocument: async () => {} },
      },
    };
    sandbox.globalThis = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(fs.readFileSync(BACKGROUND_SOURCE, "utf8"), sandbox, { filename: "background.js" });
    vm.runInContext(
      `connected = ${connectedFlag};
       favoritesKnown = true;
       settings.tabLifetimeHours = ${lifetimeHours};
       settings.favorites = [];
       send = (m) => { __sent.push(m); };`,
      Object.assign(sandbox, { __sent: sent }),
    );

    return {
      sent,
      /// 经 offscreen 发给 helper 的（⌘Z 的结果走这条，不走 send）
      undoReports: () => toHelper.filter((m) => m.type === "undoClosed"),
      pinReports: () => toHelper.filter((m) => m.type === "pinnedTab"),
      restored,
      removed,
      localStorage,
      run: (code) => vm.runInContext(code, sandbox),
      /// 模拟网页脚本发来的消息
      fromPage: (message, tab = { id: 1, incognito: false }) =>
        onMessage({ target: "sw", ...message }, { tab, id: "ext" }),
      settle: async () => { await tick(); await vm.runInContext("undoQueue", sandbox); await tick(); },
    };
  }

  {
    console.log("挑选：跳过自动关掉的，恢复用户自己关的");
    const ctx = loadBackground();
    const at = NOW_S * 1000;
    const pick = ctx.run(`pickUndoTarget(${JSON.stringify([
      { lastModified: NOW_S, tab: { url: "https://swept.example/", sessionId: "auto" } },
      { lastModified: NOW_S - 60, tab: { url: "https://mine.example/", sessionId: "mine" } },
    ])}, ${JSON.stringify([{ url: "https://swept.example/", at }])})`);
    check("挑到用户关的", pick?.tab?.sessionId === "mine", `pick=${JSON.stringify(pick)}`);
  }

  {
    console.log("挑选：登记的一笔只抵一条（同网址关过两个，只有一个是自动关的）");
    const ctx = loadBackground();
    const at = NOW_S * 1000;
    const pick = ctx.run(`pickUndoTarget(${JSON.stringify([
      { lastModified: NOW_S, tab: { url: "https://dup.example/", sessionId: "first" } },
      { lastModified: NOW_S, tab: { url: "https://dup.example/", sessionId: "second" } },
    ])}, ${JSON.stringify([{ url: "https://dup.example/", at }])})`);
    check("第二条照样恢复", pick?.tab?.sessionId === "second", `pick=${JSON.stringify(pick)}`);
  }

  {
    console.log("挑选：同网址但时间对不上的不算自动关的");
    const ctx = loadBackground();
    const pick = ctx.run(`pickUndoTarget(${JSON.stringify([
      { lastModified: NOW_S, tab: { url: "https://a.example/", sessionId: "now" } },
    ])}, ${JSON.stringify([{ url: "https://a.example/", at: (NOW_S - 3600) * 1000 }])})`);
    check("照样恢复", pick?.tab?.sessionId === "now", `pick=${JSON.stringify(pick)}`);
  }

  {
    console.log("挑选：最近关的是整个窗口 → 恢复窗口；恢复不了的类型 → 不越过它");
    const ctx = loadBackground();
    const win = ctx.run(`pickUndoTarget(${JSON.stringify([
      { lastModified: NOW_S, window: { sessionId: "w1", tabs: [] } },
      { lastModified: NOW_S - 5, tab: { url: "https://older.example/", sessionId: "older" } },
    ])}, [])`);
    check("恢复窗口", win?.window?.sessionId === "w1", `pick=${JSON.stringify(win)}`);
    const unknown = ctx.run(`pickUndoTarget(${JSON.stringify([
      { lastModified: NOW_S },
      { lastModified: NOW_S - 5, tab: { url: "https://older.example/", sessionId: "older" } },
    ])}, [])`);
    check("什么都不恢复", unknown === null, `pick=${unknown}`);
  }

  {
    console.log("整条链路：自动清理关了一批之后按 ⌘Z，回来的是用户自己关的");
    const HOUR = 3600 * 1000;
    const ctx = loadBackground({
      tabs: [
        { id: 1, url: "https://keep.example/", active: true, lastAccessed: Date.now() },
        ...[2, 3, 4].map((id) => ({ id, url: `https://idle${id}.example/`, lastAccessed: Date.now() - 300 * HOUR })),
      ],
      recent: [{ lastModified: NOW_S - 120, tab: { url: "https://mine.example/", sessionId: "mine" } }],
      lifetimeHours: 12,
    });
    await ctx.run("sweepExpiredTabs()");
    check("清理确实关了 3 个", ctx.removed.length === 3, `removed=${ctx.removed}`);
    ctx.fromPage({ type: "undoCloseTab" });
    await ctx.settle();
    check("恢复的是用户关的", ctx.restored.length === 1 && ctx.restored[0] === "mine", `restored=${ctx.restored}`);
  }

  {
    console.log("连按两下 ⌘Z → 依次恢复两条，不是同一条恢复两遍");
    const ctx = loadBackground({
      recent: [
        { lastModified: NOW_S, tab: { url: "https://b.example/", sessionId: "b" } },
        { lastModified: NOW_S - 10, tab: { url: "https://a.example/", sessionId: "a" } },
      ],
    });
    ctx.fromPage({ type: "undoCloseTab" });
    ctx.fromPage({ type: "undoCloseTab" });
    await ctx.settle();
    check("先 b 后 a", ctx.restored.join(",") === "b,a", `restored=${ctx.restored}`);
  }

  {
    console.log("开关关掉 / 无痕标签里 / TabFlick 没在运行 → 不恢复");
    const recent = [{ lastModified: NOW_S, tab: { url: "https://a.example/", sessionId: "a" } }];

    const off = loadBackground({ recent, local: { undoCloseTab: false } });
    off.fromPage({ type: "undoCloseTab" });
    await off.settle();
    check("开关关掉", off.restored.length === 0, `restored=${off.restored}`);

    const incognito = loadBackground({ recent });
    incognito.fromPage({ type: "undoCloseTab" }, { id: 1, incognito: true });
    await incognito.settle();
    check("无痕标签里", incognito.restored.length === 0, `restored=${incognito.restored}`);

    const gone = loadBackground({ recent, connectedFlag: false, offscreenOpen: false });
    gone.fromPage({ type: "undoCloseTab" });
    await gone.settle();
    check("TabFlick 没在运行", gone.restored.length === 0, `restored=${gone.restored}`);

    // SW 刚被按键唤醒：内存里还没连上的标记，但 offscreen 那边连着
    const woke = loadBackground({ recent, connectedFlag: false, offscreenOpen: true });
    woke.fromPage({ type: "undoCloseTab" });
    await woke.settle();
    check("SW 刚醒、offscreen 连着 → 照常恢复", woke.restored.join(",") === "a", `restored=${woke.restored}`);
  }

  {
    console.log("结果报给 helper 弹 toast：恢复了什么 / 没东西可恢复");
    const tabCtx = loadBackground({
      recent: [{ lastModified: NOW_S, tab: { url: "https://a.example/", title: "Alpha", sessionId: "a" } }],
    });
    tabCtx.fromPage({ type: "undoCloseTab" });
    await tabCtx.settle();
    const r1 = tabCtx.undoReports();
    check("标签：报了一条，带标题", r1.length === 1 && r1[0].restored === true && r1[0].kind === "tab" && r1[0].title === "Alpha",
      JSON.stringify(r1));

    const winCtx = loadBackground({
      recent: [{ lastModified: NOW_S, window: { sessionId: "w", tabs: [
        { url: "https://x.example/", title: "X", active: false },
        { url: "https://y.example/", title: "Y", active: true },
      ] } }],
    });
    winCtx.fromPage({ type: "undoCloseTab" });
    await winCtx.settle();
    const r2 = winCtx.undoReports();
    check("窗口：标题取当时正在看的那个标签", r2.length === 1 && r2[0].kind === "window" && r2[0].title === "Y", JSON.stringify(r2));

    const emptyCtx = loadBackground({ recent: [] });
    emptyCtx.fromPage({ type: "undoCloseTab" });
    await emptyCtx.settle();
    const r3 = emptyCtx.undoReports();
    check("没东西可恢复：也报一声", r3.length === 1 && r3[0].restored === false, JSON.stringify(r3));

    // SW 刚被按键唤醒、内存里还没连上的标记：走 send 的话这条会被丢掉，toast 就没了
    const woke = loadBackground({
      recent: [{ lastModified: NOW_S, tab: { url: "https://a.example/", title: "Alpha", sessionId: "a" } }],
      connectedFlag: false,
      offscreenOpen: true,
    });
    woke.fromPage({ type: "undoCloseTab" });
    await woke.settle();
    check("SW 刚醒时照样报出去", woke.undoReports().length === 1, JSON.stringify(woke.undoReports()));

    const off = loadBackground({ recent: [], local: { undoCloseTab: false } });
    off.fromPage({ type: "undoCloseTab" });
    await off.settle();
    check("开关关掉时不报（功能关着，不该有任何回响）", off.undoReports().length === 0, JSON.stringify(off.undoReports()));
  }

  {
    console.log("恢复回来的固定标签报给 helper，把置顶记回来");
    const pinned = loadBackground({
      recent: [{ lastModified: NOW_S, tab: { url: "https://mail.example/inbox", title: "Mail", favIconUrl: "https://mail.example/f.ico", pinned: true, sessionId: "p" } }],
    });
    pinned.fromPage({ type: "undoCloseTab" });
    await pinned.settle();
    const p1 = pinned.pinReports();
    check("固定标签：报了一条，带新标签的 id", p1.length === 1 && p1[0].tabId === 5000 && p1[0].url === "https://mail.example/inbox"
      && p1[0].title === "Mail" && p1[0].favIconUrl === "https://mail.example/f.ico", JSON.stringify(p1));

    const plain = loadBackground({
      recent: [{ lastModified: NOW_S, tab: { url: "https://a.example/", title: "A", pinned: false, sessionId: "a" } }],
    });
    plain.fromPage({ type: "undoCloseTab" });
    await plain.settle();
    check("普通标签：不报", plain.pinReports().length === 0, JSON.stringify(plain.pinReports()));

    const win = loadBackground({
      recent: [{ lastModified: NOW_S, window: { sessionId: "w", tabs: [
        { url: "https://pin.example/", title: "Pin", pinned: true, active: false },
        { url: "https://plain.example/", title: "Plain", pinned: false, active: true },
      ] } }],
    });
    win.fromPage({ type: "undoCloseTab" });
    await win.settle();
    const p3 = win.pinReports();
    check("窗口：只报里面固定的那个", p3.length === 1 && p3[0].url === "https://pin.example/", JSON.stringify(p3));
  }

  {
    console.log("helper 推来的开关落到 storage.local（SW 回收后还在）");
    const ctx = loadBackground();
    await ctx.run(`handleHelperMessage(JSON.stringify({ type: "settings", undoCloseTab: false }))`);
    check("存下来了", ctx.localStorage.undoCloseTab === false, `local=${JSON.stringify(ctx.localStorage)}`);
  }

  {
    console.log("网页发来的别的消息一律不认（网页环境不可信）");
    const ctx = loadBackground({ tabs: [{ id: 7, url: "https://victim.example/" }] });
    ctx.fromPage({ type: "ws-message", data: JSON.stringify({ type: "close", tabId: 7 }) });
    await tick();
    await ctx.run("helperQueue");
    await tick();
    check("没有关标签", ctx.removed.length === 0, `removed=${ctx.removed}`);
  }

  console.log(failures === 0 ? "\n全部通过" : `\n${failures} 项失败`);
  process.exit(failures === 0 ? 0 : 1);
})();
