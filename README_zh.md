<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>macOS 上 Chrome 的标签切换器和搜索面板。</strong><br>
  ⌃⇥ 回到上一个用过的标签。⌘E 在一个框里找标签、书签、历史记录、文件夹和 App。
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chromium-116%2B-7C3AED?style=flat-square" alt="Chromium">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/TabFlick/">🌐 <strong>官网</strong></a> ｜ <a href="#安装">🚀 <strong>安装</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>赞助</strong></a> ｜ <a href="README.md">English</a>
</p>

---

## 切换器 —— ⌃⇥

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/08/tabflick-demo-full.gif" width="820" alt="TabFlick 切换器">
</p>

Chrome 的 ⌃⇥ 按标签栏顺序走。TabFlick 让它按你用过的顺序走，和 ⌘⇥ 切 App 一样。

- **来回切换稳定。** 按一下 ⌃⇥ 回到上一个标签，再按一下回来。按住 ⌃ 时只移动游标，松开才切，中途经过的不算用过。
- **网页缩略图。** 靠页面样子认标签，不用读截断的标题。
- **键盘、方向键、鼠标都行。** ⌃⇧⇥ 反向，按住 ⌃ 时方向键移动，或直接点卡片。
- **按窗口分开。** 只列当前窗口的标签，每个窗口有自己的顺序。设置里可以关。
- **两种排布。** 横向长条，或一屏排下全部标签的宫格。

## 搜索面板 —— ⌘E

<p align="center">
  <img src="docs/search-demo.gif" width="820" alt="TabFlick 搜索面板">
</p>

活标签、最近关闭、书签、历史记录、收藏的文件夹、已装的 App，都在同一个框里。

- **Tab 换范围。** 全部、浏览器标签、搜索、历史记录、浏览器书签、最近关闭、文件夹、应用依次切，哪些进循环、什么顺序在设置里定。
- **中文用拼音也能搜。** 全拼和首字母都认，`mnjt` 能找到「蒙牛集团」。
- **没找到就搜网页。** 用浏览器自己的默认引擎，也可以用 GitHub、YouTube 这类站内搜索（模板可改）。
- **在别的 App 里也能用。** 按 ⌥Space，搜所有浏览器的标签。没输入时列的是最近用过的浏览器标签和正在运行的 App，按时间排在一起，回车回到上一件事。
- **⌘↩ 展开操作。** 拷贝网址、标题或 Markdown 链接，重新加载，关闭标签，从历史记录里删除，文件夹换个 App 打开或拷贝路径。底栏写着回车会做什么。
- **内置命令。** 打「锁定」锁屏；装了 Amphetamine 的话，打「amp」或「结束」开始、结束会话。第一次用 Amphetamine 的命令时，系统会问是否允许 TabFlick 控制它。
- **越用越顺手。** 同一个词再搜时，上次选的那条排在前面；最贴切的一条单独提到最前。英文首字母（`pr` 找到 Pull Request）和打错一个字母也能找到。
- **重复的标签会标出来**，操作里可以关掉其余几个。
- ⌘1–⌘9 直接选第几行，Esc 先清空输入再关面板，⌘, 打开设置。

## 还有这些

- **置顶常驻**：置顶的标签重启浏览器后自动回来，停在最后看的那页。
- **自动清理闲置标签**：12 小时、24 小时或 7 天没用过就关掉，置顶、在放声音的、标签组里的不动。默认关。
- **菜单栏标签列表**：按窗口列出所有标签，还有最近关闭的。
- **收藏的文件夹**：常用目录收在菜单栏，选任意 App 打开。
- **全局切换器**：在浏览器之外按 ⌃⇥，按浏览器分组列出所有标签。默认关。
- **多个浏览器、多个 Profile 同时用**：Chrome、Edge、Brave 等 Chromium 浏览器，每个浏览器、每个 Profile 各自一份列表，最近关闭和置顶也各管各的。
- **八种语言**：简体中文、繁體中文、English、日本語、한국어、Español、Français、Deutsch。
- **应用内更新**：检查 GitHub Releases，原地替换。
- **出问题不会吞键**：扩展没连上时，⌃⇥ 交回给 Chrome 自带的切换，不会按了没反应。

## 安装

需要 macOS 14 以上，Chrome（或其他 Chromium 浏览器）116 以上。

