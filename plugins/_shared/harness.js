// 官方插件测试共用的沙箱：vm 里加载真实的 main.js，`tabflick` 用桩。不是插件（没有 manifest），不进商店。
//
//   const { load, test, done, plain } = require("../../_shared/harness")
//   const p = load(__dirname + "/..", { routes: (url) => ({ status: 200, text: "…" }) })
//   const rows = await p.handlers.list("")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

/** 沙箱里建的对象原型和这边的不是同一个，deepStrictEqual 会连原型一起比 —— 先转成普通对象。 */
const plain = (x) => JSON.parse(JSON.stringify(x))

/**
 * 起一份插件。routes(url, options) 返回 {status, text}，抛错表示网络失败；不给就一律失败（本地插件不该联网）。
 * 返回沙箱（能直接调顶层函数）、注册的 handlers、发过的请求、打开过的网址、拷贝过的文字、toast、存储。
 */
function load(dir, { locale = "zh", stored = {}, routes = null, settings = {} } = {}) {
  const source = fs.readFileSync(path.join(dir, "main.js"), "utf8")
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"))
  const out = { requests: [], opened: [], copied: [], toasts: [], settingsOpened: 0, storage: { ...stored }, handlers: null }
  const sandbox = {
    tabflick: {
      locale,
      register: (h) => { out.handlers = h },
      storage: {
        get: (k) => out.storage[k],
        set: (k, v) => { out.storage[k] = JSON.parse(JSON.stringify(v)); return true },
        remove: (k) => { delete out.storage[k] },
      },
      fetch: async (url, options) => {
        out.requests.push({ url, options })
        const host = new URL(url).host
        // 同 PluginNetPolicy：完全一样，或者落在 `*.example.com` 下面（不含它自己）
        const allowed = (manifest.hosts || []).some((h) => (h.startsWith("*.") ? host.endsWith(h.slice(1)) : h === host))
        if (!allowed) throw new Error("blocked: not in manifest hosts")
        if (!routes) throw new Error("network")
        return routes(url, options)
      },
      settings: { get: (k) => settings[k] },
      openURL: (url) => { out.opened.push(url); return true },
      openSettings: () => { out.settingsOpened++ },
      copy: (text) => { out.copied.push(text) },
      toast: (text, detail) => { out.toasts.push(detail ? text + " / " + detail : text) },
    },
  }
  vm.createContext(sandbox)
  vm.runInContext(source, sandbox)
  out.sandbox = sandbox
  return out
}

let passed = 0
async function test(name, fn) {
  try { await fn(); passed++ } catch (e) { console.error("✗ " + name + "\n  " + e.message); process.exitCode = 1 }
}

function done() {
  console.log(process.exitCode ? "有失败" : `全部通过（${passed} 条）`)
}

const fixture = (dir, name) => fs.readFileSync(path.join(dir, "fixtures", name), "utf8")

module.exports = { load, test, done, plain, fixture }
