// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reflex",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Reflex", targets: ["Reflex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Reflex",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Reflex",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
