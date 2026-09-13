// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VPlayer", targets: ["VPlayer"])
    ],
    targets: [
        .target(
            name: "Cmpv",
            path: "Sources/Cmpv",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        .target(
            name: "Cavformat",
            path: "Sources/Cavformat",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        .executableTarget(
            name: "VPlayer",
            dependencies: ["Cmpv", "Cavformat"],
            path: "Sources/VPlayer",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lmpv", "-lavformat", "-lavcodec", "-lavutil", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"])
            ]
        )
    ]
)
