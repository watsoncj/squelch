// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadioFun",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CFT8",
            path: "Sources/CFT8",
            exclude: ["LICENSE.ft8_lib"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "CSerial",
            path: "Sources/CSerial",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "RadioFun",
            dependencies: ["CFT8", "CSerial"],
            path: "Sources/RadioFun",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "RadioFunTests",
            dependencies: ["RadioFun"],
            path: "Tests/RadioFunTests",
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
