// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacolimaKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacolimaKit", targets: ["MacolimaKit"]),
    ],
    targets: [
        .target(name: "MacolimaKit"),
        .testTarget(
            name: "MacolimaKitTests",
            dependencies: ["MacolimaKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
