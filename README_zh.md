<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>给 Google Chrome 加上按最近使用顺序切换标签的能力，并带切换器浮层。</strong><br>
  按住 ⌃ 点 ⇥，按你实际使用的顺序在标签之间移动。
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chrome-116%2B-7C3AED?style=flat-square" alt="Chrome">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/TabFlick/">🌐 <strong>官网</strong></a> ｜ <a href="#安装">🚀 <strong>快速开始</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>赞助</strong></a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/08/tabflick-demo.gif" width="860" alt="TabFlick 演示">
</p>

<p align="center">
  <sub>高清视频见<a href="https://www.lifedever.com/TabFlick/">官网</a>。</sub>
</p>

Chrome 的 ⌃⇥ 按标签栏顺序切换。TabFlick 把它改成按最近使用顺序切换，并在按住按键期间显示切换器浮层，与 ⌘⇥ 切换应用的方式一致。

## 功能

- ⌃⇥ 切换到上一个使用的标签
- 再点一次 ⌃⇥ 回到出发的标签，A↔B 来回切换保持稳定
- 列表中每个标签都带网页缩略图
- 键盘（⌃⇥、⌃⇧⇥）、方向键、鼠标点击都可以操作切换器
- 浮层显示在正在使用的 Chrome 窗口正中，支持多显示器
- 深浅色外观跟随系统设置
- helper 或扩展不可用时，⌃⇥ 回落到 Chrome 自带的切换行为

## 工作原理

TabFlick 由两部分组成，通过本地回环 WebSocket 通信：

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

两部分缺一不可：

- **扩展读不到键盘。** `Tab` 键在 Chrome 33 时就被移出了 `chrome.commands` 的可用键列表，任何扩展都无法绑定 ⌃⇥。
- **helper 读不到标签。** 标题、MRU 顺序、缩略图和执行切换都要通过 `chrome.tabs` API。

## 安装

### 环境要求

- macOS 13 或更高
- Xcode 命令行工具 —— `xcode-select --install`
- Google Chrome 116 或更高

### 1. 克隆仓库

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

> 开发阶段用 `swift build` / `swift run`（debug 模式）编译快得多。

### 3. 加载扩展

1. 打开 `chrome://extensions`
2. 右上角打开 **开发者模式**
3. 点击 **加载已解压的扩展程序**
4. 选择本仓库的 `extension/` 目录

### 4. 授予辅助功能权限

helper 通过 `CGEventTap` 在 Chrome 收到之前拦截 ⌃⇥，这需要辅助功能权限。

先启动一次：

```bash
./.build/release/tabflick
```

macOS 会弹出授权提示。授权给启动这个二进制的应用（终端、iTerm 等），然后完全退出该应用再重新打开 —— 权限在进程启动时读取。

如果 `CGEvent.tapCreate` 仍然失败，在 **系统设置 → 隐私与安全性 → 输入监控** 里也打开同一个应用。

### 5. 运行

```bash
./.build/release/tabflick
```

启动输出：

```
[HH:MM:SS.mmm] tabflick started — binary built ...
[HH:MM:SS.mmm] WebSocket server listening → ws://127.0.0.1:41573/
[HH:MM:SS.mmm] Keyboard hook installed — waiting for ⌃⇥ in Chrome
[HH:MM:SS.mmm] ✅ Extension connected (1 client(s))
```

最后一行表示扩展已连上 helper。（运行日志统一为英文。）

## 使用

### 快捷键

| 操作 | 效果 |
|---|---|
| 点一下 ⌃⇥ 松开 | 切换到上一个使用的标签 |
| 连点两下 ⌃⇥ | 回到出发时的标签 |
| 按住 ⌃ 连点 ⇥ | 沿使用历史继续往回移动 |
| 按住 ⌃ 按 ⌃⇧⇥ | 往前移动 |
| 按住 ⌃ 按 ← 或 → | 用方向键移动游标 |
| 按住 ⌃ 点击卡片 | 立即切换到该标签 |
| 按住 ⌃ 鼠标悬停 | 用鼠标移动游标 |

浮层在按下 ⇥ 时出现，松开 ⌃ 时关闭。快速点一下会短暂闪现，与 ⌘⇥ 的行为一致。

### 设置

点击 Chrome 工具栏上的 TabFlick 图标打开设置页。改动立即生效，helper 不需要重启。

| 设置项 | 默认 | 作用 |
|---|---|---|
| Limit switching to the current window | 开 | 切换器只列出正在使用的那个 Chrome 窗口的标签。关闭后所有窗口的标签合并成一张列表。 |

两种模式下每个窗口都保留各自的历史。关闭该选项只是把列表合并展示，不会丢弃任何记录。

### 标签排序规则

列表分为两段：

1. **本次会话访问过的标签** —— 按最后访问时间排序，最近的在前
2. **从未打开过的标签** —— 恢复的会话、后台打开的链接，排在第一段之后，按标签栏顺序

刚启动 helper 时第一段是空的，所以列表初始等同于标签栏顺序，随着使用会逐步重排。

### 缩略图

`captureVisibleTab` 只能截取当前可见的标签，因此 TabFlick 在每次标签被激活时截取一张。MRU 列表中的标签都曾被激活过，缩略图会在正常使用中逐步补齐。

`chrome://` 页面和 Chrome 应用商店无法截图，这是 Chrome 的限制，这些卡片显示 favicon。

## 常见问题

排查从 helper 日志开始：`~/Library/Logs/TabFlick/tabflick.log`，同时也打印在终端。日志每次启动时截断，因此内容始终对应当前这次运行。

### 按 ⌃⇥ 没有反应

在日志中查找 `✅ Extension connected`。

- **没有这一行** —— 扩展没有连上 helper。确认 helper 进程在运行，且扩展在 `chrome://extensions` 中处于启用状态。
- **有这一行，但仍是原生切换** —— 说明连接在之后断开了。TabFlick 在断连时会把 ⌃⇥ 放行给 Chrome，因此原生切换正是预期的回落行为。

### `CGEvent.tapCreate failed`

辅助功能权限缺失或未生效。按安装步骤 4 处理。注意终端应用必须完全退出（⌘Q，仅关闭窗口不够）后重开，新授予的权限才会生效。

### 改了代码没有变化

helper 不支持热重载。

- **改了 helper** —— 第一行日志会打印二进制的编译时间，早于你最后一次编译就说明旧进程还在跑，停掉重启即可。
- **改了扩展** —— 在 `chrome://extensions` 上点击该扩展卡片的 ↻。

### Chrome 提示「停用开发者模式扩展」

这是 Chrome 对所有以 unpacked 方式加载的扩展的通用提示，不影响 TabFlick 使用。

### 浮层出现在错误的显示器上

浮层跟随最前面的 Chrome 窗口。多个显示器上都有 Chrome 窗口时，以最近位于最前的那个为准。

## 赞助

TabFlick 免费且开源。如果它对你有用，可以 [赞助开发](https://www.lifedever.com/sponsor/) 💖

## 许可证

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
