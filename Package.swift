// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],   // self-update; embedded by scripts/embed-sparkle.sh
    targets: [
        .executableTarget(name: "MailApp", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources/MailApp",
                          // the self-test and screenshot harness exists in debug builds only; the shipped release app has none of it
                          swiftSettings: [.define("TESTHARNESS", .when(configuration: .debug))],
                          // the app bundle keeps Sparkle.framework in Contents/Frameworks
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ],
    swiftLanguageModes: [.v5]
)
