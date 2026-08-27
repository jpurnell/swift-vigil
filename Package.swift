// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-vigil",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VigilKit", targets: ["VigilKit"]),
        .executable(name: "vigil", targets: ["vigil"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpurnell/quality-gate-types.git", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/jpurnell/swift-process-kernel.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "VigilKit",
            dependencies: [
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            // Declared as a resource, not excluded. `exclude:` removes the catalogue from the
            // target's sourceFiles, which is how swift-docc-plugin finds it — so excluding
            // quiets SwiftPM's unhandled-file warning by handing DocC nothing, and doc-lint
            // then passes over an article it never opened.
            resources: [.copy("VigilKit.docc")]
        ),
        .testTarget(
            name: "VigilKitTests",
            dependencies: ["VigilKit"]
        ),
        .executableTarget(
            name: "vigil",
            dependencies: [
                "VigilKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ProcessKernel", package: "swift-process-kernel"),
            ]
        ),
    ]
)
