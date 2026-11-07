# 开发 TabFlick 插件

TabFlick 的插件是一段 JavaScript，跑在 TabFlick 内嵌的 JavaScriptCore 里。**界面全由 TabFlick 画，插件只交数据**：插件说「列表里有这几行、每行有这些动作」，搜索面板、菜单栏、设置页按统一的样子画出来。插件碰不到窗口、菜单、文件系统，联网只能去 manifest 里声明过的主机。

插件能往三个地方加东西：

| 位置 | 怎么接 | 例子 |
|---|---|---|
| 搜索面板 | 一条命令（「股票…」），回车后列表换成插件给的行，打字交给插件去搜 | 股票、汇率、世界时钟 |
| 菜单栏 | 状态栏菜单里一个二级菜单，用户在设置里打开 | 自选股、常用币种 |
| 设置页 | 下拉框、文本框、链接、「测试」按钮 | 天气的 API Key |

这个目录里的 7 个官方插件就是最好的参考：`worldclock`（不联网、最简单）、`currency`（联网 + 菜单栏）、`weather`（要用户填 Key + 测试按钮）、`stocks`（最完整）。

## 目录结构

```
plugins/<id>/
  manifest.json   插件信息（必须）
  main.js         入口脚本（必须，manifest 的 main 可以改）
  icon.svg        图标（或 icon.png）
  tests/          测试，不进插件包
```

`tests/` 和以 `.`、`_` 开头的文件不会打进插件包。一个插件最多 20 个文件、总共 4 MB。

## 最小的例子

`plugins/hello/manifest.json`：

```json
{
  "id": "hello",
  "version": "1.0.0",
  "name": { "zh-Hans": "问候", "en": "Hello" },
  "summary": { "zh-Hans": "打个招呼。", "en": "Says hello." },
  "symbol": "hand.wave.fill",
  "tint": "orange",
  "icon": "icon.svg",
  "hosts": [],
  "contributes": {
    "list": {
      "title": { "zh-Hans": "问候", "en": "Hello" },
      "keywords": ["hello", "wh"],
      "placeholder": { "zh-Hans": "打一个名字", "en": "Type a name" }
    }
  }
}
```

`plugins/hello/main.js`：

```js
tabflick.register({
  list(query) {
    const name = query.trim() || "World"
    return [{
      id: "greet",
      title: `Hello, ${name}`,
      subtitle: "↩ 拷贝",
      actions: [{ id: "copy", title: "拷贝", symbol: "doc.on.doc.fill" }],
    }]
  },
  perform(action, rowID) {
    if (action === "copy") {
      tabflick.copy("Hello")
      tabflick.toast("已拷贝")
    }
  },
})
```

在 ⌥Space 的搜索面板里打「hello」，回车进入插件的列表。

## 本机调试

1. 把插件目录软链接到 TabFlick 的插件目录（目录名必须等于 manifest 的 `id`）：

   ```bash
   ln -s "$PWD/plugins/hello" "$HOME/Library/Application Support/TabFlick/Plugins/hello"
   ```

2. 重启 TabFlick（状态栏菜单 →「重启 TabFlick」）。改了 JS 或 manifest 都要重启。
3. 看日志：`~/Library/Logs/TabFlick/tabflick.log`，插件相关的行都以 `🧩` 开头 —— 加载成功没有、manifest 哪里不对、脚本报错的行号、被拦下的请求、`console.log` 的输出都在这里。

   ```bash
   grep 🧩 ~/Library/Logs/TabFlick/tabflick.log
   ```

`id` 不能和内置插件撞（`calculator`、`appCommands`、`processes`、`windowCommands`）。

## manifest.json

多语言的字段（`name`、`summary`、`title`…）写成 `{"zh-Hans": "…", "en": "…"}`，键是 `zh-Hans`、`zh-Hant`、`en`、`ja`、`ko`、`es`、`fr`、`de`；只写一个字符串当英文。没有当前语言时，繁中退简中，再退英文。

