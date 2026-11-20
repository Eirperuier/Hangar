// swift-tools-version: 6.0

import PackageDescription

/// Hangar: a picture's editor as Photos has it, Adjust, Filters and Crop (video to come), for iPhone and iPad.
/// Its tools and modes are the app's to add to and its look the app's to set: an adjustment, a filter, a mode, a colour.
///
/// HangarCore: what an edit is (values, and the pictures of steps made elsewhere by their ids) and how a picture is
/// drawn from it, with Core Image, on any thread: for a thumbnail, a share, a server.
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
