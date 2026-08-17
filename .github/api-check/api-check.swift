#!/usr/bin/env swift-sh

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

import ArgumentParser // apple/swift-argument-parser ~> 1.3
import Files // JohnSundell/Files ~> 4.2
import Foundation
import ShellOut // JohnSundell/ShellOut ~> 2.3

// Run via: swiftly run +xcode swift-sh .github/api-check/api-check.swift --base <ref> [--platform P]
//
// Builds LiveKit for distribution (library evolution) at HEAD and at a base ref,
// dumps each module's API surface with `swift-api-digester -dump-sdk`, and
// diagnoses the base -> HEAD delta. Anything the digester reports is a source or
// ABI break for consumers, so the job fails; an intended break is acknowledged by
// moving the base (i.e. merging it), not by allowlisting it here.

struct APICheck: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Detect public API breakage against a base ref.")

    @Option(help: "Platform to build for, e.g. macOS or iOS. Must not contain spaces.")
    var platform = "macOS"

    @Option(help: "Git ref to compare against, e.g. origin/main.")
    var base: String

    func run() throws {
        let work = try Folder.temporary.createSubfolder(named: "api-check-\(UUID().uuidString)")
        let head = try Folder(path: shellOut(to: "git", arguments: ["rev-parse", "--show-toplevel"]))
        let baseTree = "\(work.path)base"
        defer {
            try? shellOut(to: "git", arguments: ["worktree", "remove", "--force", baseTree], at: head.path)
            try? work.delete()
        }

        try grouped("checkout \(base)") {
            try shellOut(to: "git", arguments: ["worktree", "add", "--detach", baseTree, base], at: head.path)
        }
        let old = try dump(source: baseTree, into: work, named: "base")
        let new = try dump(source: head.path, into: work, named: "head")

        let findings = try diagnose(old: old, new: new, into: work)
        guard !findings.isEmpty else {
            print("No public API breakage on \(platform).")
            return
        }
        emit(render(findings))
        print("::error::Public API breakage on \(platform) — see the job summary.")
        throw ExitCode.failure
    }

    // MARK: - Build & dump

    /// Builds `source` for distribution and returns the path of its API dump.
    private func dump(source: String, into work: Folder, named name: String) throws -> String {
        let derived = "\(work.path)dd-\(name)"
        try grouped("build \(name)") {
            do {
                try shellOut(to: "xcodebuild", arguments: [
                    "build", "-quiet",
                    "-scheme", "LiveKit",
                    "-configuration", "Release",
                    // Generic: no simulator device or runtime version to keep
                    // pinned, and no space to quote past ShellOut.
                    "-destination", "generic/platform=\(platform)",
                    "-derivedDataPath", derived,
                    // Both builds share one package cache: the WebRTC xcframework
                    // is ~0.5 GB and would otherwise be downloaded twice.
                    "-clonedSourcePackagesDirPath", "\(work.path)spm",
                    // One slice, so exactly one .swiftmodule to digest.
                    "ARCHS=arm64",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
                ], at: source)
            } catch let error as ShellOutError {
                print(error.output)
                print(error.message)
                throw ValidationError("xcodebuild build \(name) failed")
            }
        }

        let output = "\(work.path)\(name).json"
        try grouped("dump \(name)") {
            let build = try Folder(path: "\(derived)/Build")
            guard let products = try build.subfolder(named: "Products").subfolders
                .first(where: { $0.name.hasPrefix("Release") })
            else { throw ValidationError("no Release products in \(derived)") }
            // The .swiftmodule's basename is the triple it was built for.
            guard let triple = try products.subfolder(named: "LiveKit.swiftmodule").files
                .first(where: { $0.extension == "swiftmodule" })?.nameExcludingExtension
            else { throw ValidationError("no swiftmodule in \(products.path)") }
            // `Release-iphoneos` -> `iphoneos`; plain `Release` -> macOS.
            let suffix = products.name.dropFirst("Release".count).drop { $0 == "-" }
            let sdk = try shellOut(to: "xcrun", arguments: [
                "--sdk", suffix.isEmpty ? "macosx" : String(suffix), "--show-sdk-path",
            ])

            try shellOut(to: "xcrun", arguments: [
                "swift-api-digester", "-dump-sdk",
                "-module", "LiveKit",
                "-target", triple,
                "-sdk", sdk,
                "-I", products.path, "-F", products.path, "-F", "\(products.path)PackageFrameworks",
                "-abort-on-module-fail",
                "-o", output,
            ] + cModuleArguments(source: source, build: build))
            // -abort-on-module-fail still exits 0 when the module fails to load,
            // leaving an empty dump behind.
            let size = (try? FileManager.default.attributesOfItem(atPath: output))?[.size] as? Int
            guard let size, size > 0 else {
                throw ValidationError("swift-api-digester produced no dump for \(name)")
            }
        }
        return output
    }

    /// swift-api-digester can't reach `CLiveKitProto` on its own: the module lives
    /// behind the module map Xcode generates for the C target, and its headers
    /// include nanopb's `<pb.h>` by angle brackets.
    private func cModuleArguments(source: String, build: Folder) -> [String] {
        guard let intermediates = try? build.subfolder(named: "Intermediates.noindex"),
              let moduleMap = intermediates.files.recursive.first(where: { $0.name == "CLiveKitProto.modulemap" })
        else { return [] }
        return [
            "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
            "-Xcc", "-I\(source)/Sources/CLiveKitProto/include",
        ]
    }

    // MARK: - Diagnose

    /// Sections of the digester report that actually contain findings.
    private func diagnose(old: String, new: String, into work: Folder) throws -> [(section: String, lines: [String])] {
        let report = "\(work.path)report.txt"
        try grouped("diagnose") {
            try shellOut(to: "xcrun", arguments: [
                "swift-api-digester", "-diagnose-sdk",
                "-input-paths", old,
                "-input-paths", new,
                "-o", report,
            ])
        }
        // The digester exits 0 whether or not it found anything; the report is the
        // verdict. Every line is a `/* Section */` header, a blank, or a finding.
        var sections: [(String, [String])] = []
        for line in try File(path: report).readAsString().components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/*") {
                sections.append((trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/* ")), []))
            } else if !trimmed.isEmpty, !sections.isEmpty {
                sections[sections.count - 1].1.append(trimmed)
            }
        }
        return sections.filter { !$0.1.isEmpty }.map { (section: $0.0, lines: $0.1) }
    }

    // MARK: - Output

    private func render(_ findings: [(section: String, lines: [String])]) -> String {
        var md = "## 🔒 LiveKit SDK — public API breakage (`\(platform)`)\n\n"
        md += "Comparing `HEAD` against `\(base)`:\n\n"
        for finding in findings {
            md += "### \(finding.section)\n\n"
            for line in finding.lines {
                md += "- `\(line)`\n"
            }
            md += "\n"
        }
        md += "<sub>Source- or ABI-breaking for existing consumers. If intended, note it in the "
        md += "changeset and bump accordingly. Generated by `.github/api-check`.</sub>\n"
        return md
    }

    private func grouped(_ title: String, _ body: () throws -> Void) throws {
        print("::group::\(title)")
        defer { print("::endgroup::") }
        try body()
    }

    private func emit(_ markdown: String) {
        print(markdown, terminator: "")
        if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
            try? File(path: summary).append(markdown)
        }
    }
}

APICheck.main()
