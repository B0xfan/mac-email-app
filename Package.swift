// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MailCore", targets: ["MailCore"])],   // gives xcodebuild a MailCore scheme for the iOS CI check
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],   // self-update; embedded by scripts/embed-sparkle.sh
    targets: [
        // the mail logic shared with the iPhone app: Gmail, sync, stored mail, to-do reading, search. No screens, no Mac-only code.
        // Swift 6 mode: the compiler checks thread safety here; the apps stay on Swift 5 until this has shipped clean
        .target(name: "MailCore", path: "Sources/MailCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        // the quick check: MailCore's own checks, no app, no screens (swift run MailCoreCheck; scripts/cloud-build.sh --core)
        .executableTarget(name: "MailCoreCheck", dependencies: ["MailCore"], path: "Sources/MailCoreCheck"),
        .executableTarget(name: "MailApp", dependencies: ["MailCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/MailApp",
                          // the self-test and screenshot harness exists in debug builds only; the shipped release app has none of it
                          swiftSettings: [.define("TESTHARNESS", .when(configuration: .debug))],
                          // the app bundle keeps Sparkle.framework in Contents/Frameworks
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ],
    swiftLanguageModes: [.v5]
)
