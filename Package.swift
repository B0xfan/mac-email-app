// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MailApp", path: "Sources/MailApp",
                          // the self-test and screenshot harness exists in debug builds only; the shipped release app has none of it
                          swiftSettings: [.define("TESTHARNESS", .when(configuration: .debug))])
    ],
    swiftLanguageModes: [.v5]
)
