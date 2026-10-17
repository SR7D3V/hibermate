// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HibermateCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HibermateCore", targets: ["HibermateCore"]),
    ],
    targets: [
        // Pure logic plus Darwin-only helpers (sysctl, file IO). No IOKit, no
        // ServiceManagement: everything that touches power lives in the app and
        // helper targets behind the protocols declared here.
        .target(name: "HibermateCore"),
        .testTarget(name: "HibermateCoreTests", dependencies: ["HibermateCore"]),
    ]
)
