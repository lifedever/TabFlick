<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>给 Google Chrome 补上 Arc 式的最近使用标签切换器。</strong><br>
  按住 ⌃ 点 ⇥，标签一览无遗 —— 就像 ⌘⇥ 切换 App 那样。
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chrome-116%2B-7C3AED?style=flat-square" alt="Chrome">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="#安装">🚀 <strong>快速开始</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>赞助</strong></a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

<!-- 截图占位：跑起来后截一张浮层的图，上传到图床后替换这里
<p align="center">
  <img src="<screenshot-url>" width="800" alt="TabFlick 截图">
</p>
-->

Chrome 从来没有提供过「按最近使用顺序切换标签」。TabFlick 把这个功能补上，并配了一个真正好用的切换器界面。

## 功能

- **真正的 MRU 顺序** —— ⌃⇥ 切到你刚才待的那个标签，而不是右边那个
- **来回切换稳定可靠** —— 连按两下 ⌃⇥ 必定回到原处，每次都是
- **网页实时缩略图** —— 靠画面认标签，而不是靠被截断的标题猜
- **键盘、方向键、鼠标都行** —— ⌃⇥ / ⌃⇧⇥，按住时用 ←/→，或者直接点卡片
- **跟随 Chrome 窗口** —— 出现在你正在用的那个窗口正中，不是屏幕正中
- **深浅色自适应** —— 跟随系统外观
- **优雅降级** —— 任何一环出问题时，⌃⇥ 会放行给 Chrome 原生行为，而不是静默失灵

## 工作原理

两个进程，因为任何一半单独都做不成这件事：

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  Chrome 扩展 (MV3)      │  ws://  │  Swift helper            │
│                         │◄───────►│                          │
│  · tabs.onActivated     │  :41573 │  · CGEventTap  (拦 ⌃⇥)   │
│    → 维护 MRU 顺序      │         │  · NSPanel     (浮层)    │
│  · captureVisibleTab    │         │  · MRU 状态机            │
│    → 采集缩略图         │         │                          │
│  · tabs.update          │         │                          │
│    → 执行切换           │         │                          │
└─────────────────────────┘         └──────────────────────────┘
```

**为什么不能只写扩展？** `Tab` 键早在 Chrome 33 就被移出了 `chrome.commands` 的可用键列表。扩展**根本无法绑定** ⌃⇥。

**为什么不能只写原生 App？** 标签列表、MRU 顺序、缩略图、执行切换全都要走 `chrome.tabs` API。用辅助功能 / AppleScript 轮询又慢又不准。

## 安装

### 环境要求

- macOS 13 或更高
- Xcode 命令行工具（`xcode-select --install`）
- Google Chrome 116 或更高

### 1. 克隆

```bash
git clone https://github.com/lifedever/TabFlick.git
cd TabFlick
```

### 2. 编译 helper

```bash
cd helper
swift build -c release
```

产物在 `helper/.build/release/tabflick`。

> 开发时用 `swift build` / `swift run`（debug 模式）就行，编译快得多。

### 3. 加载扩展

1. 打开 `chrome://extensions`
2. 右上角打开 **开发者模式**
3. 点击 **加载已解压的扩展程序**
4. 选择本仓库的 `extension/` 目录

### 4. 授予「辅助功能」权限

TabFlick 用 `CGEventTap` 在 Chrome 收到之前拦截 ⌃⇥，这需要辅助功能权限。

先跑一次：

```bash
./.build/release/tabflick
```

macOS 会弹出授权窗口。授权给**运行这个二进制的那个 App**（终端 / iTerm 等），然后**完全退出并重新打开那个 App** —— macOS 在进程启动时才读取权限。

如果 `CGEvent.tapCreate` 仍然失败，再到
**系统设置 → 隐私与安全性 → 输入监控** 里把同一个 App 也打开。

### 5. 运行

```bash
./.build/release/tabflick
```

应该看到：

```
[HH:MM:SS.mmm] tabflick started — binary built ...
[HH:MM:SS.mmm] WebSocket server listening → ws://127.0.0.1:41573/
[HH:MM:SS.mmm] Keyboard hook installed — waiting for ⌃⇥ in Chrome
[HH:MM:SS.mmm] ✅ Extension connected (1 client(s))
```

出现最后一行就说明扩展和 helper 接上了，可以用了。（运行日志统一用英文输出。）

## 使用

| 操作 | 效果 |
|---|---|
| 点一下 ⌃⇥ 松开 | 跳到上一个使用的标签 |
| 快速连点两下 ⌃⇥ | 回到原处 —— 稳定的 A↔B 来回切换 |
| 按住 ⌃ 连点 ⇥ | 沿使用历史继续往回走 |
| 按住 ⌃ 按 ⌃⇧⇥ | 往前走 |
| 按住 ⌃ 按 ← / → | 用方向键移动游标 |
| 按住 ⌃ 点击卡片 | 直接跳到那个标签 |
| 按住 ⌃ 鼠标悬停 | 用鼠标移动游标 |

### 标签排序规则

分两段：

1. **本次会话访问过的标签** —— 按最后访问时间倒序，最近的在前
2. **从没打开过的标签**（恢复的会话、后台打开的链接）—— 排在第一段之后，按标签栏从左到右

第二段解释了为什么刚启动 helper 时列表看起来是「标签栏顺序」—— 那时第一段还是空的。用一会儿就长起来了。

### 缩略图

`captureVisibleTab` 只能截取**当前可见**的标签，所以 TabFlick 的策略是每次标签被激活时截一张。由于 MRU 列表里的标签按定义都被激活过，缩略图会随着你正常使用自然攒齐。

`chrome://` 和 Web Store 页面永远截不了（Chrome 不允许），这些卡片会降级显示 favicon。

## 常见问题

**按 ⌃⇥ 完全没反应**
看 helper 日志（`~/Library/Logs/TabFlick/tabflick.log`，同时也打在终端）里有没有 `✅ Extension connected`。没有就说明扩展没连上 helper —— 确认 helper 在跑、扩展是启用状态。断连时 TabFlick 会**故意**放行 ⌃⇥ 给 Chrome 原生行为。

**`CGEvent.tapCreate 失败`**
辅助功能权限问题，见第 4 步 —— 注意授权后终端必须完全退出重开。

**改了代码没有变化**
helper 不会热重载。它的第一行日志会打印二进制的编译时间，跟你最后一次编译对不上就说明跑的是旧进程，重启即可。改扩展则要在 `chrome://extensions` 点 ↻。

**Chrome 一直提示「停用开发者模式扩展」**
以 unpacked 方式加载扩展就会这样。上架 Chrome Web Store 已列入计划。

## 计划

- [ ] helper 打包成正式的 `.app`（`LSUIElement`）并支持登录时自启
- [ ] 扩展上架 Chrome Web Store
- [ ] helper 守护 / 崩溃自动重启
- [ ] Esc 取消当前这轮切换
- [ ] 快捷键可配置

## 赞助

如果 TabFlick 帮你省下了翻标签的时间，欢迎 [赞助](https://www.lifedever.com/sponsor/) 💖

## 许可证

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
