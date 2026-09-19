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
        // Both mutation services (G2b display, G2c lid) consume their owned-
        // record stores from the persistence layer.
        .target(name: "RunClosedMacSystem",
                dependencies: ["RunClosedCore", "RunClosedPersistence"]),
        // Cross-target persistence layer (ADR 011): owns the on-disk lease
        // file path + atomic write discipline so the CLI writer and the
        // menu-bar reader can never drift apart.
        .target(name: "RunClosedPersistence", dependencies: ["RunClosedCore"]),
        .executableTarget(
            name: "runclosed",
            dependencies: ["RunClosedCore", "RunClosedMacSystem", "RunClosedPersistence",
                           "RunClosedHelperSupport"]
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
            dependencies: ["RunClosedCore", "RunClosedMacSystem", "RunClosedPersistence", "RunClosedApp"]
        ),
        // A14 — privileged LaunchDaemon helper (registration skeleton, no
        // XPC yet) + its support lib. See ADR 016.
        .target(name: "RunClosedHelperSupport"),
        .executableTarget(
            name: "RunClosedHelper",
            dependencies: ["RunClosedHelperSupport"]
        ),
        // Explicit lowercase path: this repo already has a `tests/` dir (Python),
        // and on a case-sensitive filesystem SwiftPM's default `Tests/` would not
        // resolve to it. Pin the path so the package builds on Linux CI too.
        .testTarget(name: "RunClosedCoreTests", dependencies: ["RunClosedCore"],
                    path: "tests/RunClosedCoreTests"),
        .testTarget(name: "RunClosedAppTests", dependencies: ["RunClosedCore", "RunClosedApp"],
                    path: "tests/RunClosedAppTests"),
        .testTarget(name: "RunClosedPersistenceTests",
                    dependencies: ["RunClosedCore", "RunClosedPersistence"],
                    path: "tests/RunClosedPersistenceTests"),
        .testTarget(name: "RunClosedHelperSupportTests",
                    dependencies: ["RunClosedHelperSupport"],
                    path: "tests/RunClosedHelperSupportTests"),
        .testTarget(name: "RunClosedMacSystemTests",
                    dependencies: ["RunClosedCore", "RunClosedMacSystem", "RunClosedPersistence"],
                    path: "tests/RunClosedMacSystemTests"),
    ]
)
