// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LockDown",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LockDown", targets: ["LockDownApp"]),
        .executable(name: "lockdownd", targets: ["lockdownd"]),
    ],
    targets: [
        // Shared models, lock rules, domain matching and the IPC protocol.
        .target(name: "LockDownCore"),
        // Root daemon: DNS blocker, pf firewall rules, lock engine host, watchdog.
        .executableTarget(name: "lockdownd", dependencies: ["LockDownCore"]),
        // GUI app; the same binary runs the per-user agent with --agent.
        .executableTarget(name: "LockDownApp", dependencies: ["LockDownCore"]),
        .testTarget(name: "LockDownCoreTests", dependencies: ["LockDownCore"]),
    ]
)
