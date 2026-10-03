<h3 align="center">⌘ TabFlick</h3>

<p align="center">
  <strong>A tab switcher and search panel for Chrome on macOS.</strong><br>
  ⌃⇥ goes back to the last tab you used. ⌘E finds tabs, bookmarks, history, folders and apps.
</p>

<p align="center">
  <a href="https://github.com/lifedever/TabFlick/stargazers"><img src="https://img.shields.io/github/stars/lifedever/TabFlick?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Chromium-116%2B-7C3AED?style=flat-square" alt="Chromium">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/TabFlick/">🌐 <strong>Website</strong></a> ｜ <a href="#installation">🚀 <strong>Install</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>Sponsor</strong></a> ｜ <a href="README_zh.md">中文文档</a>
</p>

---

## Switcher — ⌃⇥

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/08/tabflick-demo-full.gif" width="820" alt="TabFlick switcher">
</p>

Chrome's ⌃⇥ walks the tab strip in order. TabFlick makes it walk the order you actually used, the way ⌘⇥ works for apps.

- **Stable A↔B.** Tap ⌃⇥ to go back, tap again to return. While ⌃ is held only a cursor moves; the switch commits on release, so tabs you pass through aren't counted as used.
- **Page thumbnails.** Recognise tabs by how they look, not by truncated titles.
- **Keys, arrows or mouse.** ⌃⇧⇥ goes back, arrows move while ⌃ is held, or click a card.
- **Per window.** Lists only the current window's tabs, each window with its own order. Can be turned off.
- **Two layouts.** A horizontal strip, or a grid that fits every tab on one screen.

## Search panel — ⌘E

<p align="center">
  <img src="docs/search-demo.gif" width="820" alt="TabFlick search panel">
</p>

One box for open tabs, recently closed tabs, bookmarks, history, favorite folders and installed apps.

- **Tab changes scope.** All, Browser tabs, Search, History, Browser bookmarks, Recently closed, Folders, Apps. Pick which ones are in the cycle and their order in Settings.
- **Pinyin works.** Chinese titles match full pinyin and initials.
- **Nothing found? Search the web** with the browser's own default engine, or with site search such as GitHub and YouTube (templates are editable).
- **From any app.** ⌥Space opens the panel outside the browser and searches every connected browser's tabs. With nothing typed it lists recent browser tabs and running apps together, most recent first; Enter goes back to what you were doing before.
- **⌘↩ for actions.** Copy the URL, title or a Markdown link, reload, return a pinned tab to its pinned URL, close the tab, delete from history, open a folder with another app or copy its path. The footer shows what Enter will do.
- **Built-in commands.** Type "lock" to lock the screen; with Amphetamine installed, type "amp" or "end" to start or end a session. The first time you run an Amphetamine command, macOS asks whether TabFlick may control it.
- **Learns as you go.** Search the same thing again and what you picked last time comes first; the closest match gets its own top row. Word initials (`pr` finds Pull Request) and one-letter typos still match.
- **Duplicate tabs are marked**, with an action to close the others.
- ⌘1–⌘9 pick a row, Esc clears the query before closing, ⌘, opens Settings.

## Also included

- **Pins that stick** — pinned tabs come back after a restart, on the last page you visited. Typed a different address into one? ⌘W takes it back to its pinned URL (press again and Chrome closes it as usual); the same action is in the menu bar and under ⌘↩.
- **Idle tab cleanup** — close tabs unused for 12 h, 24 h or 7 days; pinned, audible and grouped tabs stay. Off by default.
- **Menu bar tab list** — every tab by window, plus recently closed ones.
- **Favorite folders** — keep your usual folders in the menu bar and open them in any app.
- **Global switcher** — ⌃⇥ outside the browser lists every browser's tabs, grouped. Off by default.
- **Several browsers and profiles at once** — Chrome, Edge, Brave and other Chromium browsers; each browser and each profile keeps its own list, recently closed tabs and pins.
- **Eight languages** — 简体中文, 繁體中文, English, 日本語, 한국어, Español, Français, Deutsch.
- **In-app updates** — checks GitHub Releases and replaces itself in place.
- **Fails open** — if the extension isn't connected, ⌃⇥ falls back to Chrome's own switching instead of doing nothing.

## Installation

Requires macOS 14+ and Chrome (or another Chromium browser) 116+.

