import Foundation

/// 启动时摘掉「启动我的那个会话」留下的环境变量。
///
/// 从终端或 Claude Code 会话里启动时（`build-app.sh --install` 末尾的 `open -a`、`dev-run.sh`），
/// TabFlick 继承那个 shell 的整份环境；之后经 `NSWorkspace`、`Process`、osascript 打开的每个 App
/// 都原样拿到这份环境（2026-11-26 实测：Typora、Word、Amphetamine 都带着 `CLAUDECODE`、
/// `CLAUDE_CODE_SESSION_ID`、`CLAUDE_EFFORT`、`GIT_EDITOR=true`）。在这些 App 里的终端起 `claude`，
/// 会被当成嵌套会话、继承上一个会话的 effort 和消息通道。
///
/// 只摘描述会话的变量，不动 shell 配置里 export 的（`JAVA_HOME`、token、`CFFIXED_USER_HOME`）：
/// 那些是用户自己的设置，自检用的变量也在里面。
enum LaunchEnvironment {

    /// Claude Code 给自己和子进程设的。只在带 `CLAUDECODE` 时摘：
    /// 用户也可能用 `launchctl setenv` 设 `CLAUDE_CONFIG_DIR` 这类配置，正常启动时不能动。
    nonisolated static let claudeNames: Set<String> = [
        "CLAUDECODE", "GIT_EDITOR", "NoDefaultCurrentDirectoryInExePath",
    ]
    nonisolated static let claudePrefixes = ["CLAUDE_"]

    /// 终端 / shell 会话的。launchd 给 GUI App 的环境里不会有，任何时候都摘。
    nonisolated static let sessionNames: Set<String> = [
        "AI_AGENT",
        "SHLVL", "PWD", "OLDPWD", "_",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO", "COLORTERM",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG",
        "TMUX", "TMUX_PANE", "STY", "WINDOWID",
    ]
    nonisolated static let sessionPrefixes = [
        "MUXY_", "ITERM_", "GHOSTTY_", "KITTY_", "WEZTERM_", "ALACRITTY_", "WARP_", "VSCODE_", "ZELLIJ",
    ]

    /// 纯函数：这份环境里该摘掉的变量名，按名字排好。
    nonisolated static func sessionVariables(in env: [String: String]) -> [String] {
        let fromClaude = env["CLAUDECODE"] != nil
        return env.keys.filter { name in
            if sessionNames.contains(name) { return true }
            if sessionPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
            guard fromClaude else { return false }
            return claudeNames.contains(name) || claudePrefixes.contains(where: { name.hasPrefix($0) })
        }.sorted()
    }

    /// 进程一开始、任何子进程和 App 被打开之前调用。返回摘掉的名字，只给日志用（不记值：里面有 token）。
    @discardableResult
    nonisolated static func scrub() -> [String] {
        let names = sessionVariables(in: ProcessInfo.processInfo.environment)
        for name in names { unsetenv(name) }
        return names
    }
}
