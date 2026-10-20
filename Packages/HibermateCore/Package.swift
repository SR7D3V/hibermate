// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HibermateCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HibermateCore", targets: ["HibermateCore"]),
        .library(name: "HibermateHelperKit", targets: ["HibermateHelperKit"]),
    ],
    targets: [
        // Only what the privileged helper needs. Kept separate so the helper
        // binary changes only when helper code changes: an unsigned helper is
        // pinned to its exact build, and every change needs re-approval in
        // Login Items.
        .target(name: "HibermateHelperKit"),
        // Pure logic plus Darwin-only helpers (sysctl, file IO). No IOKit, no
        // ServiceManagement: everything that touches power lives in the app and
        // helper targets behind the protocols declared here.
        .target(name: "HibermateCore", dependencies: ["HibermateHelperKit"]),
        .testTarget(name: "HibermateCoreTests", dependencies: ["HibermateCore"]),
    ]
)
