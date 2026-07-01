// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "POC_CVDependencies",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "POC_CVDependencies",
            targets: ["POC_CVDependencies"]
        )
    ],
    dependencies: [
        // Add remote packages here:
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.9.0"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "5.7.1"),
    ],
    targets: [
        .target(
            name: "POC_CVDependencies",
            dependencies: [
                // Add package products here:
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "SnapKit", package: "SnapKit"),
            ],
            path: "Sources/POC_CVDependencies"
        )
    ]
)
