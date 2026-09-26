# TabFlick 界面翻译说明

输入：`scripts/l10n/source.json`，数组，每项 `{key, zh, refs}`。
- `key` 是英文原文，也是查表的键，**逐字照抄当键，不许改动一个字符**（包括弯引号、空格、换行）。
- `zh` 是简体中文原文，含义以中英两份一起为准；两者有出入时以中文为准（中文是作者写的第一稿）。
- `refs` 是源码位置（`文件:行号`），拿不准语境时去 `helper/Sources/tabflick/` 里看那一行附近的代码。

输出：`scripts/l10n/<lang>.json`，一个 JSON 对象 `{ "<key>": "<译文>", ... }`，**source.json 里每一个 key 都要有**，不多不少。UTF-8，`ensure_ascii` 关掉。

## 硬规则（校验脚本会查）

1. `{0}` `{1}` … 占位符原样保留，个数和编号与 key 一致；可以按语序调换位置。
2. 换行 `\n` 的数量与 key 一致（多行说明保持同样的分段）。
3. 这些原样保留、不翻译：`TabFlick`、`Chrome`、`Chromium`、`GitHub`、`YouTube`、`Raycast`、`Finder`、`Claude`、`Claude Code`、`macOS`、快捷键符号 `⌃ ⇥ ⌘ ⌥ ⇧ ↩ ⌫ ← → ↑ ↓ Esc Space Tab`、`chrome://extensions`、网址、文件路径、bundle id、`%s`。
4. key 末尾没有句号的（按钮、菜单项、标签、列表项），译文也不加句末标点；key 是完整句子的，按目标语言习惯加。

## 语气

- 这是给自己装扩展、会用快捷键的 macOS 用户看的工具界面。说事，不解释实现，不推销，不客套。
- 长度不要明显超过英文：菜单项、按钮、胶囊标签的地方很窄。
- 系统里已有的叫法一律用 **macOS / Chrome 在该语言里的官方用词**（系统设置里的面板名、Chrome 里的菜单名），不自造。
- 日语：句子用です・ます体，标签/按钮用名词形。韩语：句子用 -습니다/-세요 这类 Apple 常用体，标签用名词形。西/法/德：按钮和菜单项用动词原形或名词，说明文字用 macOS 该语言的惯用称呼方式（法语 vous；德语、西语尽量用无人称或不定式结构，和 macOS 一致）。
- 繁体中文按台湾用语（Chrome 繁中版、macOS 繁中版的叫法），不是简体逐字转换：标签→分頁、文件夹→資料夾、设置→設定、扩展→擴充功能、菜单栏→選單列、搜索→搜尋、应用→App 或 應用程式、快捷键→快速鍵、默认→預設、窗口→視窗、屏幕→螢幕、链接→連結、信息→資訊。

## 术语表（全项目一致，一处定了处处用）

| 中文 | English | 说明 |
|---|---|---|
| 切换器 | switcher | ⌃⇥ 弹出的那个缩略图浮层 |
| 全局切换器 | global switcher | 浏览器之外唤出、列所有浏览器标签的切换器 |
| 搜索面板 | search panel | ⌘E 弹出的搜索框 |
| 标签 | tab | 浏览器标签页（用 Chrome 该语言的叫法） |
| 置顶 | pin / pinned | 就是 Chrome 的「固定标签页」，用 Chrome 该语言的叫法 |
| 收藏（的文件夹） | favorite (folders) | 只用于文件夹 |
| 最近关闭 | recently closed | 用 Chrome 该语言的叫法 |
| 书签 / 历史记录 | bookmarks / history | 用 Chrome 该语言的叫法（繁中是「書籤 / 歷史記錄」，德语置顶是 anpinnen / loslösen） |
| 排除 | exclude | |
| 打开方式 | Open With | 用 Finder 该语言里「打开方式」菜单的叫法 |
| 扩展 | extension | 用 Chrome 该语言的叫法 |
| 辅助功能 | Accessibility | 用 macOS 系统设置里那个面板的名字 |
| 设置 | Settings | 用 macOS 该语言的叫法 |
| 状态栏 / 菜单栏 | menu bar | 用 macOS 该语言的叫法 |
| 站内搜索 | site search | 在某个网站里搜 |
| 全部 / 标签 / 搜索 / 历史记录 / 书签 / 最近关闭 / 文件夹 / 应用 | All / Tabs / Search / History / Bookmarks / Recently closed / Folders / Apps | 搜索面板的模式名，要短 |
