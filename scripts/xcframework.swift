#!/usr/bin/swift sh

/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import ArgumentParser // apple/swift-argument-parser ~> 1.5.0
import Foundation
import PathKit // @kylef ~> 1.0
import Rainbow // @onevcat ~> 4.0
import Stencil // @stencilproject ~> 0.15.1
import Subprocess // swiftlang/swift-subprocess == main
import ZIPFoundation // @weichsel ~> 0.9

// MARK: - Helpers

let fm = FileManager.default

func step(_ msg: String) { print("\n==> \(msg)".green.bold) }

/// Run a command, return trimmed stdout.
@discardableResult
func exec(_ args: String...) async throws -> String {
    try await exec(args)
}

@discardableResult
func exec(_ args: [String]) async throws -> String {
    let name = args[0]
    let rest = Array(args.dropFirst())
    let result = try await Subprocess.run(
        .name(name),
        arguments: .init(rest),
        output: .string(limit: 50 * 1024 * 1024),
    )
    guard case .exited(0) = result.terminationStatus else {
        let msg = result.standardOutput ?? ""
        throw ValidationError("\(name) failed (\(result.terminationStatus)): \(msg.prefix(500))")
    }
    return (result.standardOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Platform

struct Platform {
    let label, destination, stagingName: String
}

let platforms: [Platform] = [
    .init(label: "iOS Device", destination: "generic/platform=iOS", stagingName: "ios-arm64"),
    .init(label: "iOS Simulator", destination: "generic/platform=iOS Simulator", stagingName: "ios-arm64_x86_64-simulator"),
    .init(label: "macOS", destination: "generic/platform=macOS", stagingName: "macos-arm64_x86_64"),
    .init(label: "Mac Catalyst", destination: "generic/platform=macOS,variant=Mac Catalyst", stagingName: "ios-arm64_x86_64-maccatalyst"),
    .init(label: "tvOS Device", destination: "generic/platform=tvOS", stagingName: "tvos-arm64"),
    .init(label: "tvOS Simulator", destination: "generic/platform=tvOS Simulator", stagingName: "tvos-arm64_x86_64-simulator"),
    .init(label: "visionOS Device", destination: "generic/platform=visionOS", stagingName: "xros-arm64"),
    .init(label: "visionOS Simulator", destination: "generic/platform=visionOS Simulator", stagingName: "xros-arm64-simulator"),
]

// MARK: - Binary dependency info

struct BinaryDep {
    let url: String
    let checksum: String
}

// Regex: url: "https://github.com/.../foo.git", exact: "1.2.3"
private let depLineRegex = #/url:\s*"(?<url>https://[^"]+)".*exact:\s*"(?<version>[^"]+)"/#
// Regex: checksum: "abc123..."
private let checksumRegex = #/checksum:\s*"(?<hash>[0-9a-f]{64})"/#

/// Parse binary dependency URL + version from our Package.swift, then read checksum
/// from the upstream Package.swift in the local SPM checkout.
func parseBinaryDep(repoRoot: Path, spmDir: Path, pattern: String, xcfw: String) throws -> BinaryDep {
    let contents: String = try (repoRoot + "Package.swift").read()
    guard let line = contents.components(separatedBy: .newlines)
        .first(where: { $0.contains("github") && $0.contains(pattern) }),
        let match = line.firstMatch(of: depLineRegex)
    else {
        throw ValidationError("\(pattern) not found in Package.swift")
    }

    let repo = String(match.url).replacingOccurrences(of: ".git", with: "")
    let ver = String(match.version)
    let zipURL = "\(repo)/releases/download/\(ver)/\(xcfw).xcframework.zip"

    // Read checksum from local SPM checkout
    let repoName = repo.components(separatedBy: "/").last ?? pattern
    let checkoutPkg = spmDir + "checkouts" + repoName + "Package.swift"
    guard checkoutPkg.exists else {
        throw ValidationError("Upstream Package.swift not found at \(checkoutPkg). Run SPM resolve first.")
    }
    let upstreamContents: String = try checkoutPkg.read()
    guard let csMatch = upstreamContents.firstMatch(of: checksumRegex) else {
        throw ValidationError("Could not find checksum in \(checkoutPkg)")
    }
    return BinaryDep(url: zipURL, checksum: String(csMatch.hash))
}

// MARK: - Command

@main
struct BuildXCFramework: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcframework",
        abstract: "Build LiveKit.xcframework for all supported Apple platforms.",
        discussion: "Usage: ./xcframework.swift [--version <version> | --local] [--output <dir>]",
    )

    @Option(help: "Version tag for release URLs (required unless --local).")
    var version: String?

    @Flag(help: "Generate Package.swift with local paths instead of remote URLs.")
    var local = false

    @Option(help: "Output directory.")
    var output: String?

    func validate() throws {
        if !local, version == nil || version!.isEmpty {
            throw ValidationError("--version is required unless --local is set.")
        }
    }

    mutating func run() async throws {
        // Resolve repo root by walking up from cwd to find Package.swift
        var repoRoot = Path(fm.currentDirectoryPath)
        while repoRoot != Path("/"), !(repoRoot + "Package.swift").exists {
            repoRoot = repoRoot.parent()
        }

        let outputDir = Path(output ?? (repoRoot + "build" + "xcframework").string)
        let buildDir = Path(NSTemporaryDirectory()) + "livekit-xcfw-\(UUID().uuidString)"
        let spmDir = buildDir + "spm"

        defer { try? buildDir.delete() }
        try buildDir.mkpath()
        if outputDir.exists { try outputDir.delete() }
        try outputDir.mkpath()

        // --- Resolve SPM packages (populates spmDir/checkouts) ---
        step("Resolving Swift packages...")
        try await exec([
            "xcodebuild", "-resolvePackageDependencies",
            "-scheme", "LiveKit",
            "-clonedSourcePackagesDirPath", spmDir.string,
        ])

        // --- Parse binary dependency info from local checkouts ---
        step("Reading binary dependency info...")
        let webrtcDep = try parseBinaryDep(repoRoot: repoRoot, spmDir: spmDir, pattern: "webrtc-xcframework", xcfw: "LiveKitWebRTC")
        let uniffiDep = try parseBinaryDep(repoRoot: repoRoot, spmDir: spmDir, pattern: "uniffi-xcframework", xcfw: "RustLiveKitUniFFI")
        print("  LiveKitWebRTC: \(webrtcDep.url)")
        print("  RustLiveKitUniFFI: \(uniffiDep.url)")

        // --- Archive & stage all platforms (parallel) ---
        step("Archiving \(platforms.count) platforms in parallel...")
        let stagingDirs: [(Platform, Path)] = try await withThrowingTaskGroup(
            of: (Platform, Path).self,
            returning: [(Platform, Path)].self,
        ) { group in
            for p in platforms {
                group.addTask {
                    let archive = buildDir + "\(p.stagingName).xcarchive"
                    let dd = buildDir + "dd-\(p.stagingName)"

                    let archiveOutput = try await exec([
                        "xcodebuild", "archive",
                        "-scheme", "LiveKit", "-configuration", "Release",
                        "-destination", p.destination,
                        "-archivePath", archive.string, "-derivedDataPath", dd.string,
                        "-clonedSourcePackagesDirPath", spmDir.string,
                        "BUILD_LIBRARY_FOR_DISTRIBUTION=YES", "SKIP_INSTALL=NO",
                    ])
                    let lastLine = archiveOutput.components(separatedBy: .newlines).last ?? ""
                    print("  \(p.label): \(lastLine)")

                    let bpRoot = dd + "Build/Intermediates.noindex/ArchiveIntermediates/LiveKit/BuildProductsPath"
                    guard let bp = try bpRoot.children().first(where: { $0.isDirectory }) else {
                        throw ValidationError("Build products not found for \(p.label)")
                    }

                    let staging = buildDir + "staging" + p.stagingName
                    try await stageArtifacts(label: p.label, archive: archive, bp: bp, staging: staging, repoRoot: repoRoot)
                    return (p, staging)
                }
            }
            var results: [(Platform, Path)] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0.stagingName < $1.0.stagingName }
        }
        print("  All \(stagingDirs.count) platforms archived.".green)

        // --- Create LiveKit.xcframework ---
        step("Creating LiveKit.xcframework...")
        var xcfwArgs = ["xcodebuild", "-create-xcframework"]
        for (_, staging) in stagingDirs {
            xcfwArgs += ["-library", (staging + "LiveKit.a").string]
            let headers = staging + "include"
            if headers.exists { xcfwArgs += ["-headers", headers.string] }
        }
        let xcfwPath = outputDir + "LiveKit.xcframework"
        xcfwArgs += ["-output", xcfwPath.string]
        let xcfwOutput = try await exec(xcfwArgs)
        if !xcfwOutput.isEmpty { print(xcfwOutput) }

        // --- Embed Swift modules into xcframework slices ---
        step("Embedding Swift modules into xcframework slices...")
        try embedSwiftModules(xcfwPath: xcfwPath, stagingDirs: stagingDirs)

        // --- Zip & checksum (release builds only) ---
        var liveKitChecksum = ""
        if !local {
            step("Zipping LiveKit.xcframework...")
            let zipPath = outputDir + "LiveKit.xcframework.zip"
            try fm.zipItem(at: xcfwPath.url, to: zipPath.url)
            liveKitChecksum = try await exec("swift", "package", "compute-checksum", zipPath.string)
            print("  LiveKit.xcframework.zip  checksum: \(liveKitChecksum)")
        }

        // --- Generate Package.swift ---
        step("Generating Package.swift...")
        try generatePackageSwift(
            outputDir: outputDir, liveKitChecksum: liveKitChecksum,
            webrtcDep: webrtcDep, uniffiDep: uniffiDep, repoRoot: repoRoot,
        )
        print("  Written to \(outputDir)/Package.swift (local=\(local))")

        // --- Summary ---
        step("Done! Output: \(outputDir)")
        print("")
        for item in try outputDir.children().map(\.lastComponent).sorted() {
            print(item)
        }
        print("")
        print("LiveKit.xcframework:")
        for slice in try xcfwPath.children().filter(\.isDirectory).map(\.lastComponent).sorted() {
            print("  - \(slice)")
        }
    }

    // MARK: - Embed Swift modules

    func embedSwiftModules(xcfwPath: Path, stagingDirs: [(Platform, Path)]) throws {
        for sliceDir in try xcfwPath.children().filter(\.isDirectory) {
            let sliceBase = sliceDir.lastComponent
            let slicePfx = sliceBase.components(separatedBy: "-").first ?? ""
            let sliceSim = sliceBase.hasSuffix("-simulator")
            let sliceCat = sliceBase.hasSuffix("-maccatalyst")

            for (platform, staging) in stagingDirs {
                let stgPfx = platform.stagingName.components(separatedBy: "-").first ?? ""
                if slicePfx == stgPfx,
                   sliceSim == platform.stagingName.hasSuffix("-simulator"),
                   sliceCat == platform.stagingName.hasSuffix("-maccatalyst")
                {
                    for item in try staging.children() {
                        let dst = sliceDir + item.lastComponent
                        if item.lastComponent.hasSuffix(".swiftmodule"), !dst.exists {
                            try item.copy(dst)
                            print("  + \(item.lastComponent) -> \(sliceBase)")
                        }
                        if item.lastComponent.hasSuffix(".bundle"), !dst.exists {
                            try? item.copy(dst)
                        }
                    }
                    break
                }
            }
        }
    }

    // MARK: - Generate Package.swift via Stencil

    func generatePackageSwift(
        outputDir: Path, liveKitChecksum: String,
        webrtcDep: BinaryDep, uniffiDep: BinaryDep, repoRoot: Path,
    ) throws {
        let tmpl: String = try (repoRoot + "scripts" + "Package.swift.stencil").read()
        let baseURL = version.map {
            "https://github.com/livekit/client-sdk-swift-xcframework/releases/download/\($0)"
        } ?? ""

        let env = Environment(loader: DictionaryLoader(templates: ["pkg": tmpl]))
        let rendered = try env.renderTemplate(name: "pkg", context: [
            "local": local,
            "baseURL": baseURL,
            "checksumLiveKit": liveKitChecksum,
            "webrtcURL": webrtcDep.url,
            "webrtcChecksum": webrtcDep.checksum,
            "uniffiURL": uniffiDep.url,
            "uniffiChecksum": uniffiDep.checksum,
        ])
        try (outputDir + "Package.swift").write(rendered)
    }
}

