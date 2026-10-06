// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scribey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Scribey",
            path: "Sources/Scribey"
        )
    ]
)
