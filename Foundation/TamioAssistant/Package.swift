// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TamioAssistant",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "TamioAssistant",
            targets: ["TamioAssistant"]
        ),
        .library(
            name: "TamioAssistantUI",
            targets: ["TamioAssistantUI"]
        ),
    ],
    dependencies: [
        .package(name: "TamioModule", path: "../TamioModule"),
        .package(name: "TamioDesign", path: "../TamioDesign"),
        .package(name: "Keychain", path: "../Keychain"),
        .package(name: "MachineStatus", path: "../MachineStatus"),
        .package(name: "MachineStatusView", path: "../MachineStatusView"),
        .package(url: "https://github.com/Lakr233/MarkdownView.git", from: "4.8.6"),
    ],
    targets: [
        .target(
            name: "TamioAssistant",
            dependencies: [
                "TamioModule",
                "Keychain",
                "MachineStatus",
                "MachineStatusView",
            ]
        ),
        .target(
            name: "TamioAssistantUI",
            dependencies: [
                "TamioAssistant",
                "TamioModule",
                "TamioDesign",
                .product(name: "MarkdownView", package: "MarkdownView"),
                .product(name: "MarkdownParser", package: "MarkdownView"),
            ]
        ),
        .testTarget(
            name: "TamioAssistantTests",
            dependencies: ["TamioAssistant"]
        ),
    ]
)