// MARK: - Stage (free function for TaskGroup compatibility)

func stageArtifacts(label: String, archive: Path, bp: Path, staging: Path, repoRoot: Path) async throws {
    try staging.mkpath()

    // Discover source modules dynamically from .o files in the archive
    let productsDir = archive + "Products"
    let objects = try productsDir.recursiveChildren().filter { $0.extension == "o" }

    // Also include liblivekit_uniffi.a (Rust/C static lib)
    var allObjects = objects.map(\.string)
    if let lib = try bp.recursiveChildren().first(where: { $0.lastComponent == "liblivekit_uniffi.a" }) {
        allObjects.append(lib.string)
    }

    print("  Merging \(allObjects.count) objects into LiveKit.a (\(label))")
    try await exec(["libtool", "-static", "-o", (staging + "LiveKit.a").string] + allObjects)

    // Copy all .swiftmodule directories from build products
    for item in try bp.children() where item.lastComponent.hasSuffix(".swiftmodule") {
        try item.copy(staging + item.lastComponent)
    }

    // ObjC headers + module map for LKObjCHelpers
    let includeDir = staging + "include" + "LKObjCHelpers"
    try includeDir.mkpath()
    let objcSrc = repoRoot + "Sources" + "LKObjCHelpers" + "include"
    if objcSrc.exists {
        for h in try objcSrc.children().filter({ $0.extension == "h" }) {
            try h.copy(includeDir + h.lastComponent)
        }
    }
    try (includeDir + "module.modulemap").write("module LKObjCHelpers {\n    header \"LKObjCHelpers.h\"\n    export *\n}\n")

    // Resource bundles
    for item in try bp.children() where item.lastComponent.hasSuffix(".bundle") {
        try? item.copy(staging + item.lastComponent)
    }
}
