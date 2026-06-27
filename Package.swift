// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v13)],
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
    ]
)
