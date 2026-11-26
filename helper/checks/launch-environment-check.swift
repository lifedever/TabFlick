// LaunchEnvironment（启动时摘掉会话环境变量）的校验。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/LaunchEnvironment.swift \
//          checks/launch-environment-check.swift -o /tmp/launchenvcheck && /tmp/launchenvcheck
//
// 样本的变量名取自 2026-11-26 被污染的 Typora / Word 的真实环境（值换成占位）。
// 断言两头都写：该摘的摘了，用户自己 export 的、launchd 给的、自检用的一个都没碰。

import Darwin

var cases = 0
var failures = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    cases += 1
    if !ok {
        failures += 1
        print("✗ " + message())
    }
}

func env(_ names: [String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: names.map { ($0, "x") })
}

/// launchd 给 GUI App 的那份（TabFlick 正常启动时 ps -E 读到的）+ 用 launchctl setenv 设的
let launchd = [
    "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "SSH_AUTH_SOCK", "COMMAND_MODE", "OSLogRateLimit",
    "XPC_FLAGS", "XPC_SERVICE_NAME", "__CFBundleIdentifier", "__CF_USER_TEXT_ENCODING",
    "IDEA_VM_OPTIONS", "STUDIO_VM_OPTIONS",
]
/// shell 配置里 export 的（用户自己的设置）+ 自检用的
let userExports = [
    "JAVA_HOME", "JAVA_TOOL_OPTIONS", "GITHUB_PERSONAL_ACCESS_TOKEN", "FNM_DIR", "FNM_MULTISHELL_PATH",
    "HOMEBREW_PREFIX", "LANG", "LESS", "PAGER", "LS_COLORS", "MCP_TIMEOUT", "DISABLE_TELEMETRY",
    "DISABLE_AUTOUPDATER", "CFFIXED_USER_HOME",
]
let claudeSession = [
    "CLAUDECODE", "CLAUDE_CODE_CHILD_NOTES_DIR", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_EXECUTABLE", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_EFFORT", "CLAUDE_PID",
    "GIT_EDITOR", "NoDefaultCurrentDirectoryInExePath",
]
let terminalSession = [
    "AI_AGENT", "SHLVL", "PWD", "OLDPWD", "_", "TERM", "TERM_PROGRAM", "COLORTERM", "TERMINFO",
    "MUXY_SERVER_ID", "MUXY_SESSION_ID", "MUXY_SHELL_INTEGRATION", "MUXY_SHELL_INTEGRATION_DIR",
    "GHOSTTY_RESOURCES_DIR", "VSCODE_GIT_IPC_HANDLE", "TMUX",
]

@main
struct LaunchEnvironmentCheck {
    static func main() {
        // ① 从 Muxy 里的 Claude Code 会话启动（今天的现场）：会话的全摘，别的全留
        do {
            let all = launchd + userExports + claudeSession + terminalSession
            let removed = Set(LaunchEnvironment.sessionVariables(in: env(all)))
            for name in claudeSession + terminalSession {
                check(removed.contains(name), "Claude 会话：\(name) 应该摘掉")
            }
            for name in launchd + userExports {
                check(!removed.contains(name), "Claude 会话：\(name) 不该碰")
            }
        }

        // ② 普通终端里启动：没有 CLAUDECODE，用户自己设的 GIT_EDITOR、CLAUDE_CONFIG_DIR 要留着
        do {
            let all = launchd + userExports + ["GIT_EDITOR", "CLAUDE_CONFIG_DIR"] + terminalSession
            let removed = Set(LaunchEnvironment.sessionVariables(in: env(all)))
            for name in terminalSession {
                check(removed.contains(name), "普通终端：\(name) 应该摘掉")
            }
            for name in ["GIT_EDITOR", "CLAUDE_CONFIG_DIR"] + launchd + userExports {
                check(!removed.contains(name), "普通终端：\(name) 不该碰")
            }
        }

        // ③ 从程序坞 / 登录项启动：launchd 里用 launchctl setenv 设了 CLAUDE_CONFIG_DIR，一个都不摘
        do {
            let removed = LaunchEnvironment.sessionVariables(in: env(launchd + ["CLAUDE_CONFIG_DIR"]))
            check(removed.isEmpty, "正常启动：不该摘任何变量，实际摘了 \(removed)")
        }

        // ④ 前缀带着下划线比，只是名字开头相同的不算
        do {
            let lookalikes = ["CLAUDECODE", "CLAUDEX", "MUXYX", "TERMINAL_EMULATOR", "PWDX", "VSCODEX"]
            let removed = Set(LaunchEnvironment.sessionVariables(in: env(lookalikes)))
            for name in lookalikes.dropFirst() {
                check(!removed.contains(name), "前缀边界：\(name) 不该摘")
            }
        }

        // ⑤ 结果按名字排好（日志稳定、可比）
        do {
            let removed = LaunchEnvironment.sessionVariables(in: env(claudeSession + terminalSession))
            check(removed == removed.sorted(), "结果没排序：\(removed)")
        }

        // ⑥ scrub 真的作用在进程环境上（子进程、NSWorkspace 打开的 App 读的就是它）
        do {
            setenv("CLAUDECODE", "1", 1)
            setenv("CLAUDE_CODE_SESSION_ID", "x", 1)
            setenv("TF_CHECK_KEEP", "1", 1)
            let removed = LaunchEnvironment.scrub()
            check(removed.contains("CLAUDE_CODE_SESSION_ID"), "scrub 没返回摘掉的名字")
            check(getenv("CLAUDECODE") == nil && getenv("CLAUDE_CODE_SESSION_ID") == nil, "scrub 后进程环境里还在")
            check(getenv("TF_CHECK_KEEP") != nil, "scrub 摘了不该摘的")
        }

        if failures == 0 {
            print("✓ launch-environment：\(cases) 条全过")
        } else {
            print("✗ \(failures) / \(cases) 条失败")
            exit(1)
        }
    }
}
