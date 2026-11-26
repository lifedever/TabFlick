// Amphetamine（App 插件）：开始、结束会话。
// 走 Amphetamine 公开的 AppleScript 接口：脚本写死在 manifest 的 app.scripts 里，这里只按名字调（插件拼不出别的脚本）。
// 时长、是否允许显示器睡眠都用 Amphetamine 设置里的默认值（它的脚本接口不传参数时就是这样）。

const TEXT = {
  "zh": {
    "started": "已开始新会话",
    "ended": "已结束会话",
    "none": "现在没有进行中的会话",
    "failed": "没能执行「{0}」"
  },
  "zh-Hant": {
    "started": "已開始新工作階段",
    "ended": "已結束工作階段",
    "none": "目前沒有進行中的工作階段",
    "failed": "無法執行「{0}」"
  },
  "en": {
    "started": "Session started",
    "ended": "Session ended",
    "none": "No session is running",
    "failed": "Couldn't run “{0}”"
  },
  "ja": {
    "started": "セッションを開始しました",
    "ended": "セッションを終了しました",
    "none": "実行中のセッションはありません",
    "failed": "「{0}」を実行できませんでした"
  },
  "ko": {
    "started": "세션을 시작했습니다",
    "ended": "세션을 종료했습니다",
    "none": "진행 중인 세션이 없습니다",
    "failed": "‘{0}’ 실행할 수 없음"
  },
  "es": {
    "started": "Sesión iniciada",
    "ended": "Sesión finalizada",
    "none": "No hay ninguna sesión en curso",
    "failed": "No se pudo ejecutar “{0}”"
  },
  "fr": {
    "started": "Session démarrée",
    "ended": "Session terminée",
    "none": "Aucune session en cours",
    "failed": "Impossible d’exécuter « {0} »"
  },
  "de": {
    "started": "Sitzung gestartet",
    "ended": "Sitzung beendet",
    "none": "Keine Sitzung aktiv",
    "failed": "„{0}“ konnte nicht ausgeführt werden"
  }
}

function t(key) {
  const table = TEXT[tabflick.locale] || (tabflick.locale === "zh-Hant" ? TEXT.zh : null) || TEXT.en
  return table[key] || TEXT.en[key]
}

// 没授权（"not permitted"）TabFlick 自己会弹 toast 指路，这里不再说一遍
function reportFailure(title, error) {
  const message = String(error && error.message ? error.message : error)
  if (message === "not permitted") return
  tabflick.toast(t("failed").replace("{0}", title), message)
}

tabflick.register({
  async command(id) {
    if (id === "start") {
      try {
        await tabflick.app.runScript("start")
        tabflick.toast(t("started"), "Amphetamine")
      } catch (error) {
        reportFailure("Amphetamine", error)
      }
    } else if (id === "end") {
      try {
        // 先问有没有会话：没有也照结束的话，回响「已结束」是在说假话
        const output = await tabflick.app.runScript("end")
        tabflick.toast(output === "none" ? t("none") : t("ended"), "Amphetamine")
      } catch (error) {
        reportFailure("Amphetamine", error)
      }
    }
  },
})
