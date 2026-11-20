// swift-tools-version: 6.0

import PackageDescription

/// Hangar: a picture's editor as Photos has it, Adjust and Filters (Crop and video to come), for iPhone and iPad.
/// Its tools are the app's to add to and its look the app's to set: an adjustment, a filter, a colour, a font.
///
/// HangarCore: what an edit is (values, never pixels) and how a picture is drawn from it, with Core Image, on any
/// thread: for a thumbnail, a share, a server.
let package = Package(
    name: "Hangar",
    platforms: [.iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "Hangar", targets: ["Hangar"]),
        .library(name: "HangarCore", targets: ["HangarCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Eirperuier/Flight.git", from: "0.7.23"),
    ],
    targets: [
        .target(name: "HangarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Hangar", dependencies: ["HangarCore", .product(name: "Flight", package: "Flight")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HangarCoreTests", dependencies: ["HangarCore", "Hangar"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
