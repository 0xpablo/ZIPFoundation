// swift-tools-version:5.9
import PackageDescription

#if canImport(Compression)
let targets: [Target] = [
    .target(name: "ZIPFoundation", resources: [.process("Resources")]),
    .testTarget(
        name: "ZIPFoundationTests",
        dependencies: ["ZIPFoundation"],
        resources: [.process("Resources")]
    )
]
#else
let targets: [Target] = [
    .systemLibrary(name: "CZLib", pkgConfig: "zlib", providers: [.brew(["zlib"]), .apt(["zlib"])]),
    .target(
        name: "ZIPFoundation",
        dependencies: ["CZLib"],
        resources: [.process("Resources")],
        cSettings: [.define("_GNU_SOURCE", to: "1")]
    ),
    .testTarget(
        name: "ZIPFoundationTests",
        dependencies: ["ZIPFoundation"],
        resources: [.process("Resources")]
    )
]
#endif

let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v10_15), .iOS(.v12), .tvOS(.v12), .watchOS(.v4)
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"])
    ],
    targets: targets,
    swiftLanguageVersions: [.v4, .v4_2, .v5]
)
