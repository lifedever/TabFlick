TabFlick — 安装说明 / Setup Guide
================================================================

【中文】

1. 安装
   把 TabFlick.app 拖进左边的「应用程序」文件夹。

2. 首次打开会被系统拦下
   双击时如果提示「无法打开，因为无法验证开发者」或「已损坏」，
   这是因为本应用没有 Apple 付费开发者证书的签名，不是真的有问题。

   两种解决方式，任选其一：

   a) 在「应用程序」里【右键】TabFlick →「打开」→ 再点「打开」
      （只需做一次，之后双击即可）

   b) 打开「终端」执行一行命令：
        xattr -dr com.apple.quarantine /Applications/TabFlick.app

3. 授予「辅助功能」权限
   TabFlick 需要在 Chrome 收到之前拦截 ⌃⇥，macOS 只允许有辅助功能
   权限的应用这样做。首次启动会弹窗引导，或手动前往：

     系统设置 → 隐私与安全性 → 辅助功能 → 打开 TabFlick

   授权后需要重新启动 TabFlick（macOS 只在进程启动时读取权限）。

4. 安装 Chrome 扩展（必需）
   TabFlick 由两部分组成，缺一不可。扩展需要手动加载：

     ① 打开 chrome://extensions
     ② 右上角打开「开发者模式」
     ③ 点「加载已解压的扩展程序」
     ④ 选择源码仓库里的 extension 目录
        （从 https://github.com/lifedever/TabFlick 下载）

   菜单栏图标变亮、显示「Connected」即表示接通。

5. 关于更新后要重新授权
   由于没有开发者证书，应用只能使用 ad-hoc 签名。macOS 通过代码哈希
   识别这类应用，而每次更新哈希都会变，系统会把新版本当作另一个应用，
   因此【每次更新后需要重新授予辅助功能权限】。
   TabFlick 会在启动时检测并弹窗引导，跟着点两下即可。

   想彻底避免这一步，可以自行从源码编译并用自己的证书签名。


================================================================

【English】

1. Install
   Drag TabFlick.app into the Applications folder on the left.

2. macOS will block the first launch
   If you see "cannot be opened because the developer cannot be verified"
   or "is damaged", that is because this app is not signed with a paid
   Apple Developer certificate — nothing is actually wrong with it.

   Either of these works:

   a) In Applications, RIGHT-CLICK TabFlick → Open → Open
      (once only; double-click works from then on)

   b) In Terminal:
        xattr -dr com.apple.quarantine /Applications/TabFlick.app

3. Grant Accessibility permission
   TabFlick intercepts ⌃⇥ before Chrome receives it, which macOS only
   allows for apps with Accessibility access. The first launch shows a
   prompt, or go to:

     System Settings → Privacy & Security → Accessibility → enable TabFlick

   Relaunch TabFlick afterwards — macOS only reads this permission when a
   process starts.

4. Install the Chrome extension (required)
   TabFlick is two halves and needs both. Load the extension manually:

     1. Open chrome://extensions
     2. Turn on Developer mode (top right)
     3. Click "Load unpacked"
     4. Select the extension folder from the source repository
        (get it at https://github.com/lifedever/TabFlick)

   The menu bar icon brightens and reads "Connected" once they connect.

5. Why permission resets after each update
   Without a developer certificate the app can only be ad-hoc signed.
   macOS identifies such apps by their code hash, which changes with every
   build — so after an update the system treats it as a different app and
   ACCESSIBILITY PERMISSION MUST BE GRANTED AGAIN.
   TabFlick detects this at launch and walks you through it.

   To avoid this entirely, build from source and sign with your own
   certificate.

================================================================
https://www.lifedever.com/TabFlick/
