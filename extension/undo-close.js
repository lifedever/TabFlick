// TabFlick — ⌘Z 恢复刚关闭的标签（Arc 的做法）
//
// 挂在每个网页的顶层框架里，只认 ⌘Z 一个键。⌘Z 在浏览器里多数时候是「撤销输入」，
// 所以下面几条都满足才算数，否则当没看见，网页和浏览器照常处理：
//   · 用户真按的（isTrusted），不是按住连发，不在组字
//   · 焦点不在能输入的地方（输入框、可编辑区域，含 shadow DOM 里的）
//   · 网页自己没占用这次按键（Figma、Google 文档这类自己做撤销的都会 preventDefault）
// 最后一条只能等事件派发完再看：挂在 window 冒泡阶段，下一轮任务里读 defaultPrevented。
//
// 为什么不在 helper 的键盘钩子里拦：那边分不出焦点在不在输入框、网页用没用 ⌘Z，
// 要分清就得读网页的辅助功能树，Chrome 会因此对所有网页打开无障碍模式，整体变慢。
//
// 恢复哪一个、开关开没开由 background.js 的 undoCloseTab 决定，这里只报一声。

(() => {
  const KEY = "__tabflickUndoClose";

  // 扩展更新后，旧脚本还留在已打开的页面里，新的一份又补注入进来（background.js 的
  // injectUndoClose）：同一个隔离环境里先摘掉旧的监听，只留一份，免得一次按键报两遍
  const previous = globalThis[KEY];
  if (typeof previous === "function") window.removeEventListener("keydown", previous);

  // 不接收文字输入的 input：焦点停在这些上面（刚点过的复选框、提交按钮）不算在输入
  const NON_TEXT_INPUTS = new Set([
    "button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit",
  ]);

  function isTextEntry(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.isContentEditable) return true;
    switch (el.tagName) {
      case "TEXTAREA":
      case "SELECT":
        return true;
      case "INPUT":
        return !NON_TEXT_INPUTS.has(String(el.type || "text").toLowerCase());
      // 焦点在内嵌页面 / 插件里：那边什么情况看不到，按在输入处理
      case "IFRAME":
      case "FRAME":
      case "OBJECT":
      case "EMBED":
        return true;
      default:
        return false;
    }
  }

  function focusedElement() {
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el;
  }

  function isUndoKey(e) {
    if (!e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return false;
    const key = typeof e.key === "string" ? e.key.toLowerCase() : "";
    // 俄语这类非拉丁布局按住 ⌘ 时 key 可能是本地字符，这时才退回看物理键位。
    // 按出来是 ASCII 的一律认字符：Dvorak 在 QWERTY 的 Z 位上是分号，那是 ⌘; 不是 ⌘Z
    return /^[\x20-\x7e]$/.test(key) ? key === "z" : e.code === "KeyZ";
  }

  function onKeyDown(e) {
    if (!e.isTrusted || e.repeat || e.isComposing || !isUndoKey(e)) return;
    if (document.designMode === "on") return;
    const target = typeof e.composedPath === "function" ? e.composedPath()[0] : e.target;
    if (isTextEntry(target) || isTextEntry(focusedElement())) return;

    setTimeout(() => {
      if (e.defaultPrevented) return;
      // 扩展被更新 / 卸载后，这份脚本还挂在页面上，但已经联系不上扩展了
      if (!globalThis.chrome?.runtime?.id) {
        window.removeEventListener("keydown", onKeyDown);
        return;
      }
      try {
        chrome.runtime.sendMessage({ target: "sw", type: "undoCloseTab" }).catch(() => {});
      } catch {
        window.removeEventListener("keydown", onKeyDown);
      }
    }, 0);
  }

  globalThis[KEY] = onKeyDown;
  window.addEventListener("keydown", onKeyDown);
})();
