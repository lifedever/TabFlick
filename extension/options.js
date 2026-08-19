// 选项页。改动写进 chrome.storage.sync，background 那边靠 storage.onChanged
// 感知并立即重推列表，所以不需要额外的消息通道。

const DEFAULTS = {
  scopeToWindow: true,
};

const controls = {
  scopeToWindow: document.getElementById("scopeToWindow"),
};

async function restore() {
  const stored = await chrome.storage.sync.get(DEFAULTS);
  for (const [key, input] of Object.entries(controls)) {
    input.checked = stored[key];
  }
}

for (const [key, input] of Object.entries(controls)) {
  input.addEventListener("change", () => {
    chrome.storage.sync.set({ [key]: input.checked });
  });
}

// 在别处（另一个选项页标签、另一台同步设备）改过时跟着更新
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "sync") return;
  for (const [key, { newValue }] of Object.entries(changes)) {
    if (controls[key] && typeof newValue === "boolean") {
      controls[key].checked = newValue;
    }
  }
});

restore();
