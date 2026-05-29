// swift-tools-version:5.5
// SpotHaptics/Package.swift
//
// Theos SPM package definition for the SpotHaptics tweak.
// Mirrors the structure of EeveeSpotify's Package.swift so it integrates
// cleanly with the same `make spm` / `make package` workflow.

import PackageDescription
import Foundation

let projectDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

@dynamicMemberLookup
struct TheosConfiguration {
    private let dict: [String: String]
    init(at path: String) {
        let url = URL(fileURLWithPath: path, relativeTo: projectDir)
        guard let raw = try? String(contentsOf: url) else {
            fatalError("""
            Could not read Theos SPM config at \(path).
            Have you run `make spm` first?
            """)
        }
        dict = Dictionary(uniqueKeysWithValues:
            raw.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1,
                                       omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )
    }
    subscript(_ key: String, or def: @autoclosure () -> String? = nil) -> String {
        dict[key] ?? def() ?? { fatalError("Missing key '\(key)' in Theos SPM config") }()
    }
    subscript(dynamicMember key: String) -> String { self[key] }
}

let conf            = TheosConfiguration(at: ".theos/spm_config")
let theosPath       = conf.theos
let sdk             = conf.sdk
let resourceDir     = conf.swiftResourceDir
let deploymentTarget = conf.deploymentTarget
let triple          = "arm64-apple-ios\(deploymentTarget)"

let libFlags: [String] = [
    "-F\(theosPath)/vendor/lib",
    "-F\(theosPath)/lib",
    "-I\(theosPath)/vendor/include",
    "-I\(theosPath)/include",
]

let swiftFlags: [String] = libFlags + [
    "-target", triple,
    "-sdk",    sdk,
    "-resource-dir", resourceDir,
]

let package = Package(
    name: "SpotHaptics",
    platforms: [.iOS(deploymentTarget)],
    products: [
        .library(name: "SpotHaptics", targets: ["SpotHaptics"]),
    ],
    targets: [
        .target(
            name: "SpotHaptics",
            // CoreHaptics is a system framework; Theos links it via the SDK path
            swiftSettings: [.unsafeFlags(swiftFlags)]
        ),
    ]
)
