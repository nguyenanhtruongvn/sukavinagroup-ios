// swift-tools-version:5.9
// Unit tests for the app's pure (Foundation-only) logic in App/Shared.
// The same files are compiled into the App target by App.xcodeproj; this
// package only lets CI run them as tests with `swift test`, without a
// simulator, signing or an IPA. Run: swift test --package-path apps/ios/App
import PackageDescription

let package = Package(
    name: "SukavinaShared",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SukavinaShared", path: "App/Shared"),
        .testTarget(name: "SukavinaSharedTests", dependencies: ["SukavinaShared"], path: "SharedTests"),
    ]
)
