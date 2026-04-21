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
import XcodeProj // @tuist ~> 8.8.0
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
        error: .string(limit: 10 * 1024 * 1024)
    )
    guard case .exited(0) = result.terminationStatus else {
        let stdout = result.standardOutput ?? ""
        let stderr = result.standardError ?? ""
        let combined = stderr.isEmpty ? stdout : stderr
        throw ValidationError("\(name) failed (\(result.terminationStatus)): \(combined.suffix(1000))")
    }
    return (result.standardOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Platform

struct Platform {
    let label, destination, archiveName: String
}

let platforms: [Platform] = [
    .init(label: "iOS Device", destination: "generic/platform=iOS", archiveName: "ios-arm64"),
    .init(label: "iOS Simulator", destination: "generic/platform=iOS Simulator", archiveName: "ios-arm64_x86_64-simulator"),
    .init(label: "macOS", destination: "generic/platform=macOS", archiveName: "macos-arm64_x86_64"),
    .init(label: "Mac Catalyst", destination: "generic/platform=macOS,variant=Mac Catalyst", archiveName: "ios-arm64_x86_64-maccatalyst"),
    .init(label: "tvOS Device", destination: "generic/platform=tvOS", archiveName: "tvos-arm64"),
    .init(label: "tvOS Simulator", destination: "generic/platform=tvOS Simulator", archiveName: "tvos-arm64_x86_64-simulator"),
    .init(label: "visionOS Device", destination: "generic/platform=visionOS", archiveName: "xros-arm64"),
    .init(label: "visionOS Simulator", destination: "generic/platform=visionOS Simulator", archiveName: "xros-arm64-simulator"),
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

// MARK: - Xcode project generation

/// Recursively add source files from a directory to an Xcode group and build phase.
func addSources(
    dir: Path, group: PBXGroup, sourcesBP: PBXSourcesBuildPhase, resourcesBP: PBXResourcesBuildPhase,
    pbxProj: PBXProj, repoRoot: Path, excludes: [String] = []
) throws {
    for child in try dir.children().sorted(by: { $0.string < $1.string }) {
        let name = child.lastComponent
        if excludes.contains(name) { continue }

        if child.isDirectory {
            let subgroup = PBXGroup(sourceTree: .group, name: name, path: name)
            pbxProj.add(object: subgroup)
            group.children.append(subgroup)
            try addSources(dir: child, group: subgroup, sourcesBP: sourcesBP, resourcesBP: resourcesBP, pbxProj: pbxProj, repoRoot: repoRoot)
        } else {
            let ext = child.extension ?? ""
            let fileRef = PBXFileReference(sourceTree: .absolute, name: name, path: child.string)
            pbxProj.add(object: fileRef)
            group.children.append(fileRef)

            switch ext {
            case "swift":
                let bf = PBXBuildFile(file: fileRef)
                pbxProj.add(object: bf)
                sourcesBP.files?.append(bf)
            case "m":
                let bf = PBXBuildFile(file: fileRef)
                pbxProj.add(object: bf)
                sourcesBP.files?.append(bf)
            case "xcprivacy":
                let bf = PBXBuildFile(file: fileRef)
                pbxProj.add(object: bf)
                resourcesBP.files?.append(bf)
            default:
                break // headers and other files are added to group but not to build phases
            }
        }
    }
}

/// Generate a temporary .xcodeproj with a framework target that includes all
/// LiveKit source files directly. SPM binary dependencies (WebRTC, UniFFI) and
/// SwiftProtobuf are added as package dependencies. The target-level
/// MACH_O_TYPE=mh_dylib setting produces a proper dynamic .framework bundle.
func generateFrameworkProject(at projectPath: Path, repoRoot: Path) throws {
    let pbxProj = PBXProj()

    // --- Project-level build configuration ---
    let projectConfig = XCBuildConfiguration(name: "Release", buildSettings: [
        "SDKROOT": "auto",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx appletvos appletvsimulator xros xrsimulator",
        "SWIFT_VERSION": "6.0",
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "SUPPORTS_MACCATALYST": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "14.0",
        "MACOSX_DEPLOYMENT_TARGET": "10.15",
        "TVOS_DEPLOYMENT_TARGET": "17.0",
        "DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER": "NO",
    ])
    pbxProj.add(object: projectConfig)

    let projectConfigList = XCConfigurationList(
        buildConfigurations: [projectConfig],
        defaultConfigurationName: "Release"
    )
    pbxProj.add(object: projectConfigList)

    let mainGroup = PBXGroup(sourceTree: .sourceRoot)
    pbxProj.add(object: mainGroup)

    let project = PBXProject(
        name: "LiveKit",
        buildConfigurationList: projectConfigList,
        compatibilityVersion: "Xcode 26.0",
        preferredProjectObjectVersion: 77,
        minimizedProjectReferenceProxies: 1,
        mainGroup: mainGroup
    )
    pbxProj.add(object: project)
    pbxProj.rootObject = project

    // --- SPM package dependencies ---
    var remotePackageRefs: [XCRemoteSwiftPackageReference] = []
    func addRemotePackage(url: String, version: String) -> XCRemoteSwiftPackageReference {
        let ref = XCRemoteSwiftPackageReference(repositoryURL: url, versionRequirement: .exact(version))
        pbxProj.add(object: ref)
        remotePackageRefs.append(ref)
        return ref
    }

    func addProductDep(name: String, package: XCRemoteSwiftPackageReference) -> XCSwiftPackageProductDependency {
        let dep = XCSwiftPackageProductDependency(productName: name, package: package)
        pbxProj.add(object: dep)
        return dep
    }

    // Parse versions from Package.swift
    let pkgContents: String = try (repoRoot + "Package.swift").read()
    func extractVersion(pattern: String) -> String {
        guard let line = pkgContents.components(separatedBy: .newlines)
            .first(where: { $0.contains(pattern) }),
            let match = line.firstMatch(of: #/exact:\s*"(?<ver>[^"]+)"/#) ?? line.firstMatch(of: #/from:\s*"(?<ver>[^"]+)"/#)
        else { return "1.0.0" }
        return String(match.ver)
    }

    let webrtcPkg = addRemotePackage(url: "https://github.com/livekit/webrtc-xcframework.git", version: extractVersion(pattern: "webrtc-xcframework"))
    let uniffiPkg = addRemotePackage(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", version: extractVersion(pattern: "uniffi-xcframework"))
    let protobufPkg = addRemotePackage(url: "https://github.com/apple/swift-protobuf.git", version: extractVersion(pattern: "swift-protobuf"))

    let webrtcDep = addProductDep(name: "LiveKitWebRTC", package: webrtcPkg)
    let uniffiDep = addProductDep(name: "LiveKitUniFFI", package: uniffiPkg)
    let protobufDep = addProductDep(name: "SwiftProtobuf", package: protobufPkg)

    // --- Build phases ---
    let sourcesBP = PBXSourcesBuildPhase()
    let frameworksBP = PBXFrameworksBuildPhase()
    let resourcesBP = PBXResourcesBuildPhase()
    let headersBP = PBXHeadersBuildPhase()
    pbxProj.add(object: sourcesBP)
    pbxProj.add(object: frameworksBP)
    pbxProj.add(object: resourcesBP)
    pbxProj.add(object: headersBP)

    // --- Target-level build configuration ---
    let targetConfig = XCBuildConfiguration(name: "Release", buildSettings: [
        "PRODUCT_NAME": "LiveKit",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.livekit.LiveKit",
        "GENERATE_INFOPLIST_FILE": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.0",
        "SKIP_INSTALL": "NO",
        "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
        "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks",
        "DEFINES_MODULE": "YES",
        "MACH_O_TYPE": "mh_dylib",
        "CLANG_ENABLE_MODULES": "YES",
        "HEADER_SEARCH_PATHS": "$(inherited) " + (repoRoot + "Sources/LKObjCHelpers/include").string,
        // LKObjCHelpers needs its own modulemap so `import LKObjCHelpers` works in Swift
        "SWIFT_INCLUDE_PATHS": "$(inherited) " + (repoRoot + "Sources/LKObjCHelpers").string,
    ])
    pbxProj.add(object: targetConfig)

    let targetConfigList = XCConfigurationList(
        buildConfigurations: [targetConfig],
        defaultConfigurationName: "Release"
    )
    pbxProj.add(object: targetConfigList)

    // --- Framework target ---
    let target = PBXNativeTarget(
        name: "LiveKit",
        buildConfigurationList: targetConfigList,
        buildPhases: [headersBP, sourcesBP, frameworksBP, resourcesBP],
        productType: .framework
    )
    pbxProj.add(object: target)
    target.packageProductDependencies = [webrtcDep, uniffiDep, protobufDep]
    project.remotePackages = remotePackageRefs
    project.targets.append(target)

    // --- Add source files ---
    // LiveKit sources
    let liveKitGroup = PBXGroup(sourceTree: .group, name: "LiveKit", path: "Sources/LiveKit")
    pbxProj.add(object: liveKitGroup)
    mainGroup.children.append(liveKitGroup)
    try addSources(
        dir: repoRoot + "Sources" + "LiveKit", group: liveKitGroup,
        sourcesBP: sourcesBP, resourcesBP: resourcesBP, pbxProj: pbxProj, repoRoot: repoRoot,
        excludes: ["NOTICE"]
    )

    // LKObjCHelpers sources
    let objcGroup = PBXGroup(sourceTree: .group, name: "LKObjCHelpers", path: "Sources/LKObjCHelpers")
    pbxProj.add(object: objcGroup)
    mainGroup.children.append(objcGroup)
    try addSources(
        dir: repoRoot + "Sources" + "LKObjCHelpers", group: objcGroup,
        sourcesBP: sourcesBP, resourcesBP: resourcesBP, pbxProj: pbxProj, repoRoot: repoRoot
    )

    // Make ObjC headers public in the headers build phase
    let objcHeaderDir = repoRoot + "Sources" + "LKObjCHelpers" + "include"
    if objcHeaderDir.exists {
        for h in try objcHeaderDir.children().filter({ $0.extension == "h" }) {
            if let fileRef = pbxProj.fileReferences.first(where: { $0.path == h.string }) {
                let hf = PBXBuildFile(file: fileRef, settings: ["ATTRIBUTES": ["Public"]])
                pbxProj.add(object: hf)
                headersBP.files?.append(hf)
            }
        }
    }

    // --- Create LKObjCHelpers modulemap if it doesn't exist ---
    let modulemapPath = repoRoot + "Sources" + "LKObjCHelpers" + "module.modulemap"
    if !modulemapPath.exists {
        try modulemapPath.write("module LKObjCHelpers {\n    header \"include/LKObjCHelpers.h\"\n    export *\n}\n")
    }

    // --- Write project ---
    let xcodeProj = XcodeProj(workspace: XCWorkspace(), pbxproj: pbxProj)
    try xcodeProj.write(path: projectPath)
    print("  Generated \(projectPath) with \(sourcesBP.files?.count ?? 0) source files")
}

// MARK: - Command

@main
struct BuildXCFramework: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcframework",
        abstract: "Build LiveKit.xcframework for all supported Apple platforms.",
        discussion: "Usage: ./xcframework.swift [--version <version> | --local] [--output <dir>]"
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

        // --- Generate Xcode project with all source files ---
        step("Generating Xcode project...")
        let projectPath = buildDir + "LiveKit.xcodeproj"
        try generateFrameworkProject(at: projectPath, repoRoot: repoRoot)
        print("  \(projectPath)")

        // --- Resolve SPM packages (populates spmDir/checkouts) ---
        step("Resolving Swift packages...")
        try await exec([
            "xcodebuild", "-resolvePackageDependencies",
            "-project", projectPath.string,
            "-scheme", "LiveKit",
            "-clonedSourcePackagesDirPath", spmDir.string,
        ])

        // --- Parse binary dependency info from local checkouts ---
        step("Reading binary dependency info...")
        let webrtcDep = try parseBinaryDep(repoRoot: repoRoot, spmDir: spmDir, pattern: "webrtc-xcframework", xcfw: "LiveKitWebRTC")
        let uniffiDep = try parseBinaryDep(repoRoot: repoRoot, spmDir: spmDir, pattern: "uniffi-xcframework", xcfw: "RustLiveKitUniFFI")
        print("  LiveKitWebRTC: \(webrtcDep.url)")
        print("  RustLiveKitUniFFI: \(uniffiDep.url)")

        // --- Archive all platforms (parallel) ---
        step("Archiving \(platforms.count) platforms in parallel...")
        let archiveResults: [(Platform, Result<Path, Swift.Error>)] = await withTaskGroup(
            of: (Platform, Result<Path, Swift.Error>).self,
            returning: [(Platform, Result<Path, Swift.Error>)].self
        ) { group in
            for p in platforms {
                group.addTask {
                    let archive = buildDir + "\(p.archiveName).xcarchive"
                    let dd = buildDir + "dd-\(p.archiveName)"
                    do {
                        let archiveOutput = try await exec([
                            "xcodebuild", "archive",
                            "-project", projectPath.string,
                            "-scheme", "LiveKit", "-configuration", "Release",
                            "-destination", p.destination,
                            "-archivePath", archive.string,
                            "-derivedDataPath", dd.string,
                            "-clonedSourcePackagesDirPath", spmDir.string,
                        ])
                        let lastLine = archiveOutput.components(separatedBy: .newlines).last ?? ""
                        print("  ✓ \(p.label): \(lastLine)")
                        return (p, .success(archive))
                    } catch {
                        print("  ✗ \(p.label): \(error)".red)
                        return (p, .failure(error))
                    }
                }
            }
            var results: [(Platform, Result<Path, Swift.Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0.archiveName < $1.0.archiveName }
        }

        let archives = archiveResults.compactMap { p, r -> (Platform, Path)? in
            if case let .success(path) = r { return (p, path) }
            return nil
        }
        let failed = archiveResults.filter { if case .failure = $0.1 { return true }; return false }
        if !failed.isEmpty {
            print("  \(failed.count) platform(s) failed, \(archives.count) succeeded.".yellow)
        }
        guard !archives.isEmpty else {
            throw ValidationError("All platform archives failed.")
        }
        print("  \(archives.count) platforms archived.".green)

        // --- Create LiveKit.xcframework ---
        step("Creating LiveKit.xcframework...")
        var xcfwArgs = ["xcodebuild", "-create-xcframework"]
        for (_, archive) in archives {
            xcfwArgs += ["-archive", archive.string, "-framework", "LiveKit.framework"]
        }
        let xcfwPath = outputDir + "LiveKit.xcframework"
        xcfwArgs += ["-output", xcfwPath.string]
        let xcfwOutput = try await exec(xcfwArgs)
        if !xcfwOutput.isEmpty { print(xcfwOutput) }

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
            webrtcDep: webrtcDep, uniffiDep: uniffiDep, repoRoot: repoRoot
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

    // MARK: - Generate Package.swift via Stencil

    func generatePackageSwift(
        outputDir: Path, liveKitChecksum: String,
        webrtcDep: BinaryDep, uniffiDep: BinaryDep, repoRoot: Path
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

        // Create stub target (workaround for apple/swift-package-manager#6069)
        let stubDir = outputDir + "Sources" + "_LiveKitStub"
        try stubDir.mkpath()
        try (stubDir + "Stub.swift").write("// Workaround: without a non-binary target, SPM won't show the\n// package in Xcode's \"Frameworks, Libraries, and Embedded Content\".\n// See https://github.com/apple/swift-package-manager/issues/6069\nclass _LiveKitStub {}\n")
    }
}
