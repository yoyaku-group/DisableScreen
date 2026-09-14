// swift-tools-version: 6.0
import PackageDescription

// RunClosed (provisional name): the Swift successor to the DisableScreen Python
// app. This tranche ships the UI-independent Core, a read-only macOS system
// layer, and a CLI with a real idle-sleep wrapper. The menu-bar UI stays Python
// until Swift reaches display-feature parity (backlog G2 suite).
let package = Package(
    name: "RunClosed",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RunClosedCore"),
        .target(name: "RunClosedMacSystem", dependencies: ["RunClosedCore"]),
        .executableTarget(
            name: "runclosed",
            dependencies: ["RunClosedCore", "RunClosedMacSystem"]
        ),
        // G2a — pure presentation logic (ViewModel + renderer). AppKit lives in
        // the RunClosedMenuBar executable target so the Core stays platform-
        // agnostic and testable on Linux CI (per ADR 002).
        .target(
            name: "RunClosedApp",
            dependencies: ["RunClosedCore", "RunClosedMacSystem"]
        ),
        // G2a — menu-bar app shell (READ-ONLY; mutation toggles disabled).
        .executableTarget(
            name: "RunClosedMenuBar",
            dependencies: ["RunClosedCore", "RunClosedMacSystem", "RunClosedApp"]
        ),
        // Explicit lowercase path: this repo already has a `tests/` dir (Python),
        // and on a case-sensitive filesystem SwiftPM's default `Tests/` would not
        // resolve to it. Pin the path so the package builds on Linux CI too.
        .testTarget(name: "RunClosedCoreTests", dependencies: ["RunClosedCore"],
                    path: "tests/RunClosedCoreTests"),
        .testTarget(name: "RunClosedAppTests", dependencies: ["RunClosedCore", "RunClosedApp"],
                    path: "tests/RunClosedAppTests"),
    ]
)
