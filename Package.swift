// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReceiptTodo",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ReceiptTodo", targets: ["ReceiptTodo"])
    ],
    targets: [
        .executableTarget(
            name: "ReceiptTodo",
            path: "Sources/ReceiptTodo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("z")
            ]
        )
    ]
)