| 字段 | 必须 | 说明 |
|---|---|---|
| `id` | ✓ | 小写字母开头，小写字母、数字、`-`，2–40 个字符。是存盘的键，**发布后别改** |
| `version` | ✓ | `1.0.0` 这种，一到四段数字。改了插件文件就要升 |
| `name` | ✓ | 插件名 |
| `summary` | | 设置页里的一句说明 |
| `symbol` | | SF Symbol 名（实心那一版），没有图标时画在底色方块上。默认 `puzzlepiece.fill` |
| `tint` | | 底色：`red` `orange` `yellow` `green` `mint` `teal` `cyan` `blue` `indigo` `purple` `pink` `brown` `gray` |
| `icon` | | 图标文件，插件目录里的 `.svg` / `.png`，见下面「图标」 |
| `hosts` | | 能联网去的主机，只走 https。完全匹配；`*.example.com` 认它下面任意深的子域名（不含它自己） |
| `minAppVersion` | | 要求的最低 TabFlick 版本，比它旧的 TabFlick 不加载、商店里不让装 |
| `main` | | 入口脚本，默认 `main.js` |
| `contributes` | | 往哪里加东西，见下面 |
| `settings` | | 设置项，见下面 |

### contributes

```json
"contributes": {
  "menu": true,
  "list": {
    "title": { "zh-Hans": "股票" },
    "keywords": ["gp", "stock"],
    "placeholder": { "zh-Hans": "搜股票代码、名字、拼音" },
    "empty": { "zh-Hans": "还没有自选。搜一只，回车加入。" }
  }
}
```

- `list`：搜索面板里多一条命令「标题…」，回车进插件的列表。`keywords` 是除了名字之外也能搜到它的词（拼音首字母、英文别名），最多 20 个。`placeholder` 是列表里输入框的占位，`empty` 是列表空着时那句话。
- `menu`：状态栏菜单里一个二级菜单，默认不显示，用户在设置 → 插件页里打开。

### settings

```json
"settings": {
  "choices": [
    { "key": "tab", "title": { "zh-Hans": "看什么" }, "default": "hot",
      "options": [{ "value": "hot", "title": { "zh-Hans": "热议" } }, { "value": "latest", "title": { "zh-Hans": "最新" } }] }
  ],
  "inputs": [
    { "key": "apiKey", "title": { "zh-Hans": "API Key" }, "placeholder": { "zh-Hans": "在控制台里拿" },
      "note": { "zh-Hans": "免费额度每月 5 万次。" }, "secret": true }
  ],
  "links": [{ "title": { "zh-Hans": "去控制台拿 Key" }, "url": "https://example.com/console" }],
  "upDownColors": true
}
```

- `choices`：下拉框，最多 5 个，每个 2–10 个选项。`key` 和选项的 `value` 只许字母、数字、`_`。
- `inputs`：要用户填的文字，最多 5 个，`secret` 画成密码框。值明文存在 TabFlick 的偏好设置里，只适合放免费服务的 Key，别让用户填密码。**有 `inputs` 就必须实现 `test()`**（设置页的「测试」按钮），不然用户填完不知道能不能用 —— `build-index.py` 会拦。
- `links`：设置页里的链接，只许 https，最多 3 条。
- `upDownColors`：插件页里出「涨跌颜色」（红涨绿跌 / 绿涨红跌），行的 `tone` 跟着它变色。

插件用 `tabflick.settings.get(key)` 读，每次现读，用户改了下一次调用就生效。

## 图标

插件在设置侧边栏（22pt）、插件总览（26pt）、插件页（40pt）、搜索面板（17pt）、菜单栏（16pt）、商店里都画同一个图标。

插件的图标块和设置里的系统页反过来：系统页是彩色底 + 白色图形，插件是**中性底 + 彩色图形**，一眼就知道哪些是插件。**底由 TabFlick 画**（浅色模式白、深色模式深灰，带一圈淡描边，圆角统一），插件只交图形：

- **背景透明，只画图形**。正方形画布（SVG 的 viewBox 建议 `0 0 64 64`），主体放在中间，四周留 8 左右的空。
- **颜色用中间调**：同一张图要放在白底和深灰底上，别用黑、白和很深、很浅的颜色（白色的云、黑色的字在其中一种底上会看不见）。品牌色本身是黑或白的，画成一块彩色或深色的小圆角块，图形放在块上（参考 `hackernews`、`v2ex`）。
- **16pt 下要认得出**：主体一两样东西，在 64 的画布里线宽不小于 4。在深浅两种底上都看一眼。
- **SVG 优先**，任何尺寸都清楚。不能有 `<script>`、`<image>`、`<use>`、`<foreignObject>` 和外部链接（`build-index.py` 会拦）。也可以用 PNG，至少 128×128 的正方形。文件不超过 256 KB。
- **`symbol` 和 `tint` 照样要写**：没有图标、或者图标读不出来时，TabFlick 在同一块底上用 `tint` 的颜色画 `symbol`。

