// node plugins/cleanshot/tests/cleanshot.test.js
const assert = require("assert")
const fs = require("fs")
const { load, test, done } = require("../../_shared/harness")
const dir = __dirname + "/.."
const manifest = JSON.parse(fs.readFileSync(dir + "/manifest.json", "utf8"))

;(async () => {
  await test("截取窗口：交给 CleanShot、不激活（激活了前台窗口会失焦，截出来红绿灯是灰的）", () => {
    const p = load(dir)
    p.handlers.command("capture-window")
    assert.deepStrictEqual(p.appOpened, [{ url: "cleanshot://capture-window", activate: false }])
  })

  await test("截图、录屏类都不激活", () => {
    for (const id of ["capture-area", "capture-fullscreen", "capture-previous-area", "scrolling-capture",
      "self-timer", "capture-text", "record-screen", "all-in-one", "toggle-desktop-icons"]) {
      const p = load(dir)
      p.handlers.command(id)
      assert.deepStrictEqual(p.appOpened, [{ url: "cleanshot://" + id, activate: false }], id)
    }
  })

  await test("弹 CleanShot 自己窗口的两条要激活", () => {
    for (const id of ["open-history", "open-from-clipboard"]) {
      const p = load(dir)
      p.handlers.command(id)
      assert.deepStrictEqual(p.appOpened, [{ url: "cleanshot://" + id, activate: true }], id)
    }
  })

  await test("认不出的命令不拼网址", () => {
    const p = load(dir)
    p.handlers.command("pin?filepath=/etc/passwd")
    p.handlers.command("toString")
    assert.deepStrictEqual(p.appOpened, [])
  })

  await test("manifest 里的每条命令都有人接，没有多出来的", () => {
    const handled = []
    for (const command of manifest.contributes.commands) {
      const p = load(dir)
      p.handlers.command(command.id)
      if (p.appOpened.length === 1) handled.push(command.id)
    }
    assert.deepStrictEqual(handled, manifest.contributes.commands.map((c) => c.id))
    const source = fs.readFileSync(dir + "/main.js", "utf8")
    const inScript = [...source.matchAll(/^\s+"([a-z-]+)": (true|false),$/gm)].map((m) => m[1]).sort()
    assert.deepStrictEqual(inScript, handled.slice().sort())
  })

  await test("不跑脚本、不联网", () => {
    assert.strictEqual(manifest.app.scripts, undefined)
    assert.deepStrictEqual(manifest.hosts, [])
  })
  done()
})()
