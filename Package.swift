// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Dribble",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "Dribble",
            targets: ["Dribble"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.92.0"),
        .package(url: "https://github.com/needletails/swift-crypto.git", from: "1.0.1")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "Dribble",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "_NIOConcurrency", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .executableTarget(name: "CLIExample", dependencies: [
            "Dribble"
        ]),
        .testTarget(
            name: "DribbleTests",
            dependencies: ["Dribble"]),
    ]
)
