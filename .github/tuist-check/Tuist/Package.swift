// swift-tools-version: 6.1
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

// One dynamic framework per SPM target links each target against its declared
// dependencies only — the topology `swift build` flattens away (#1126).
let packageSettings = PackageSettings(productTypes: ["LiveKit": .framework])
#endif

let package = Package(
    name: "TuistCheck",
    dependencies: [
        // Served from the checkout by run.sh: Tuist treats a path dependency as
        // editable and pulls in its test targets, which cannot resolve here.
        .package(url: "git://127.0.0.1/client-sdk-swift.git", branch: "ci-check"),
    ],
)