## JavaScript API

脚本加载时调一次 `tabflick.register({...})`，传进去的函数可以是普通函数，也可以返回 Promise（`async` 函数）。

### 注册的函数

| 函数 | 什么时候调 | 返回 |
|---|---|---|
| `list(query, scope)` | 进列表、打字、面板开着时每 5 秒（没输入时）。`scope` 是进到了哪一层（见「多层列表」），首页是 `undefined` | 行的数组，见下面 |
| `perform(actionID, rowID, scope)` | 用户对一行做了某个动作（回车 = 第一个动作，⌘↩ 列出全部） | 不用返回 |
| `menu()` | 用户打开状态栏菜单 | 菜单行的数组 |
| `action(id)` | 用户点了菜单里带 `action` 的那一行 | 不用返回 |
| `test()` | 设置页的「测试」按钮 | `{ok, title, detail}` |

抛异常、Promise 被拒绝、超时，TabFlick 都当「这次没取到」：列表留着上一次的行，菜单留着上次的内容并写「数据未更新」。

联网的插件（`hosts` 不空）打字时 TabFlick 合并 250ms 再问一次；不联网的每打一个字都问。没输入时面板开着每 5 秒问一次，取得慢的插件自己做缓存（参考 `stocks` 按开没开市缓存）。

### 列表的行

```js
{
  id: "sh600519",              // 必须，同一份列表里不能重复
  title: "贵州茅台",            // 必须
  badge: "沪",                  // 标题后面的小标签，最多 12 个字
  subtitle: "600519 · 白酒",
  value: "1452.00",            // 行尾的数，最多 20 个字
  detail: "+1.23%",            // 行尾的胶囊，最多 20 个字
  tone: "up",                  // detail 的颜色：up / down / plain / secondary
  spark: [1440, 1445, 1452],   // 行尾的迷你走势线
  icon: { text: "沪", tint: "red" },   // 行首的方块：一两个字 + 底色（也认 #RRGGBB）
  clock: "Asia/Tokyo",         // 行尾画这个时区的「时:分:秒」，每秒走一下，代替 value
  actions: [
    { id: "open", title: "打开行情页", symbol: "safari.fill" },
    { id: "remove", title: "移出自选", symbol: "minus.circle.fill", destructive: true, stay: true },
  ],
}
```

- 一份列表最多 60 行，文字最长 120 个字，认不出的字段丢掉。
- `actions` 第一个是回车做的事，最多 10 个。`symbol` 是 SF Symbol 名。`destructive` 标红排最后；`stay` 做完面板不关、列表重新取一次（加入 / 移出自选）；`clear` 做完清空输入、回到列表首页，游标落在这一行（搜到了加进自选之后回到自选）；`enter` 不调 `perform`，而是进这一行的下一层（见「多层列表」）。不带 `stay`、`enter` 的动作先关面板再做（打开网页）。
- `clock` 是 IANA 时区名，认不出的当没写。为了老版本的 TabFlick（`tabflick.features` 里没有 `"clock"`），`value` 里照样写一个时间。

### 多层列表

列表里的一行可以再进一层：开发工具箱首页列出全部工具，在「JWT 解码」上回车，列表换成只解 JWT 的那一层。

```js
{
  id: "tool:jwt",
  title: "JWT 解码",
  subtitle: "数据 · 看载荷、头和过期时间",
  actions: [{ id: "enter", title: "打开", enter: true, placeholder: "粘贴 JWT", empty: "粘贴 JWT，这里列出载荷和过期时间。" }],
}
```

- 带 `enter: true` 的动作不交给 `perform`：TabFlick 清空输入，之后调 `list(query, "tool:jwt")`，第二个参数就是这一行的 `id`。`placeholder` 是这一层输入框的占位，`empty` 是这一层没内容时那句话。
- 这一层里 `perform` 的第三个参数也是这一行的 `id`。
- Esc、或者输入空着按 ⌫，退回上一层：输入、游标和进去之前一样。底栏写当前的路径（开发工具箱 › JWT 解码）。可以一层套一层，`scope` 只给最里面那一层的 `id`。
- 老版本的 TabFlick 不认 `enter`。先看 `tabflick.features` 里有没有 `"enter"`，没有就别给这个动作（行照样列出来，用户至少知道有这些功能）。

### 菜单行

