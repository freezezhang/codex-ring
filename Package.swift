// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CodexRing", defaultLocalization: "en", platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexRing", targets: ["QuotaRing"])],
    targets: [.target(name:"QuotaCore",resources:[.process("Resources")]),.target(name:"RingDrawing",dependencies:["QuotaCore"]),
              .executableTarget(name:"QuotaRing",dependencies:["QuotaCore","RingDrawing"]),
              .testTarget(name:"QuotaCoreTests",dependencies:["QuotaCore"]),
              .testTarget(name:"QuotaRingTests",dependencies:["QuotaRing"]),
              .testTarget(name:"RingDrawingTests",dependencies:["QuotaCore","RingDrawing"])])
