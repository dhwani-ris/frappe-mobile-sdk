// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "frappe_mobile_sdk",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        // If the plugin name contains "_", replace it with "-" for the library name.
        .library(name: "frappe-mobile-sdk", targets: ["frappe_mobile_sdk"])
    ],
    // Intentionally empty. Flutter is linked implicitly by the generated
    // FlutterGeneratedPluginSwiftPackage; declaring an explicit FlutterFramework
    // path dependency instead would require Flutter 3.44+ of every consumer.
    dependencies: [],
    targets: [
        .target(
            name: "frappe_mobile_sdk",
            dependencies: []
        )
    ]
)
