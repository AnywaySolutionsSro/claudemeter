// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v26)],
    products: [
        // Exposed so the Xcode project (app + widget extension) can depend on the core.
        .library(name: "ClaudeMeterCore", targets: ["ClaudeMeterCore"]),
    ],
    targets: [
        // Pure, dependency-free, fully unit-testable core: models + parsing + formatting.
        // Swift 6 mode: the core is Sendable-clean, so strict concurrency is enforced
        // by the compiler rather than by convention.
        .target(
            name: "ClaudeMeterCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The menu-bar app shell: AppKit status item + SwiftUI popover + networking + Keychain.
        .executableTarget(
            name: "ClaudeMeter",
            dependencies: ["ClaudeMeterCore"]
        ),
        .testTarget(
            name: "ClaudeMeterCoreTests",
            dependencies: ["ClaudeMeterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    // Target the latest macOS. The app shell stays in Swift 5 language mode (not
    // yet audited for strict concurrency — a separate cleanup); the core target
    // overrides this to Swift 6 above.
    swiftLanguageModes: [.v5]
)
