import AppKit
import Carbon.HIToolbox

/// 模拟按键。搜索面板计算结果的「粘贴到 X」：把结果贴回打开面板前在用的 App。照 PasteMemo 的 `simulateCommandV`。
enum Keystroke {
    /// 给某个 App 发一次 ⌘V。直接投给那个进程（`postToPid`），不看此刻键盘归谁 —— 面板刚收起时
    /// 键盘焦点还没回去，走系统事件流的 ⌘V 会落空。要辅助功能权限（键盘钩子本来就要）。
    static func commandV(to pid: pid_t) {
        // 修饰键完全由这里指定，不并入用户此刻还按着的键
        let source = CGEventSource(stateID: .privateState)
        // V 按当前键盘布局找（纯 Dvorak / Colemak 下 ANSI 的 V 位置打出来的不是 V）
        let vKey = virtualKey(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let commandKey = CGKeyCode(kVK_Command)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else { return }
        // 抽象的 ⌘ 位之外再带「左 ⌘」的设备位：远程桌面这类客户端认的是后者（PasteMemo issue #60）
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        commandDown.flags = flags
        vDown.flags = flags
        vUp.flags = flags
        commandUp.flags = []
        for event in [commandDown, vDown, vUp, commandUp] { event.postToPid(pid) }
    }

    /// 当前键盘布局下，哪个键（不按修饰键）打出这个字符。读不到布局时 nil。
    private static func virtualKey(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character)
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            for code in 0..<128 {
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: chars, count: length) == target { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
