// 扩展跟着 app 自动更新：helper 换好文件夹后发 extensionFilesUpdated，扩展重载自己。
//
// 为什么值得测：
//   · 重载会清空 storage.session —— MRU 没接上的话，每次 app 更新 ⌃⇥ 的顺序都归零，不报错
//   · 防反复重载失效 —— helper 换的不是我们加载的那个文件夹时，扩展会每次连上就重载、
//     连上又重载，整个浏览器侧的功能时有时无
//
// 跑法：node extension/tests/self-update.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// local / session 两份存储从外面传进来：模拟「重载」= 用同一份 local、清空的 session 再装一次。
function loadExtension({ version = "1.0.0", local = {}, session = {}, tabs = [] } = {}) {
  const sent = [];
  let reloads = 0;
  const noopEvent = () => ({ addListener() {} });
  const area = (store) => ({
    get: async (keys) => {
      if (keys === null) return structuredClone(store);
      const out = {};
      for (const k of [].concat(keys)) if (k in store) out[k] = structuredClone(store[k]);
      return out;
    },
    set: async (obj) => { Object.assign(store, structuredClone(obj)); },
    remove: async (keys) => { for (const k of [].concat(keys)) delete store[k]; },
  });
  const sandbox = {
    console, setTimeout, clearTimeout, structuredClone, URL, Date, Promise, Set, Map, Array, Object, JSON, Number,
    self: { addEventListener() {} },
    WebSocket: function () {},
    chrome: {
      runtime: {
        onMessage: noopEvent(), onStartup: noopEvent(), onInstalled: noopEvent(),
        getManifest: () => ({ version }),
        getURL: (p) => p,
        sendMessage: async () => {},
        reload: () => { reloads += 1; },
        lastError: undefined,
      },
      tabs: {
        onActivated: noopEvent(), onCreated: noopEvent(), onRemoved: noopEvent(), onUpdated: noopEvent(),
        onAttached: noopEvent(), onDetached: noopEvent(),
        query: async () => tabs,
        get: async (id) => tabs.find((t) => t.id === id),
        update: async () => {}, remove: async () => {}, create: async () => ({ id: 999, windowId: 1 }),
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: { session: area(session), local: area(local) },
      offscreen: { hasDocument: async () => true, createDocument: async () => {} },
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SOURCE, "utf8"), sandbox, { filename: "background.js" });
  vm.runInContext(`connected = true; send = (m) => { __sent.push(m); };`, Object.assign(sandbox, { __sent: sent }));
  const run = (code) => vm.runInContext(code, sandbox);
  return {
    local, session, sent, run,
    reloads: () => reloads,
    mru: () => JSON.parse(run("JSON.stringify(mru)")),
    logs: () => sent.filter((m) => m.type === "log").map((m) => m.message),
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
const tab = (id) => ({ id, windowId: 1, title: `T${id}`, url: `https://t${id}.example/`, active: id === 1 });

(async () => {
  {
    console.log("helper 说有新版本：暂存 MRU 后重载，重载完接上");
    const local = {};
    const before = loadExtension({ version: "0.20.0", local, session: { mru: [1, 3, 2], tabMeta: { 1: { url: "u" } } } });
    await before.run(`handleHelperMessage(JSON.stringify({ type: "extensionFilesUpdated", version: "0.21.0" }))`);
    check("重载了一次", before.reloads() === 1, `reloads=${before.reloads()}`);
    check("MRU 暂存进了 storage.local", same(local.mruCarry?.mru, [1, 3, 2]), JSON.stringify(local.mruCarry));
    check("记下了这次重载的目标版本", local.selfReload?.version === "0.21.0", JSON.stringify(local.selfReload));

    // 重载 = 同一份 local、空的 session、新版本号
    const after = loadExtension({ version: "0.21.0", local, tabs: [tab(1), tab(2), tab(3)] });
    await after.run("loadMRU()");
    check("重载后 MRU 接上了", same(after.mru(), [1, 3, 2]), `mru=${JSON.stringify(after.mru())}`);
    check("写回了 storage.session（SW 再被回收也还在）", same(after.session.mru, [1, 3, 2]),
          JSON.stringify(after.session.mru));
    check("影子副本也接上了", after.run("tabMeta[1]?.url") === "u");
    check("暂存的那份用完就删", !("mruCarry" in local));
  }

  {
    console.log("版本不比自己新就不重载");
    for (const v of ["0.20.0", "0.19.9", "0.20"]) {
      const ctx = loadExtension({ version: "0.20.0" });
      await ctx.run(`reloadForUpdate(${JSON.stringify(v)})`);
      check(`${v} 不重载`, ctx.reloads() === 0);
    }
    const ctx = loadExtension({ version: "0.9.0" });
    await ctx.run(`reloadForUpdate("0.10.0")`);
    check("按数字比（0.10.0 比 0.9.0 新）", ctx.reloads() === 1);
  }

  {
    console.log("重载完还是旧版本（换的不是我们的文件夹）：10 分钟内不再重载");
    const local = { selfReload: { version: "0.21.0", at: Date.now() - 60 * 1000 } };
    const ctx = loadExtension({ version: "0.20.0", local });
    await ctx.run(`reloadForUpdate("0.21.0")`);
    check("没有重载", ctx.reloads() === 0);
    check("写了日志", ctx.logs().some((m) => m.includes("skipped")), JSON.stringify(ctx.logs()));

    const later = loadExtension({ version: "0.20.0", local: { selfReload: { version: "0.21.0", at: Date.now() - 11 * 60 * 1000 } } });
    await later.run(`reloadForUpdate("0.21.0")`);
    check("过了 10 分钟再试", later.reloads() === 1);

    const other = loadExtension({ version: "0.20.0", local: { selfReload: { version: "0.21.0", at: Date.now() } } });
    await other.run(`reloadForUpdate("0.22.0")`);
    check("目标换了新版本照样重载", other.reloads() === 1);
  }

  {
    console.log("暂存的 MRU 太久、坏掉的不接");
    const stale = loadExtension({ local: { mruCarry: { mru: [1, 2], tabMeta: {}, at: Date.now() - 3 * 60 * 1000 } } });
    await stale.run("loadMRU()");
    check("太久的不接", same(stale.mru(), []), JSON.stringify(stale.mru()));
    check("太久的也删掉", !("mruCarry" in stale.local));

    const broken = loadExtension({ local: { mruCarry: { mru: [1, "x"], at: Date.now() } } });
    await broken.run("loadMRU()");
    check("不是整数 id 的不接", same(broken.mru(), []), JSON.stringify(broken.mru()));
  }

  {
    console.log("普通的 SW 重启（session 还在）不碰暂存的那份");
    const ctx = loadExtension({ session: { mru: [5, 6] }, local: { mruCarry: { mru: [1, 2], at: Date.now() } } });
    await ctx.run("loadMRU()");
    check("用 session 里的", same(ctx.mru(), [5, 6]), JSON.stringify(ctx.mru()));
  }

  console.log(failures === 0 ? "\n全部通过" : `\n${failures} 条失败`);
  process.exit(failures === 0 ? 0 : 1);
})();
