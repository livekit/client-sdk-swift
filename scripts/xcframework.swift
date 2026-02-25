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
import Stencil // @stencilproject ~> 0.15.1
import Subprocess // swiftlang/swift-subprocess == main

// MARK: - Helpers

let fm = FileManager.default

func step(_ msg: String) { print("\n==> \(msg)") }

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

/// Run a command, print all output.
func execPrint(_ args: [String]) async throws {
    let output = try await exec(args)
    if !output.isEmpty { print(output) }
}

func findFirst(under root: String, named name: String, isDirectory: Bool? = nil) -> String? {
    guard let enumerator = fm.enumerator(atPath: root) else { return nil }
    while let path = enumerator.nextObject() as? String {
        if (path as NSString).lastPathComponent == name {
            let full = (root as NSString).appendingPathComponent(path)
            if let isDirectory {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue != isDirectory { continue }
            }
            return full
        }
    }
    return nil
}

func subdirs(of path: String) -> [String] {
    (try? fm.contentsOfDirectory(atPath: path))?.compactMap { entry in
        let full = (path as NSString).appendingPathComponent(entry)
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue ? full : nil
    }.sorted() ?? []
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
        let repoRoot: String = {
            var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            while dir.path != "/" {
                if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir.path }
                dir = dir.deletingLastPathComponent()
            }
            return fm.currentDirectoryPath
        }()
        let outputDir = output ?? (repoRoot as NSString).appendingPathComponent("build/xcframework")
        let buildDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("livekit-xcfw-\(UUID().uuidString)")
        let spmDir = (buildDir as NSString).appendingPathComponent("spm")

        defer { try? fm.removeItem(atPath: buildDir) }
        try fm.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputDir) { try fm.removeItem(atPath: outputDir) }
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // --- Parse binary dependency info from Package.swift ---
        step("Resolving binary dependencies from Package.swift...")
        let webrtcDep = try await parseBinaryDep(repoRoot: repoRoot, pattern: "webrtc-xcframework", xcfw: "LiveKitWebRTC")
        let uniffiDep = try await parseBinaryDep(repoRoot: repoRoot, pattern: "uniffi-xcframework", xcfw: "RustLiveKitUniFFI")
        print("  LiveKitWebRTC: \(webrtcDep.url)")
        print("  RustLiveKitUniFFI: \(uniffiDep.url)")

        // --- Resolve SPM packages once before parallel builds ---
        step("Resolving Swift packages...")
        try await exec([
            "xcodebuild", "-resolvePackageDependencies",
            "-scheme", "LiveKit",
            "-clonedSourcePackagesDirPath", spmDir,
        ])

        // --- Archive & stage all platforms (parallel) ---
        step("Archiving \(platforms.count) platforms in parallel...")
        let stagingDirs: [(Platform, String)] = try await withThrowingTaskGroup(
            of: (Platform, String).self,
            returning: [(Platform, String)].self,
        ) { group in
            for p in platforms {
                group.addTask {
                    let archive = (buildDir as NSString).appendingPathComponent("\(p.stagingName).xcarchive")
                    let dd = (buildDir as NSString).appendingPathComponent("dd-\(p.stagingName)")

                    let archiveOutput = try await exec([
                        "xcodebuild", "archive",
                        "-scheme", "LiveKit", "-configuration", "Release",
                        "-destination", p.destination,
                        "-archivePath", archive, "-derivedDataPath", dd,
                        "-clonedSourcePackagesDirPath", spmDir,
                        "BUILD_LIBRARY_FOR_DISTRIBUTION=YES", "SKIP_INSTALL=NO",
                    ])
                    let lastLine = archiveOutput.components(separatedBy: .newlines).last ?? ""
                    print("  \(p.label): \(lastLine)")

                    let bpRoot = "\(dd)/Build/Intermediates.noindex/ArchiveIntermediates/LiveKit/BuildProductsPath"
                    guard let bp = subdirs(of: bpRoot).first else {
                        throw ValidationError("Build products not found for \(p.label)")
                    }

                    let staging = (buildDir as NSString).appendingPathComponent("staging/\(p.stagingName)")
                    try await stageArtifacts(label: p.label, archive: archive, bp: bp, staging: staging, repoRoot: repoRoot)
                    return (p, staging)
                }
            }
            var results: [(Platform, String)] = []
            for try await result in group {
                results.append(result)
            }
            // Preserve platform order for deterministic xcframework
            return results.sorted { $0.0.stagingName < $1.0.stagingName }
        }
        print("  All \(stagingDirs.count) platforms archived.")

        // --- Create LiveKit.xcframework ---
        step("Creating LiveKit.xcframework...")
        var xcfwArgs = ["xcodebuild", "-create-xcframework"]
        for (_, staging) in stagingDirs {
            xcfwArgs += ["-library", "\(staging)/LiveKit.a"]
            let headers = (staging as NSString).appendingPathComponent("include")
            if fm.fileExists(atPath: headers) { xcfwArgs += ["-headers", headers] }
        }
        let xcfwPath = (outputDir as NSString).appendingPathComponent("LiveKit.xcframework")
        xcfwArgs += ["-output", xcfwPath]
        try await execPrint(xcfwArgs)

        // --- Embed Swift modules ---
        step("Embedding Swift modules into xcframework slices...")
        try embedSwiftModules(xcfwPath: xcfwPath, stagingDirs: stagingDirs)

        // --- Zip & checksum LiveKit.xcframework ---
        step("Zipping LiveKit.xcframework...")
        let liveKitZip = "LiveKit.xcframework.zip"
        try await exec("bash", "-c", "cd '\(outputDir)' && zip -qry '\(liveKitZip)' 'LiveKit.xcframework'")
        let liveKitChecksum = try await exec(
            "swift", "package", "compute-checksum",
            (outputDir as NSString).appendingPathComponent(liveKitZip),
        )
        print("  \(liveKitZip)  checksum: \(liveKitChecksum)")

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
        for item in try fm.contentsOfDirectory(atPath: outputDir).sorted() {
            print(item)
        }
        print("")
        print("LiveKit.xcframework:")
        for slice in subdirs(of: (outputDir as NSString).appendingPathComponent("LiveKit.xcframework"))
            .map({ ($0 as NSString).lastPathComponent }).sorted()
        {
            print("  - \(slice)")
        }
    }

    // MARK: - Parse dependency info from Package.swift

    struct BinaryDep {
        let url: String
        let checksum: String
    }

    /// Parse binary dependency URL and checksum from the upstream Package.swift.
    /// Fetches the upstream repo's Package.swift to get the checksum.
    func parseBinaryDep(repoRoot: String, pattern: String, xcfw: String) async throws -> BinaryDep {
        let contents = try String(contentsOfFile: (repoRoot as NSString).appendingPathComponent("Package.swift"), encoding: .utf8)
        guard let line = contents.components(separatedBy: .newlines)
            .first(where: { $0.contains("github") && $0.contains(pattern) })
        else {
            throw ValidationError("\(pattern) not found in Package.swift")
        }
        guard let urlRange = line.range(of: #"https://[^"]+"#, options: .regularExpression),
              let verRange = line.range(of: #"exact: "([^"]+)"#, options: .regularExpression)
        else {
            throw ValidationError("Could not parse URL/version from: \(line)")
        }
        let repo = String(line[urlRange]).replacingOccurrences(of: ".git", with: "")
        let ver = line[verRange].replacingOccurrences(of: "exact: \"", with: "")
        let zipURL = "\(repo)/releases/download/\(ver)/\(xcfw).xcframework.zip"

        // Fetch upstream Package.swift to get the checksum
        let rawURL = repo.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com") + "/\(ver)/Package.swift"
        let upstreamPkg = try await exec("curl", "-fsSL", rawURL)
        guard let csLine = upstreamPkg.components(separatedBy: .newlines)
            .first(where: { $0.contains("checksum") })
        else {
            throw ValidationError("Could not find checksum in upstream Package.swift at \(rawURL)")
        }
        guard let csRange = csLine.range(of: #""[0-9a-f]{64}""#, options: .regularExpression) else {
            throw ValidationError("Could not parse checksum from: \(csLine)")
        }
        let checksum = String(csLine[csRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        return BinaryDep(url: zipURL, checksum: checksum)
    }

    // stage() moved to free function for TaskGroup compatibility

    // MARK: - Embed Swift modules

    func embedSwiftModules(xcfwPath: String, stagingDirs: [(Platform, String)]) throws {
        for sliceDir in subdirs(of: xcfwPath) {
            let sliceBase = (sliceDir as NSString).lastPathComponent
            let slicePfx = sliceBase.components(separatedBy: "-").first ?? ""
            let sliceSim = sliceBase.hasSuffix("-simulator")
            let sliceCat = sliceBase.hasSuffix("-maccatalyst")

            for (platform, staging) in stagingDirs {
                let stgPfx = platform.stagingName.components(separatedBy: "-").first ?? ""
                if slicePfx == stgPfx,
                   sliceSim == platform.stagingName.hasSuffix("-simulator"),
                   sliceCat == platform.stagingName.hasSuffix("-maccatalyst")
                {
                    for item in (try? fm.contentsOfDirectory(atPath: staging)) ?? [] {
                        let src = (staging as NSString).appendingPathComponent(item)
                        let dst = (sliceDir as NSString).appendingPathComponent(item)
                        if item.hasSuffix(".swiftmodule"), !fm.fileExists(atPath: dst) {
                            try fm.copyItem(atPath: src, toPath: dst)
                            print("  + \(item) -> \(sliceBase)")
                        }
                        if item.hasSuffix(".bundle") { try? fm.copyItem(atPath: src, toPath: dst) }
                    }
                    break
                }
            }
        }
    }

    // MARK: - Generate Package.swift via Stencil

    func generatePackageSwift(
        outputDir: String, liveKitChecksum: String,
        webrtcDep: BinaryDep, uniffiDep: BinaryDep, repoRoot: String,
    ) throws {
        let scriptsDir = (repoRoot as NSString).appendingPathComponent("scripts")
        let templatePath = (scriptsDir as NSString).appendingPathComponent("Package.swift.stencil")
        let tmpl = try String(contentsOfFile: templatePath, encoding: .utf8)

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
        try rendered.write(
            toFile: (outputDir as NSString).appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8,
        )
    }
}

// MARK: - Stage (free function for TaskGroup compatibility)

func stageArtifacts(label: String, archive: String, bp: String, staging: String, repoRoot: String) async throws {
    try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

    // Discover source modules dynamically from .o files in the archive
    let productsDir = "\(archive)/Products"
    var objects: [String] = []
    if let enumerator = fm.enumerator(atPath: productsDir) {
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".o") {
                objects.append((productsDir as NSString).appendingPathComponent(path))
            }
        }
    }

    // Also include liblivekit_uniffi.a (Rust/C static lib)
    if let lib = findFirst(under: bp, named: "liblivekit_uniffi.a", isDirectory: false) {
        objects.append(lib)
    }

    print("  Merging \(objects.count) objects into LiveKit.a (\(label))")
    try await exec(["libtool", "-static", "-o", "\(staging)/LiveKit.a"] + objects)

    // Copy all .swiftmodule directories from build products
    for item in (try? fm.contentsOfDirectory(atPath: bp)) ?? [] where item.hasSuffix(".swiftmodule") {
        let src = (bp as NSString).appendingPathComponent(item)
        try await exec("cp", "-R", src, staging)
    }

    // ObjC headers + module map for LKObjCHelpers
    let includeDir = (staging as NSString).appendingPathComponent("include/LKObjCHelpers")
    try fm.createDirectory(atPath: includeDir, withIntermediateDirectories: true)
    let objcSrc = (repoRoot as NSString).appendingPathComponent("Sources/LKObjCHelpers/include")
    if fm.fileExists(atPath: objcSrc) {
        for h in try fm.contentsOfDirectory(atPath: objcSrc).filter({ $0.hasSuffix(".h") }) {
            try fm.copyItem(
                atPath: (objcSrc as NSString).appendingPathComponent(h),
                toPath: (includeDir as NSString).appendingPathComponent(h),
            )
        }
    }
    try "module LKObjCHelpers {\n    header \"LKObjCHelpers.h\"\n    export *\n}\n"
        .write(toFile: (includeDir as NSString).appendingPathComponent("module.modulemap"),
               atomically: true, encoding: .utf8)

    // Resource bundles
    for item in (try? fm.contentsOfDirectory(atPath: bp)) ?? [] where item.hasSuffix(".bundle") {
        try? fm.copyItem(
            atPath: (bp as NSString).appendingPathComponent(item),
            toPath: (staging as NSString).appendingPathComponent(item),
        )
    }
}
