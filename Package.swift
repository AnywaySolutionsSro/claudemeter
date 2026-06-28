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
        .target(
            name: "ClaudeMeterCore"
        ),
        // The menu-bar app shell: AppKit status item + SwiftUI popover + networking + Keychain.
        .executableTarget(
            name: "ClaudeMeter",
            dependencies: ["ClaudeMeterCore"]
        ),
        .testTarget(
            name: "ClaudeMeterCoreTests",
            dependencies: ["ClaudeMeterCore"]
        ),
    ],
    // Target the latest macOS, but keep the Swift 5 language mode: the existing app
    // code isn't audited for Swift 6 strict concurrency yet (a separate cleanup).
    swiftLanguageModes: [.v5]
)
