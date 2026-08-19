<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>An Arc-style most-recently-used tab switcher for Google Chrome.</strong><br>
  Hold ⌃, tap ⇥, see your tabs — the way ⌘⇥ works for apps.
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chrome-116%2B-7C3AED?style=flat-square" alt="Chrome">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="#installation">🚀 <strong>Get Started</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>Sponsor</strong></a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

<!-- 截图占位：跑起来后截一张浮层的图，上传到图床后替换这里
<p align="center">
  <img src="<screenshot-url>" width="800" alt="TabFlick Screenshot">
</p>
-->

Chrome has never shipped most-recently-used tab cycling. TabFlick adds it, with the switcher UI that makes it usable.

## Features

- **True MRU order** — ⌃⇥ goes to the tab you were just on, not the one to the right
- **Reliable back-and-forth** — tap ⌃⇥ twice and you're back where you started, every time
- **Live page thumbnails** — recognize tabs by what they look like, not by a truncated title
- **Keyboard, arrows, and mouse** — ⌃⇥ / ⌃⇧⇥, ←/→ while held, or click any card
- **Follows your Chrome window** — appears centered on the window you're actually using
- **Light and dark** — adapts to your system appearance
- **Graceful degradation** — if anything is down, ⌃⇥ falls through to Chrome's native behavior instead of dying silently

## How it works

Two processes, because neither half can do the job alone:

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  Chrome extension (MV3) │  ws://  │  Swift helper            │
│                         │◄───────►│                          │
│  · tabs.onActivated     │  :41573 │  · CGEventTap  (⌃⇥)      │
│    → maintain MRU order │         │  · NSPanel     (overlay) │
│  · captureVisibleTab    │         │  · MRU state machine     │
│    → collect thumbnails │         │                          │
│  · tabs.update          │         │                          │
│    → perform the switch │         │                          │
└─────────────────────────┘         └──────────────────────────┘
```

**Why not a pure extension?** The `Tab` key was removed from `chrome.commands`' supported-key list back in Chrome 33. An extension literally cannot bind ⌃⇥.

**Why not pure native?** Tab list, MRU order, thumbnails and switching all need the `chrome.tabs` API. Accessibility/AppleScript polling is slow and unreliable.

## Installation

### Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Google Chrome 116 or later

### 1. Clone

```bash
git clone https://github.com/lifedever/TabFlick.git
cd TabFlick
```

### 2. Build the helper

```bash
cd helper
swift build -c release
```

The binary lands at `helper/.build/release/tabflick`.

> For development use `swift build` / `swift run` (debug) instead — it compiles much faster.

### 3. Load the extension

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. Click **Load unpacked**
4. Select the `extension/` folder in this repo

### 4. Grant Accessibility permission

TabFlick uses a `CGEventTap` to intercept ⌃⇥ before Chrome sees it, which requires Accessibility access.

Run the helper once:

```bash
./.build/release/tabflick
```

macOS will prompt for permission. Grant it to **whichever app is running the binary** (Terminal, iTerm, etc.), then **fully quit and reopen that app** — macOS reads the permission at process launch.

If `CGEvent.tapCreate` still fails, also enable the same app under
**System Settings → Privacy & Security → Input Monitoring**.

### 5. Run

```bash
./.build/release/tabflick
```

You should see:

```
[HH:MM:SS.mmm] tabflick started — binary built ...
[HH:MM:SS.mmm] WebSocket server listening → ws://127.0.0.1:41573/
[HH:MM:SS.mmm] Keyboard hook installed — waiting for ⌃⇥ in Chrome
[HH:MM:SS.mmm] ✅ Extension connected (1 client(s))
```

That last line means the extension found the helper. You're done.

## Usage

| Action | Result |
|---|---|
| Tap ⌃⇥ and release | Jump to the previously used tab |
| Tap ⌃⇥ twice (quickly) | Come back — reliable A↔B toggling |
| Hold ⌃, tap ⇥ repeatedly | Walk further back through history |
| Hold ⌃, press ⌃⇧⇥ | Walk forward |
| Hold ⌃, press ← / → | Move the cursor with arrow keys |
| Hold ⌃, click a card | Jump straight to that tab |
| Hold ⌃, hover a card | Move the cursor with the mouse |

### Tab ordering

Two tiers:

1. **Tabs you've visited this session** — sorted by last-visit time, most recent first
2. **Tabs you've never opened** (restored sessions, background links) — after the first group, in tab-strip order

The second tier is why a freshly started helper seems to list tabs "in tab bar order" — the first tier is still empty. It fills in as you browse.

### Thumbnails

`captureVisibleTab` can only capture the *visible* tab, so TabFlick grabs a screenshot each time a tab becomes active. Since every tab in your MRU list has been active by definition, thumbnails fill in naturally as you use Chrome.

`chrome://` and Web Store pages can never be captured (Chrome forbids it) — those cards fall back to the favicon.

## Troubleshooting

**Nothing happens when I press ⌃⇥**
Check the helper log (`~/Library/Logs/TabFlick/tabflick.log`, also printed to stdout) for `✅ Extension connected`. If it's absent, the extension isn't reaching the helper — make sure the helper is running and the extension is enabled. When disconnected, TabFlick deliberately lets ⌃⇥ pass through to Chrome's native behavior.

**`CGEvent.tapCreate failed`**
Accessibility permission. See step 4 — and remember the terminal app must be fully restarted after granting it.

**I changed the code and nothing changed**
The helper doesn't hot-reload. Its first log line prints the binary's build time — if that doesn't match your last build, you're running a stale process. Restart it. For extension changes, hit ↻ on `chrome://extensions`.

**Chrome nags about developer-mode extensions**
Expected while the extension is loaded unpacked. Web Store distribution is on the roadmap.

## Roadmap

- [ ] Ship the helper as a proper `.app` (`LSUIElement`) with a login-item toggle
- [ ] Publish the extension to the Chrome Web Store
- [ ] Supervise/auto-restart the helper
- [ ] Esc to cancel the current cycle
- [ ] Configurable hotkey

## Sponsor

If TabFlick saves you some tab-hunting, consider [sponsoring](https://www.lifedever.com/sponsor/) 💖

## License

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
