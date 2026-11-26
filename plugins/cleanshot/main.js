// CleanShot X（App 插件）：截图、录屏、识别文字。
// 走 CleanShot 公开的网址接口（cleanshot.com/docs-api），只挑不带参数就能用的几条；要指定文件的（贴图、标注某个文件、
// Quick Access）不放。命令名照 CleanShot 菜单里的叫法。

// 截图、录屏这类不把 CleanShot 拉到前台：平时按它的快捷键时前台 App 一直是活跃的，激活了它的话，
// 前台窗口在截图那一刻已经失焦，「截取窗口」截出来红绿灯是灰的。只有弹 CleanShot 自己窗口的两条要激活，
// 不然窗口可能落在后面。
const COMMANDS = {
  "capture-area": false,
  "capture-fullscreen": false,
  "capture-window": false,
  "capture-previous-area": false,
  "scrolling-capture": false,
  "self-timer": false,
  "capture-text": false,
  "record-screen": false,
  "all-in-one": false,
  "toggle-desktop-icons": false,
  "open-history": true,
  "open-from-clipboard": true,
}

tabflick.register({
  command(id) {
    if (!Object.prototype.hasOwnProperty.call(COMMANDS, id)) return
    tabflick.app.open("cleanshot://" + id, { activate: COMMANDS[id] })
  },
})
