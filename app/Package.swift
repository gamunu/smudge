// swift-tools-version:6.0
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import PackageDescription

let package = Package(
    name: "Smudge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Thin module that exposes libcups from the macOS SDK to Swift.
        .target(
            name: "CCups",
            cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])],
            linkerSettings: [.linkedLibrary("cups")]
        ),
        // USB and LEDM transport shared by the app and the scanner agent.
        .target(
            name: "SmudgeKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // eSCL and LEDM scan translation. No USB, so it tests without hardware.
        .target(
            name: "SmudgeScan",
            dependencies: ["SmudgeKit"]
        ),
        // Non-UI logic of the app: printer model, CUPS and LEDM controllers, parsing.
        .target(
            name: "SmudgeCore",
            dependencies: ["CCups", "SmudgeKit", "SmudgeScan"],
            swiftSettings: [
                // libcups is deprecated in the SDK but still works.
                .unsafeFlags(["-Xcc", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        // Per-user agent that serves attached HP scanners to Image Capture over loopback eSCL.
        .executableTarget(
            name: "smudge-scand",
            dependencies: ["SmudgeKit", "SmudgeScan"]
        ),
        .executableTarget(
            name: "Smudge",
            dependencies: [
                "SmudgeCore",
                "SmudgeKit",
                "SmudgeScan",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework lives in Contents/Frameworks of the app bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SmudgeTests",
            dependencies: ["SmudgeCore", "SmudgeKit"]
        ),
        .testTarget(
            name: "SmudgeScanTests",
            dependencies: ["SmudgeScan", "SmudgeKit"]
        ),
    ]
)
