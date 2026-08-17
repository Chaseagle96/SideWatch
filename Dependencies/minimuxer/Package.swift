// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "Minimuxer",
            targets: ["Minimuxer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        )
    ],
    targets: [
//        .binaryTarget(
//            name: "IDevice",
//            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.64/idevice-xcframework-v0.1.64.zip",
//            checksum: "b8250402a23c850f80b9be1d4add309aae6c935ee6a797b73616e4d8f170be5d"
//        ),
         .binaryTarget(
             name: "IDevice",
             url: "https://github.com/SideStore/idevice/releases/download/v0.1.65-ss-895f502/idevice-xcframework-v0.1.65-ss-895f502.zip",
             checksum: "6dbc7589b5796a5ec1f622e3e7a5e7a999adb2a5b58c876faa63b26c513f1610"
         ),
//        .binaryTarget(
//            name: "IDevice",
//            path: "../../local/idevice/swift/bundle.zip"
//        ),
        .binaryTarget(
            name: "EMProxy",
            url: "https://github.com/SideStore/em_proxy/releases/download/v0.9.2/EMProxy.xcframework.zip",
            checksum: "4a4ae57ae2e6e110484399a72b95fcdeda8db2aff658cf3793761371098dee08"
        ),
//         .binaryTarget(
//             name: "EMProxy",
//             path: "../../local/em_proxy/libs/EMProxy.xcframework"
//         ),

        // MARK: Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                "IDevice",
                "EMProxy",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MinimuxerTests",
            dependencies: ["Minimuxer"],
            path: "Tests"
        )
    ]
)
