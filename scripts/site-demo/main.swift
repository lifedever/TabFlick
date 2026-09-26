import AppKit
import SwiftUI

// ── 参数：shot <name> <dark|light> <mode> <query>   |  video <dark|light>
let args = CommandLine.arguments.dropFirst().map { $0 }
let command = args.first ?? "shot"
let isVideo = command == "video"
let shotName = isVideo ? "video" : (args.count > 1 ? args[1] : "shot")
let appearanceName = isVideo ? (args.count > 1 ? args[1] : "dark") : (args.count > 2 ? args[2] : "dark")
let modeName = args.count > 3 ? args[3] : "all"
let query = args.count > 4 ? args[4] : ""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)

// ── 背景：柔和渐变的大窗口，模拟浮在桌面 / 网页上
final class GradientView: NSView {
    var dark = true
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = dark
            ? [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.30, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.26, alpha: 1)]
            : [NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.92, blue: 0.94, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.96, blue: 0.97, alpha: 1)]
        NSGradient(colors: colors)!.draw(in: bounds, angle: 28)
        // 几个虚化的色块，让玻璃有东西可折射
        let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.22, 0.65, 260, NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.95, alpha: dark ? 0.35 : 0.30)),
            (0.72, 0.30, 320, NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.55, alpha: dark ? 0.30 : 0.25)),
            (0.55, 0.80, 200, NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.70, alpha: dark ? 0.28 : 0.25)),
        ]
        for (fx, fy, r, c) in blobs {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width * fx - r / 2, y: bounds.height * fy - r / 2, width: r, height: r)).fill()
        }
    }
}
let screen = NSScreen.main!
let bg = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
let gv = GradientView(frame: NSRect(origin: .zero, size: screen.frame.size)); gv.dark = appearanceName == "dark"
bg.contentView = gv; bg.level = .normal; bg.isOpaque = true; bg.orderFrontRegardless()