1. **App.** Download the DMG for your Mac from [Releases](https://github.com/lifedever/TabFlick/releases/latest) (`arm64` for Apple Silicon, `x86_64` for Intel) and drag TabFlick into Applications. If macOS says the developer can't be verified, right-click TabFlick in Applications and choose Open.
2. **Extension.** Download [TabFlick-Extension.zip](https://github.com/lifedever/TabFlick/releases/latest/download/TabFlick-Extension.zip), unzip it somewhere permanent, open `chrome://extensions`, turn on Developer mode and click **Load unpacked**. [Step-by-step guide](https://www.lifedever.com/TabFlick/install-extension.html).
3. **Accessibility.** On first launch System Settings opens at Accessibility with TabFlick already in the list; turn it on and the app relaunches. A lit menu bar icon means both halves are connected.

The extension asks for tabs, bookmarks, history, favicons and search. The data only goes to TabFlick on the same Mac over a local WebSocket. After an update, allow any new permissions Chrome asks about and reload the extension.

### Build from source

```bash
git clone https://github.com/lifedever/TabFlick.git
cd TabFlick
./scripts/dev-run.sh                      # run the helper in debug
./scripts/build-app.sh 0.0.0 --install    # or build TabFlick.app and install it
```

Use these scripts rather than a bare `swift build`: they pass the SDK path to the linker. Without it the binary records SDK 14.0 and macOS draws the whole app with the old appearance.

Load `extension/` as an unpacked extension (step 2). When running from Terminal, macOS attributes the Accessibility permission to Terminal; quit it completely (⌘Q) after granting.

## Shortcuts

All of them can be changed in Settings.

**Switcher** — while a browser is frontmost

| Keys | Result |
|---|---|
| ⌃⇥ | Switch to the previous tab |
| ⌃⇥⇥… | Hold ⌃ and keep tapping to go further back |
| ⌃⇧⇥ | Reverse |
| ⌃ ← → ↑ ↓ | Move while ⌃ is held (↑↓ move by row in the grid) |
| Release ⌃ | Switch |

**Search panel**

| Keys | Result |
|---|---|
| ⌘E | Open inside the browser; press again to close |
| ⌥Space | Open from any app, across all browsers |
| ⇥ / ⇧⇥ | Change scope |
| ⌘1–⌘9 | Pick a row |
| ⌘↩ | Actions: copy the URL, reload, close the tab, open a folder with another app… |
| ⌘, | Open Settings |

## Settings

Open from the menu bar icon, the TabFlick icon in the Chrome toolbar, or ⌘, in the search panel. Changes apply immediately.

| Page | What's there |
|---|---|
| General | Language, appearance, open at login, update checks, apps excluded from the global switcher |
| Switcher | Shortcut, per-window scope, layout, global switcher |
| Search panel | On/off, both shortcuts, what "All" shows when empty, Tab order and which modes are in it, site search templates |
| Tabs | Pinned tabs, idle tab lifetime, pin shortcut |
| Folders / Open With | Favorite folders and the apps offered to open them |
| Browsers | Connection and extension version per browser |

## How it works

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  Browser extension (MV3)│  ws://  │  Swift helper            │
│                         │◄───────►│                          │
│  · tabs / bookmarks     │  :41573 │  · CGEventTap  (keys)    │
│  · history / favicons   │         │  · NSPanel     (panels)  │
│  · captureVisibleTab    │         │  · MRU state machine     │
└─────────────────────────┘         └──────────────────────────┘
```

- **The extension cannot read the keyboard.** Since Chrome 33, `chrome.commands` refuses shortcuts containing Tab, so no extension can bind ⌃⇥.
- **The helper cannot read the tabs.** Tabs, bookmarks, history, thumbnails and switching all go through Chrome's extension APIs.

Thumbnails: `captureVisibleTab` only captures the visible tab, so TabFlick takes one each time a tab becomes active; they accumulate as you browse. `chrome://` pages and the Web Store can't be captured and show the favicon instead.

## Troubleshooting

The log is at `~/Library/Logs/TabFlick/tabflick.log` and is truncated on every launch.

- **⌃⇥ does nothing / Chrome switches in strip order.** Look for `✅ Extension connected` in the log. If it's missing, the extension isn't reaching the app: check it's enabled in `chrome://extensions` and TabFlick is running. TabFlick deliberately passes ⌃⇥ to Chrome while disconnected.
- **Bookmarks or history don't show up in search.** The extension is older than the app. Download the latest extension zip, replace the folder, and reload it.
- **`CGEvent.tapCreate failed`.** Accessibility permission is missing or stale. Re-grant it and fully quit and reopen TabFlick; macOS only reads it at launch.
- **Chrome warns about developer-mode extensions.** Chrome shows this for every unpacked extension. It doesn't affect TabFlick.

## Translations

UI strings live next to the code as `L10n.t("中文", "English")`; other languages are tables generated from `scripts/l10n/<lang>.json`. Fixes are welcome — edit the JSON, then run `python3 scripts/l10n/build.py --strict`. Terms and tone are in [scripts/l10n/GUIDE.md](scripts/l10n/GUIDE.md).

## Sponsor

TabFlick is free and open source. If it saves you time, you can [sponsor its development](https://www.lifedever.com/sponsor/) 💖

## License

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
