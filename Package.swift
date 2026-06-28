// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "R6CPhoneControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "R6CPhoneControl", targets: ["R6CPhoneControl"])
    ],
    targets: [
        .executableTarget(
            name: "R6CPhoneControl",
            path: "Sources/R6CPhoneControl"
        ),
        .testTarget(
            name: "R6CPhoneControlTests",
            dependencies: ["R6CPhoneControl"]
        )
    ]
)
