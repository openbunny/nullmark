// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.strictMemorySafety(), .treatAllWarnings(as: .error)]

let package = Package(
  name: "OpenBunnyComponents",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "OpenBunnyComponents", targets: ["OpenBunnyComponents"])
  ],
  dependencies: [
    .package(url: "https://github.com/openbunny/theme", exact: "0.1.1")
  ],
  targets: [
    .target(
      name: "OpenBunnyComponents",
      dependencies: [
        .product(name: "OpenBunnyTheme", package: "theme"),
        .product(name: "OpenBunnyUI", package: "theme"),
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "OpenBunnyComponentsTests",
      dependencies: ["OpenBunnyComponents"],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
