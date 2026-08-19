import Cocoa

let kPort: UInt16 = 41573

// main.swift 的 top-level 代码运行在主线程，等同于 MainActor 上下文。
MainActor.assumeIsolated {

    // .accessory：有窗口能力但不占 Dock、不抢激活。浮层要的就是这个。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    log("tabflick started — binary built \(binaryBuildTime())")

    let server = WebSocketServer(port: kPort)
    let controller = MRUController(server: server)

    server.onText = { data in
        MainActor.assumeIsolated { controller.handleMessage(data) }
    }
    server.onClientCountChange = { count in
        MainActor.assumeIsolated { controller.handleClientCountChange(count) }
    }

    do {
        try server.start()
        log("WebSocket server listening → ws://127.0.0.1:\(kPort)/")
    } catch {
        log("❌ Failed to start WebSocket server: \(error)")
        exit(1)
    }

    let tap = EventTap()
    do {
        try tap.start(
            onStep: { backward in
                MainActor.assumeIsolated { controller.step(backward: backward) }
            },
            onCommit: {
                MainActor.assumeIsolated { controller.commit() }
            }
        )
        log("Keyboard hook installed — waiting for ⌃⇥ in Chrome")
    } catch {
        print("\n❌ \(error)\n")
        exit(1)
    }

    print("""

    ╭──────────────────────────────────────────────────────────╮
    │  TabFlick — MRU tab switcher for Chrome                  │
    ╰──────────────────────────────────────────────────────────╯

    Log file: \(kLogPath)

    Waiting for the extension to connect. If you haven't loaded it yet:
      1. Open chrome://extensions
      2. Enable "Developer mode"
      3. "Load unpacked" → select this repo's extension/ folder

    Shortcuts (while Chrome is frontmost):
      ⌃⇥            switch to the previously used tab
      ⌃ + ⇥ ⇥ …     hold ⌃ and keep tapping to walk further back
      ⌃⇧⇥ / ⌃←→     move the cursor backward / with arrow keys
      click a card  jump straight to that tab

    Press Ctrl+C to quit.
    ──────────────────────────────────────────────────────────

    """)
    fflush(stdout)
}

NSApplication.shared.run()
