<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>Most-recently-used tab switching for Google Chrome, with a switcher overlay.</strong><br>
  Hold ⌃ and tap ⇥ to move through tabs in the order you used them.
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chrome-116%2B-7C3AED?style=flat-square" alt="Chrome">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/TabFlick/">🌐 <strong>Website</strong></a> ｜ <a href="#installation">🚀 <strong>Get Started</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>Sponsor</strong></a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/08/tabflick-demo-full.gif" width="860" alt="TabFlick demo">
</p>

<p align="center">
  <sub>Full-quality video on the <a href="https://www.lifedever.com/TabFlick/">website</a>.</sub>
</p>

Chrome cycles tabs in tab-strip order. TabFlick makes ⌃⇥ cycle them by recent use and shows a switcher overlay while you hold the key, the same way ⌘⇥ works for applications.

## Features

- ⌃⇥ switches to the tab you used last
- Tapping ⌃⇥ again returns to where you started, so A↔B toggling stays stable
- Every tab in the list carries a live page thumbnail
- Keyboard (⌃⇥, ⌃⇧⇥), arrow keys and mouse clicks all drive the switcher
- Two switcher layouts: a horizontal strip, or an adaptive grid that fits every tab on one screen
- The overlay is centered on the Chrome window in use, across multiple displays
- Light and dark appearance follow the system setting
- In-app updates — checks GitHub Releases on a schedule you pick and installs in place after one click
- If the helper or extension is unavailable, ⌃⇥ falls back to Chrome's built-in behavior

## How it works

TabFlick runs as two parts that talk over a loopback WebSocket:

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

Both halves are required:

- **The extension cannot read the keyboard.** `Tab` was removed from the supported-key list of `chrome.commands` in Chrome 33, so no extension can bind ⌃⇥.
- **The helper cannot read the tabs.** Titles, MRU order, thumbnails and switching all go through the `chrome.tabs` API.

## Installation

### Requirements

- macOS 14 or later
- Google Chrome 116 or later
- Xcode Command Line Tools (source build only) — `xcode-select --install`

### Option 1 — Download the app (recommended)

1. Grab the DMG for your Mac from [Releases](https://github.com/lifedever/TabFlick/releases/latest): `arm64` for Apple Silicon, `x86_64` for Intel
2. Drag **TabFlick.app** into **Applications** and launch it — a guided overlay walks you through granting Accessibility permission
3. Load the extension (step 3 below) — this part is always required
4. Done. Future versions update themselves: TabFlick checks GitHub Releases on your chosen schedule and installs in place after one click

### Option 2 — Build from source

### 1. Clone the repository

```bash
git clone https://github.com/lifedever/TabFlick.git
cd TabFlick
```

### 2. Build the helper

```bash
cd helper
swift build -c release
```

The binary is written to `helper/.build/release/tabflick`.

> During development, `swift build` / `swift run` (debug) compile much faster.

### 3. Load the extension

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. Click **Load unpacked**
4. Select the `extension/` folder of this repository

### 4. Grant Accessibility permission

The helper installs a `CGEventTap` to intercept ⌃⇥ before Chrome receives it, which requires Accessibility access.

Start it once:

```bash
./.build/release/tabflick
```

macOS shows a permission prompt. Grant access to the app that launched the binary (Terminal, iTerm, and so on), then quit that app completely and reopen it — permissions are read at process launch.

If `CGEvent.tapCreate` still fails, enable the same app under **System Settings → Privacy & Security → Input Monitoring** as well.

### 5. Run

```bash
./.build/release/tabflick
```

Startup output:

```
[HH:MM:SS.mmm] tabflick started — binary built ...
[HH:MM:SS.mmm] WebSocket server listening → ws://127.0.0.1:41573/
[HH:MM:SS.mmm] Keyboard hook installed — waiting for ⌃⇥ in Chrome
[HH:MM:SS.mmm] ✅ Extension connected (1 client(s))
```

The last line confirms the extension reached the helper.

## Usage

### Shortcuts

| Action | Result |
|---|---|
| Tap ⌃⇥ and release | Switch to the previously used tab |
| Tap ⌃⇥ twice | Return to the tab you started from |
| Hold ⌃, tap ⇥ repeatedly | Move further back through the history |
| Hold ⌃, press ⌃⇧⇥ | Move forward |
| Hold ⌃, press ← or → | Move the cursor with arrow keys |
| Hold ⌃, press ↑ or ↓ | Move by row (grid layout) |
| Hold ⌃, click a card | Switch to that tab immediately |
| Hold ⌃, hover a card | Move the cursor with the mouse |

The overlay appears when you press ⇥ and closes when you release ⌃. A single quick tap flashes it briefly, matching the behaviour of ⌘⇥.

### Settings

Open the settings window from the menu bar icon (**Settings…**, or ⌘, while a TabFlick window is focused) or by clicking the TabFlick icon in the Chrome toolbar. Changes take effect immediately — nothing needs to restart.

| Setting | Default | Effect |
|---|---|---|
| Limit switching to the current window | On | The switcher lists only the tabs of the Chrome window in use. Turn it off to cycle through every window's tabs in one list. |
| Switcher layout | Horizontal strip | Grid wraps the cards so every tab fits on one screen; ⌃↑/⌃↓ then move by row. |
| Check for updates | Daily | Automatic update checks: daily / weekly / never. Updates download, install in place, and relaunch after you confirm. |
| Language / Appearance / Open at Login | — | Interface language (中文/English), light/dark override, launch at login. |

Each window keeps its own history either way. Switching the scope setting off merges the lists for display; it does not discard anything.

### Tab ordering

The list has two sections:

1. **Tabs visited this session** — sorted by last visit, most recent first
2. **Tabs never opened** — restored sessions and background links, listed after the first section in tab-strip order

A freshly started helper has an empty first section, so the list initially matches tab-strip order. It reorders itself as you browse.

### Thumbnails

`captureVisibleTab` only captures the visible tab, so TabFlick takes a screenshot each time a tab becomes active. Every tab in the MRU list has been active at some point, so thumbnails accumulate through normal use.

`chrome://` pages and the Chrome Web Store cannot be captured — Chrome blocks it. Those cards show the favicon.

## Troubleshooting

Start with the helper log at `~/Library/Logs/TabFlick/tabflick.log`, which is also printed to the terminal. It is truncated on every launch, so it always describes the current run.

### ⌃⇥ does nothing

Look for `✅ Extension connected` in the log.

- **Line missing** — the extension is not reaching the helper. Confirm the helper process is running and the extension is enabled in `chrome://extensions`.
- **Line present, native switching still happens** — the connection dropped afterwards. TabFlick passes ⌃⇥ through to Chrome whenever it is disconnected, so Chrome's own switching is the expected fallback.

### `CGEvent.tapCreate failed`

Accessibility permission is missing or stale. Follow step 4 of the installation. The terminal app must be quit completely (⌘Q, not just closing the window) before a newly granted permission applies.

### Code changes have no effect

The helper does not hot-reload.

- **Helper changes** — the first log line prints the binary's build time. If it predates your last build, a stale process is still running; stop it and start again.
- **Extension changes** — click ↻ on the extension card in `chrome://extensions`.

### Chrome warns about developer-mode extensions

Chrome shows this notice for any unpacked extension. It does not affect TabFlick.

### The overlay opens on the wrong display

The overlay follows the frontmost Chrome window. With windows on several displays, the one most recently in front is used.

## Sponsor

TabFlick is free and open source. If you find it useful, you can [sponsor its development](https://www.lifedever.com/sponsor/) 💖

## License

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
