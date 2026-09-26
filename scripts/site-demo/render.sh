#!/bin/bash
# 官网素材渲染：用真实的搜索面板代码 + 样例数据，在渐变背景上截图 / 录屏。
#   ./scripts/site-demo/render.sh            # 五张截图 + 一段视频，落到 docs/
# 桩文件（stubs.swift）由这里从 OverlayPanel.swift 抽 BrowserSupport / makeBackdrop 生成，
# 其余直接编译 helper 的真实源码，所以面板长什么样就渲染成什么样。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/helper/Sources/tabflick"
WORK="$(mktemp -d)"
cp "$SRC"/{TabSearchPanel,TabSearch,Pinyin,L10n,Log,AppSettings,LoginItem,FavoriteFolders,Toast,WindowShadow,AppCatalog}.swift "$WORK/"
sed -i '' 's/^private final class SearchPanel: NSPanel/final class SearchPanel: NSPanel/' "$WORK/TabSearchPanel.swift"
cp "$ROOT/scripts/site-demo/main.swift" "$WORK/"
python3 - "$SRC/OverlayPanel.swift" "$WORK/stubs.swift" <<'PY'
import sys
src=open(sys.argv[1]).read()
def between(a, b_after):
    i=src.index(a); j=src.index("\n    }\n", i)+7; return src[i:j]
backdrop=between("    static func makeBackdrop(size: NSSize, content: NSView) -> NSView {", None)
mask=between("    private static func roundedMask(radius: CGFloat) -> NSImage {", None)
i=src.index("@MainActor\nenum BrowserSupport {"); j=src.index("\n}\n", i)+3
bs=src[i:j]
stubs='''import AppKit
import SwiftUI
enum CursorSource { case keyboard, mouse }
struct TabInfo: Decodable { let id: Int; let windowId: Int; let title: String; let url: String; let favIconUrl: String; let lastAccessed: Double?; let pinned: Bool? }
extension TabInfo { var relativeLastAccessed: String? { relativeTime(msEpoch: lastAccessed) } }
struct IconInfo { let image: NSImage; let isLight: Bool }
struct SwitcherItem: Identifiable { let id: String; let tab: TabInfo; let browser: String?; let clientID: UUID
    init(tab: TabInfo, browser: String?, clientID: UUID) { self.id = "\\(clientID.uuidString)#\\(tab.id)"; self.tab = tab; self.browser = browser; self.clientID = clientID } }
struct BookmarkInfo: Decodable { let title: String; let url: String; let path: String; var clientID: UUID? = nil
    private enum CodingKeys: String, CodingKey { case title, url, path } }
struct HistoryInfo: Decodable { let title: String; let url: String; let lastVisitTime: Double; var clientID: UUID? = nil
    private enum CodingKeys: String, CodingKey { case title, url, lastVisitTime } }
enum CloseReason: String, Codable { case manual }
struct ClosedTab: Identifiable, Codable, Equatable { let id: String; let url: String; let title: String; let favIconUrl: String; let browser: String; let reason: CloseReason; let closedAt: Double
    var displayTitle: String { title.isEmpty ? url : title } }
@MainActor enum ChromeWindowLocator { static func frontmostWindowFrame() -> NSRect? { nil }; static var activeBundleID = "com.google.Chrome" }
private let kPanelCornerRadius: CGFloat = 14
private let kGlassBackdrop = true
@MainActor enum OverlayPanel {
    static var panelCornerRadius: CGFloat { kPanelCornerRadius }
    static var usesGlassBackdrop: Bool { kGlassBackdrop }
''' + backdrop + mask + "}\n\n" + bs
open(sys.argv[2],'w').write(stubs)
PY
cd "$WORK"
swiftc -O main.swift stubs.swift TabSearchPanel.swift TabSearch.swift Pinyin.swift L10n.swift Log.swift AppSettings.swift LoginItem.swift FavoriteFolders.swift Toast.swift WindowShadow.swift AppCatalog.swift -o demo -sdk "$(xcrun --show-sdk-path --sdk macosx)"
./demo shot s1 dark all git >/dev/null; ./demo shot s2 light all >/dev/null; ./demo shot s3 dark actions swift >/dev/null
./demo shot s4 dark folders >/dev/null; ./demo shot s5 light bookmarks >/dev/null
./demo video dark >/dev/null
ffmpeg -v error -y -i video.mov -vf "scale=1600:-2,format=yuv420p" -c:v libx264 -preset slow -crf 22 -movflags +faststart -an "$ROOT/docs/search-demo.mp4"
ffmpeg -v error -y -ss 3.2 -i "$ROOT/docs/search-demo.mp4" -frames:v 1 -q:v 3 "$ROOT/docs/search-demo-poster.jpg"
python3 - "$WORK" "$ROOT/docs" <<'PY'
import sys
from PIL import Image
work, docs = sys.argv[1], sys.argv[2]
for src, dst in {'s1':'search-all-dark','s2':'search-all-light','s3':'search-web-dark','s4':'search-folders-dark','s5':'search-bookmarks-light'}.items():
    im = Image.open(f'{work}/{src}.png').convert('RGB'); w, h = im.size
    im.resize((1400, int(h*1400/w)), Image.LANCZOS).save(f'{docs}/{dst}.jpg', quality=88, optimize=True)
PY
echo "done → $ROOT/docs"
