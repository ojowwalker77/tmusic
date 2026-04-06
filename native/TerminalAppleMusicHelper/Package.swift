// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TerminalAppleMusicHelper",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(
      name: "TerminalAppleMusicHelper",
      targets: ["TerminalAppleMusicHelper"],
    ),
  ],
  targets: [
    .executableTarget(
      name: "TerminalAppleMusicHelper",
      path: "Sources",
    ),
  ],
)
