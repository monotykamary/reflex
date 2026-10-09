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
    ],
    targets: [
        .executableTarget(
            name: "Reflex",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Reflex",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