1. **装 App。** 从 [Releases](https://github.com/lifedever/TabFlick/releases/latest) 下载对应的 DMG（Apple 芯片选 `arm64`，Intel 选 `x86_64`），把 TabFlick 拖进「应用程序」。第一次打开如果提示无法验证开发者，在「应用程序」里右键 TabFlick 选「打开」。
2. **装扩展。** 下载 [TabFlick-Extension.zip](https://github.com/lifedever/TabFlick/releases/latest/download/TabFlick-Extension.zip)，解压到不会误删的位置，打开 `chrome://extensions`，开启开发者模式，点「加载已解压的扩展程序」选中文件夹。[图文步骤](https://www.lifedever.com/TabFlick/install-extension.html)。
3. **给辅助功能权限。** 第一次启动会打开「系统设置」的「辅助功能」页，TabFlick 已经在列表里，打开它的开关，App 会自动重启。菜单栏图标变亮就是两端连上了。

扩展要标签、书签、历史记录、图标、搜索这几项权限，数据只通过本机 WebSocket 交给同一台 Mac 上的 TabFlick。升级后 Chrome 提示新权限时点允许，再重新加载扩展。

### 源码构建

```bash
git clone https://github.com/lifedever/TabFlick.git
cd TabFlick
./scripts/dev-run.sh                      # 调试运行 helper
./scripts/build-app.sh 0.0.0 --install    # 或者打出 TabFlick.app 并安装
```

别用裸的 `swift build`：这两个脚本会把 SDK 路径传给链接器，不传的话二进制记的是 SDK 14.0，macOS 会按旧外观画整个 App。

扩展按第 2 步加载 `extension/` 目录。从终端运行时，辅助功能权限归到终端名下，授权后要完全退出终端（⌘Q）再打开。

## 快捷键

都可以在设置里改。

**切换器**（浏览器在前台时）

| 按键 | 效果 |
|---|---|
| ⌃⇥ | 切到上一个用过的标签 |
| ⌃⇥⇥… | 按住 ⌃ 连点，继续往回走 |
| ⌃⇧⇥ | 反向 |
| ⌃ ← → ↑ ↓ | 按住 ⌃ 时移动（宫格里 ↑↓ 按行） |
| 松开 ⌃ | 切过去 |

**搜索面板**

| 按键 | 效果 |
|---|---|
| ⌘E | 在浏览器里打开，再按一次关闭 |
| ⌥Space | 在别的 App 里打开，搜所有浏览器 |
| ⇥ / ⇧⇥ | 切换范围 |
| ⌘1–⌘9 | 直接选第几行 |
| ⌘↩ | 展开操作：拷贝网址、重新加载、关闭标签、换一个 App 打开文件夹…… |
| ⌘, | 打开设置 |

## 设置

从菜单栏图标、Chrome 工具栏的 TabFlick 图标，或搜索面板里按 ⌘, 打开。改了立即生效。

| 分页 | 内容 |
|---|---|
| 通用 | 语言、外观、开机启动、检查更新、全局切换器排除的 App |
| 切换器 | 快捷键、按窗口分开、排布、全局切换器 |
| 搜索面板 | 开关、两个快捷键、「全部」没输入时显示什么、Tab 顺序和开关、站内搜索模板 |
| 标签管理 | 置顶标签、闲置标签存活时间、置顶快捷键 |
| 文件夹管理 / 打开方式 | 收藏的文件夹，以及打开它们时可选的 App |
| 浏览器 | 每个浏览器的连接状态和扩展版本 |

## 工作原理

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  Browser extension (MV3)│  ws://  │  Swift helper            │
│                         │◄───────►│                          │
│  · tabs / bookmarks     │  :41573 │  · CGEventTap  (keys)    │
│  · history / favicons   │         │  · NSPanel     (panels)  │
│  · captureVisibleTab    │         │  · MRU state machine     │
└─────────────────────────┘         └──────────────────────────┘
```

- **扩展读不到键盘。** Chrome 33 起 `chrome.commands` 不接受带 Tab 的快捷键，任何扩展都绑不了 ⌃⇥。
- **原生进程读不到标签。** 标签、书签、历史记录、缩略图和切换都要走 Chrome 的扩展 API。

缩略图：`captureVisibleTab` 只能截当前可见的标签，所以每次标签被激活时截一张，用着用着就齐了。`chrome://` 页面和应用商店截不了，显示网站图标。

## 常见问题

日志在 `~/Library/Logs/TabFlick/tabflick.log`，每次启动清空。

- **⌃⇥ 没反应 / 还是按标签栏顺序切。** 在日志里找 `✅ Extension connected`。没有这一行说明扩展没连上 App：确认扩展在 `chrome://extensions` 里是开着的、TabFlick 在运行。没连上时 TabFlick 会故意把 ⌃⇥ 交还给 Chrome。
- **搜索面板里没有书签或历史记录。** 扩展比 App 旧。下载最新的扩展包替换原文件夹，再重新加载。
- **`CGEvent.tapCreate failed`。** 辅助功能权限没给或已失效。重新授权后完全退出 TabFlick 再打开，macOS 只在启动时读这项权限。
- **Chrome 提示停用开发者模式扩展。** 所有未打包的扩展都会有这个提示，不影响 TabFlick。

## 参与翻译

界面文案写在代码里，形如 `L10n.t("中文", "English")`；其他语言是从 `scripts/l10n/<lang>.json` 生成的翻译表。欢迎改进：改 JSON，然后跑 `python3 scripts/l10n/build.py --strict`。术语和语气见 [scripts/l10n/GUIDE.md](scripts/l10n/GUIDE.md)。

## 赞助

TabFlick 免费开源。觉得有用的话，可以[赞助开发](https://www.lifedever.com/sponsor/) 💖

## 许可证

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