```js
[
  { type: "header", text: "自选" },
  { title: "贵州茅台", badge: "沪", value: "1452.00", detail: "+1.23%", tone: "up", symbol: "chart.line.uptrend.xyaxis", action: "open:sh600519" },
  { type: "separator" },
  { type: "note", text: "数据来自腾讯" },
]
```

最多 40 行，每段文字最长 80 个字。点了带 `action` 的行，TabFlick 调 `action("open:sh600519")`。有列表的插件，菜单最后自动多一行「在快捷搜索里打开」。

### tabflick 对象

| API | 说明 |
|---|---|
| `tabflick.locale` | 界面语言：`zh` `zh-Hant` `en` `ja` `ko` `es` `fr` `de` |
| `tabflick.features` | 这个版本的 TabFlick 认哪些后来加的能力：`"enter"`（多层列表）、`"clock"`（行尾走秒的钟）。老版本没有这一项，用之前先判断 |
| `tabflick.fetch(url, {method, headers, body, encoding})` | 返回 `Promise<{status, text}>`。只能去 `hosts` 里的主机（重定向也算），只走 https；`method` 只认 GET / POST；`encoding: "gbk"` 按 GBK 解码；`Host`、`Cookie` 头会被丢掉。单次请求 8 秒超时，响应最大 4 MB |
| `tabflick.storage.get(key)` / `set(key, value)` / `remove(key)` | 插件自己的存储，按 JSON 的规则存（函数、`undefined` 存不进去），整份最多 1 MB。更新插件不丢，卸载时用户可以选择留着 |
| `tabflick.settings.get(key)` | 读 manifest 里声明的设置项。文本框没填是空串 |
| `tabflick.toast(text, detail)` | 屏幕底部的轻提示 |
| `tabflick.copy(text)` | 拷贝到剪贴板 |
| `tabflick.openURL(url)` | 用默认浏览器打开，只认 http(s) |
| `tabflick.openSettings()` | 打开设置里这个插件的那一页（没填 Key 时引导用户去填） |
| `console.log` / `console.error` | 写进 TabFlick 的日志 |
| `setTimeout(fn, ms)` | 最长 60 秒 |

### 限制

- 一次同步执行最多 2 秒，超了被掐断（等网络不算）。算大东西（哈希、大段文本）前先限长度。
- 闲置 10 分钟 TabFlick 会卸掉插件的运行环境，下次调用重新加载脚本：**全局变量会丢**，要留着的放进 `storage`。
- 没有 DOM、`window`、`require`、`crypto`。`Intl` 有。
- 数据源只用正常的请求：User-Agent 照实写、不冒充浏览器或别人的 App、不用从别处扒来的 token、不为了过防盗链伪造 Referer。对方限流或拒绝就如实显示「取不到」。

## 测试

官方插件的测试用 node 跑，`_shared/harness.js` 在 vm 里加载真实的 `main.js`，`tabflick` 换成桩（网络、存储、拷贝、toast 都能断言）：

```js
// plugins/hello/tests/hello.test.js
const assert = require("assert")
const { load, test, done } = require("../../_shared/harness")
const dir = __dirname + "/.."

;(async () => {
  await test("没输入时问候 World", async () => {
    const p = load(dir)
    const rows = await p.handlers.list("")
    assert.strictEqual(rows[0].title, "Hello, World")
  })
  done()
})()
```

```bash
node plugins/hello/tests/hello.test.js
```

联网的插件用 `load(dir, { routes: (url) => ({ status: 200, text: "…" }) })` 喂真实接口存下来的样本（放在 `tests/fixtures/`）。node 和 JavaScriptCore 不是同一个引擎，改了语法层面的东西在 TabFlick 里再跑一遍。

## 发布

商店目前只收官方插件，目录是这里的 `index.json`。

1. 改了插件的任何文件，升 `version`。
2. 重新生成目录：`python3 scripts/plugins/build-index.py`（会校验 manifest、入口、图标、文件大小，并记下每个文件的 sha256）。
3. 发布前核对：`python3 scripts/plugins/build-index.py --check`。
4. 和插件文件一起提交到 `main`。TabFlick 先从 raw.githubusercontent.com 拉，拉不到再走 jsDelivr（有最长 12 小时的缓存）；下载后逐个核对大小和 sha256，对不上不装。

用到新版 TabFlick 才有的功能时写上 `minAppVersion`，旧版本的用户不会装上一个用不了的插件。
