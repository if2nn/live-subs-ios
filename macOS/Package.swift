// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LiveSubsMac", platforms: [.macOS(.v15)], products: [.executable(name: "LiveSubsMac", targets: ["LiveSubsMac"])], targets: [
 .executableTarget(name: "LiveSubsMac"),
 .testTarget(name: "LiveSubsMacTests", dependencies: ["LiveSubsMac"])
])
