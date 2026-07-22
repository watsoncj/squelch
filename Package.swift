// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squelch",
    platforms: [.macOS(.v15)], // WindowDragGesture (titlebar drag vs map pan)
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
            name: "Squelch",
            dependencies: ["CFT8", "CSerial"],
            path: "Sources/Squelch",
            resources: [
                .copy("Resources/ne_110m_land.geojson"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "SquelchTests",
            dependencies: ["Squelch"],
            path: "Tests/SquelchTests",
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