// ── 样例数据
let cid = UUID()
let now = Date().timeIntervalSince1970 * 1000
func tab(_ id: Int, _ title: String, _ url: String, _ minutesAgo: Double, pinned: Bool = false) -> SwitcherItem {
    SwitcherItem(tab: TabInfo(id: id, windowId: 1, title: title, url: url,
                              favIconUrl: "https://icons.duckduckgo.com/ip3/\(URL(string: url)!.host!).ico",
                              lastAccessed: now - minutesAgo * 60_000, pinned: pinned), browser: nil, clientID: cid)
}
let tabs: [SwitcherItem] = [
    tab(1, "TabFlick — Arc-style tab switcher for Chrome", "https://lifedever.github.io/TabFlick/", 0),
    tab(2, "GitHub - lifedever/TabFlick: Arc-like MRU tab switcher", "https://github.com/lifedever/TabFlick", 2),
    tab(3, "Swift Forums", "https://forums.swift.org/", 5),
    tab(4, "Claude", "https://claude.ai/", 9),
    tab(5, "Liquid Glass — Apple Developer Documentation", "https://developer.apple.com/documentation/technologyoverviews/liquid-glass", 14, pinned: true),
    tab(6, "Hacker News", "https://news.ycombinator.com/", 21),
    tab(7, "Raycast - Your shortcut to everything", "https://www.raycast.com/", 33),
    tab(8, "Figma: The Collaborative Interface Design Tool", "https://www.figma.com/", 47),
    tab(9, "MDN Web Docs", "https://developer.mozilla.org/", 65),
    tab(10, "YouTube", "https://www.youtube.com/", 90),
]
func closedTab(_ id: Int, _ title: String, _ url: String, _ minutesAgo: Double) -> ClosedTab {
    ClosedTab(id: "c\(id)", url: url, title: title, favIconUrl: "https://icons.duckduckgo.com/ip3/\(URL(string: url)!.host!).ico",
              browser: "com.google.Chrome", reason: .manual, closedAt: now - minutesAgo * 60_000)
}
let closed = [
    closedTab(1, "git rebase 交互式教程", "https://git-scm.com/docs/git-rebase", 12),
    closedTab(2, "Stack Overflow - How to squash commits", "https://stackoverflow.com/questions/5189560", 40),
    closedTab(3, "Notion – The all-in-one workspace", "https://www.notion.so/", 130),
]
let bookmarks = [
    BookmarkInfo(title: "GitHub", url: "https://github.com/", path: "书签栏"),
    BookmarkInfo(title: "GitHub Actions 文档", url: "https://docs.github.com/actions", path: "书签栏 / 开发"),
    BookmarkInfo(title: "Swift Package Index", url: "https://swiftpackageindex.com/", path: "书签栏 / 开发"),
    BookmarkInfo(title: "Dribbble - Discover the World's Top Designers", url: "https://dribbble.com/", path: "书签栏 / 设计"),
    BookmarkInfo(title: "Vercel", url: "https://vercel.com/", path: "书签栏 / 部署"),
]
let history = [
    HistoryInfo(title: "gitignore.io - Create useful .gitignore files", url: "https://www.toptal.com/developers/gitignore", lastVisitTime: now - 3 * 3_600_000),
    HistoryInfo(title: "GitLab: The DevSecOps Platform", url: "https://about.gitlab.com/", lastVisitTime: now - 26 * 3_600_000),
    HistoryInfo(title: "Swift.org - Welcome to Swift.org", url: "https://www.swift.org/", lastVisitTime: now - 50 * 3_600_000),
]
let home = FileManager.default.homeDirectoryForCurrentUser.path
let folders = [
    FavoriteFolder(path: "\(home)/Documents/Dev/myspace/TabFlick", addedAt: now - 5e6, openedAt: now - 3e5),
    FavoriteFolder(path: "\(home)/Documents/Dev/myspace/PasteMemo", addedAt: now - 8e6, openedAt: now - 2e6),
    FavoriteFolder(path: "\(home)/Downloads", addedAt: now - 9e6, openedAt: nil),
    FavoriteFolder(path: "\(home)/Desktop", addedAt: now - 9.5e6, openedAt: nil),
]
var openers: [OpenerApp] = [
    OpenerApp(name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
]
MainActor.assumeIsolated {
    for path in ["/Applications/Ghostty.app", "/Applications/iTerm.app", "/Applications/Warp.app", "/System/Applications/Utilities/Terminal.app",
                 "/Applications/Visual Studio Code.app", "/Applications/Claude.app", "/Applications/Xcode.app"]
    where FileManager.default.fileExists(atPath: path) {
        openers.append(OpenerApp(name: OpenerCatalog.appDisplayName(URL(fileURLWithPath: path)), url: URL(fileURLWithPath: path)))
    }
}
let sites = [SiteSearch(name: "GitHub", template: "https://github.com/search?q=%s"),
             SiteSearch(name: "YouTube", template: "https://www.youtube.com/results?search_query=%s")]
let catalog = MainActor.assumeIsolated { AppCatalog() }

// ── 图标：favicon 走网络，本机文件走 NSWorkspace
var iconCache: [String: IconInfo] = [:]
let iconLock = NSLock()
func downscale(_ image: NSImage, _ side: CGFloat) -> NSImage {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), max(cg.width, cg.height) > Int(side),
          let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) } ?? image
}
func prefetch(_ urlsByKey: [String: String], done: @escaping () -> Void) {
    let group = DispatchGroup()
    for (key, url) in urlsByKey {
        guard let u = URL(string: url) else { continue }
        group.enter()
        URLSession.shared.dataTask(with: u) { data, _, _ in
            if let data, let img = NSImage(data: data) {
                iconLock.lock(); iconCache[key] = IconInfo(image: downscale(img, 64), isLight: false); iconLock.unlock()
            }
            group.leave()
        }.resume()
    }
    group.notify(queue: .main, execute: done)
}
var wanted: [String: String] = [:]
for t in tabs { wanted[t.tab.favIconUrl] = t.tab.favIconUrl }
for c in closed { wanted[c.favIconUrl] = c.favIconUrl }
for b in bookmarks { let h = URL(string: b.url)!.host!; wanted["site:" + h] = "https://icons.duckduckgo.com/ip3/\(h).ico" }
for h in history { let host = URL(string: h.url)!.host!; wanted["site:" + host] = "https://icons.duckduckgo.com/ip3/\(host).ico" }
for s in sites { wanted["site:" + s.host] = "https://icons.duckduckgo.com/ip3/\(s.host).ico" }

