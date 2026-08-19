// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tabflick",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tabflick",
            path: "Sources/tabflick",
            // 语言模式停在 v5：event tap 的 C 回调需要文件级可变全局状态，
            // v6 的严格并发检查在这里只会逼出一堆 nonisolated(unsafe) 噪音。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
