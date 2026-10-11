// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebWatcher",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WebWatcher", targets: ["WebWatcher"])],
    targets: [
        .target(name: "WatcherCore"),
        .executableTarget(name: "WebWatcher", dependencies: ["WatcherCore"]),
        .testTarget(name: "WatcherCoreTests", dependencies: ["WatcherCore"])
    ]
)
