// node plugins/amphetamine/tests/amphetamine.test.js
const assert = require("assert")
const fs = require("fs")
const { load, test, done } = require("../../_shared/harness")
const dir = __dirname + "/.."
const manifest = JSON.parse(fs.readFileSync(dir + "/manifest.json", "utf8"))

;(async () => {
  await test("开始：跑 start 那段脚本，说已开始", async () => {
    const p = load(dir, { script: () => "" })
    await p.handlers.command("start")
    assert.deepStrictEqual(p.scripts, ["start"])
    assert.deepStrictEqual(p.toasts, ["已开始新会话 / Amphetamine"])
  })

  await test("结束：有会话时说已结束", async () => {
    const p = load(dir, { script: () => "ended" })
    await p.handlers.command("end")
    assert.deepStrictEqual(p.scripts, ["end"])
    assert.deepStrictEqual(p.toasts, ["已结束会话 / Amphetamine"])
  })

  await test("结束：没有会话时照实说，不说已结束", async () => {
    const p = load(dir, { script: () => "none" })
    await p.handlers.command("end")
    assert.deepStrictEqual(p.toasts, ["现在没有进行中的会话 / Amphetamine"])
  })

  await test("没授权：TabFlick 自己指路，插件不再弹一次", async () => {
    const p = load(dir)
    await p.handlers.command("start")
    assert.deepStrictEqual(p.toasts, [])
  })

  await test("别的失败：说没能执行，带上报错", async () => {
    const p = load(dir, { script: () => { throw "Amphetamine got an error: boom" } })
    await p.handlers.command("end")
    assert.deepStrictEqual(p.toasts, ["没能执行「Amphetamine」 / Amphetamine got an error: boom"])
  })

  await test("英文界面", async () => {
    const p = load(dir, { locale: "en", script: () => "none" })
    await p.handlers.command("end")
    assert.deepStrictEqual(p.toasts, ["No session is running / Amphetamine"])
  })

  await test("认不出的命令什么都不做", async () => {
    const p = load(dir, { script: () => "" })
    await p.handlers.command("nope")
    assert.deepStrictEqual(p.scripts, [])
    assert.deepStrictEqual(p.toasts, [])
  })

  await test("manifest 里的每条命令都有人接", async () => {
    for (const command of manifest.contributes.commands) {
      const p = load(dir, { script: () => "" })
      await p.handlers.command(command.id)
      assert.strictEqual(p.scripts.length, 1, command.id)
    }
  })

  await test("能跑脚本的插件不联网", () => {
    assert.deepStrictEqual(manifest.hosts, [])
  })
  done()
})()