let panel = MainActor.assumeIsolated { TabSearchPanel() }
MainActor.assumeIsolated {
    panel.model.iconProvider = { keys in
        var map: [String: IconInfo] = [:]
        iconLock.lock(); defer { iconLock.unlock() }
        for key in keys where !key.isEmpty {
            if key.hasPrefix("file:") {
                let path = String(key.dropFirst(5))
                if let hit = iconCache[key] { map[key] = hit; continue }
                if FileManager.default.fileExists(atPath: path) {
                    let info = IconInfo(image: downscale(NSWorkspace.shared.icon(forFile: path), 64), isLight: false)
                    iconCache[key] = info; map[key] = info
                }
            } else if let hit = iconCache[key] { map[key] = hit }
        }
        return map
    }
}
let modes: [SearchMode] = [.all, .tabs, .actions, .history, .bookmarks, .closed, .folders, .apps]

@MainActor func show() {
    panel.show(items: tabs, closed: closed, bookmarks: bookmarks, folders: folders, apps: catalog.entries, openers: openers,
               siteSearches: sites, modes: modes, allEmptyContent: .tabs, icons: [:], global: true,
               showBrowserBadges: false, searchBrowser: "com.google.Chrome")
    panel.setHistory(history, for: query)
}
@MainActor func typeText(_ text: String) {
    guard let win = NSApp.windows.first(where: { $0 is SearchPanel }),
          let editor = win.firstResponder as? NSTextView else { return }
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
}
@MainActor func panelFrame() -> NSRect { NSApp.windows.first { $0 is SearchPanel }?.frame ?? .zero }

func capture(_ file: String, rect: NSRect) {
    let H = screen.frame.height
    let t = Process(); t.launchPath = "/usr/sbin/screencapture"
    t.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(H - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", file]
    t.launch(); t.waitUntilExit()
}

prefetch(wanted) {
    MainActor.assumeIsolated {
        catalog.refreshIfStale {
            if isVideo { runVideo() } else { runShot() }
        }
    }
}

func parkMouse() {
    CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 4, y: screen.frame.maxY - 4))
}

@MainActor func runShot() {
    parkMouse()
    show()
    if let m = SearchMode(rawValue: modeName) { panel.model.select(m) }
    if !query.isEmpty { typeText(query) }
    panel.setHistory(history, for: query)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        MainActor.assumeIsolated {
            let f = panelFrame().insetBy(dx: -70, dy: -70)
            capture("./\(shotName).png", rect: f)
            exit(0)
        }
    }
}

@MainActor func runVideo() {
    // 固定录制区域：面板贴屏幕居中偏上、宽 680；高度按 10 行留足
    let W = screen.visibleFrame.width, top = screen.visibleFrame.maxY - screen.visibleFrame.height * 0.16
    let rect = NSRect(x: screen.visibleFrame.minX + (W - 680) / 2 - 70, y: top - 640 + 40, width: 820, height: 680)
    let H = screen.frame.height
    parkMouse()
    let rec = Process(); rec.launchPath = "/usr/sbin/screencapture"
    rec.arguments = ["-x", "-V", "16", "-R", "\(Int(rect.minX)),\(Int(H - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", "./video.mov"]
    rec.launch()
    var t: Double = 1.2
    func at(_ delay: Double, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(block) }
    }
    at(t) { show() }
    t += 1.0
    for ch in "git" { at(t) { typeText(String(ch)); panel.setHistory(history, for: panel.model.query.trimmingCharacters(in: .whitespaces)) }; t += 0.22 }
    t += 1.8
    at(t) { panel.model.cycleMode(1) }; t += 1.3   // 标签
    at(t) { panel.model.cycleMode(1) }; t += 1.4   // 搜索
    at(t) { panel.model.query = "" }; t += 0.5
    at(t) { panel.model.cycleMode(1); panel.setHistory(history, for: "") }; t += 1.3   // 历史
    at(t) { panel.model.cycleMode(1) }; t += 1.3   // 书签
    at(t) { panel.model.cycleMode(1) }; t += 1.2   // 最近关闭
    at(t) { panel.model.cycleMode(1) }; t += 1.4   // 文件夹
    at(t) { panel.model.cycleMode(1) }; t += 1.5   // 应用
    at(t) { _ = panel.model.escape() }; t += 1.3   // 回到全部
    at(t) { panel.close() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 18.5) { rec.waitUntilExit(); exit(0) }
}
app.run()
