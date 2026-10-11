// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MailApp", path: "Sources/MailApp")
    ],
    swiftLanguageModes: [.v5]
)
